pub const maxTableLog: u8 = 11;

const testing = @import("std").testing;

test "huffman maxTableLog" {
    try testing.expectEqual(@as(u8, 11), maxTableLog);
}
