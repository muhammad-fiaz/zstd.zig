const c = @import("../common/constants.zig");
pub fn strategyFromLevel(l: i32) c.Strategy {
    if (l <= 1) return .fast else if (l <= 3) return .dfast else if (l <= 5) return .greedy else if (l <= 7) return .lazy else if (l <= 9) return .lazy2 else if (l <= 12) return .btlazy2 else if (l <= 15) return .btopt else if (l <= 18) return .btultra else return .btultra2;
}

const testing = @import("std").testing;

test "strategyFromLevel" {
    try testing.expectEqual(.fast, strategyFromLevel(1));
    try testing.expectEqual(.fast, strategyFromLevel(0));
    try testing.expectEqual(.dfast, strategyFromLevel(2));
    try testing.expectEqual(.dfast, strategyFromLevel(3));
    try testing.expectEqual(.greedy, strategyFromLevel(4));
    try testing.expectEqual(.greedy, strategyFromLevel(5));
    try testing.expectEqual(.lazy, strategyFromLevel(6));
    try testing.expectEqual(.lazy, strategyFromLevel(7));
    try testing.expectEqual(.lazy2, strategyFromLevel(8));
    try testing.expectEqual(.lazy2, strategyFromLevel(9));
    try testing.expectEqual(.btlazy2, strategyFromLevel(10));
    try testing.expectEqual(.btlazy2, strategyFromLevel(12));
    try testing.expectEqual(.btopt, strategyFromLevel(13));
    try testing.expectEqual(.btopt, strategyFromLevel(15));
    try testing.expectEqual(.btultra, strategyFromLevel(16));
    try testing.expectEqual(.btultra, strategyFromLevel(18));
    try testing.expectEqual(.btultra2, strategyFromLevel(19));
    try testing.expectEqual(.btultra2, strategyFromLevel(22));
}
