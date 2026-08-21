const c = @import("../common/constants.zig");
pub fn isSkippable(m: u32) bool {
    return (m & c.magic_skippable_mask) == c.magic_skippable_start;
}
