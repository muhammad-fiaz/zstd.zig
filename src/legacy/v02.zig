//! Support for legacy Zstandard v0.2 frames.

const std = @import("std");
const bits = @import("../common/bits.zig");
const bitstream = @import("../common/bitstream.zig");
const errors = @import("../common/errors.zig");
const huffman = @import("huffman.zig");
const sequences = @import("sequences.zig");
const decoder = @import("decoder.zig");
const format = @import("format.zig");

pub const magic: u32 = 0xFD2FB522;
pub const version: format.Version = .v02;

/// The smallest a compressed block can be: five bytes of literal header plus a
/// one-byte "no sequences" marker.
const min_compressed_block_size: usize = 8;

// Decoding

/// The literals a block regenerated, and how many bytes of the block they took.
const Literals = struct {
    bytes: []const u8,
    read: usize,
};

/// Reads a block's literals section into `scratch`.
///
/// `scratch` must hold `format.block_size_max` bytes: every historic reader bounds
/// the literal section at 128 KB, and a size above that is corruption in all seven
/// versions.
fn readLiterals(
    ver: format.Version,
    allocator: std.mem.Allocator,
    scratch: []u8,
    src: []const u8,
) errors.ZstdError!Literals {
    if (src.len < min_compressed_block_size) return error.Corruption;
    if (ver.hasScaledLiteralHeader()) return readScaledLiterals(allocator, scratch, src);
    return readFixedLiterals(ver, allocator, scratch, src);
}

/// The header v0.1 through v0.4 write: the section type in the low two bits, and
/// a fixed width of sizes behind it.
fn readFixedLiterals(
    ver: format.Version,
    allocator: std.mem.Allocator,
    scratch: []u8,
    src: []const u8,
) errors.ZstdError!Literals {
    const kind = @as(u2, @truncate(src[0]));
    switch (kind) {
        1 => {
            // Raw: the literals sit three bytes into the block. They are copied
            // out so a sequence writing into the output cannot overwrite literals
            // a later sequence still needs.
            const size: usize = (bits.readLe32(src[0..4]) & 0xFFFFFF) >> 2;
            if (size > scratch.len) return error.Corruption;
            if (size > src.len - 3) return error.Corruption;
            @memcpy(scratch[0..size], src[3..][0..size]);
            return .{ .bytes = scratch[0..size], .read = size + 3 };
        },
        2 => {
            const size: usize = (bits.readLe32(src[0..4]) & 0xFFFFFF) >> 2;
            if (size > scratch.len) return error.Corruption;
            if (src.len < 4) return error.Corruption;
            @memset(scratch[0..size], src[3]);
            return .{ .bytes = scratch[0..size], .read = 4 };
        },
        0 => {},
        // Type 3 is a nominal case no encoder emits, and the two families treat it
        // differently. v0.1 to v0.3 put the switch's `default` label on the
        // compressed arm, so type 3 decodes as compressed there. v0.4 gave the
        // switch an explicit `default` that reports corruption instead, and v0.5 on
        // kept that. Accepting it either way would mean decoding a section the
        // reference would have refused, so the version decides.
        3 => if (ver.rejectsLiteralType3()) {
            return error.Corruption;
        },
    }
    {
        const size: usize = (bits.readLe32(src[0..4]) & 0x1FFFFF) >> 2;
        const csize: usize = (bits.readLe32(src[2..6]) & 0xFFFFFF) >> 5;
        if (size > scratch.len) return error.Corruption;
        if (csize + 5 > src.len) return error.Corruption;
        try decompressLiterals(allocator, scratch[0..size], src[5..][0..csize]);
        return .{ .bytes = scratch[0..size], .read = csize + 5 };
    }
}

/// The header v0.5 introduced: the section type moves to the top two bits and
/// both sizes are written in a scaled form whose width the header itself names.
///
/// Where v0.2 spent a fixed five bytes on a compressed section, this spends three,
/// four or five, chosen by a two-bit code, and the two sizes share whatever width
/// is left over: 10 and 10 bits, 14 and 14, or 18 and 18. A raw or RLE section
/// spends one, two or three bytes the same way, carrying only one size. The code
/// reads `0` and `1` alike as the narrowest form, exactly as the reference does.
fn readScaledLiterals(
    allocator: std.mem.Allocator,
    scratch: []u8,
    src: []const u8,
) errors.ZstdError!Literals {
    const kind = src[0] >> 6;
    const code = (src[0] >> 4) & 3;
    switch (kind) {
        // Huffman-coded: the flag in bit 4 says whether the section is one stream
        // or the four the earlier versions always use.
        0 => {
            const narrow = code <= 1;
            var header: usize = 3;
            var lit_size: usize = 0;
            var c_size: usize = 0;
            var single_stream = false;
            if (narrow) {
                if (src.len < 3) return error.Corruption;
                single_stream = (src[0] & 16) != 0;
                lit_size = (@as(usize, src[0] & 15) << 6) + (src[1] >> 2);
                c_size = (@as(usize, src[1] & 3) << 8) + src[2];
            } else if (code == 2) {
                header = 4;
                if (src.len < 4) return error.Corruption;
                lit_size = (@as(usize, src[0] & 15) << 10) + (@as(usize, src[1]) << 2) + (src[2] >> 6);
                c_size = (@as(usize, src[2] & 63) << 8) + src[3];
            } else {
                header = 5;
                if (src.len < 5) return error.Corruption;
                lit_size = (@as(usize, src[0] & 15) << 14) + (@as(usize, src[1]) << 6) + (src[2] >> 2);
                c_size = (@as(usize, src[2] & 3) << 16) + (@as(usize, src[3]) << 8) + src[4];
            }
            if (lit_size > scratch.len) return error.Corruption;
            if (c_size + header > src.len) return error.Corruption;
            const body = src[header..][0..c_size];
            if (single_stream) {
                try decompressLiterals1X(allocator, scratch[0..lit_size], body);
            } else {
                try decompressLiterals(allocator, scratch[0..lit_size], body);
            }
            return .{ .bytes = scratch[0..lit_size], .read = c_size + header };
        },
        // Pre-computed Huffman with a dictionary: only the narrowest header is
        // defined, and it needs a dictionary this reader does not have.
        1 => return error.DictionaryCorrupted,
        2 => {
            const size = readScaledSize(src, code, 1) catch return error.Corruption;
            const header: usize = scaledSizeHeaderSize(code);
            if (size > scratch.len) return error.Corruption;
            if (size + header > src.len) return error.Corruption;
            @memcpy(scratch[0..size], src[header..][0..size]);
            return .{ .bytes = scratch[0..size], .read = size + header };
        },
        3 => {
            const size = readScaledSize(src, code, 1) catch return error.Corruption;
            const header: usize = scaledSizeHeaderSize(code);
            if (size > scratch.len) return error.Corruption;
            if (header > src.len) return error.Corruption;
            @memset(scratch[0..size], src[header]);
            return .{ .bytes = scratch[0..size], .read = header + 1 };
        },
        else => unreachable,
    }
}

