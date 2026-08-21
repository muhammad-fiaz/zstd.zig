const std = @import("std");
const errors = @import("errors.zig");
const bit_reader_mod = @import("bit_reader.zig");
const huffman_mod = @import("huffman.zig");
const fse_mod = @import("fse.zig");

pub const ZstdError = errors.ZstdError;
pub const BitReader = bit_reader_mod.BitReader;
pub const HuffmanTable = huffman_mod.HuffmanTable;
pub const FseTable = fse_mod.FseTable;

pub const SeqSymbolType = enum { literal_length, match_length, offset };

pub fn readHufTable(reader: *BitReader, lit_len: *HuffmanTable, match_len: *HuffmanTable, offset: *HuffmanTable) ZstdError!void {
    const header = try reader.readBits(8);
    const dtype_count = (header >> 6) + 1;
    const hlog = (header & 0x3F) + 5;
    if (hlog > 11) return error.MalformedHuffmanTree;

    var weights: [256]u8 = .{0} ** 256;
    var i: u16 = 0;
    while (i < dtype_count) : (i += 1) {
        const w = try reader.readBits(5);
        if (w == 0) return error.MalformedHuffmanTree;
    }

    i = 0;
    while (i < 256) {
        const w = try reader.readBits(5);
        if (w > 0) {
            weights[i] = @intCast(w);
            i += 1;
        } else {
            const remaining = try reader.readBits(2);
            const jump: u16 = 3 + remaining;
            var j: u16 = 0;
            while (j < jump and i < 256) : (j += 1) {
                weights[i] = 0;
                i += 1;
            }
            if (remaining == 3) {
                const run = try reader.readBits(7);
                const total_run: u16 = 11 + run;
                var k: u16 = 0;
                while (k < total_run and i < 256) : (k += 1) {
                    weights[i] = 0;
                    i += 1;
                }
            }
        }
    }

    var lit_weights: [256]u8 = undefined;
    var ml_weights: [256]u8 = undefined;
    var of_weights: [256]u8 = undefined;
    @memcpy(&lit_weights, weights[0..256]);
    @memcpy(&ml_weights, weights[0..256]);
    @memcpy(&of_weights, weights[0..256]);

    try huffman_mod.buildTable(&lit_weights, lit_len);
    try huffman_mod.buildTable(&ml_weights, match_len);
    try huffman_mod.buildTable(&of_weights, offset);
}

pub fn readFseTable(reader: *BitReader, table: *fse_mod.FseTable) ZstdError!void {
    const accuracy_log = try reader.readBits(4);
    if (accuracy_log < 5) return error.MalformedFseTable;
    const table_log = accuracy_log;

    var weights: [256]u8 = .{0} ** 256;
    var remaining = (@as(u32, 1) << @intCast(table_log)) - 1;
    var idx: u16 = 0;

    while (remaining > 0) {
        const w = try reader.readBits(6);
        if (w == 0) return error.MalformedFseTable;

        if (w > table_log) return error.MalformedFseTable;

        const max_sym_plus_one = @min(remaining + 1, 256 - @as(u32, idx));
        if (max_sym_plus_one == 0) break;

        const extra = try reader.readBitsRuntime(@intCast(@min(table_log - w, 4)));
        weights[idx] = @intCast(w + extra);
        idx += 1;
        remaining -= @as(u32, @intCast(weights[idx - 1]));
    }

    try table.initFromWeights(weights[0..idx]);
}

pub const Sequence = struct {
    lit_length: u32,
    match_length: u32,
    offset: u32,
};

pub fn decodeSequences(
    reader: *BitReader,
    sequences: []Sequence,
    lit_len_table: *const HuffmanTable,
    match_len_table: *const HuffmanTable,
    offset_table: *const HuffmanTable,
    ll_decode: ?*const FseTable,
    ml_decode: ?*const FseTable,
    of_decode: ?*const FseTable,
) ZstdError!usize {
    var i: usize = 0;
    while (i < sequences.len) {
        const ll_sym = try lit_len_table.decodeFast(reader);
        const ml_sym = try match_len_table.decodeFast(reader);
        const of_sym = try offset_table.decodeFast(reader);

        const lit_len = decodeLitLength(ll_sym, reader, ll_decode) catch return error.InvalidBitStream;
        const match_len = decodeMatchLength(ml_sym, reader, ml_decode) catch return error.InvalidBitStream;
        const offset_val = decodeOffset(of_sym, reader, of_decode) catch return error.InvalidBitStream;

        if (match_len < 3) return error.InvalidBlockData;
        if (offset_val == 0) return error.InvalidBlockData;

        sequences[i] = .{
            .lit_length = lit_len,
            .match_length = match_len - 3,
            .offset = offset_val,
        };
        i += 1;
    }
    return i;
}

fn decodeLitLength(sym: u8, reader: *BitReader, fse_table: ?*const fse_mod.FseTable) ZstdError!u32 {
    if (sym < 16) return @intCast(sym);
    if (sym < 65) {
        const extra_bits: u4 = @intCast(sym - 16);
        const extra = try reader.readBits(extra_bits);
        return 16 + @as(u32, extra);
    }
    return error.InvalidBitStream;
}

fn decodeMatchLength(sym: u8, reader: *BitReader, fse_table: ?*const fse_mod.FseTable) ZstdError!u32 {
    if (sym < 16) return @intCast(sym) + 3;
    if (sym < 65) {
        const extra_bits: u4 = @intCast(sym - 16);
        const extra = try reader.readBits(extra_bits);
        return 19 + @as(u32, extra);
    }
    return error.InvalidBitStream;
}

fn decodeOffset(sym: u8, reader: *BitReader, fse_table: ?*const fse_mod.FseTable) ZstdError!u32 {
    if (sym < 1) return 1;
    const extra_bits: u5 = @intCast(@min(sym, 28));
    const extra = try reader.readBits(extra_bits);
    return (@as(u32, 1) << @intCast(extra_bits)) + extra;
}
