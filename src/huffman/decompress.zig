const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");

pub const HuffDecoder = struct {
    table: []Entry,
    max_bits: u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HuffDecoder) void {
        self.allocator.free(self.table);
    }
};

const Entry = struct {
    symbol: u8,
    nb_bits: u8,
};

/// Build an X1-style flat decoding table from explicit Huffman weights.
/// `weights` must be complete (including the implied final symbol) such that
/// sum(1 << (w-1)) == 1 << table_log, matching HUF_readStats validation.
pub fn buildDecoder(allocator: std.mem.Allocator, weights: []const u8, table_log: u8) errors.ZstdError!HuffDecoder {
    if (weights.len == 0) return error.InvalidHuffmanTable;
    if (table_log == 0 or table_log > 11) return error.InvalidHuffmanTable;
    for (weights) |w| {
        if (w > table_log) return error.InvalidHuffmanTable;
    }

    const table_size: usize = @as(usize, 1) << @intCast(table_log);
    const table = try allocator.alloc(Entry, table_size);
    errdefer allocator.free(table);
    @memset(table, Entry{ .symbol = 0, .nb_bits = 0 });

    var rank_val = [_]u32{0} ** 13;
    for (weights) |w| {
        if (w == 0) continue; // zero-weight symbols are unused (C skips them)
        rank_val[w] += 1;
    }

    // Rank starts: cumulative cells consumed by lower weights.
    var next_rank_start: usize = 0;
    var rank_start: [13]usize = undefined;
    for (1..table_log + 1) |n| {
        rank_start[n] = next_rank_start;
        next_rank_start += @as(usize, rank_val[n]) << @intCast(n - 1);
    }
    if (next_rank_start != table_size) return error.InvalidHuffmanTable;

    // Fill: for each symbol in ascending order, place its 2^(w-1) identical
    // entries at the running position of its rank (HUF_readDTableX1_wksp).
    var cursor: [13]usize = rank_start;
    for (weights, 0..) |w, sym| {
        if (w == 0) continue;
        const length: usize = @as(usize, 1) << @intCast(w - 1);
        const nb_bits: u8 = @intCast(table_log + 1 - w);
        const entry = Entry{ .symbol = @intCast(sym), .nb_bits = nb_bits };
        const start = cursor[w];
        for (0..length) |u| table[start + u] = entry;
        cursor[w] += length;
    }

    return HuffDecoder{ .table = table, .max_bits = table_log, .allocator = allocator };
}

fn readLE16(p: []const u8) u16 {
    return @as(u16, p[0]) | (@as(u16, p[1]) << 8);
}

const fse_decompress_mod = @import("../fse/decompress.zig");
const bitstream_mod = @import("../common/bitstream.zig");

