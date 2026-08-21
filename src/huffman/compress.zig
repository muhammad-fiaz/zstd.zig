const std = @import("std");
const errors = @import("../common/errors.zig");

pub fn compressHuffman(dst: []u8, src: []const u8) errors.ZstdError!usize {
    _ = dst;
    _ = src;
    return error.UnsupportedFeature;
}

pub fn buildWeights(weights: []u8, counts: []const u32, max_symbol: usize) errors.ZstdError!u8 {
    _ = weights;
    _ = counts;
    _ = max_symbol;
    return error.UnsupportedFeature;
}