/// How many bytes a raw or RLE header of this width occupies.
fn scaledSizeHeaderSize(code: u8) usize {
    return switch (code) {
        0, 1 => 1,
        2 => 2,
        else => 3,
    };
}

/// The one size a raw or RLE header carries, in the width its code names.
fn readScaledSize(src: []const u8, code: u8, header: usize) errors.ZstdError!usize {
    return switch (code) {
        0, 1 => blk: {
            if (src.len < header) return error.Corruption;
            break :blk @as(usize, src[0] & 31);
        },
        2 => blk: {
            if (src.len < 2) return error.Corruption;
            break :blk (@as(usize, src[0] & 15) << 8) + src[1];
        },
        else => blk: {
            if (src.len < 3) return error.Corruption;
            break :blk (@as(usize, src[0] & 15) << 16) + (@as(usize, src[1]) << 8) + src[2];
        },
    };
}

/// The reference's `HUF_decompress`: three shapes short of any table work.
///
/// These matter more than they look. A literal section whose compressed size equals
/// its expanded size is stored verbatim, and one byte is a single repeated byte. A
/// reader that built a table for either would reject the section, because there is
/// no table description to build one from.
fn decompressLiterals(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
) errors.ZstdError!void {
    if (try huffman.decompressFrontEndChecks(dst.len, src.len)) |shape| {
        switch (shape) {
            .copy => @memcpy(dst, src),
            .rle => @memset(dst, src[0]),
        }
        return;
    }
    _ = try huffman.decompress4X(allocator, dst, src);
}

/// The single-stream shape v0.5's literals header can select: the same front-end
/// checks, then one flat table over one bitstream.
fn decompressLiterals1X(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
) errors.ZstdError!void {
    if (try huffman.decompressFrontEndChecks(dst.len, src.len)) |shape| {
        switch (shape) {
            .copy => @memcpy(dst, src),
            .rle => @memset(dst, src[0]),
        }
        return;
    }
    _ = try huffman.decompress1X(allocator, dst, src);
}

/// The size of a v0.2 frame, or `error.SrcSizeWrong` when it is cut short.
///
/// v0.2 has no content size and no checksum, so a frame's length is knowable only
/// by walking its blocks to the end marker.
pub fn findFrameSize(allocator: std.mem.Allocator, src: []const u8) errors.ZstdError!usize {
    return findFrameSizeFor(version, allocator, src);
}

/// `findFrameSize` for an explicit version. v0.2 and v0.3 share this entirely: a
/// line-by-line comparison of the two references shows the only format difference
/// between them is the magic number and the initial repeat offset, neither of which
/// affects a frame's length.
pub fn findFrameSizeFor(
    ver: format.Version,
    allocator: std.mem.Allocator,
    src: []const u8,
) errors.ZstdError!usize {
    _ = allocator;
    if (src.len < 4) return error.SrcSizeWrong;
    const header = try format.readFrameHeader(ver, src);
    var pos = header.size;
    while (true) {
        const block = try format.readBlockHeader(src[pos..]);
        pos += format.block_header_size + block.block_type.payloadLen(block.size);
        if (block.block_type == .end) return pos;
        if (pos > src.len) return error.SrcSizeWrong;
    }
}

/// Decodes a v0.2 frame into `dst`.
///
/// A block's regenerated size is recorded nowhere in v0.2, so this is driven by the
/// sections themselves: the literals say how many bytes there are, and the
/// sequences say how many matches to apply to them.
pub fn decompress(allocator: std.mem.Allocator, dst: []u8, src: []const u8) errors.ZstdError!decoder.Result {
    return decompressFor(version, allocator, dst, src);
}

/// `decompress` for an explicit version. Everything except the frame header and the
/// sequence section's starting repeat offset is shared with v0.2, so v0.3 reuses
/// this rather than copying it: two copies of a decoder would drift, and the only
/// way to know they have not is to not have them.
pub fn decompressFor(
    ver: format.Version,
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
) errors.ZstdError!decoder.Result {
    const header = try format.readFrameHeader(ver, src);
    var pos = header.size;
    var out: usize = 0;

    const scratch = try allocator.alloc(u8, format.block_size_max);
    defer allocator.free(scratch);

    while (true) {
        const block = try format.readBlockHeader(src[pos..]);
        pos += format.block_header_size;
        switch (block.block_type) {
            .end => {
                // The reference requires the end block to be the frame's last byte:
                // trailing bytes mean the frame was cut short, or two frames were
                // concatenated with nothing between them.
                if (pos != src.len) return error.SrcSizeWrong;
                return .{ .decoded = out, .consumed = pos };
            },
            .raw => {
                if (src.len < pos + block.size) return error.SrcSizeWrong;
                if (dst.len < out + block.size) return error.DstSizeTooSmall;
                @memcpy(dst[out..][0..block.size], src[pos..][0..block.size]);
                out += block.size;
                pos += block.size;
            },
            .rle => {
                // Every reference reader refuses RLE blocks at the frame level.
                // Expanding them is a strict superset: no historic encoder emitted
                // one, so no real frame depends on the refusal.
                if (src.len < pos + 1) return error.SrcSizeWrong;
                if (block.size > format.block_size_max) return error.Corruption;
                if (dst.len < out + block.size) return error.DstSizeTooSmall;
                @memset(dst[out..][0..block.size], src[pos]);
                out += block.size;
                pos += 1;
            },
            .compressed => {
                if (src.len < pos + block.size) return error.SrcSizeWrong;
                const produced = try decompressCompressed(
                    ver,
                    allocator,
                    dst[out..],
                    scratch,
                    src[pos..][0..block.size],
                );
                out += produced;
                pos += block.size;
            },
        }
    }
}

