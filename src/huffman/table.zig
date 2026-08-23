const std = @import("std");
const errors = @import("../common/errors.zig");

pub const HuffmanTable = struct {
    max_bits: u8,
    symbols: []u8,
    nb_bits: []u8,
    val: []u16,

    pub fn deinit(self: *HuffmanTable, allocator: std.mem.Allocator) void {
        allocator.free(self.symbols);
        allocator.free(self.nb_bits);
        allocator.free(self.val);
    }
};

pub fn buildTableFromWeights(allocator: std.mem.Allocator, weights: []const u8, max_bits: u8) errors.ZstdError!HuffmanTable {
    if (weights.len == 0) return error.InvalidHuffmanTable;
    var nb_per_rank = [_]u16{0} ** 16;
    var val_per_rank = [_]u16{0} ** 16;

    const symbols = try allocator.alloc(u8, weights.len);
    errdefer allocator.free(symbols);
    const nb_bits = try allocator.alloc(u8, weights.len);
    errdefer allocator.free(nb_bits);
    const val = try allocator.alloc(u16, weights.len);
    errdefer allocator.free(val);

    for (weights, 0..) |w, i| {
        symbols[i] = @truncate(i);
        const bits = if (w == 0) 0 else (max_bits + 1 - w);
        nb_bits[i] = bits;
        if (bits <= 15) {
            nb_per_rank[bits] += 1;
        }
    }

    var min: u16 = 0;
    var r = @as(isize, @intCast(max_bits));
    while (r > 0) : (r -= 1) {
        val_per_rank[@intCast(r)] = min;
        min += nb_per_rank[@intCast(r)];
        min >>= 1;
    }

    for (weights, 0..) |_, i| {
        const bits = nb_bits[i];
        if (bits > 0) {
            val[i] = val_per_rank[bits];
            val_per_rank[bits] += 1;
        } else {
            val[i] = 0;
        }
    }

    return HuffmanTable{
        .max_bits = max_bits,
        .symbols = symbols,
        .nb_bits = nb_bits,
        .val = val,
    };
}

const testing = std.testing;

test "buildTableFromWeights basic" {
    const weights = [_]u8{ 4, 3, 2, 1 };
    var tbl = try buildTableFromWeights(testing.allocator, &weights, 4);
    defer tbl.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 4), tbl.max_bits);
}
