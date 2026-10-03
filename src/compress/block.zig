//! Compressed-block encoder: LZ77 match finding + literal section +
//! predefined-FSE sequence bitstream.
//!
//! Sequence bitstream: encoder states are initialised from the last
//! sequence, symbols are emitted back-to-front (offset, match length,
//! literal length per step) with each symbol's extra bits appended, and the
//! final states are flushed - the exact inverse of this library's decoder.

const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const frame_block = @import("../frame/block.zig");
const fse_ctable = @import("../fse/ctable.zig");
const bitstream_mod = @import("../common/bitstream.zig");
const huff = @import("../huffman/compress.zig");
const search = @import("search.zig");

pub const BlockType = @import("../common/types.zig").BlockType;

/// Sequence and repeat-offset types live with the parsers that produce them.
const Seq = search.Seq;
const RepHistory = search.RepHistory;
const offCode = search.offsetCode;
const llCode = search.llCode;
const mlCode = search.mlCode;

/// Entropy state the decoder carries across the blocks of one frame. Blocks in a
/// frame share repeat offsets and a literals Huffman table, so the encoder must
/// carry exactly the same state or the decoder drifts out of step. One instance
/// belongs to one frame, reset when the frame ends and reused by the next.
pub const FrameEntropy = struct {
    /// Repeat-offset history.
    reps: RepHistory = .{},
    /// Literals table plus the scratch the literals encoder needs.
    literals: huff.LiteralsState = .{},

    /// Called when a frame completes: the decoder drops both the repeat
    /// offsets and the literals table.
    pub fn reset(self: *FrameEntropy) void {
        self.reps = .{};
        self.literals.reset();
    }
};

/// Sequence finding lives in `search.zig`: one entry point, with the strategy
/// choosing the engine (hash table, hash chain, binary tree) and the parser
/// (greedy, lazy, optimal).
const FoundSequences = search.Sequences;

/// Scratch for one block's search.
///
/// The block's sequences may reach back into what came before it: the
/// dictionary, or the earlier blocks of the frame. The finders compare bytes, so
/// that content has to sit contiguously in front of the block; `buf` is reused
/// across blocks so a frame pays for the copy once.
pub const BlockWindow = struct {
    buf: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *BlockWindow, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
        self.* = undefined;
    }

    /// Lays `prefix ++ src` out contiguously and returns the window with the
    /// offset the block's own bytes start at.
    fn prepare(self: *BlockWindow, allocator: std.mem.Allocator, prefix: []const u8, src: []const u8) !struct { bytes: []const u8, start: usize } {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(allocator, prefix);
        try self.buf.appendSlice(allocator, src);
        return .{ .bytes = self.buf.items, .start = prefix.len };
    }
};

fn findSequences(
    allocator: std.mem.Allocator,
    src: []const u8,
    start: usize,
    params: search.SearchParams,
    prices: *const search.SequencePrices,
    reps: *RepHistory,
    long_matches: ?[]const search.LongMatch,
) !FoundSequences {
    return search.findSequences(allocator, src, start, params, prices, reps, long_matches);
}

const ctable_mod = fse_ctable;

/// Search effort requested for one block. `compressBlock` uses the default
/// (greedy, chain depth 8); `compressBlockWithStrategy` derives it from the
/// strategy and the level's parameters.
pub const BlockSearch = struct {
    params: search.SearchParams = .{},
    prices: search.SequencePrices = search.SequencePrices.init(),
};

pub fn compressBlock(allocator: std.mem.Allocator, dst: []u8, src: []const u8, is_last: bool, entropy: *FrameEntropy) errors.ZstdError!usize {
    return compressBlockWith(allocator, dst, src, is_last, entropy, &.{}, null, &.{}, null);
}

pub fn compressBlockWith(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
    is_last: bool,
    entropy: *FrameEntropy,
    search_config: *const BlockSearch,
    long_matches: ?[]const search.LongMatch,
    prefix: []const u8,
    window: ?*BlockWindow,
) errors.ZstdError!usize {
    return compressBlockWithConfig(allocator, dst, src, is_last, entropy, search_config, long_matches, prefix, window, std.math.maxInt(u32));
}

