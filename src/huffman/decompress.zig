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
    const table_log = max_weight;
    const table_size: usize = @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(table_log));
    var table = try allocator.alloc(Entry, table_size);
    errdefer allocator.free(table);

    var rank_counts = [_]usize{0} ** 12;
    for (weights) |w| {
        if (w > 11) return error.InvalidHuffmanTable;
        if (w != 0) rank_counts[w] += 1;
    }

    var symbols_by_weight = try allocator.alloc(u8, weights.len);
    defer allocator.free(symbols_by_weight);
    var sorted_pos: usize = 0;
    var w: usize = 1;
    while (w <= table_log) : (w += 1) {
        for (weights, 0..) |weight, sym| {
            if (weight == w) {
                symbols_by_weight[sorted_pos] = @intCast(sym);
                sorted_pos += 1;
            }
        }
    }

    var rank_start: usize = 0;
    var symbol_idx: usize = 0;
    w = 1;
    while (w <= table_log) : (w += 1) {
        const count = rank_counts[w];
        if (count == 0) continue;
        const nb_bits: u8 = @intCast(table_log + 1 - w);
        const length: usize = @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(w - 1));
        var s: usize = 0;
        while (s < count) : (s += 1) {
            const sym = symbols_by_weight[symbol_idx + s];
            var k: usize = 0;
            while (k < length) : (k += 1) {
                table[rank_start + k] = .{ .symbol = sym, .nb_bits = nb_bits };
            }
            rank_start += length;
        }
        symbol_idx += count;
    }

    return HuffDecoder{ .table = table, .max_bits = table_log, .allocator = allocator };
}

pub fn decode4Streams(dst: []u8, src: []const u8, decoder: *const HuffDecoder) errors.ZstdError!void {
    if (src.len < 6) return error.SrcSizeWrong;
    const o1 = readLE16(src[0..2]);
    const o2 = readLE16(src[2..4]);
    const o3 = readLE16(src[4..6]);
    const total = o1 + o2 + o3;
    if (total > dst.len) return error.Corruption;
    const s1 = src[6 .. 6 + o1];
    const s2 = src[6 + o1 .. 6 + o1 + o2];
    const s3 = src[6 + o1 + o2 .. 6 + total];
    const s4 = src[6 + total ..];
    var p1 = BitReader.init(s1);
    var p2 = BitReader.init(s2);
    var p3 = BitReader.init(s3);
    var p4 = BitReader.init(s4);
    var out_pos: usize = 0;
    const chunk = dst.len / 4;
    try decodeStream(dst[0..chunk], &p1, decoder);
    out_pos += chunk;
    try decodeStream(dst[chunk .. 2 * chunk], &p2, decoder);
    out_pos += chunk;
    try decodeStream(dst[2 * chunk .. 3 * chunk], &p3, decoder);
    out_pos += chunk;
    try decodeStream(dst[3 * chunk ..], &p4, decoder);
}

fn decodeStream(dst: []u8, br: *BitReader, decoder: *const HuffDecoder) errors.ZstdError!void {
    var pos: usize = 0;
    while (pos < dst.len) {
        if (br.bits_consumed + decoder.max_bits > 64) br.reload();
        const idx = (br.container >> @intCast(br.bits_consumed)) & ((@as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(decoder.max_bits))) - 1);
        const e = decoder.table[@intCast(idx)];
        if (e.nb_bits == 0) return error.Corruption;
        dst[pos] = e.symbol;
        pos += 1;
        br.bits_consumed += e.nb_bits;
    }
}

const BitReader = struct {
    src: []const u8,
    container: u64,
    bits_consumed: u32,
    ptr: usize,

    fn init(src: []const u8) BitReader {
        var r = BitReader{ .src = src, .container = 0, .bits_consumed = 64, .ptr = src.len };
        r.reload();
        return r;
    }

    fn reload(r: *BitReader) void {
        while (r.bits_consumed >= 32 and r.ptr >= 4) {
            r.ptr -= 4;
            const v: u64 = @as(u64, r.src[r.ptr]) | (@as(u64, r.src[r.ptr + 1]) << 8) | (@as(u64, r.src[r.ptr + 2]) << 16) | (@as(u64, r.src[r.ptr + 3]) << 24);
            r.container = (r.container << 32) | v;
            r.bits_consumed -= 32;
        }
        if (r.ptr > 0 and r.bits_consumed >= 8) {
            const rem: usize = @min(r.ptr, 4);
            if (rem > 0) {
                var v: u64 = 0;
                for (0..rem) |i| v |= @as(u64, r.src[r.ptr - rem + i]) << @as(std.math.Log2Int(u64), @intCast(i * 8));
                r.ptr -= rem;
                r.container = (r.container << @as(std.math.Log2Int(u64), @intCast(rem * 8))) | v;
                r.bits_consumed -= @intCast(rem * 8);
            }
        }
    }
};

fn readLE16(p: []const u8) u16 {
    return @as(u16, p[0]) | (@as(u16, p[1]) << 8);
}

pub fn decodeSingleStream(dst: []u8, src: []const u8, decoder: *const HuffDecoder) errors.ZstdError!void {
    var br = BitReader.init(src);
    var pos: usize = 0;
    while (pos < dst.len) {
        if (br.bits_consumed + decoder.max_bits > 64) br.reload();
        const idx = (br.container >> @intCast(br.bits_consumed)) & ((@as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(decoder.max_bits))) - 1);
        const e = decoder.table[@intCast(idx)];
        if (e.nb_bits == 0) return error.Corruption;
        dst[pos] = e.symbol;
        pos += 1;
        br.bits_consumed += e.nb_bits;
    }
}

pub fn decompressHuffmanBlock(allocator: std.mem.Allocator, dst: []u8, src: []const u8) errors.ZstdError!usize {
    if (src.len < 1) return error.SrcSizeWrong;
    const header = src[0];
    if (header < 128) {
        return error.UnsupportedFeature;
    }
    _ = allocator;
    _ = dst;
    return error.UnsupportedFeature;
}
