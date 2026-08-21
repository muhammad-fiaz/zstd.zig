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

pub fn buildDecoder(allocator: std.mem.Allocator, weights: []const u8) errors.ZstdError!HuffDecoder {
    if (weights.len == 0) return error.InvalidHuffmanTable;
    var max_weight: u8 = 0;
    for (weights) |w| {
        if (w > max_weight) max_weight = w;
    }
    if (max_weight == 0) return error.InvalidHuffmanTable;
    if (max_weight > 11) return error.InvalidHuffmanTable;

    const table_log = max_weight;
    const table_size: usize = @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(table_log));
    const table = try allocator.alloc(Entry, table_size);
    errdefer allocator.free(table);
    @memset(table, Entry{ .symbol = 0, .nb_bits = 0 });

    var rank_val = [_]u32{0} ** 12;
    for (weights) |w| {
        if (w > 11) return error.InvalidHuffmanTable;
        rank_val[w] += 1;
    }

    var rank_start = [_]u32{0} ** 12;
    var next_rank_start: u32 = 0;
    for (0..table_log + 1) |n| {
        const curr = next_rank_start;
        next_rank_start += rank_val[n];
        rank_start[n] = curr;
    }

    const symbols = try allocator.alloc(u8, weights.len);
    defer allocator.free(symbols);

    var cur_rank_start: [12]u32 = rank_start;
    for (weights, 0..) |w, sym| {
        symbols[cur_rank_start[w]] = @intCast(sym);
        cur_rank_start[w] += 1;
    }

    var symbol_idx = rank_val[0];
    var u_start: usize = 0;
    for (1..table_log + 1) |w| {
        const symbol_count = rank_val[w];
        const length: usize = @as(usize, 1) << @intCast(w - 1);
        const nb_bits: u8 = @intCast(table_log + 1 - w);

        for (0..symbol_count) |s| {
            const sym = symbols[symbol_idx + s];
            for (0..length) |u| {
                table[u_start + u] = Entry{ .symbol = sym, .nb_bits = nb_bits };
            }
            u_start += length;
        }
        symbol_idx += symbol_count;
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

        const fse_dec = try fse_decompress_mod.buildDecoder(allocator, fse_norm[0 .. max_sv + 1], fse_tlog, max_sv);
        var fse_dec_mut = fse_dec;
        defer fse_dec_mut.deinit(allocator);

        var dstream = try bitstream_mod.BIT_DStream.init(compressed_header[ncount_read..]);
        var state1 = fse_decompress_mod.FseDState.init(&fse_dec, &dstream);
        var state2 = fse_decompress_mod.FseDState.init(&fse_dec, &dstream);

        var out_idx: usize = 0;
        while (out_idx + 1 < huff_weight.len) {
            _ = dstream.reload();
            huff_weight[out_idx] = state1.decodeSymbol(&dstream);
            out_idx += 1;
            if (dstream.reload() == .overflow) {
                huff_weight[out_idx] = state2.decodeSymbol(&dstream);
                out_idx += 1;
                break;
            }
            huff_weight[out_idx] = state2.decodeSymbol(&dstream);
            out_idx += 1;
            if (dstream.reload() == .overflow) {
                huff_weight[out_idx] = state1.decodeSymbol(&dstream);
                out_idx += 1;
                break;
            }
        }
        o_size = out_idx;
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

pub fn decodeSingleStream(dst: []u8, src: []const u8, decoder: *const HuffDecoder) errors.ZstdError!void {
    var bit_stream = try bitstream_mod.BIT_DStream.init(src);
    const table_log = decoder.max_bits;
    const mask: u64 = (@as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(table_log))) - 1;

    var p: usize = 0;
    const p_end = dst.len;

    if (p_end - p > 3) {
        while (bit_stream.reload() == .unfinished and p < p_end - 3) {
            const val1 = bit_stream.lookBits(table_log) & mask;
            const entry1 = decoder.table[@intCast(val1)];
            dst[p] = entry1.symbol;
            p += 1;
            bit_stream.skipBits(entry1.nb_bits);

            const val2 = bit_stream.lookBits(table_log) & mask;
            const entry2 = decoder.table[@intCast(val2)];
            dst[p] = entry2.symbol;
            p += 1;
            bit_stream.skipBits(entry2.nb_bits);

            const val3 = bit_stream.lookBits(table_log) & mask;
            const entry3 = decoder.table[@intCast(val3)];
            dst[p] = entry3.symbol;
            p += 1;
            bit_stream.skipBits(entry3.nb_bits);

            const val4 = bit_stream.lookBits(table_log) & mask;
            const entry4 = decoder.table[@intCast(val4)];
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
    var decoder = try buildDecoder(allocator, huff_weight[0..nb_symbols]);
    defer decoder.deinit();

    const bitstream_data = src[header_read..];
    if (dst.len < 256) {
        try decodeSingleStream(dst, bitstream_data, &decoder);
    } else {
        try decode4Streams(dst, bitstream_data, &decoder);
    }
    return dst.len;
}