fn decompressCompressed(
    ver: format.Version,
    allocator: std.mem.Allocator,
    dst: []u8,
    scratch: []u8,
    block: []const u8,
) errors.ZstdError!usize {
    const literals = try readLiterals(ver, allocator, scratch, block);
    if (literals.read > block.len) return error.SrcSizeWrong;
    return sequences.decompressSequences(
        ver,
        allocator,
        // `frame_start = 0` because a match may reach back into any earlier byte of
        // the frame, including those of previous blocks.
        .{ .dst = dst, .base = 0, .frame_start = 0 },
        literals.bytes,
        block[literals.read..],
    );
}

// Huffman code construction

/// One literal's code.
pub const Code = struct {
    bits: u32,
    nb_bits: u32,
};

/// The code assignment for one literal section, plus the weights that describe it.
pub const Assignment = struct {
    codes: [huffman.max_symbol + 1]Code = @splat(.{ .bits = 0, .nb_bits = 0 }),
    /// Explicit weights for symbols `0..count - 1`; symbol `count`'s weight is
    /// derived by the reader.
    weights: [huffman.max_symbol + 2]u8 = @splat(0),
    /// One past the highest symbol in use.
    count: usize = 0,
    max_bits: u8 = 0,
};

/// Builds code lengths for `data`'s byte histogram and derives the codes.
///
/// Lengths come from a Huffman tree over the bytes that occur, so the Kraft sum is
/// exactly one and the reader's implied final weight lands on the right symbol.
/// The codes then come from the reader's own slot formula rather than from a
/// canonical assignment, which is what makes the two halves agree by construction.
fn assignCodes(out: *Assignment, data: []const u8) errors.ZstdError!void {
    var counts: [huffman.max_symbol + 1]u32 = @splat(0);
    for (data) |b| counts[b] += 1;

    var present: [huffman.max_symbol + 1]u8 = undefined;
    var n_present: usize = 0;
    for (counts, 0..) |c, sym| {
        if (c != 0) {
            present[n_present] = @intCast(sym);
            n_present += 1;
        }
    }
    // One distinct symbol has no code at all: a Huffman table whose every literal
    // is the same byte is what the repeated-literal form is for.
    if (n_present < 2) return error.InvalidHuffmanTable;

    const lengths = try huffmanLengths(&counts, present[0..n_present]);

    var max_bits: u8 = 0;
    for (lengths) |l| max_bits = @max(max_bits, l);
    if (max_bits > huffman.max_table_log or max_bits < 1) return error.InvalidHuffmanTable;

    // The highest symbol in use has its weight left implicit: the reader derives
    // it from the total, so the explicit list stops *before* it.
    var highest: usize = 0;
    for (counts, 0..) |c, sym| {
        if (c != 0) highest = sym;
    }
    if (highest >= huffman.max_symbol) return error.InvalidHuffmanTable;
    out.count = highest;

    // Weight per symbol, and how many symbols share each weight.
    var weight: [huffman.max_symbol + 1]u8 = @splat(0);
    var per_weight: [huffman.max_table_log + 1]u32 = @splat(0);
    for (lengths, 0..) |l, sym| {
        if (counts[sym] == 0) continue;
        weight[sym] = @intCast(max_bits + 1 - l);
        per_weight[weight[sym]] += 1;
    }

    // The slot formula the reader uses, computed here so the codes match.
    var start: [huffman.max_table_log + 1]u32 = @splat(0);
    var at: u32 = 0;
    var w: usize = 1;
    while (w <= max_bits) : (w += 1) {
        start[w] = at;
        at += per_weight[w] << @intCast(w - 1);
    }
    // Kraft check: the slots must exactly fill the table.
    if (at != (@as(u32, 1) << @intCast(max_bits))) return error.InvalidHuffmanTable;

    var rank: [huffman.max_table_log + 1]u32 = @splat(0);
    for (weight, 0..) |wv, sym| {
        if (wv == 0) continue;
        const code_len = max_bits + 1 - wv;
        // The slot a weight-`w` symbol occupies is `2^(w-1)` entries wide, so the
        // first entry of weight `w`'s run divided by that width is the code the
        // decoder will read at the top of its window. The rank then counts symbols
        // of the same weight in symbol order. Dividing first and adding after is
        // what makes the two agree: the run's start is always a whole number of
        // widths, which the Kraft equality above is what guarantees.
        out.codes[sym] = .{
            .bits = (start[wv] >> @intCast(wv - 1)) + rank[wv],
            .nb_bits = code_len,
        };
        rank[wv] += 1;
    }

    out.max_bits = max_bits;
    for (0..out.count) |sym| out.weights[sym] = weight[sym];
    // The implied symbol's weight is not written, but it is recorded here so a
    // test can check that the reader would derive the same value.
    out.weights[out.count] = weight[out.count];
}

/// Huffman code lengths for the symbols that occur, by repeated merge of the two
/// least frequent nodes.
///
/// With at most 256 distinct symbols a linear scan for the two smallest is a few
/// tens of thousands of comparisons, which is far cheaper than maintaining a heap
/// for the handful of literals a block usually holds. Merging records a parent
/// link, and the code length of a leaf is then the number of links above it.
fn huffmanLengths(
    counts: *const [huffman.max_symbol + 1]u32,
    present: []const u8,
) errors.ZstdError![huffman.max_symbol + 1]u8 {
    const max_nodes = 2 * huffman.max_symbol + 1;
    const Node = struct { weight: u32, symbol: u16 };
    const none = std.math.maxInt(usize);

    var nodes: [max_nodes]Node = undefined;
    var parent: [max_nodes]usize = @splat(none);
    var alive: [max_nodes]bool = @splat(true);

    for (present, 0..) |sym, i| nodes[i] = .{ .weight = counts[sym], .symbol = sym };

    var n_alive = present.len;
    var nxt = present.len;
    while (n_alive > 1) {
        // The two lightest alive nodes, ties broken by position so the tree is
        // deterministic and the encoder's output is reproducible.
        var a: usize = none;
        var b: usize = none;
        for (0..nxt) |i| {
            if (!alive[i]) continue;
            if (a == none or nodes[i].weight < nodes[a].weight) {
                b = a;
                a = i;
            } else if (b == none or nodes[i].weight < nodes[b].weight) {
                b = i;
            }
        }
        if (a == none or b == none or nxt >= max_nodes) return error.InvalidHuffmanTable;
        alive[a] = false;
        alive[b] = false;
        nodes[nxt] = .{ .weight = nodes[a].weight + nodes[b].weight, .symbol = 0 };
        parent[a] = nxt;
        parent[b] = nxt;
        alive[nxt] = true;
        n_alive -= 1;
        nxt += 1;
    }
    if (nxt == 0 or present.len == 0) return error.InvalidHuffmanTable;
    const root = nxt - 1;

    var lengths: [huffman.max_symbol + 1]u8 = @splat(0);
    for (present, 0..) |sym, i| {
        var depth: usize = 0;
        var walk = i;
        while (walk != root) {
            walk = parent[walk];
            if (walk == none) return error.InvalidHuffmanTable;
            depth += 1;
            if (depth > huffman.max_table_log) return error.InvalidHuffmanTable;
        }
        if (depth == 0 or depth > huffman.max_table_log) return error.InvalidHuffmanTable;
        lengths[sym] = @intCast(depth);
    }
    return lengths;
}