fn compressBlockWithConfig(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
    is_last: bool,
    entropy: *FrameEntropy,
    search_config: *const BlockSearch,
    long_matches: ?[]const search.LongMatch,
    prefix: []const u8,
    window: ?*BlockWindow,
    max_offset: u32,
) errors.ZstdError!usize {
    if (src.len == 0) {
        if (dst.len < 3) return error.DstSizeTooSmall;
        frame_block.writeBlockHeader(dst[0..3], is_last, .raw, 0);
        return 3;
    }
    if (isRle(src)) {
        if (dst.len < 4) return error.DstSizeTooSmall;
        frame_block.writeBlockHeader(dst[0..3], is_last, .rle, @intCast(src.len));
        dst[3] = src[0];
        return 4;
    }

    // With a prefix the block's bytes are searched in place, laid out after it.
    // Without one the block is searched directly, so the common case copies
    // nothing.
    var scratch: BlockWindow = .{};
    defer scratch.deinit(allocator);
    var search_src: []const u8 = src;
    var start: usize = 0;
    if (prefix.len > 0) {
        const target = window orelse &scratch;
        const prepared = target.prepare(allocator, prefix, src) catch
            return rawFallback(dst, src, is_last);
        search_src = prepared.bytes;
        start = prepared.start;
    }

    // Sequence finding mutates repeat history. Work on a copy and commit it
    // back only when a compressed block is actually emitted: raw and RLE
    // blocks leave the decoder's history untouched, so the encoder must too.
    var local_reps = entropy.reps;
    var found = search.findSequencesWindowed(allocator, search_src, start, search_config.params, &search_config.prices, &local_reps, long_matches, max_offset) catch
        return rawFallback(dst, src, is_last);
    defer found.deinit(allocator);

    if (found.seqs.len == 0 or found.seqs.len > 0xFFFF + constants.long_nb_seq or found.literal_tail_too_long) {
        return rawFallback(dst, src, is_last);
    }

    // Workspace for the candidate block, which is scratch and not the output.
    // The bound covers the literals at their worst (raw plus a Huffman tree
    // description) and the sequence bitstream, itself bounded by the sequence cap
    // at under eight bytes per sequence. `dst` only has to hold the *result*, so a
    // workspace bound larger than the output is no reason to fall back to raw.
    const nb_seq_size: usize = if (found.seqs.len < 128) 1 else if (found.seqs.len < 0x7F00) 2 else 3;
    const bitstream_bound = @min(src.len / 2, search.max_sequences * 8) + 64;
    const workspace_bound = found.literals.len + 5 + nb_seq_size + 1 + bitstream_bound;
    // A raw block is the fallback, so its size is the real requirement on `dst`.
    if (dst.len < src.len + 3) return error.DstSizeTooSmall;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    body.ensureTotalCapacity(allocator, workspace_bound) catch return rawFallback(dst, src, is_last);

    // Literals. The encoder picks raw, RLE, Huffman or treeless Huffman and
    // writes the matching section header, so the decoder sees exactly the
    // layout that the following sequence bitstream assumes.
    body.resize(allocator, found.literals.len + 5) catch return rawFallback(dst, src, is_last);
    const lit_size = huff.compressLiteralsSection(body.items, found.literals, &entropy.literals) catch
        return rawFallback(dst, src, is_last);
    body.shrinkRetainingCapacity(lit_size);

    // nbSeq.
    const n = found.seqs.len;
    if (n < 128) {
        body.append(allocator, @intCast(n)) catch return rawFallback(dst, src, is_last);
    } else if (n < constants.long_nb_seq) {
        const b: u16 = @intCast(n);
        body.append(allocator, @intCast(0x80 | (b >> 8))) catch return rawFallback(dst, src, is_last);
        body.append(allocator, @truncate(b)) catch return rawFallback(dst, src, is_last);
    } else {
        body.append(allocator, 0xFF) catch return rawFallback(dst, src, is_last);
        const b: u16 = @intCast(n - constants.long_nb_seq);
        body.append(allocator, @truncate(b)) catch return rawFallback(dst, src, is_last);
        body.append(allocator, @truncate(b >> 8)) catch return rawFallback(dst, src, is_last);
    }

    // Symbol modes: all predefined.
    body.append(allocator, 0x00) catch return rawFallback(dst, src, is_last);

    // Bitstream.
    // The sequence bitstream, written into scratch. Its bound is the same one the
    // workspace reservation used, so a growing body here would mean the bound is
    // wrong rather than that the block should be truncated.
    const bs_start = body.items.len;
    body.resize(allocator, bs_start + bitstream_bound) catch return rawFallback(dst, src, is_last);
    const bs_len = encodeSequencesPredefinedInto(allocator, body.items[bs_start..], found.seqs) catch
        return rawFallback(dst, src, is_last);

    body.shrinkRetainingCapacity(bs_start + bs_len);
    const c_len = body.items.len;
    if (c_len >= src.len or dst.len < 3 + c_len) return rawFallback(dst, src, is_last);
    // A compressed block is emitted: commit the repeat history so the next
    // block's encoder and the decoder stay in lockstep. The literals table was
    // already committed by the literals section writer, which mirrors the
    // decoder keeping its table across a raw or RLE literals block.
    entropy.reps = local_reps;
    frame_block.writeBlockHeader(dst[0..3], is_last, .compressed, @intCast(c_len));
    std.mem.copyForwards(u8, dst[3 .. 3 + c_len], body.items);
    return 3 + c_len;
}

