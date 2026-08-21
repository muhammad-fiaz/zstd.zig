const std = @import("std");
const errors = @import("../common/errors.zig");

pub fn countFrequencies(counts: []u32, src: []const u8, max_symbol: usize) usize {
    @memset(counts[0 .. max_symbol + 1], 0);
    var max: usize = 0;
    for (src) |b| {
        const v: usize = b;
        if (v <= max_symbol) {
            counts[v] += 1;
            if (v > max) max = v;
        }
    }
    return max;
}

pub fn normalizeCounts(normalized: []i16, counts: []const u32, table_log: u8, total: usize) errors.ZstdError!void {
    _ = normalized;
    _ = counts;
    _ = table_log;
    _ = total;
    return error.UnsupportedFeature;
}
