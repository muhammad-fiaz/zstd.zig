pub fn copy8(dst: [*]u8, src: [*]const u8) void {
    dst[0..8].* = src[0..8].*;
}

pub fn copy16(dst: [*]u8, src: [*]const u8) void {
    dst[0..16].* = src[0..16].*;
}

const testing = @import("std").testing;

test "copy8" {
    var src = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var dst: [8]u8 = undefined;
    copy8(&dst, &src);
    try testing.expectEqualSlices(u8, &src, &dst);
}

test "copy16" {
    var src: [16]u8 = undefined;
    for (&src, 0..) |*b, j| b.* = @intCast(j);
    var dst: [16]u8 = undefined;
    copy16(&dst, &src);
    try testing.expectEqualSlices(u8, &src, &dst);
}
