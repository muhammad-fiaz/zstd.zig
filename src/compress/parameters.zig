const std = @import("std");
const constants = @import("../common/constants.zig");

pub const CompressionParameters = struct {
    window_log: u8,
    chain_log: u8,
    hash_log: u8,
    search_log: u8,
    min_match: u8,
    target_length: u32,
    strategy: constants.Strategy,
};

pub fn getParams(level: i32, src_size: usize, dict_size: usize) CompressionParameters {
    _ = dict_size;
    const table = [_]CompressionParameters{
        .{ .window_log = 19, .chain_log = 12, .hash_log = 12, .search_log = 1, .min_match = 4, .target_length = 16, .strategy = .fast },
        .{ .window_log = 19, .chain_log = 13, .hash_log = 13, .search_log = 1, .min_match = 4, .target_length = 16, .strategy = .dfast },
        .{ .window_log = 20, .chain_log = 14, .hash_log = 14, .search_log = 1, .min_match = 4, .target_length = 16, .strategy = .greedy },
        .{ .window_log = 21, .chain_log = 16, .hash_log = 15, .search_log = 2, .min_match = 4, .target_length = 16, .strategy = .lazy },
        .{ .window_log = 21, .chain_log = 17, .hash_log = 16, .search_log = 3, .min_match = 4, .target_length = 16, .strategy = .lazy2 },
        .{ .window_log = 22, .chain_log = 18, .hash_log = 17, .search_log = 3, .min_match = 4, .target_length = 16, .strategy = .btlazy2 },
        .{ .window_log = 22, .chain_log = 19, .hash_log = 17, .search_log = 4, .min_match = 4, .target_length = 16, .strategy = .btopt },
        .{ .window_log = 23, .chain_log = 20, .hash_log = 18, .search_log = 5, .min_match = 4, .target_length = 16, .strategy = .btultra },
        .{ .window_log = 23, .chain_log = 21, .hash_log = 19, .search_log = 6, .min_match = 4, .target_length = 16, .strategy = .btultra2 },
    };
    var idx: usize = 0;
    if (level <= 1) idx = 0 else if (level <= 3) idx = 1 else if (level <= 5) idx = 2 else if (level <= 7) idx = 3 else if (level <= 9) idx = 4 else if (level <= 12) idx = 5 else if (level <= 15) idx = 6 else if (level <= 18) idx = 7 else idx = 8;
    var p = table[idx];
    if (src_size < @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(p.window_log))) {
        const needed = 63 - @clz(src_size | 1);
        p.window_log = @intCast(@max(10, @min(@as(usize, p.window_log), needed + 1)));
    }
    return p;
}
