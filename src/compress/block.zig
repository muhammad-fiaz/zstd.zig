//! Compressed-block encoder: LZ77 match finding + literal section +
//! predefined-FSE sequence bitstream.
//!
//! Sequence bitstream: encoder states are initialised from the last
//! sequence, symbols are emitted back-to-front (offset, match length,
//! literal length per step) with each symbol's extra bits appended, and the
//! final states are flushed — the exact inverse of this library's decoder.

const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const frame_block = @import("../frame/block.zig");
const fse_ctable = @import("../fse/ctable.zig");
const bitstream_mod = @import("../common/bitstream.zig");

pub const BlockType = @import("../common/types.zig").BlockType;

const Seq = struct {
    lit_len: u32,
    match_len: u32, // actual length (>=3)
    offset: u32,
};

/// Offset code for a raw distance (predefined-table safe: code <= 28).
inline fn offCode(dist: u32) ?u8 {
    if (dist < 4) return null;
    const v: u64 = @as(u64, dist) + 3;
    const code: u8 = @intCast(63 - @clz(v));
    if (code > constants.default_max_off) return null; // beyond predefined table
    return code;
}

/// Literal-length code (LL_base/ll_bits tables).
fn llCode(len: u32) u8 {
    var code: u32 = 0;
    while (code + 1 < constants.ll_base.len and constants.ll_base[code + 1] <= len) code += 1;
    return @intCast(code);
}

/// Match-length code (ML_base already includes the minimum of 3).
fn mlCode(len: u32) u8 {
    var code: u32 = 0;
    while (code + 1 < constants.ml_base.len and constants.ml_base[code + 1] <= len) code += 1;
    return @intCast(code);
}

const MatchFinder = struct {
    head: []u32, // hash -> position+1 (0 = empty)
    prev: []u32, // chain
    hash_log: u8,

    fn init(allocator: std.mem.Allocator, hash_log: u8) !MatchFinder {
        const size = @as(usize, 1) << @intCast(hash_log);
        const head = try allocator.alloc(u32, size);
        @memset(head, 0);
        const prev = try allocator.alloc(u32, constants.block_size_max);
        @memset(prev, 0);
        return .{ .head = head, .prev = prev, .hash_log = hash_log };
    }

    fn deinit(self: *MatchFinder, allocator: std.mem.Allocator) void {
        allocator.free(self.head);
        allocator.free(self.prev);
    }

    inline fn hash4(self: *const MatchFinder, src: []const u8, pos: usize) usize {
        const v = std.mem.readInt(u32, src[pos..][0..4], .little);
        return (v *% 2654435761) >> @intCast(32 - self.hash_log);
    }
};

/// Find sequences greedily over `src` using a hash chain; window covers the
/// whole block (block-local history plus caller-provided prefix is not yet
/// threaded here â€” matches stay within the current block, which is always a
/// valid subset of what full-window matching would find).
fn findSequences(
    allocator: std.mem.Allocator,
    src: []const u8,
    min_match: usize,
    search_depth: usize,
) !struct { seqs: []Seq, literals: []u8 } {
    var mf = try MatchFinder.init(allocator, 16);
    defer mf.deinit(allocator);

    const seqs = try allocator.alloc(Seq, 4096);
    errdefer allocator.free(seqs);
    const literals = try allocator.alloc(u8, src.len);
    errdefer allocator.free(literals);
    var n_lit: usize = 0;
    var n_seq: usize = 0;

    var anchor: usize = 0;
    var pos: usize = 0;

    while (pos + min_match <= src.len) {
        if (pos + 4 > src.len) break;
        const h = mf.hash4(src, pos);
        var best_len: usize = 0;
        var best_dist: usize = 0;
        var cand = mf.head[h];
        var depth: usize = 0;
        while (cand != 0 and depth < search_depth) : (depth += 1) {
            const cand_pos = cand - 1;
            if (pos - cand_pos > constants.block_size_max) break;
            // Extend match.
            const max_len = @min(src.len - pos, constants.max_ml + 3);
            var l: usize = 0;
            while (l < max_len and src[cand_pos + l] == src[pos + l]) : (l += 1) {}
            if (l > best_len) {
                best_len = l;
                best_dist = pos - cand_pos;
                if (l == max_len) break;
            }
            cand = if (cand_pos < mf.prev.len) mf.prev[cand_pos] else 0;
        }

        // Encodability constraints: predefined OF table covers dist+3 codes
        // up to default_max_off, and tiny distances (1-3) would require
        // repeat-offset codes which this encoder does not emit.
        const encodable = best_len >= min_match and best_dist >= 4 and
            (@as(u64, best_dist) + 3) <= (@as(u64, 1) << @intCast(constants.default_max_off + 1));
        if (encodable) {
            if (n_seq == seqs.len) break;
            const run = pos - anchor;
            @memcpy(literals[n_lit .. n_lit + run], src[anchor..pos]);
            n_lit += run;
            seqs[n_seq] = .{
                .lit_len = @intCast(run),
                .match_len = @intCast(best_len),
                .offset = @intCast(best_dist),
            };
            n_seq += 1;
            // Insert positions covered by the match into the chain.
            var insert = pos;
            const end_insert = pos + best_len;
            while (insert + 4 <= end_insert and insert + 4 <= src.len) : (insert += 1) {
                const hh = mf.hash4(src, insert);
                mf.prev[insert] = mf.head[hh];
                mf.head[hh] = @intCast(insert + 1);
            }
            pos += best_len;
            anchor = pos;
        } else {
            const hh = mf.hash4(src, pos);
            mf.prev[pos] = mf.head[hh];
            mf.head[hh] = @intCast(pos + 1);
            pos += 1;
        }
    }

    // Trailing literals.
    const tail = src[anchor..];
    @memcpy(literals[n_lit .. n_lit + tail.len], tail);
    n_lit += tail.len;

    return .{ .seqs = seqs[0..n_seq], .literals = literals[0..n_lit] };
}

