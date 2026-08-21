const std = @import("std");
const errors = @import("errors.zig");
const bit_reader = @import("bit_reader.zig");

pub const ZstdError = errors.ZstdError;

pub const max_sym = 256;
pub const max_bits = 16;

pub const HuffmanTable = struct {
    symbols: [max_sym]u8,
    bits: [max_sym]u8,
    max_bits: u8,
    num_symbols: u16,
    fast: [1 << 10]u16,
    fast_bits: u5,

    pub fn decodeFast(self: *const HuffmanTable, reader: *bit_reader.BitReader) ZstdError!u8 {
        const bits = try reader.peekBits(10);
        const entry = self.fast[bits];
        const len = entry >> 8;
        if (len <= 10) {
            _ = try reader.readBitsRuntime(@as(u32, len));
            return @truncate(entry);
        }
        return self.decodeSlow(reader);
    }

    pub fn decodeSlow(self: *const HuffmanTable, reader: *bit_reader.BitReader) ZstdError!u8 {
        var bits_left: u32 = self.max_bits;
        const accum: u32 = try reader.peekBitsRuntime(bits_left);
        while (bits_left > 0) {
            const idx = accum >> @intCast(bits_left - 1);
            const len = self.bits[idx];
            if (len > 0 and len <= bits_left) {
                const sym = self.symbols[idx];
                reader.skipBits(len);
                return sym;
            }
            bits_left -= 1;
        }
        return error.InvalidBitStream;
    }
};

pub fn buildTable(weights: []const u8, table: *HuffmanTable) ZstdError!void {
    var counts: [max_bits + 1]u16 = .{0} ** (max_bits + 1);
    var max_w: u8 = 0;

    for (weights) |w| {
        if (w == 0) continue;
        if (w > max_bits) return error.MalformedHuffmanTree;
        counts[w] += 1;
        if (w > max_w) max_w = w;
    }

    if (max_w == 0) {
        table.* = std.mem.zeroes(HuffmanTable);
        table.fast_bits = 10;
        return;
    }

    var sorted: [max_sym]u16 = .{0} ** max_sym;
    var offset: u16 = 0;
    var code: u16 = 0;

    var bits: u4 = 1;
    while (bits <= max_w) : (bits += 1) {
        code = (code + counts[bits - 1]) << 1;
        var sym: u16 = 0;
        while (sym < weights.len) : (sym += 1) {
            if (weights[sym] == bits) {
                sorted[offset] = sym;
                offset += 1;
            }
        }
    }

    const num_syms = offset;
    table.num_symbols = num_syms;
    table.max_bits = max_w;
    table.fast_bits = 10;
    @memset(&table.fast, 0);

    code = 0;
    bits = 1;
    var sorted_idx: u16 = 0;
    while (bits <= @min(max_w, 10)) : (bits += 1) {
        code = (code + counts[bits - 1]) << 1;
        while (sorted_idx < num_syms and weights[sorted[sorted_idx]] == bits) {
            const sym_val = sorted[sorted_idx];
            const entry: u16 = (@as(u16, @intCast(bits)) << 8) | sym_val;
            const step: u16 = @as(u16, 1) << @intCast(bits);
            var v = code;
            while (v < 1024) : (v += step) {
                table.fast[v] = entry;
            }
            code += 1;
            sorted_idx += 1;
        }
    }

    var c: u16 = 0;
    bits = 1;
    while (bits <= max_w) : (bits += 1) {
        c = (c + counts[bits - 1]) << 1;
        var s: u16 = 0;
        while (s < num_syms) : (s += 1) {
            if (weights[sorted[s]] == bits) {
                table.symbols[c] = @intCast(sorted[s]);
                table.bits[c] = bits;
                c += 1;
            }
        }
    }
}
