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

pub const default_c_parameters = [4][constants.c_level_max + 1]CompressionParameters{
    // Table 0: default - for any srcSize > 256 KB
    // W,  C,  H,  S,  L, TL, strat
    [_]CompressionParameters{
        .{ .windowLog = 19, .chainLog = 12, .hashLog = 13, .searchLog = 1, .minMatch = 6, .targetLength = 1, .strategy = .fast }, // base for negative levels
        .{ .windowLog = 19, .chainLog = 13, .hashLog = 14, .searchLog = 1, .minMatch = 7, .targetLength = 0, .strategy = .fast }, // level 1
        .{ .windowLog = 20, .chainLog = 15, .hashLog = 16, .searchLog = 1, .minMatch = 6, .targetLength = 0, .strategy = .fast }, // level 2
        .{ .windowLog = 21, .chainLog = 16, .hashLog = 17, .searchLog = 1, .minMatch = 5, .targetLength = 0, .strategy = .dfast }, // level 3
        .{ .windowLog = 21, .chainLog = 18, .hashLog = 18, .searchLog = 1, .minMatch = 5, .targetLength = 0, .strategy = .dfast }, // level 4
        .{ .windowLog = 21, .chainLog = 18, .hashLog = 19, .searchLog = 3, .minMatch = 5, .targetLength = 2, .strategy = .greedy }, // level 5
        .{ .windowLog = 21, .chainLog = 18, .hashLog = 19, .searchLog = 3, .minMatch = 5, .targetLength = 4, .strategy = .lazy }, // level 6
        .{ .windowLog = 21, .chainLog = 19, .hashLog = 20, .searchLog = 4, .minMatch = 5, .targetLength = 8, .strategy = .lazy }, // level 7
        .{ .windowLog = 21, .chainLog = 19, .hashLog = 20, .searchLog = 4, .minMatch = 5, .targetLength = 16, .strategy = .lazy2 }, // level 8
        .{ .windowLog = 22, .chainLog = 20, .hashLog = 21, .searchLog = 4, .minMatch = 5, .targetLength = 16, .strategy = .lazy2 }, // level 9
        .{ .windowLog = 22, .chainLog = 21, .hashLog = 22, .searchLog = 5, .minMatch = 5, .targetLength = 16, .strategy = .lazy2 }, // level 10
        .{ .windowLog = 22, .chainLog = 21, .hashLog = 22, .searchLog = 6, .minMatch = 5, .targetLength = 16, .strategy = .lazy2 }, // level 11
        .{ .windowLog = 22, .chainLog = 22, .hashLog = 23, .searchLog = 6, .minMatch = 5, .targetLength = 32, .strategy = .lazy2 }, // level 12
        .{ .windowLog = 22, .chainLog = 22, .hashLog = 22, .searchLog = 4, .minMatch = 5, .targetLength = 32, .strategy = .btlazy2 }, // level 13
        .{ .windowLog = 22, .chainLog = 22, .hashLog = 23, .searchLog = 5, .minMatch = 5, .targetLength = 32, .strategy = .btlazy2 }, // level 14
        .{ .windowLog = 22, .chainLog = 23, .hashLog = 23, .searchLog = 6, .minMatch = 5, .targetLength = 32, .strategy = .btlazy2 }, // level 15
        .{ .windowLog = 22, .chainLog = 22, .hashLog = 22, .searchLog = 5, .minMatch = 5, .targetLength = 48, .strategy = .btopt }, // level 16
        .{ .windowLog = 23, .chainLog = 23, .hashLog = 22, .searchLog = 5, .minMatch = 4, .targetLength = 64, .strategy = .btopt }, // level 17
        .{ .windowLog = 23, .chainLog = 23, .hashLog = 22, .searchLog = 6, .minMatch = 3, .targetLength = 64, .strategy = .btultra }, // level 18
        .{ .windowLog = 23, .chainLog = 24, .hashLog = 22, .searchLog = 7, .minMatch = 3, .targetLength = 256, .strategy = .btultra2 }, // level 19
        .{ .windowLog = 25, .chainLog = 25, .hashLog = 23, .searchLog = 7, .minMatch = 3, .targetLength = 256, .strategy = .btultra2 }, // level 20
        .{ .windowLog = 26, .chainLog = 26, .hashLog = 24, .searchLog = 7, .minMatch = 3, .targetLength = 512, .strategy = .btultra2 }, // level 21
        .{ .windowLog = 27, .chainLog = 27, .hashLog = 25, .searchLog = 9, .minMatch = 3, .targetLength = 999, .strategy = .btultra2 }, // level 22
    },
    // Table 1: for srcSize <= 256 KB
    [_]CompressionParameters{
        .{ .windowLog = 18, .chainLog = 12, .hashLog = 13, .searchLog = 1, .minMatch = 5, .targetLength = 1, .strategy = .fast }, // base for negative levels
        .{ .windowLog = 18, .chainLog = 13, .hashLog = 14, .searchLog = 1, .minMatch = 6, .targetLength = 0, .strategy = .fast }, // level 1
        .{ .windowLog = 18, .chainLog = 14, .hashLog = 14, .searchLog = 1, .minMatch = 5, .targetLength = 0, .strategy = .dfast }, // level 2
        .{ .windowLog = 18, .chainLog = 16, .hashLog = 16, .searchLog = 1, .minMatch = 4, .targetLength = 0, .strategy = .dfast }, // level 3
        .{ .windowLog = 18, .chainLog = 16, .hashLog = 17, .searchLog = 3, .minMatch = 5, .targetLength = 2, .strategy = .greedy }, // level 4
        .{ .windowLog = 18, .chainLog = 17, .hashLog = 18, .searchLog = 5, .minMatch = 5, .targetLength = 2, .strategy = .greedy }, // level 5
        .{ .windowLog = 18, .chainLog = 18, .hashLog = 19, .searchLog = 3, .minMatch = 5, .targetLength = 4, .strategy = .lazy }, // level 6
        .{ .windowLog = 18, .chainLog = 18, .hashLog = 19, .searchLog = 4, .minMatch = 4, .targetLength = 4, .strategy = .lazy }, // level 7
        .{ .windowLog = 18, .chainLog = 18, .hashLog = 19, .searchLog = 4, .minMatch = 4, .targetLength = 8, .strategy = .lazy2 }, // level 8
        .{ .windowLog = 18, .chainLog = 18, .hashLog = 19, .searchLog = 5, .minMatch = 4, .targetLength = 8, .strategy = .lazy2 }, // level 9
        .{ .windowLog = 18, .chainLog = 18, .hashLog = 19, .searchLog = 6, .minMatch = 4, .targetLength = 8, .strategy = .lazy2 }, // level 10
        .{ .windowLog = 18, .chainLog = 18, .hashLog = 19, .searchLog = 5, .minMatch = 4, .targetLength = 12, .strategy = .btlazy2 }, // level 11
        .{ .windowLog = 18, .chainLog = 19, .hashLog = 19, .searchLog = 7, .minMatch = 4, .targetLength = 12, .strategy = .btlazy2 }, // level 12
        .{ .windowLog = 18, .chainLog = 18, .hashLog = 19, .searchLog = 4, .minMatch = 4, .targetLength = 16, .strategy = .btopt }, // level 13
        .{ .windowLog = 18, .chainLog = 18, .hashLog = 19, .searchLog = 4, .minMatch = 3, .targetLength = 32, .strategy = .btopt }, // level 14
        .{ .windowLog = 18, .chainLog = 18, .hashLog = 19, .searchLog = 6, .minMatch = 3, .targetLength = 128, .strategy = .btopt }, // level 15
        .{ .windowLog = 18, .chainLog = 19, .hashLog = 19, .searchLog = 6, .minMatch = 3, .targetLength = 128, .strategy = .btultra }, // level 16
        .{ .windowLog = 18, .chainLog = 19, .hashLog = 19, .searchLog = 8, .minMatch = 3, .targetLength = 256, .strategy = .btultra }, // level 17
        .{ .windowLog = 18, .chainLog = 19, .hashLog = 19, .searchLog = 6, .minMatch = 3, .targetLength = 128, .strategy = .btultra2 }, // level 18
        .{ .windowLog = 18, .chainLog = 19, .hashLog = 19, .searchLog = 8, .minMatch = 3, .targetLength = 256, .strategy = .btultra2 }, // level 19
        .{ .windowLog = 18, .chainLog = 19, .hashLog = 19, .searchLog = 10, .minMatch = 3, .targetLength = 512, .strategy = .btultra2 }, // level 20
        .{ .windowLog = 18, .chainLog = 19, .hashLog = 19, .searchLog = 12, .minMatch = 3, .targetLength = 512, .strategy = .btultra2 }, // level 21
        .{ .windowLog = 18, .chainLog = 19, .hashLog = 19, .searchLog = 13, .minMatch = 3, .targetLength = 999, .strategy = .btultra2 }, // level 22
    },
    // Table 2: for srcSize <= 128 KB
    [_]CompressionParameters{
        .{ .windowLog = 17, .chainLog = 12, .hashLog = 12, .searchLog = 1, .minMatch = 5, .targetLength = 1, .strategy = .fast }, // base for negative levels
        .{ .windowLog = 17, .chainLog = 12, .hashLog = 13, .searchLog = 1, .minMatch = 6, .targetLength = 0, .strategy = .fast }, // level 1
        .{ .windowLog = 17, .chainLog = 13, .hashLog = 15, .searchLog = 1, .minMatch = 5, .targetLength = 0, .strategy = .fast }, // level 2
        .{ .windowLog = 17, .chainLog = 15, .hashLog = 16, .searchLog = 2, .minMatch = 5, .targetLength = 0, .strategy = .dfast }, // level 3
        .{ .windowLog = 17, .chainLog = 17, .hashLog = 17, .searchLog = 2, .minMatch = 4, .targetLength = 0, .strategy = .dfast }, // level 4
        .{ .windowLog = 17, .chainLog = 16, .hashLog = 17, .searchLog = 3, .minMatch = 4, .targetLength = 2, .strategy = .greedy }, // level 5
        .{ .windowLog = 17, .chainLog = 16, .hashLog = 17, .searchLog = 3, .minMatch = 4, .targetLength = 4, .strategy = .lazy }, // level 6
        .{ .windowLog = 17, .chainLog = 16, .hashLog = 17, .searchLog = 3, .minMatch = 4, .targetLength = 8, .strategy = .lazy2 }, // level 7
        .{ .windowLog = 17, .chainLog = 16, .hashLog = 17, .searchLog = 4, .minMatch = 4, .targetLength = 8, .strategy = .lazy2 }, // level 8
        .{ .windowLog = 17, .chainLog = 16, .hashLog = 17, .searchLog = 5, .minMatch = 4, .targetLength = 8, .strategy = .lazy2 }, // level 9
        .{ .windowLog = 17, .chainLog = 16, .hashLog = 17, .searchLog = 6, .minMatch = 4, .targetLength = 8, .strategy = .lazy2 }, // level 10
        .{ .windowLog = 17, .chainLog = 17, .hashLog = 17, .searchLog = 5, .minMatch = 4, .targetLength = 8, .strategy = .btlazy2 }, // level 11
        .{ .windowLog = 17, .chainLog = 18, .hashLog = 17, .searchLog = 7, .minMatch = 4, .targetLength = 12, .strategy = .btlazy2 }, // level 12
        .{ .windowLog = 17, .chainLog = 18, .hashLog = 17, .searchLog = 3, .minMatch = 4, .targetLength = 12, .strategy = .btopt }, // level 13
        .{ .windowLog = 17, .chainLog = 18, .hashLog = 17, .searchLog = 4, .minMatch = 3, .targetLength = 32, .strategy = .btopt }, // level 14
        .{ .windowLog = 17, .chainLog = 18, .hashLog = 17, .searchLog = 6, .minMatch = 3, .targetLength = 256, .strategy = .btopt }, // level 15
        .{ .windowLog = 17, .chainLog = 18, .hashLog = 17, .searchLog = 6, .minMatch = 3, .targetLength = 128, .strategy = .btultra }, // level 16
        .{ .windowLog = 17, .chainLog = 18, .hashLog = 17, .searchLog = 8, .minMatch = 3, .targetLength = 256, .strategy = .btultra }, // level 17
        .{ .windowLog = 17, .chainLog = 18, .hashLog = 17, .searchLog = 10, .minMatch = 3, .targetLength = 512, .strategy = .btultra }, // level 18
        .{ .windowLog = 17, .chainLog = 18, .hashLog = 17, .searchLog = 5, .minMatch = 3, .targetLength = 256, .strategy = .btultra2 }, // level 19
        .{ .windowLog = 17, .chainLog = 18, .hashLog = 17, .searchLog = 7, .minMatch = 3, .targetLength = 512, .strategy = .btultra2 }, // level 20
        .{ .windowLog = 17, .chainLog = 18, .hashLog = 17, .searchLog = 9, .minMatch = 3, .targetLength = 512, .strategy = .btultra2 }, // level 21
        .{ .windowLog = 17, .chainLog = 18, .hashLog = 17, .searchLog = 11, .minMatch = 3, .targetLength = 999, .strategy = .btultra2 }, // level 22
    },
    // Table 3: for srcSize <= 16 KB
    [_]CompressionParameters{
        .{ .windowLog = 14, .chainLog = 12, .hashLog = 13, .searchLog = 1, .minMatch = 5, .targetLength = 1, .strategy = .fast }, // base for negative levels
        .{ .windowLog = 14, .chainLog = 14, .hashLog = 15, .searchLog = 1, .minMatch = 5, .targetLength = 0, .strategy = .fast }, // level 1
        .{ .windowLog = 14, .chainLog = 14, .hashLog = 15, .searchLog = 1, .minMatch = 4, .targetLength = 0, .strategy = .fast }, // level 2
        .{ .windowLog = 14, .chainLog = 14, .hashLog = 15, .searchLog = 2, .minMatch = 4, .targetLength = 0, .strategy = .dfast }, // level 3
        .{ .windowLog = 14, .chainLog = 14, .hashLog = 14, .searchLog = 4, .minMatch = 4, .targetLength = 2, .strategy = .greedy }, // level 4
        .{ .windowLog = 14, .chainLog = 14, .hashLog = 14, .searchLog = 3, .minMatch = 4, .targetLength = 4, .strategy = .lazy }, // level 5
        .{ .windowLog = 14, .chainLog = 14, .hashLog = 14, .searchLog = 4, .minMatch = 4, .targetLength = 8, .strategy = .lazy2 }, // level 6
        .{ .windowLog = 14, .chainLog = 14, .hashLog = 14, .searchLog = 6, .minMatch = 4, .targetLength = 8, .strategy = .lazy2 }, // level 7
        .{ .windowLog = 14, .chainLog = 14, .hashLog = 14, .searchLog = 8, .minMatch = 4, .targetLength = 8, .strategy = .lazy2 }, // level 8
        .{ .windowLog = 14, .chainLog = 15, .hashLog = 14, .searchLog = 5, .minMatch = 4, .targetLength = 8, .strategy = .btlazy2 }, // level 9
        .{ .windowLog = 14, .chainLog = 15, .hashLog = 14, .searchLog = 9, .minMatch = 4, .targetLength = 8, .strategy = .btlazy2 }, // level 10
        .{ .windowLog = 14, .chainLog = 15, .hashLog = 14, .searchLog = 3, .minMatch = 4, .targetLength = 12, .strategy = .btopt }, // level 11
        .{ .windowLog = 14, .chainLog = 15, .hashLog = 14, .searchLog = 4, .minMatch = 3, .targetLength = 24, .strategy = .btopt }, // level 12
        .{ .windowLog = 14, .chainLog = 15, .hashLog = 14, .searchLog = 5, .minMatch = 3, .targetLength = 32, .strategy = .btultra }, // level 13
        .{ .windowLog = 14, .chainLog = 15, .hashLog = 15, .searchLog = 6, .minMatch = 3, .targetLength = 64, .strategy = .btultra }, // level 14
        .{ .windowLog = 14, .chainLog = 15, .hashLog = 15, .searchLog = 7, .minMatch = 3, .targetLength = 256, .strategy = .btultra }, // level 15
        .{ .windowLog = 14, .chainLog = 15, .hashLog = 15, .searchLog = 5, .minMatch = 3, .targetLength = 48, .strategy = .btultra2 }, // level 16
        .{ .windowLog = 14, .chainLog = 15, .hashLog = 15, .searchLog = 6, .minMatch = 3, .targetLength = 128, .strategy = .btultra2 }, // level 17
        .{ .windowLog = 14, .chainLog = 15, .hashLog = 15, .searchLog = 7, .minMatch = 3, .targetLength = 256, .strategy = .btultra2 }, // level 18
        .{ .windowLog = 14, .chainLog = 15, .hashLog = 15, .searchLog = 8, .minMatch = 3, .targetLength = 256, .strategy = .btultra2 }, // level 19
        .{ .windowLog = 14, .chainLog = 15, .hashLog = 15, .searchLog = 8, .minMatch = 3, .targetLength = 512, .strategy = .btultra2 }, // level 20
        .{ .windowLog = 14, .chainLog = 15, .hashLog = 15, .searchLog = 9, .minMatch = 3, .targetLength = 512, .strategy = .btultra2 }, // level 21
        .{ .windowLog = 14, .chainLog = 15, .hashLog = 15, .searchLog = 10, .minMatch = 3, .targetLength = 999, .strategy = .btultra2 }, // level 22
    },
};

