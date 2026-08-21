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
    _ = weights;
    _ = max_bits;
    _ = allocator;
    return error.UnsupportedFeature;
}