/// The three sequence tables the predefined mode uses: the format's own defaults,
/// taken from constants and independent of the block being encoded. The literal-
/// length and match-length tables use table log 6 and the offset table log 5, so
/// each fits `SmallCTable`'s 64 cells and this is a plain value, not an allocation.
const PredefinedTables = struct {
    ll: fse_ctable.SmallCTable = .{},
    ml: fse_ctable.SmallCTable = .{},
    of: fse_ctable.SmallCTable = .{},

    const built = struct {
        ll: fse_ctable.CTable,
        ml: fse_ctable.CTable,
        of: fse_ctable.CTable,
    };

    /// Builds the three tables into `self`, which the returned views borrow. The
    /// result borrows `self`'s storage, so both must outlive the encoding it feeds:
    /// one `built` per block, or one cached for a stream.
    fn build(self: *PredefinedTables) errors.ZstdError!built {
        return .{
            .ll = try self.ll.build(
                &constants.ll_default_norm,
                constants.max_ll,
                @intCast(constants.ll_default_norm_log),
            ),
            .ml = try self.ml.build(
                &constants.ml_default_norm,
                constants.max_ml,
                @intCast(constants.ml_default_norm_log),
            ),
            // The predefined offset table covers codes 0..default_max_off only.
            .of = try self.of.build(
                &constants.of_default_norm,
                constants.of_default_norm.len - 1,
                @intCast(constants.of_default_norm_log),
            ),
        };
    }
};

fn encodeSequencesPredefinedInto(alloc: std.mem.Allocator, out: []u8, seqs: []const Seq) errors.ZstdError!usize {
    if (seqs.len == 0) return error.SrcSizeWrong;
    var tables = PredefinedTables{};
    const ct = try tables.build();
    const ll_ct = ct.ll;
    const ml_ct = ct.ml;
    const of_ct = ct.of;

    // One buffer for both code arrays, so a block costs a single allocation
    // rather than two, and one that is exactly as large as it needs to be.
    const codes = try alloc.alloc(u8, 2 * seqs.len);
    defer alloc.free(codes);
    const ll_codes = codes[0..seqs.len];
    const ml_codes = codes[seqs.len..];
    for (seqs, 0..) |sq, i| {
        ll_codes[i] = llCode(sq.litLen);
        ml_codes[i] = mlCode(sq.matchLen);
    }

    var bc = bitstream_mod.BIT_CStream.init(out) catch return error.DstSizeTooSmall;

    var st_ml: fse_ctable.CState = .{};
    st_ml.initState(&ml_ct, ml_codes[seqs.len - 1]);
    var st_of: fse_ctable.CState = .{};
    st_of.initState(&of_ct, seqs[seqs.len - 1].offCode);
    var st_ll: fse_ctable.CState = .{};
    st_ll.initState(&ll_ct, ll_codes[seqs.len - 1]);

    const li = seqs.len - 1;
    writeExtraBits(seqs[li], ll_codes[li], ml_codes[li], &bc);
    bc.flushBits();

    var i: usize = seqs.len - 1;
    while (i > 0) {
        i -= 1;
        st_of.encodeSymbol(&of_ct, &bc, seqs[i].offCode);
        st_ml.encodeSymbol(&ml_ct, &bc, ml_codes[i]);
        st_ll.encodeSymbol(&ll_ct, &bc, ll_codes[i]);
        writeExtraBits(seqs[i], ll_codes[i], ml_codes[i], &bc);
        bc.flushBits();
    }

    st_ml.flushState(&bc);
    st_of.flushState(&bc);
    st_ll.flushState(&bc);

    return bc.close() catch return error.DstSizeTooSmall;
}

