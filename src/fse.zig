const std = @import("std");
const errors = @import("errors.zig");
const bit_reader = @import("bit_reader.zig");

// FSE (Finite State Entropy) table decoder, referencing lib/common/fse.h and lib/common/zstd_internal.h
// Default distributions per lib/common/zstd_internal.h: LL_defaultNorm, ML_defaultNorm, OF_defaultNorm
// Table building follows FSE_buildDTable_wksp logic (lib/common/fse_compress.c / fse_decompress.c).
pub const ZstdError = errors.ZstdError;

pub const fse_max_bits = 15;
pub const fse_max_symbols = 256;

// Default FSE distributions from lib/common/zstd_internal.h (used when SymbolEncodingType == set_basic)
pub const LL_defaultNorm = [_]i16{ 4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1 };
pub const ML_defaultNorm = [_]i16{ 1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1 };
pub const OF_defaultNorm = [_]i16{ 1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1 };

pub const FseTable = struct {
    symbols: [fse_max_symbols]u8,
    bits: [fse_max_symbols]u8,
    baseline: [fse_max_symbols]i16,
    fast: [1 << 10]u16,
    fast_bits: u5,
    max_symbols: u16,
    max_bits: u8,

    pub fn decodeSymbol(self: *const FseTable, reader: *bit_reader.BitReader) ZstdError!u8 {
        const bits = try reader.peekBits(10);
        const entry = self.fast[bits];
        const len = entry >> 8;
        if (len <= 10) {
            _ = try reader.readBits(@intCast(len));
            return @truncate(entry);
        }
        return self.decodeSlow(reader);
    }

    fn decodeSlow(self: *const FseTable, reader: *bit_reader.BitReader) ZstdError!u8 {
        const bits_left = @as(u32, self.max_bits);
        const acc = try reader.peekBitsRuntime(bits_left);
        var idx = acc >> @intCast(bits_left - 1);
        while (idx < self.max_symbols) {
            const bit_len = self.bits[idx];
            if (bit_len > 0) {
                reader.skipBits(bit_len);
                return self.symbols[idx];
            }
            idx = acc >> @intCast(self.max_bits - 1 - (@as(u32, self.max_bits) - @as(u32, bit_len)));
        }
        return error.InvalidBitStream;
    }

    pub fn initFromWeights(self: *FseTable, weights: []const u8) ZstdError!void {
        const table_log = weights.len;
        if (table_log == 0) {
            self.* = std.mem.zeroes(FseTable);
            self.fast_bits = 10;
            return;
        }

        var counts: [fse_max_symbols]u16 = .{0} ** fse_max_symbols;
        var total: u32 = 0;
        for (weights, 0..) |w, i| {
            if (w > 0) {
                counts[i] = @intCast(w);
                total += w;
            }
        }

        if (total == 0) return error.MalformedFseTable;

        const remaining = (@as(u32, 1) << @intCast(table_log)) - total;
        const step = @max(remaining >> 1, 1);
        var allocated: u32 = 0;
        var sym: u16 = 0;
        while (sym < weights.len and allocated < remaining) : (sym += 1) {
            if (weights[sym] == 0) continue;
            const extra = @min(remaining - allocated, step);
            counts[sym] += @intCast(extra);
            allocated += extra;
        }

        var sorted: [fse_max_symbols]u16 = .{0} ** fse_max_symbols;
        var n: u16 = 0;
        sym = 0;
        while (sym < weights.len) : (sym += 1) {
            if (counts[sym] != 0) {
                sorted[n] = sym;
                n += 1;
            }
        }

        self.max_symbols = n;
        self.max_bits = @intCast(table_log);
        self.fast_bits = 10;
        @memset(&self.fast, 0);
        @memset(&self.symbols, 0);
        @memset(&self.bits, 0);
        @memset(&self.baseline, 0);

        var pos: u16 = 0;
        var b: u8 = 1;
        while (b <= table_log) : (b += 1) {
            var s: u16 = 0;
            while (s < n) : (s += 1) {
                const sym_idx = sorted[s];
                if (counts[sym_idx] > 0) {
                    const entry: u16 = (@as(u16, b) << 8) | sym_idx;
                    const step_size: u16 = @as(u16, 1) << @intCast(table_log - b);
                    var v = @as(u16, @intCast(pos >> @intCast(table_log - b)));
                    var cnt: u16 = 0;
                    while (cnt < counts[sym_idx]) : (cnt += 1) {
                        const fast_idx = v & 0x3FF;
                        self.fast[fast_idx] = entry;
                        v += step_size;
                    }
                    self.symbols[pos >> @intCast(table_log - b)] = sym_idx;
                    self.bits[pos >> @intCast(table_log - b)] = b;
                    self.baseline[pos >> @intCast(table_log - b)] = @intCast(pos);
                    pos += counts[sym_idx];
                }
            }
        }
    }
};