// Encoding

/// Worst-case bytes a v0.2 frame needs for `src_size` input bytes.
///
/// One block holds at most `format.block_size_max` input bytes, and a compressed
/// block is bounded by its literals section plus its sequence section. Both can
/// exceed their input, so the bound leaves room for the worst case and the encoder
/// falls back to a raw block whenever the compressed form would not be smaller.
/// Builds a compressed block into `dst`, or returns null when a raw block would be
/// smaller - in which case the caller writes raw instead.
fn buildBlock(
    ver: format.Version,
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
) errors.ZstdError!?usize {
    // Below this size a compressed block cannot beat a raw one: its own headers
    // cost more than the literals they replace.
    if (src.len < 64) return null;

    const scratch = try allocator.alloc(u8, format.block_size_max);
    defer allocator.free(scratch);

    const arena = try allocator.alloc(u8, src.len);
    defer allocator.free(arena);
    const seq_storage = try allocator.alloc(sequences.Sequence, src.len / format.min_match + 2);
    defer allocator.free(seq_storage);
    const parsed = try parseBlock(allocator, src, arena, seq_storage);

    var pos: usize = 0;
    pos += try writeLiterals(dst[pos..], scratch, parsed.literals);
    const seq_section = sequences.encodeSequences(ver, dst[pos..], parsed.sequences, .{}) catch |e| switch (e) {
        error.DstSizeTooSmall => return null,
        else => return e,
    };
    pos += seq_section;

    // A compressed block that did not beat its input is not worth emitting.
    if (pos >= src.len) return null;
    return pos;
}

/// The result of parsing one block into literals and sequences.
const Parsed = struct {
    literals: []const u8,
    sequences: []const sequences.Sequence,
};

/// The parse's workspace: the literals, then room for the sequences. The hash
/// table is allocated separately because it is sized by the hash, not by the
/// block.
/// A greedy longest-match parse over `src`.
///
/// Literals accumulate until a match of at least the minimum length is found, at
/// which point one sequence is emitted carrying those literals and the match, and
/// the search resumes behind it. A match has to be worth a sequence: four bytes is
/// the format's floor, because a decoded match length is the coded value plus the
/// minimum.
///
/// The match search is a hash chain over four-byte prefixes with a bounded chain
/// length. That is deliberately the simple version - what the format needs
/// exercised is the round trip, not the ratio - but a linear scan would be
/// quadratic, which a 128 KB block would notice.
fn parseBlock(
    allocator: std.mem.Allocator,
    src: []const u8,
    workspace: []u8,
    seq_out: []sequences.Sequence,
) errors.ZstdError!Parsed {
    const literals = workspace[0..src.len];
    const seq_buf = seq_out;

    var table = try MatchTable.init(allocator, src.len);
    defer table.deinit(allocator);

    var lit_len: usize = 0;
    var seq_len: usize = 0;
    var i: usize = 0;

    while (i + format.min_match <= src.len) {
        const found = table.longestMatch(src, i);
        if (found.len < format.min_match) {
            if (lit_len >= literals.len) break;
            literals[lit_len] = src[i];
            lit_len += 1;
            i += 1;
            table.insert(src, i);
            continue;
        }
        if (seq_len < seq_buf.len and lit_len <= literals.len) {
            seq_buf[seq_len] = .{
                .lit_length = lit_len,
                // The stored length is the number of bytes the match regenerates;
                // the sequence section adds the minimum back on when it decodes.
                .match_length = found.len,
                .offset = found.distance,
            };
            seq_len += 1;
        }
        lit_len = 0;
        var remaining = found.len;
        while (remaining > 0) : (remaining -= 1) {
            i += 1;
            table.insert(src, i);
        }
    }
    // The loop above stops once fewer than a minimum match is left, because no
    // match can start there. Those bytes are still input, so they have to become
    // literals or the block would silently regenerate less than it was given.
    // The literal buffer is the size of the whole input and one literal is added
    // per input byte, so there is always room.
    while (i < src.len) : (i += 1) {
        literals[lit_len] = src[i];
        lit_len += 1;
    }
    return .{ .literals = literals[0..lit_len], .sequences = seq_buf[0..seq_len] };
}

const Match = struct { len: usize, distance: usize };