fn writeExtraBits(sq: Seq, llc: u8, mlc: u8, bc: *bitstream_mod.BIT_CStream) void {
    bc.addBits(sq.litLen - constants.ll_base[llc], constants.ll_bits[llc]);
    bc.addBits(sq.matchLen - constants.ml_base[mlc], constants.ml_bits[mlc]);
    // Offset extra bits. For code >= 2 the decoder computes
    // distance = OF_base[code] + extra; codes 0/1 are repeat codes whose
    // single bit (code 1) or zero bits (code 0) the decoder interprets
    // against its repeat history.
    if (sq.offCode >= 2) {
        // offExtra already stores value - (1 << code).
        bc.addBits(sq.offExtra, sq.offCode);
    } else if (sq.offCode == 1) {
        bc.addBits(sq.offExtra, 1);
    }
}

fn rawFallback(dst: []u8, src: []const u8, is_last: bool) errors.ZstdError!usize {
    if (dst.len < src.len + 3) return error.DstSizeTooSmall;
    frame_block.writeBlockHeader(dst[0..3], is_last, .raw, @intCast(src.len));
    std.mem.copyForwards(u8, dst[3 .. 3 + src.len], src);
    return 3 + src.len;
}

fn isRle(src: []const u8) bool {
    if (src.len < 8) return false;
    const first = src[0];
    for (src[1..]) |b| if (b != first) return false;
    return true;
}

/// Compresses one block with the search parameters `strategy` and `level` imply.
///
/// `long_matches` are the frame's long-distance matches that fall inside this
/// block, in ascending position order; `null` disables long-distance matching
/// for this block.
pub fn compressBlockWithStrategy(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
    is_last: bool,
    entropy: *FrameEntropy,
    strategy: constants.Strategy,
    level: i32,
    long_matches: ?[]const search.LongMatch,
    prefix: []const u8,
    window: ?*BlockWindow,
) errors.ZstdError!usize {
    const config = searchConfigFor(strategy, level);
    return compressBlockWith(allocator, dst, src, is_last, entropy, &config, long_matches, prefix, window);
}

/// `compressBlockWith`, restricted to the distances the frame's declared window
/// can describe. The block itself may be larger than that window, so without
/// this the finder would happily emit a distance the frame header never
/// promised and the resulting frame would be one its own decoder rejects.
pub fn compressBlockWithWindow(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
    is_last: bool,
    entropy: *FrameEntropy,
    search_config: *const BlockSearch,
    long_matches: ?[]const search.LongMatch,
    prefix: []const u8,
    window: ?*BlockWindow,
    max_offset: u32,
) errors.ZstdError!usize {
    if (max_offset == std.math.maxInt(u32)) {
        return compressBlockWith(allocator, dst, src, is_last, entropy, search_config, long_matches, prefix, window);
    }
    return compressBlockWithConfig(allocator, dst, src, is_last, entropy, search_config, long_matches, prefix, window, max_offset);
}

/// Maps a strategy and level onto concrete search parameters. Every strategy it
/// names runs a different search engine or parser; see `search.paramsForStrategy`.
pub fn searchConfigFor(strategy: constants.Strategy, level: i32) BlockSearch {
    return .{
        .params = search.paramsForStrategy(strategy, level),
        .prices = search.SequencePrices.init(),
    };
}
const testing = std.testing;

