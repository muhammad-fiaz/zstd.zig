const c = @import("../common/constants.zig");
pub fn strategyFromLevel(l: i32) c.Strategy {
    if (l <= 1) return .fast else if (l <= 3) return .dfast else if (l <= 5) return .greedy else if (l <= 7) return .lazy else if (l <= 9) return .lazy2 else if (l <= 12) return .btlazy2 else if (l <= 15) return .btopt else if (l <= 18) return .btultra else return .btultra2;
}