/// A hash chain over four-byte prefixes: the most recent position per hash, plus a
/// back-link so a colliding position can still be reached.
const MatchTable = struct {
    head: []usize,
    prev: []usize,

    const hash_bits = 14;
    const max_chain = 24;

    fn init(allocator: std.mem.Allocator, src_len: usize) errors.ZstdError!MatchTable {
        const wanted = @min(@as(usize, 1) << hash_bits, src_len);
        const slots = std.math.ceilPowerOfTwoAssert(usize, @max(wanted, 8));
        const head = try allocator.alloc(usize, slots);
        errdefer allocator.free(head);
        const prev = try allocator.alloc(usize, @max(src_len, 8));
        errdefer allocator.free(prev);
        @memset(head, invalid_position);
        @memset(prev, invalid_position);
        return .{ .head = head, .prev = prev };
    }

    fn deinit(self: MatchTable, allocator: std.mem.Allocator) void {
        allocator.free(self.head);
        allocator.free(self.prev);
    }

    fn insert(self: *MatchTable, src: []const u8, at: usize) void {
        if (at + 4 > src.len or at >= self.prev.len) return;
        const slot = hashAt(src, at) & (self.head.len - 1);
        self.prev[at] = self.head[slot];
        self.head[slot] = at;
    }

    fn longestMatch(self: *const MatchTable, src: []const u8, at: usize) Match {
        var best = Match{ .len = 0, .distance = 0 };
        if (at + 4 > src.len) return best;
        const max_len = @min(src.len - at, format.block_size_max);
        var candidate = self.head[hashAt(src, at) & (self.head.len - 1)];
        var chain: usize = 0;
        while (candidate != invalid_position and chain < max_chain) : (chain += 1) {
            if (candidate >= at) break;
            const distance = at - candidate;
            // Cheap rejection: a candidate that cannot beat the best so far does
            // not need its bytes compared.
            if (best.len > 0 and src[candidate + best.len] != src[at + best.len]) {
                candidate = self.prev[candidate];
                continue;
            }
            var len: usize = 0;
            while (len < max_len and src[candidate + len] == src[at + len]) len += 1;
            if (len > best.len) best = .{ .len = len, .distance = distance };
            candidate = self.prev[candidate];
        }
        return best;
    }
};

const invalid_position: usize = std.math.maxInt(usize);

fn hashAt(src: []const u8, at: usize) usize {
    const v = bits.readLe32(src[at..][0..4]);
    return @intCast((v *% 2654435761) >> (32 - MatchTable.hash_bits));
}

/// Worst-case bytes a frame needs for `src_size` input bytes.
///
/// One block holds at most `format.block_size_max` input bytes, and a compressed
/// block is bounded by its literals section plus its sequence section. Both can
/// exceed their input, so the bound leaves room for the worst case and the encoder
/// falls back to a raw block whenever the compressed form would not be smaller.
///
/// The bound is the same for every version that shares this block layout, so it
/// takes no version.
pub fn compressBound(src_size: usize) usize {
    if (src_size > format.block_size_max) {
        const blocks = src_size / format.block_size_max + 1;
        return src_size + blocks * (format.block_header_size + 8) + 64;
    }
    return 4 + format.block_header_size +
        src_size +
        sequences.sequencesBound(src_size / format.min_match + 2) +
        format.block_header_size + 64;
}

/// Encodes `src` as a single-block v0.2 frame, returning the bytes written.
///
/// `dst` must be at least `compressBound(src.len)` long. One block is enough for
/// any input this accepts, because a block's input is capped at 128 KB.
pub fn compress(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
) errors.ZstdError!usize {
    return compressFor(version, allocator, dst, src);
}

/// `compress` for an explicit version. The block layout, the literal section and
/// the sequence section are shared with v0.2; only the frame header's magic differs,
/// plus the repeat-offset start inside the sequence section. Sharing one encoder
/// here is what keeps the two versions from disagreeing about anything else.
pub fn compressFor(
    ver: format.Version,
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
) errors.ZstdError!usize {
    if (src.len > format.block_size_max) return error.SrcSizeTooLarge;
    if (dst.len < compressBound(src.len)) return error.DstSizeTooSmall;

    // v0.1 to v0.3 have a four-byte frame header that is nothing but the magic.
    // v0.4 onwards add a byte carrying the window log, relative to that version's
    // own floor. A single-block frame never needs a window larger than its input, so
    // the smallest legal log that covers the input is used.
    var header = format.FrameHeader{ .version = ver, .size = 4 };
    if (ver != .v01 and ver != .v02 and ver != .v03) {
        const base: u8 = ver.windowLogBase();
        var want: u8 = base;
        while (want < 15 and (@as(usize, 1) << @intCast(want - base + 4)) < src.len) want += 1;
        header = .{ .version = ver, .size = 5, .window_log = want };
    }
    var pos = try format.writeFrameHeader(dst[0..], header);

    const compressed = try buildBlock(ver, allocator, dst[pos + format.block_header_size ..], src);
    if (compressed) |size| {
        format.writeBlockHeader(dst[pos..][0..3], .compressed, size);
        pos += format.block_header_size + size;
    } else {
        format.writeBlockHeader(dst[pos..][0..3], .raw, src.len);
        pos += format.block_header_size;
        @memcpy(dst[pos..][0..src.len], src);
        pos += src.len;
    }

    format.writeBlockHeader(dst[pos..][0..3], .end, 0);
    return pos + format.block_header_size;
}

/// Writes a block's literals section, choosing between repeated, raw and
/// Huffman-coded forms and returning how many bytes it took.
fn writeLiterals(
    dst: []u8,
    scratch: []u8,
    literals: []const u8,
) errors.ZstdError!usize {
    if (literals.len == 0) {
        // Zero literals: a raw section with a zero size is four bytes and decodes
        // to nothing.
        if (dst.len < 4) return error.DstSizeTooSmall;
        bits.writeLe32(dst[0..4], 1);
        return 4;
    }

    // All one byte: a repeated section is four bytes of header for any length, so
    // it wins as soon as the literals are longer than that.
    if (literals.len >= 8) {
        var all_same = true;
        for (literals[1..]) |b| {
            if (b != literals[0]) {
                all_same = false;
                break;
            }
        }
        if (all_same) {
            if (dst.len < 4) return error.DstSizeTooSmall;
            // Type 2, with the size in the top bits biased by two.
            bits.writeLe32(dst[0..4], (@as(u32, 2)) | (@as(u32, @intCast(literals.len)) << 2));
            dst[3] = literals[0];
            return 4;
        }
    }

    const huffman_size = try compressLiteralsHuffman(dst, scratch, literals);
    const raw_size: usize = 3 + literals.len;
    if (huffman_size) |size| {
        if (size < raw_size) return size;
    }
    if (dst.len < raw_size) return error.DstSizeTooSmall;
    bits.writeLe32(dst[0..4], (@as(u32, 1)) | (@as(u32, @intCast(literals.len)) << 2));
    @memcpy(dst[3..][0..literals.len], literals);
    return raw_size;
}

/// Where the four literal streams split, exactly as the reader splits them.
fn segments(total: usize) [4]usize {
    const seg = (total + 3) / 4;
    return .{
        @min(seg, total),
        @min(2 * seg, total),
        @min(3 * seg, total),
        total,
    };
}