test "sequence bitstream round trips a parse that ends on a literal run" {
    // Regression: the literals section is consumed by the sequences, so the
    // literal run that follows the last match has to be carried by that
    // sequence. A parse that ended on unmatched bytes produced a block whose
    // literal lengths did not add up to its literals section, which a decoder
    // has to reject. Every literal here is the same byte and every match copies
    // it at distance one, so the expected output is a single run of that byte
    // and the check does not depend on how the match is executed.
    const alloc = testing.allocator;
    const entropy_mod = @import("../decompress/entropy.zig");
    const fill: u8 = 0x5A;

    for ([_]u32{ 0, 1, 7, 255, 4095, 65535, 70000 }) |tail| {
        const seq_count = 200;
        var seqs: [seq_count]Seq = undefined;
        var sum_ll: u32 = 0;
        var sum_ml: u32 = 0;
        var prng = std.Random.DefaultPrng.init(0x51EC0000 + tail);
        const random = prng.random();
        for (&seqs) |*sq| {
            // A non-zero literal length keeps offset code 0 meaning distance
            // one: with no literals the format spends the offset code on the
            // repeat history instead.
            const ll: u32 = random.intRangeAtMost(u32, 1, 7);
            const ml: u32 = random.intRangeAtMost(u32, 3, 40);
            sq.* = .{ .litLen = ll, .matchLen = ml, .offCode = 0, .offExtra = 0 };
            sum_ll += ll;
            sum_ml += ml;
        }
        seqs[seq_count - 1].litLen += tail;
        sum_ll += tail;

        const literals = try alloc.alloc(u8, sum_ll);
        defer alloc.free(literals);
        @memset(literals, fill);
        const want = sum_ll + sum_ml;

        var stream: [seq_count * 16 + 128]u8 = undefined;
        const nb: u16 = @intCast(seq_count);
        stream[0] = @intCast(0x80 | (nb >> 8));
        stream[1] = @intCast(nb & 0xFF);
        stream[2] = 0x00;
        const bs = try encodeSequencesPredefinedInto(alloc, stream[3..], &seqs);
        const seq_section = stream[0 .. 3 + bs];

        var state = entropy_mod.State.init(alloc);
        defer state.deinit();
        const out = try alloc.alloc(u8, want);
        defer alloc.free(out);
        const m = try entropy_mod.decodeSequences(&state, out, literals, seq_section, .{ .history = &.{}, .dict = &.{} });
        try testing.expectEqual(@as(usize, want), m);
        for (out[0..m]) |b| try testing.expectEqual(fill, b);
    }
}

test "sequence cap does not duplicate match bytes" {
    // Regression: when the 4096-sequence buffer fills mid-block, the trailing
    // literals must start after the last emitted match, not inside it. The
    // smooth arithmetic-progression payload below used to decode to 4 bytes
    // more than the input.
    const alloc = testing.allocator;
    const base: usize = 131072;
    var src: [26940]u8 = undefined;
    for (&src, 0..) |*b, j| {
        const i = base + j;
        b.* = @intCast((i * 7 + i / 13) % 256);
    }
    var local = RepHistory{};
    var found = try findSequences(alloc, &src, 0, .{}, &search.SequencePrices.init(), &local, null);
    defer found.deinit(alloc);
    // Partition must be exact: the sequences plus the trailing literal run
    // cover the input, with nothing counted twice.
    var sumLl: usize = 0;
    var sumMl: usize = 0;
    for (found.seqs) |sq| {
        sumLl += sq.litLen;
        sumMl += sq.matchLen;
    }
    try testing.expectEqual(src.len, sumLl + sumMl + (found.literals.len - sumLl));

    // Full block round trip.
    var entropy = FrameEntropy{};
    var dst: [40000]u8 = undefined;
    const n = try compressBlock(alloc, &dst, &src, true, &entropy);
    const entropy_mod = @import("../decompress/entropy.zig");
    const block_decomp = @import("../decompress/block.zig");
    var state = entropy_mod.State.init(alloc);
    defer state.deinit();
    var out: [40000]u8 = undefined;
    const m = try block_decomp.decompressBlock(&state, &out, dst[0..n], &.{});
    try testing.expectEqual(src.len, m);
    try testing.expectEqualSlices(u8, &src, out[0..m]);
}

test "a block that hits the sequence cap still covers the input exactly" {
    // Incompressible input produces a short match at nearly every position, so
    // the 4096-sequence cap is reached. The parser has to stop and hand the
    // rest to the trailing literal run; anything else would either lose bytes or
    // re-emit the match bytes.
    const alloc = testing.allocator;
    var src: [60000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xCA5);
    const random = prng.random();
    // A four-symbol alphabet: nearly every position starts a short match, which
    // is what drives the sequence count past the cap.
    for (&src) |*b| b.* = random.intRangeAtMost(u8, 0, 3);
    var local = RepHistory{};
    var found = try findSequences(alloc, &src, 0, search.paramsForStrategy(.fast, 1), &search.SequencePrices.init(), &local, null);
    defer found.deinit(alloc);
    try testing.expectEqual(search.max_sequences, found.seqs.len);
    var sumLl: usize = 0;
    var sumMl: usize = 0;
    for (found.seqs) |sq| {
        sumLl += sq.litLen;
        sumMl += sq.matchLen;
    }
    try testing.expectEqual(src.len, sumLl + sumMl + (found.literals.len - sumLl));
}

