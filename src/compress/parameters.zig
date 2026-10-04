const std = @import("std");
const constants = @import("../common/constants.zig");

pub const CompressionParameters = struct {
    windowLog: u8,
    chainLog: u8,
    hashLog: u8,
    searchLog: u8,
    minMatch: u8,
    targetLength: u32,
    strategy: constants.Strategy,
};

pub fn getParams(level: i32, src_size: usize, dictSize: usize) CompressionParameters {
    _ = dictSize;
    const table = [_]CompressionParameters{
        .{ .windowLog = 19, .chainLog = 12, .hashLog = 12, .searchLog = 1, .minMatch = 4, .targetLength = 16, .strategy = .fast },
        .{ .windowLog = 19, .chainLog = 13, .hashLog = 13, .searchLog = 1, .minMatch = 4, .targetLength = 16, .strategy = .dfast },
        .{ .windowLog = 20, .chainLog = 14, .hashLog = 14, .searchLog = 1, .minMatch = 4, .targetLength = 16, .strategy = .greedy },
        .{ .windowLog = 21, .chainLog = 16, .hashLog = 15, .searchLog = 2, .minMatch = 4, .targetLength = 16, .strategy = .lazy },
        .{ .windowLog = 21, .chainLog = 17, .hashLog = 16, .searchLog = 3, .minMatch = 4, .targetLength = 16, .strategy = .lazy2 },
        .{ .windowLog = 22, .chainLog = 18, .hashLog = 17, .searchLog = 3, .minMatch = 4, .targetLength = 16, .strategy = .btlazy2 },
        .{ .windowLog = 22, .chainLog = 19, .hashLog = 17, .searchLog = 4, .minMatch = 4, .targetLength = 16, .strategy = .btopt },
        .{ .windowLog = 23, .chainLog = 20, .hashLog = 18, .searchLog = 5, .minMatch = 4, .targetLength = 16, .strategy = .btultra },
        .{ .windowLog = 23, .chainLog = 21, .hashLog = 19, .searchLog = 6, .minMatch = 4, .targetLength = 16, .strategy = .btultra2 },
    };
    var idx: usize = 0;
    if (level <= 1) idx = 0 else if (level <= 3) idx = 1 else if (level <= 5) idx = 2 else if (level <= 7) idx = 3 else if (level <= 9) idx = 4 else if (level <= 12) idx = 5 else if (level <= 15) idx = 6 else if (level <= 18) idx = 7 else idx = 8;
    var p = table[idx];
    if (src_size < @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(p.windowLog))) {
        const needed = 63 - @clz(src_size | 1);
        p.windowLog = @intCast(@max(10, @min(@as(usize, p.windowLog), needed + 1)));
    }
    return p;
}

const testing = std.testing;

test "getParams level 1" {
    const p = getParams(1, 1000, 0);
    try testing.expectEqual(.fast, p.strategy);
}

test "getParams level 22" {
    const p = getParams(22, 1000, 0);
    try testing.expectEqual(.btultra2, p.strategy);
}

test "getParams small src adjusts window" {
    const p = getParams(1, 100, 0);
    try testing.expect(p.windowLog <= 19);
    try testing.expect(p.windowLog >= 10);
}