/// Huffman-codes a literal section into `dst`, returning its size in bytes, or null
/// when the raw form would be smaller or the section cannot be coded.
///
/// The layout written is the one the reader expects: five bytes of header, then the
/// weight description, then the six-byte jump table, then the four streams.
fn compressLiteralsHuffman(
    dst: []u8,
    scratch: []u8,
    literals: []const u8,
) errors.ZstdError!?usize {
    var assignment = Assignment{};
    assignCodes(&assignment, literals) catch return null;

    const o_size = assignment.count;
    // The description cannot name more symbols than a byte can hold.
    if (o_size >= 128) return null;

    // Streams are staged in scratch at fixed offsets, because their lengths are
    // only known once each has been closed.
    const bounds = segments(literals.len);
    const starts = [4]usize{ 0, bounds[0], bounds[1], bounds[2] };
    var stride: usize = 0;
    for (0..4) |s| {
        const end: usize = if (s == 0) bounds[0] else bounds[s];
        const need = ((end - starts[s]) + 16);
        if (need > stride) stride = need;
    }
    if (4 * stride > scratch.len) return null;

    var stream_lens: [4]usize = @splat(0);
    for (0..4) |s| {
        const end: usize = if (s == 0) bounds[0] else bounds[s];
        const count = end - starts[s];
        if (count == 0) continue;
        const region = scratch[s * stride ..][0 .. count + 16];
        var writer = bitstream.BIT_CStream.init(region) catch return null;
        // The bitstream is written least-significant bit first and the reader
        // consumes it from the end backwards, so the last symbol written is the
        // first one decoded. Each segment's symbols therefore go in reverse, which
        // is what the reference's own `HUF_compress1X_usingCTable` loop does.
        var p = end;
        while (p > starts[s]) {
            p -= 1;
            const code = assignment.codes[literals[p]];
            writer.addBitsFast(code.bits, code.nb_bits);
        }
        stream_lens[s] = writer.close() catch return null;
    }

    // One header byte plus one nibble per two weights.
    const desc_bytes = (o_size + 1) / 2;
    const body = 1 + desc_bytes + 6 + stream_lens[0] + stream_lens[1] + stream_lens[2] + stream_lens[3];
    const total = 5 + body;
    if (total >= 3 + literals.len) return null;
    if (dst.len < total) return null;
    if (body > 0xFFFFFF) return null;
    // The jump table stores three of the four stream lengths in 16 bits each, so a
    // stream longer than 64 KB cannot be described. Falling back to the raw form is
    // better than writing a length that would silently truncate.
    for (0..3) |s| {
        if (stream_lens[s] > 0xFFFF) return null;
    }

    // Header: the literal size and the compressed size share five bytes, and they
    // meet inside byte 2 without overlapping. The reader takes the size from bytes
    // 0-2 using only byte 2's low five bits, and the compressed size from byte 2's
    // high three bits plus bytes 3-4. Verified against the captured frame's header
    // `60 03 20 13 00`, which is size 216 and compressed size 153.
    //
    //   b0 b1        = size << 2, low 16 bits
    //   b2 low 5     = size << 2, bits 16..20
    //   b2 high 3    = compressed size, bits 0..2
    //   b3           = compressed size, bits 3..10
    //   b4           = compressed size, bits 11..18
    //
    // The section's type lives in b0's low two bits, which both fields leave zero.
    const size_field: u32 = @as(u32, @intCast(literals.len)) << 2;
    const b2: u8 = @as(u8, @truncate(size_field >> 16)) |
        (@as(u8, @truncate(body)) << 5);
    dst[0] = @truncate(size_field);
    dst[1] = @truncate(size_field >> 8);
    dst[2] = b2;
    dst[3] = @truncate(body >> 3);
    dst[4] = @truncate(body >> 11);
    var at: usize = 5;

    // Weight description: the nibble form, which is one byte naming the symbol
    // count and then one nibble per weight, high nibble first.
    //
    // The header byte is `127 + count`, so the count must stay below 115: at 242
    // and above the reader switches to the "every symbol has weight one" form
    // instead, and would read the wrong number of weights. Larger alphabets have
    // to take the raw form, because this writer only emits the nibble form.
    if (127 + o_size >= 242) return null;
    dst[at] = @intCast(127 + o_size);
    at += 1;
    var n: usize = 0;
    while (n < o_size) : (n += 2) {
        const hi: u8 = assignment.weights[n];
        const lo: u8 = if (n + 1 < o_size) assignment.weights[n + 1] else 0;
        dst[at] = (hi << 4) | lo;
        at += 1;
    }

    bits.writeLe16(dst[at..][0..2], @intCast(stream_lens[0]));
    at += 2;
    bits.writeLe16(dst[at..][0..2], @intCast(stream_lens[1]));
    at += 2;
    bits.writeLe16(dst[at..][0..2], @intCast(stream_lens[2]));
    at += 2;
    for (0..4) |s| {
        if (stream_lens[s] == 0) continue;
        @memcpy(dst[at..][0..stream_lens[s]], scratch[s * stride ..][0..stream_lens[s]]);
        at += stream_lens[s];
    }
    return at;
}

// Tests

const testing = std.testing;
const golden = @import("golden_frames.zig");

test "v02: the magic is little-endian, unlike v0.1" {
    var frame = [_]u8{ 0, 0, 0, 0 };
    std.mem.writeInt(u32, frame[0..4], magic, .little);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x22, 0xB5, 0x2F, 0xFD }, &frame);
    try testing.expectEqual(magic, bits.readLe32(golden.frame_v02[0..4]));
    try testing.expect(!std.mem.eql(u8, golden.frame_v01[0..4], golden.frame_v02[0..4]));
}

test "v02: the real v0.2 frame is sized by walking its blocks" {
    try testing.expectEqual(golden.frame_v02.len, try findFrameSize(testing.allocator, golden.frame_v02[0..]));
    // 4-byte header + 3-byte block header + 177 payload + 3-byte end block.
    try testing.expectEqual(@as(usize, 187), golden.frame_v02.len);
}