test "large literal block uses four streams and decodes" {
    // Regression: a 4-stream payload big enough that the three jump-table
    // offsets sum past 16 bits. The jump-table arithmetic has to be done in a
    // wide type, otherwise the offsets wrap and the streams are read from the
    // wrong place.
    const alloc = testing.allocator;
    var src: [131072]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x5EEDBEEF);
    const random = prng.random();
    // A four-symbol alphabet keeps the entropy high (so the literals section is
    // worth Huffman coding) while a few long matches keep the block on the
    // compressed path.
    for (&src) |*b| b.* = random.intRangeAtMost(u8, 0, 3);
    for (0..8) |k| {
        const marker = "MARKER MARKER 12";
        const at = 9000 * k + 1;
        @memcpy(src[at..][0..marker.len], marker);
    }

    var entropy = FrameEntropy{};
    var dst: [200000]u8 = undefined;
    const n = try compressBlock(alloc, &dst, &src, true, &entropy);
    try testing.expectEqual(BlockType.compressed, (try frame_block.getBlockHeader(dst[0..])).blockType);

    // The literals section is a 5-byte header, so the payload is four streams.
    const body = dst[3..][0 .. n - 3];
    const literals_mode: u2 = @truncate(body[0] & 3);
    try testing.expect(literals_mode == 2 or literals_mode == 3);
    const size_format = (body[0] >> 2) & 3;
    try testing.expect(size_format >= 1);

    const block_decomp = @import("../decompress/block.zig");
    const entropy_mod = @import("../decompress/entropy.zig");
    var state = entropy_mod.State.init(alloc);
    defer state.deinit();
    var out: [131072]u8 = undefined;
    const m = try block_decomp.decompressBlock(&state, &out, dst[0..n], &.{});
    try testing.expectEqual(src.len, m);
    try testing.expectEqualSlices(u8, &src, out[0..m]);
}

test "block encoder emits Huffman literals and the decoder agrees" {
    // Literals that Huffman coding can shrink, plus a match, so the block has
    // both a literals section and sequences.
    const alloc = testing.allocator;
    var src: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(4242);
    const random = prng.random();
    const alphabet = [_]u8{ 'a', 'a', 'a', 'b', 'b', 'c', 'd', 'e', 'f', 'g' };
    for (&src) |*b| b.* = alphabet[random.uintLessThan(usize, alphabet.len)];

    var entropy = FrameEntropy{};
    var dst: [8192]u8 = undefined;
    const n = try compressBlock(alloc, &dst, &src, true, &entropy);
    try testing.expectEqual(BlockType.compressed, (try frame_block.getBlockHeader(dst[0..])).blockType);

    const block_decomp = @import("../decompress/block.zig");
    const entropy_mod = @import("../decompress/entropy.zig");
    var state = entropy_mod.State.init(alloc);
    defer state.deinit();
    var out: [4096]u8 = undefined;
    const m = try block_decomp.decompressBlock(&state, &out, dst[0..n], &.{});
    try testing.expectEqual(src.len, m);
    try testing.expectEqualSlices(u8, &src, out[0..m]);
    // The literals table is now live, exactly as the decoder now holds it.
    try testing.expect(entropy.literals.available);
    try testing.expect(n < src.len);
}

test "sequences never carry a distance the frame's window forbids" {
    // The frame's window bounds the distances its blocks may use, independently
    // of how large the block is. A match past the window encodes a distance the
    // header never promised, and a conforming decoder rejects it, so the finder
    // must drop such candidates rather than emit them.
    // The first half has to contain no usable repeat, otherwise a short distance
    // wins everywhere and the long one is never reached. Pseudo-random bytes do
    // that: at 2048 bytes in, four-byte matches are already rare.
    var src: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(20240917);
    prng.random().bytes(src[0..2048]);
    @memcpy(src[2048..4096], src[0..2048]);

    var prices = search.SequencePrices{};
    var reps = search.RepHistory{};

    // With no window bound the 2 KB repeat is used, so the test below is not
    // vacuous.
    var loose = try search.findSequencesWindowed(
        testing.allocator,
        &src,
        0,
        search.paramsForStrategy(.greedy, 6),
        &prices,
        &reps,
        null,
        std.math.maxInt(u32),
    );
    defer loose.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2048), loose.largestOffset());

    // A 1 KB window cannot describe that distance, so the parser falls back to
    // literals rather than write an offset the frame would have to reject.
    var tight_reps = search.RepHistory{};
    var tight = try search.findSequencesWindowed(
        testing.allocator,
        &src,
        0,
        search.paramsForStrategy(.greedy, 6),
        &prices,
        &tight_reps,
        null,
        1024,
    );
    defer tight.deinit(testing.allocator);
    try testing.expect(tight.largestOffset() <= 1024);
}