pub fn getParams(level: i32, src_size: usize, dictSize: usize) CompressionParameters {
    const rSize: usize = if (src_size == 0 and dictSize == 0)
        std.math.maxInt(usize)
    else
        src_size + dictSize;

    const tableID: usize = @as(usize, @intFromBool(rSize <= 256 * 1024)) +
        @as(usize, @intFromBool(rSize <= 128 * 1024)) +
        @as(usize, @intFromBool(rSize <= 16 * 1024));

    const row: usize = if (level == 0)
        @as(usize, @intCast(constants.c_level_default))
    else if (level < 0)
        0
    else if (level > constants.c_level_max)
        @as(usize, @intCast(constants.c_level_max))
    else
        @as(usize, @intCast(level));

    var cp = default_c_parameters[tableID][row];

    if (level < 0) {
        const clamped = @max(-@as(i32, @intCast(constants.target_length_max)), level);
        cp.targetLength = @intCast(-clamped);
    }

    if (src_size > 0 and src_size <= (@as(usize, 1) << (constants.window_log_max - 1))) {
        const tSize = src_size + dictSize;
        const srcLog: u8 = if (tSize < (1 << constants.hash_log_min))
            constants.hash_log_min
        else
            @intCast(64 - @clz(tSize - 1));
        if (cp.windowLog > srcLog) cp.windowLog = srcLog;
    }
    if (cp.windowLog < constants.window_log_absolutemin) {
        cp.windowLog = constants.window_log_absolutemin;
    }

    return cp;
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