test "v02: the real v0.2 frame decodes to its exact content, byte for byte" {
    var dst: [1024]u8 = undefined;
    const result = try decompress(testing.allocator, &dst, golden.frame_v02[0..]);
    try testing.expectEqual(golden.block.len, result.decoded);
    try testing.expectEqualSlices(u8, golden.block[0..], dst[0..result.decoded]);
    try testing.expectEqual(golden.frame_v02.len, result.consumed);
}

test "v02: every truncated prefix of the real frame is refused" {
    var dst: [512]u8 = undefined;
    for (0..golden.frame_v02.len) |len| {
        const r = decompress(testing.allocator, &dst, golden.frame_v02[0..len]);
        if (r) |result| {
            // Only a prefix ending exactly on the end block may parse, and then it
            // must have consumed everything it was given.
            try testing.expect(result.decoded == 0 or result.consumed == len);
        } else |_| {}
    }
}

test "v02: the literals section of the real frame has the shape v0.2 defines" {
    const block = golden.frame_v02[4 + 3 ..];
    const lit_size: usize = (bits.readLe32(block[0..4]) & 0x1FFFFF) >> 2;
    const lit_csize: usize = (bits.readLe32(block[2..6]) & 0xFFFFFF) >> 5;
    try testing.expectEqual(@as(u2, 0), @as(u2, @truncate(block[0])));
    try testing.expect(lit_size > 0 and lit_csize > 0);
    try testing.expectEqual(@as(usize, 153), lit_csize);
    try testing.expect(lit_size > lit_csize);
    // The section's own claim has to fit inside the block.
    try testing.expect(lit_csize + 5 < 177);
}

test "v02: a raw block round trips through the frame" {
    var frame: [64]u8 = undefined;
    var n = try format.writeFrameHeader(frame[0..], .{ .version = version, .size = 4 });
    format.writeBlockHeader(frame[n..][0..3], .raw, 5);
    n += 3;
    @memcpy(frame[n..][0..5], "hello");
    n += 5;
    format.writeBlockHeader(frame[n..][0..3], .end, 0);
    n += 3;

    var dst: [32]u8 = undefined;
    const result = try decompress(testing.allocator, &dst, frame[0..n]);
    try testing.expectEqual(@as(usize, 5), result.decoded);
    try testing.expectEqualStrings("hello", dst[0..5]);
    try testing.expectEqual(n, result.consumed);
    try testing.expectEqual(n, try findFrameSize(testing.allocator, frame[0..n]));
}

test "v02: an RLE block expands" {
    var frame: [64]u8 = undefined;
    var n = try format.writeFrameHeader(frame[0..], .{ .version = version, .size = 4 });
    format.writeBlockHeader(frame[n..][0..3], .rle, 9);
    n += 3;
    frame[n] = 'q';
    n += 1;
    format.writeBlockHeader(frame[n..][0..3], .end, 0);
    n += 3;

    var dst: [32]u8 = undefined;
    const result = try decompress(testing.allocator, &dst, frame[0..n]);
    try testing.expectEqual(@as(usize, 9), result.decoded);
    try testing.expectEqualStrings("qqqqqqqqq", dst[0..9]);
}

test "v02: a frame with a wrong magic is refused" {
    var frame = golden.frame_v02;
    frame[0] ^= 0xFF;
    var dst: [64]u8 = undefined;
    try testing.expectError(error.PrefixUnknown, decompress(testing.allocator, &dst, &frame));
    try testing.expectError(error.PrefixUnknown, findFrameSize(testing.allocator, &frame));
    // A neighbouring version's magic is a different format, not a corrupt v0.2.
    try testing.expectError(error.PrefixUnknown, decompress(testing.allocator, &dst, golden.frame_v03[0..]));
    try testing.expectError(error.PrefixUnknown, decompress(testing.allocator, &dst, golden.frame_v01[0..]));
}

test "v02: bytes after the end block are refused" {
    var frame: [64]u8 = @splat(0);
    var n = try format.writeFrameHeader(frame[0..], .{ .version = version, .size = 4 });
    format.writeBlockHeader(frame[n..][0..3], .end, 0);
    n += 3 + 3;
    frame[n] = 0xAA;
    n += 1;
    var dst: [32]u8 = undefined;
    try testing.expectError(error.SrcSizeWrong, decompress(testing.allocator, &dst, frame[0..n]));
}

test "v02: a short buffer is refused rather than read past" {
    var dst: [32]u8 = undefined;
    try testing.expectError(error.SrcSizeWrong, decompress(testing.allocator, &dst, &[_]u8{}));
    try testing.expectError(error.SrcSizeWrong, decompress(testing.allocator, &dst, &[_]u8{ 0x22, 0xB5 }));
    try testing.expectError(error.SrcSizeWrong, findFrameSize(testing.allocator, &[_]u8{ 0x22, 0xB5 }));
    // A magic with no block header after it is not a frame.
    var only_magic = [_]u8{ 0x22, 0xB5, 0x2F, 0xFD };
    try testing.expectError(error.SrcSizeWrong, findFrameSize(testing.allocator, &only_magic));
}

test "v02: code lengths are a valid Huffman tree" {
    var out = Assignment{};
    const data = "aaabbbcccddddddddeeeeeeeeeeeffffgggghhhh";
    try assignCodes(&out, data);

    // Every symbol that occurs has a code, and no symbol outside the text does.
    for (data) |b| {
        try testing.expect(out.codes[b].nb_bits > 0);
        try testing.expect(out.codes[b].bits < (@as(u32, 1) << @intCast(out.codes[b].nb_bits)));
    }
    for (out.codes, 0..) |code, sym| {
        var occurs = false;
        for (data) |b| {
            if (b == sym) occurs = true;
        }
        if (!occurs) try testing.expectEqual(@as(u32, 0), code.nb_bits);
    }

    // Kraft equality: the codes must exactly fill the table. Scaled up by
    // `max_bits`, that is `sum of 2^(max_bits - nb_bits) == 2^max_bits`.
    var total: u64 = 0;
    for (out.codes) |code| {
        if (code.nb_bits == 0) continue;
        total += @as(u64, 1) << @intCast(out.max_bits - code.nb_bits);
    }
    try testing.expectEqual(@as(u64, 1) << @intCast(out.max_bits), total);
}