const ctable_mod = fse_ctable;

/// Write raw-literal section header + bytes. Returns total literal section len.
fn writeRawLiterals(out: []u8, literals: []const u8) usize {
    const n = literals.len;
    if (n < 32) {
        out[0] = @intCast(n << 3); // type=0, format=0
        @memcpy(out[1 .. 1 + n], literals);
        return 1 + n;
    } else if (n < 4096) {
        // 12-bit size stored in bits [15:4] of LE16 (readLE16 >> 4 == n).
        out[0] = 0b00_01_00 | @as(u8, @intCast((n & 0xF) << 4));
        out[1] = @intCast((n >> 4) & 0xFF);
        @memcpy(out[2 .. 2 + n], literals);
        return 2 + n;
    } else {
        // 20-bit size stored in bits [23:4] of LE24 (readLE24 >> 4 == n).
        out[0] = 0b00_11_00 | @as(u8, @intCast((n & 0xF) << 4));
        out[1] = @intCast((n >> 4) & 0xFF);
        out[2] = @intCast((n >> 12) & 0xFF);
        @memcpy(out[3 .. 3 + n], literals);
        return 3 + n;
    }
}

pub fn compressBlock(dst: []u8, src: []const u8, is_last: bool) errors.ZstdError!usize {
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

    var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    const found = findSequences(alloc, src, 4, 8) catch return rawFallback(dst, src, is_last);

    if (found.seqs.len == 0 or found.seqs.len > 0xFFFF + constants.long_nb_seq) {
        return rawFallback(dst, src, is_last);
    }

    // Layout estimate: literals section + nbSeq + mode byte + bitstream slack.
    const lit_header: usize = if (found.literals.len < 32) 1 else if (found.literals.len < 4096) 2 else 3;
    const nb_seq_size: usize = if (found.seqs.len < 128) 1 else if (found.seqs.len < 0x7F00) 2 else 3;
    const upper_bound = lit_header + found.literals.len + nb_seq_size + 1 + (src.len / 2 + 64);
    if (dst.len < upper_bound) {
        return rawFallback(dst, src, is_last);
    }

    var body: std.ArrayList(u8) = .empty;
    // arena-backed; no explicit deinit needed
    body.ensureTotalCapacity(alloc, upper_bound) catch return rawFallback(dst, src, is_last);

    // Literals.
    body.resize(alloc, lit_header + found.literals.len) catch return rawFallback(dst, src, is_last);
    _ = writeRawLiterals(body.items[0..], found.literals);

    // nbSeq.
    const n = found.seqs.len;
    if (n < 128) {
        body.append(alloc, @intCast(n)) catch return rawFallback(dst, src, is_last);
    } else if (n < constants.long_nb_seq) {
        const b: u16 = @intCast(n);
        body.append(alloc, @intCast(0x80 | (b >> 8))) catch return rawFallback(dst, src, is_last);
        body.append(alloc, @truncate(b)) catch return rawFallback(dst, src, is_last);
    } else {
        body.append(alloc, 0xFF) catch return rawFallback(dst, src, is_last);
        const b: u16 = @intCast(n - constants.long_nb_seq);
        body.append(alloc, @truncate(b)) catch return rawFallback(dst, src, is_last);
        body.append(alloc, @truncate(b >> 8)) catch return rawFallback(dst, src, is_last);
    }

    // Symbol modes: all predefined.
    body.append(alloc, 0x00) catch return rawFallback(dst, src, is_last);

    // Bitstream.
    const bs_start = body.items.len;
    body.resize(alloc, bs_start + src.len + 512) catch return rawFallback(dst, src, is_last);
    const bs_len = encodeSequencesPredefinedInto(alloc, body.items[bs_start..], found.seqs) catch
        return rawFallback(dst, src, is_last);

    alloc.free(found.seqs);
    alloc.free(found.literals);

    body.shrinkRetainingCapacity(bs_start + bs_len);
    const c_len = body.items.len;
    if (c_len >= src.len or dst.len < 3 + c_len) return rawFallback(dst, src, is_last);
    frame_block.writeBlockHeader(dst[0..3], is_last, .compressed, @intCast(c_len));
    @memcpy(dst[3 .. 3 + c_len], body.items);
    return 3 + c_len;
}