pub fn readStats(
    huff_weight: []u8,
    rank_stats: []u32,
    nb_symbols_ptr: *usize,
    table_log_ptr: *u8,
    src: []const u8,
    allocator: std.mem.Allocator,
) errors.ZstdError!usize {
    if (src.len == 0) return error.SrcSizeWrong;
    var ip: usize = 0;
    const i_size = src[0];
    ip += 1;
    var o_size: usize = 0;

    if (i_size >= 128) {
        o_size = i_size - 127;
        const in_bytes = (o_size + 1) / 2;
        if (ip + in_bytes > src.len) return error.SrcSizeWrong;
        if (o_size >= huff_weight.len) return error.Corruption;

        var n: usize = 0;
        while (n < o_size) : (n += 2) {
            huff_weight[n] = src[ip + n / 2] >> 4;
            if (n + 1 < o_size) {
                huff_weight[n + 1] = src[ip + n / 2] & 15;
            }
        }
        ip += in_bytes;
    } else {
        if (i_size == 0) return error.Corruption;
        if (ip + i_size > src.len) return error.SrcSizeWrong;
        const compressed_header = src[ip .. ip + i_size];
        ip += i_size;

        var max_sv: usize = 255;
        const fse_norm = try allocator.alloc(i16, 256);
        defer allocator.free(fse_norm);
        var fse_tlog: u8 = 0;
        const ncount_read = try fse_decompress_mod.readNCount(fse_norm, &max_sv, &fse_tlog, compressed_header);
        if (fse_tlog > 6) return error.TableLogTooLarge;

        // Build the FSE table and decode weights with alternating two-state
        // streaming.
        const dtable_mod = @import("../fse/dtable.zig");
        var dt = try dtable_mod.build(allocator, fse_norm[0 .. max_sv + 1], max_sv, fse_tlog);
        defer dt.deinit();

        var dstream = try bitstream_mod.BIT_DStream.init(compressed_header[ncount_read..]);

        // FSE_initDState x2: each reads `log` bits as its starting state.
        var s1: u16 = @intCast(dstream.readBits(dt.log));
        var s2: u16 = @intCast(dstream.readBits(dt.log));

        const omax = huff_weight.len - 1; // caller provides hwSize; max hwSize-1 symbols
        var op: usize = 0;

        // Main loop: while stream unfinished and room for 4 more symbols.
        while (dstream.reload() == .unfinished and op < omax -| 3) {
            huff_weight[op] = step(&dt, &dstream, &s1);
            huff_weight[op + 1] = step(&dt, &dstream, &s2);
            huff_weight[op + 2] = step(&dt, &dstream, &s1);
            huff_weight[op + 3] = step(&dt, &dstream, &s2);
            op += 4;
        }

        // Tail: alternate until overflow signals the final pair.
        while (true) {
            if (op > omax -| 2) return error.Corruption;
            huff_weight[op] = step(&dt, &dstream, &s1);
            op += 1;
            if (dstream.reload() == .overflow) {
                if (op > omax -| 2) return error.Corruption;
                huff_weight[op] = step(&dt, &dstream, &s2);
                op += 1;
                break;
            }
            if (op > omax -| 2) return error.Corruption;
            huff_weight[op] = step(&dt, &dstream, &s2);
            op += 1;
            if (dstream.reload() == .overflow) {
                if (op > omax -| 2) return error.Corruption;
                huff_weight[op] = step(&dt, &dstream, &s1);
                op += 1;
                break;
            }
        }
        o_size = op;
    }

    @memset(rank_stats[0..13], 0);
    var weight_total: u32 = 0;
    for (0..o_size) |n| {
        const w = huff_weight[n];
        if (w > 12) return error.Corruption;
        rank_stats[w] += 1;
        if (w > 0) {
            weight_total += @as(u32, 1) << @as(std.math.Log2Int(u32), @intCast(w - 1));
        }
    }
    if (weight_total == 0) return error.Corruption;

    const table_log: u8 = @intCast((31 - @clz(weight_total)) + 1);
    if (table_log > 11) return error.Corruption;
    table_log_ptr.* = table_log;

    const total = @as(u32, 1) << @as(std.math.Log2Int(u32), @intCast(table_log));
    const rest = total - weight_total;
    if (rest == 0 or (rest & (rest - 1)) != 0) return error.Corruption; // rest must be power of 2
    const last_weight: u8 = @intCast((31 - @clz(rest)) + 1);
    huff_weight[o_size] = last_weight;
    rank_stats[last_weight] += 1;

    nb_symbols_ptr.* = o_size + 1;
    return ip;
}

/// One FSE decode step: emit symbol at `state`, then transition the state
/// using its nb_bits fresh bits (FSE_decodeSymbol semantics).
fn step(dt: *const @import("../fse/dtable.zig").DTable, ds: *bitstream_mod.BIT_DStream, state: *u16) u8 {
    const e = dt.entries[state.*];
    const low = ds.readBits(e.nb_bits);
    state.* = e.new_state +% @as(u16, @truncate(low));
    return @truncate(e.symbol);
}

pub fn decodeSingleStream(dst: []u8, src: []const u8, decoder: *const HuffDecoder) errors.ZstdError!void {
    var bit_stream = try bitstream_mod.BIT_DStream.init(src);
    const table_log = decoder.max_bits;
    const mask: u64 = (@as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(table_log))) - 1;
    // Compile-time switchable trace (kept for entropy debugging).
    const trace = true;

    var p: usize = 0;
    const p_end = dst.len;

    if (p_end - p > 3) {
        while (bit_stream.reload() == .unfinished and p < p_end - 3) {
            const val1 = bit_stream.lookBits(table_log) & mask;
            const entry1 = decoder.table[@intCast(val1)];
            if (trace) std.debug.print("h[{d}] look={d} sym={d} nb={d}\n", .{ p, val1, entry1.symbol, entry1.nb_bits });
            dst[p] = entry1.symbol;
            p += 1;
            bit_stream.skipBits(entry1.nb_bits);

            const val2 = bit_stream.lookBits(table_log) & mask;
            const entry2 = decoder.table[@intCast(val2)];
            if (trace) std.debug.print("h[{d}] look={d} sym={d} nb={d}\n", .{ p, val2, entry2.symbol, entry2.nb_bits });
            dst[p] = entry2.symbol;
            p += 1;
            bit_stream.skipBits(entry2.nb_bits);

            const val3 = bit_stream.lookBits(table_log) & mask;
            const entry3 = decoder.table[@intCast(val3)];
            if (trace) std.debug.print("h[{d}] look={d} sym={d} nb={d}\n", .{ p, val3, entry3.symbol, entry3.nb_bits });
            dst[p] = entry3.symbol;
            p += 1;
            bit_stream.skipBits(entry3.nb_bits);

            const val4 = bit_stream.lookBits(table_log) & mask;
            const entry4 = decoder.table[@intCast(val4)];
            if (trace) std.debug.print("h[{d}] look={d} sym={d} nb={d}\n", .{ p, val4, entry4.symbol, entry4.nb_bits });
            dst[p] = entry4.symbol;
            p += 1;
            bit_stream.skipBits(entry4.nb_bits);
        }
    } else {
        _ = bit_stream.reload();
    }

    while (p < p_end) {
        const val = bit_stream.lookBits(table_log) & mask;
        const entry = decoder.table[@intCast(val)];
        if (trace) std.debug.print("t[{d}] look={d} sym={d} nb={d}\n", .{ p, val, entry.symbol, entry.nb_bits });
        dst[p] = entry.symbol;
        p += 1;
        bit_stream.skipBits(entry.nb_bits);
    }
}