test "v02: the reader derives the symbol the encoder left implicit" {
    // The encoder writes weights for symbols 0..count-1 and relies on the reader to
    // derive symbol `count`. That only works if the derived weight is the one the
    // encoder intended, so the arithmetic is checked directly.
    var out = Assignment{};
    try assignCodes(&out, "aaabbbcccddddddddeeeeeeeeeeeffffgggghhhh");

    var weight_total: u32 = 0;
    for (out.weights[0..out.count]) |w| {
        if (w >= huffman.max_table_log) return error.TestUnexpectedResult;
        weight_total += (@as(u32, 1) << @intCast(w)) >> 1;
    }
    const derived_max_bits: u8 = @intCast(bits.highbit32(weight_total) + 1);
    try testing.expectEqual(out.max_bits, derived_max_bits);

    const rest: u32 = (@as(u32, 1) << @intCast(derived_max_bits)) - weight_total;
    const derived_last: u8 = @intCast(bits.highbit32(rest) + 1);
    try testing.expectEqual(out.weights[out.count], derived_last);

    // And the rank-1 population the reader insists on must be even.
    var rank_one: u32 = 0;
    for (out.weights[0 .. out.count + 1]) |w| {
        if (w == 1) rank_one += 1;
    }
    try testing.expect(rank_one >= 2);
    try testing.expectEqual(@as(u32, 0), rank_one & 1);
}

test "v02: the codes the reader builds select the symbols the encoder wrote" {
    // The strongest check available without the reference: build the reader's
    // table from the encoder's weights and confirm every code leads to its own
    // symbol. This is what makes the slot formula the encoder uses the right one.
    var out = Assignment{};
    const data = "the quick brown fox jumps over the lazy dog the quick brown fox";
    try assignCodes(&out, data);

    var weights = huffman.Stats{};
    // The reader sees the implied symbol too: it is symbol count, whose weight it
    // derives from the total.
    @memcpy(weights.weights[0 .. out.count + 1], out.weights[0 .. out.count + 1]);
    weights.count = out.count + 1;
    weights.max_bits = out.max_bits;
    var table: huffman.TableX2 = undefined;
    try huffman.buildX2(&table, &weights);

    for (data) |b| {
        const code = out.codes[b];
        // A code of `nb_bits` bits is read out of a `max_bits`-wide window, so its
        // bits sit at the top of the index and the window extends it downwards. The
        // table's own index arithmetic is the shift: a weight-`w` symbol's code is
        // `max_bits + 1 - w` bits wide, and it starts at the slot group the encoder
        // counted, which is `2^(w-1)` slots per symbol.
        const w: u32 = out.max_bits + 1 - code.nb_bits;
        const index = @as(usize, code.bits) << @intCast(w - 1);
        const cell = table.cells[index];
        try testing.expectEqual(b, cell.byte);
        try testing.expectEqual(@as(u8, @intCast(code.nb_bits)), cell.nbBits);
    }
}

test "v02: a Huffman table cannot be built for fewer than two symbols" {
    var out = Assignment{};
    var single: [64]u8 = @splat(255);
    try testing.expectError(error.InvalidHuffmanTable, assignCodes(&out, &single));
    try testing.expectError(error.InvalidHuffmanTable, assignCodes(&out, &[_]u8{}));
}

test "v02: the encoder's frame decodes back to its input" {
    // The cases span the shapes the block writer chooses between: a raw fallback
    // below the compressed-block threshold, repeated literals, raw literals, and
    // Huffman literals with real sequences. The sizes that straddle the 64-byte
    // threshold matter, because that is where a block switches shape.
    var repeated: [64]u8 = undefined;
    @memset(&repeated, 'a');
    var alternating: [128]u8 = undefined;
    for (&alternating, 0..) |*b, i| b.* = if (i % 2 == 0) 'a' else 'b';
    var patterned: [80]u8 = undefined;
    for (&patterned, 0..) |*b, i| {
        b.* = switch (i % 97) {
            0...3 => 'x',
            4...5 => 'y',
            else => @intCast('a' + (i % 26)),
        };
    }
    // Larger than one hash-chain stride and than a short literal section, so the
    // literal split is uneven and sequences run long. Found by the cross-compatibility
    // harness: a frame this size encoded but would not decode.
    var large: [4000]u8 = undefined;
    for (&large, 0..) |*b, i| {
        b.* = switch (i % 97) {
            0...3 => 'x',
            4...5 => 'y',
            else => @intCast('a' + (i % 26)),
        };
    }
    const cases = [_][]const u8{
        "",
        "a",
        "ab",
        "abcabcabcabcabcabc",
        repeated[0..],
        &alternating,
        &patterned,
        &large,
        golden.block[0..],
    };
    for (cases) |src| {
        const bound = compressBound(src.len);
        const frame = try testing.allocator.alloc(u8, bound);
        defer testing.allocator.free(frame);
        const n = try compress(testing.allocator, frame, src);
        try testing.expect(n <= bound);

        const out = try testing.allocator.alloc(u8, src.len + 16);
        defer testing.allocator.free(out);
        const result = try decompress(testing.allocator, out, frame[0..n]);
        try testing.expectEqual(src.len, result.decoded);
        try testing.expectEqualSlices(u8, src, out[0..result.decoded]);
        try testing.expectEqual(n, result.consumed);
        try testing.expectEqual(n, try findFrameSize(testing.allocator, frame[0..n]));
    }
}

test "v02: the bound is never smaller than a frame this encoder writes" {
    for ([_]usize{ 0, 1, 7, 16, 64, 1000, 4096, 65536, format.block_size_max }) |size| {
        const bound = compressBound(size);
        var prng = std.Random.DefaultPrng.init(@intCast(size + 1));
        const random = prng.random();
        const src = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(src);
        random.bytes(src);
        const frame = try testing.allocator.alloc(u8, bound);
        defer testing.allocator.free(frame);
        const n = try compress(testing.allocator, frame, src);
        try testing.expect(n <= bound);
    }
}

test "v02: input larger than one block is refused" {
    // A block's input is capped at 128 KB in this format's buffer model. Emitting a
    // frame that cannot hold the input would be worse than refusing.
    var frame: [1024]u8 = undefined;
    const too_big = try testing.allocator.alloc(u8, format.block_size_max + 1);
    defer testing.allocator.free(too_big);
    @memset(too_big, 0);
    try testing.expectError(error.SrcSizeTooLarge, compress(testing.allocator, &frame, too_big));
}