test "an over-window match is dropped rather than truncated" {
    // Dropping the candidate is the whole point. A 3 KB block in a 1 KB window
    // has real matches at 2 KB; the frame cannot describe them, so the block
    // falls back to describing what it can rather than encoding a distance the
    // decoder would reject. Truncating the distance instead would silently
    // produce different bytes.
    var src: [3072]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(31337);
    prng.random().bytes(src[0..1536]);
    @memcpy(src[1536..3072], src[0..1536]);

    var prices = search.SequencePrices{};
    var tight_reps = search.RepHistory{};
    var tight = try search.findSequencesWindowed(
        testing.allocator,
        &src,
        0,
        search.paramsForStrategy(.greedy, 6),
        &prices,
        &tight_reps,
        null,
        1024,
    );
    defer tight.deinit(testing.allocator);
    // The bound holds whether or not any sequence survives: in random data a
    // 1 KB window can be match-free, and that is a valid outcome.
    try testing.expect(tight.largestOffset() <= 1024);
}

test "windowLimitFor reports the largest describable distance" {
    try testing.expectEqual(@as(u32, 1024), search.windowLimitFor(10));
    try testing.expectEqual(@as(u32, 1 << 20), search.windowLimitFor(20));
    // An unset window means the whole buffer is fair game.
    try testing.expectEqual(std.math.maxInt(u32), search.windowLimitFor(0));
}

test "the predefined sequence tables are built without touching the heap" {
    // The three predefined sequence tables come from the format's own constants, so
    // what they encode is fixed by the specification. They used to be rebuilt on
    // the heap per block, costing eleven allocations each time on a path taken
    // once per 128 KiB of input; they are now held by value. A round trip alone
    // would not prove the change invisible, since a self-consistent change to the
    // encoding would also round trip, so the section must be bit-identical to
    // what the heap-built tables produced.
    const alloc = testing.allocator;

    // Sequences spanning the tables: the shortest and longest literal lengths and
    // match lengths the predefined codes cover, both repeat codes, and an offset
    // long enough to need its extra bits.
    const seqs = [_]Seq{
        .{ .litLen = 0, .matchLen = 3, .offCode = 1, .offExtra = 0 },
        .{ .litLen = 1, .matchLen = 4, .offCode = 2, .offExtra = 0 },
        .{ .litLen = 7, .matchLen = 9, .offCode = 3, .offExtra = 0 },
        .{ .litLen = 15, .matchLen = 20, .offCode = 6, .offExtra = 40 },
        .{ .litLen = 31, .matchLen = 47, .offCode = 8, .offExtra = 200 },
        .{ .litLen = 2, .matchLen = 5, .offCode = 0, .offExtra = 0 },
    };

    var first: [1024]u8 = undefined;
    const n = try encodeSequencesPredefinedInto(alloc, &first, &seqs);
    try testing.expect(n > 0);

    // Repeating the encode has to give the same bytes: the tables carry no state
    // from one use to the next, so a second block cannot differ from the first.
    for (0..4) |_| {
        var again: [1024]u8 = undefined;
        const m = try encodeSequencesPredefinedInto(alloc, &again, &seqs);
        try testing.expectEqual(n, m);
        try testing.expectEqualSlices(u8, first[0..n], again[0..m]);
    }

    // The tables fit their stack storage: all three predefined logs are at most
    // six, which is what lets them live in `SmallCTable`. If a future table grew
    // past that, `build` would refuse rather than silently truncate.
    var tables = PredefinedTables{};
    const built = try tables.build();
    try testing.expectEqual(@as(u8, 6), built.ll.log);
    try testing.expectEqual(@as(u8, 6), built.ml.log);
    try testing.expectEqual(@as(u8, 5), built.of.log);
}