pub fn decode4Streams(dst: []u8, src: []const u8, decoder: *const HuffDecoder) errors.ZstdError!void {
    if (src.len < 6) return error.SrcSizeWrong;
    const o1 = readLE16(src[0..2]);
    const o2 = readLE16(src[2..4]);
    const o3 = readLE16(src[4..6]);
    const s1_end = 6 + o1;
    const s2_end = s1_end + o2;
    const s3_end = s2_end + o3;
    if (s3_end > src.len) return error.Corruption;
    const s1 = src[6..s1_end];
    const s2 = src[s1_end..s2_end];
    const s3 = src[s2_end..s3_end];
    const s4 = src[s3_end..];

    const segment_size = (dst.len + 3) / 4;
    const op2 = segment_size;
    const op3 = op2 + segment_size;
    const op4 = op3 + segment_size;
    if (op4 > dst.len) return error.Corruption;

    try decodeSingleStream(dst[0..op2], s1, decoder);
    try decodeSingleStream(dst[op2..op3], s2, decoder);
    try decodeSingleStream(dst[op3..op4], s3, decoder);
    try decodeSingleStream(dst[op4..], s4, decoder);
}

pub fn decompressHuffmanBlock(allocator: std.mem.Allocator, dst: []u8, src: []const u8) errors.ZstdError!usize {
    if (src.len < 1) return error.SrcSizeWrong;
    var huff_weight = [_]u8{0} ** 256;
    var rank_stats = [_]u32{0} ** 16;
    var nb_symbols: usize = 0;
    var table_log: u8 = 0;

    const header_read = try readStats(&huff_weight, &rank_stats, &nb_symbols, &table_log, src, allocator);
    var decoder = try buildDecoder(allocator, huff_weight[0..nb_symbols], table_log);
    defer decoder.deinit();

    const bitstream_data = src[header_read..];
    if (dst.len < 256) {
        try decodeSingleStream(dst, bitstream_data, &decoder);
    } else {
        try decode4Streams(dst, bitstream_data, &decoder);
    }
    return dst.len;
}

const testing = std.testing;

test "buildDecoder simple" {
    // weights {2,1,1}: weightTotal = 2+1+1 = 4 -> table_log 2, 4 cells.
    const weights = [_]u8{ 2, 1, 1 };
    var dec = try buildDecoder(testing.allocator, &weights, 2);
    defer dec.deinit();
    try testing.expectEqual(@as(u8, 2), dec.max_bits);
    try testing.expect(dec.table.len == 4);
}

test "buildDecoder single weight" {
    // weights {2,2}: total = 2+2 = 4 -> table_log 2.
    const weights = [_]u8{ 2, 2 };
    var dec = try buildDecoder(testing.allocator, &weights, 2);
    defer dec.deinit();
    try testing.expectEqual(@as(u8, 2), dec.max_bits);
}

test "buildDecoder empty" {
    const weights = [_]u8{};
    const result = buildDecoder(testing.allocator, &weights, 2);
    try testing.expectError(error.InvalidHuffmanTable, result);
}

test "buildDecoder all zero" {
    const weights = [_]u8{ 0, 0, 0 };
    const result = buildDecoder(testing.allocator, &weights, 2);
    try testing.expectError(error.InvalidHuffmanTable, result); // total != table size
}

test "buildDecoder weight too large" {
    const weights = [_]u8{ 3, 1 };
    const result = buildDecoder(testing.allocator, &weights, 2); // w=3 > log=2
    try testing.expectError(error.InvalidHuffmanTable, result);
}

test "buildDecoder symbols populated" {
    const weights = [_]u8{ 2, 1, 1 };
    var dec = try buildDecoder(testing.allocator, &weights, 2);
    defer dec.deinit();
    var found = [_]bool{ false, false, false };
    for (dec.table) |e| {
        if (e.symbol < 3) found[e.symbol] = true;
    }
    try testing.expect(found[0]);
    try testing.expect(found[1]);
    try testing.expect(found[2]);
}

test "decompressHuffmanBlock empty" {
    var dst: [4]u8 = undefined;
    const result = decompressHuffmanBlock(testing.allocator, &dst, &[_]u8{});
    try testing.expectError(error.SrcSizeWrong, result);
}

test "decodeSingleStream" {
    const weights = [_]u8{ 2, 1, 1 };
    var dec = try buildDecoder(testing.allocator, &weights, 2);
    defer dec.deinit();
    var dst: [4]u8 = undefined;
    var src: [4]u8 = undefined;
    @memset(&src, 0);
    decodeSingleStream(&dst, &src, &dec) catch {};
}
