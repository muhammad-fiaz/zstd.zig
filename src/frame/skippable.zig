const c = @import("../common/constants.zig");
pub fn isSkippable(m: u32) bool {
    return (m & c.magic_skippable_mask) == c.magic_skippable_start;
}

const testing = @import("std").testing;

test "skippable isSkippable" {
    try testing.expect(isSkippable(0x184D2A50));
    try testing.expect(isSkippable(0x184D2A5F));
    try testing.expect(!isSkippable(0xFD2FB528));
}