fn encodeSequencesPredefinedInto(alloc: std.mem.Allocator, out: []u8, seqs: []const Seq) errors.ZstdError!usize {
    var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const ll_ct = try fse_ctable.buildCTable(arena, &constants.ll_default_norm, constants.max_ll, @intCast(constants.ll_default_norm_log));
    const ml_ct = try fse_ctable.buildCTable(arena, &constants.ml_default_norm, constants.max_ml, @intCast(constants.ml_default_norm_log));
    // Predefined OF table covers codes 0..default_max_off only.
    const of_ct = try fse_ctable.buildCTable(arena, &constants.of_default_norm, constants.of_default_norm.len - 1, @intCast(constants.of_default_norm_log));

    const ll_codes = alloc.alloc(u8, seqs.len) catch return error.OutOfMemory;
    const ml_codes = alloc.alloc(u8, seqs.len) catch return error.OutOfMemory;
    const of_codes = alloc.alloc(u8, seqs.len) catch return error.OutOfMemory;
    for (seqs, 0..) |sq, i| {
        ll_codes[i] = llCode(sq.lit_len);
        ml_codes[i] = mlCode(sq.match_len);
        of_codes[i] = offCode(sq.offset) orelse return error.Corruption;
    }

    var bc = bitstream_mod.BIT_CStream.init(out) catch return error.DstSizeTooSmall;

    var st_ml: fse_ctable.CState = .{};
    st_ml.initState(&ml_ct, ml_codes[seqs.len - 1]);
    var st_of: fse_ctable.CState = .{};
    st_of.initState(&of_ct, of_codes[seqs.len - 1]);
    var st_ll: fse_ctable.CState = .{};
    st_ll.initState(&ll_ct, ll_codes[seqs.len - 1]);

    const li = seqs.len - 1;
    writeExtraBits(seqs[li], ll_codes[li], ml_codes[li], of_codes[li], &bc);
    bc.flushBits();

    var i: usize = seqs.len - 1;
    while (i > 0) {
        i -= 1;
        st_of.encodeSymbol(&of_ct, &bc, of_codes[i]);
        st_ml.encodeSymbol(&ml_ct, &bc, ml_codes[i]);
        st_ll.encodeSymbol(&ll_ct, &bc, ll_codes[i]);
        writeExtraBits(seqs[i], ll_codes[i], ml_codes[i], of_codes[i], &bc);
        bc.flushBits();
    }

    st_ml.flushState(&bc);
    st_of.flushState(&bc);
    st_ll.flushState(&bc);

    return bc.close() catch return error.DstSizeTooSmall;
}

fn writeExtraBits(sq: Seq, llc: u8, mlc: u8, ofc: u8, bc: *bitstream_mod.BIT_CStream) void {
    bc.addBits(sq.lit_len - constants.ll_base[llc], constants.ll_bits[llc]);
    bc.addBits(sq.match_len - constants.ml_base[mlc], constants.ml_bits[mlc]);
    const v: u64 = @as(u64, sq.offset) + 3;
    bc.addBits(v - (@as(u64, 1) << @intCast(ofc)), ofc);
}

fn rawFallback(dst: []u8, src: []const u8, is_last: bool) errors.ZstdError!usize {
    if (dst.len < src.len + 3) return error.DstSizeTooSmall;
    frame_block.writeBlockHeader(dst[0..3], is_last, .raw, @intCast(src.len));
    @memcpy(dst[3 .. 3 + src.len], src);
    return 3 + src.len;
}

fn isRle(src: []const u8) bool {
    if (src.len < 8) return false;
    const first = src[0];
    for (src[1..]) |b| if (b != first) return false;
    return true;
}

pub fn compressBlockWithStrategy(dst: []u8, src: []const u8, is_last: bool, strategy: constants.Strategy, level: i32) errors.ZstdError!usize {
    _ = strategy;
    _ = level;
    return compressBlock(dst, src, is_last);
}
