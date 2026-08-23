pub const maxTableLog: u8 = 9;
pub const minTableLog: u8 = 5;

const std = @import("std");

pub inline fn getTableStep(table_size: usize) usize {
    return (table_size >> 1) + (table_size >> 3) + 3;
}

const testing = std.testing;

test "fse maxTableLog" {
    try testing.expectEqual(@as(u8, 9), maxTableLog);
}
