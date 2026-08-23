pub fn highbit32(val: u32) u32 {
    return 31 - @clz(val);
}

pub fn countTrailingZeros32(val: u32) u32 {
    return @ctz(val);
}

pub fn countLeadingZeros32(val: u32) u32 {
    return @clz(val);
}

pub fn nbCommonBytes(val: usize) u32 {
    if (val == 0) return @sizeOf(usize);
    if (@import("builtin").target.cpu.arch.endian() == .little) {
        if (@sizeOf(usize) == 8) {
            return @as(u32, @ctz(@as(u64, val))) >> 3;
        } else {
            return @as(u32, @ctz(@as(u32, @truncate(val)))) >> 3;
        }
    } else {
        if (@sizeOf(usize) == 8) {
            return @as(u32, @clz(@as(u64, val))) >> 3;
        } else {
            return @as(u32, @clz(@as(u32, @truncate(val)))) >> 3;
        }
    }
}

pub fn rotateRightU32(val: u32, count: u32) u32 {
    return (val >> @truncate(count & 0x1F)) | (val << @truncate((@as(u32, 0) -% count) & 0x1F));
}

pub fn rotateRightU64(val: u64, count: u32) u64 {
    return (val >> @truncate(count & 0x3F)) | (val << @truncate((@as(u32, 0) -% count) & 0x3F));
}

const testing = @import("std").testing;

test "highbit32 power of two" {
    try testing.expectEqual(@as(u32, 0), highbit32(1));
    try testing.expectEqual(@as(u32, 1), highbit32(2));
    try testing.expectEqual(@as(u32, 2), highbit32(4));
    try testing.expectEqual(@as(u32, 31), highbit32(0x80000000));
}

test "highbit32 non power of two" {
    try testing.expectEqual(@as(u32, 2), highbit32(7));
    try testing.expectEqual(@as(u32, 3), highbit32(15));
}

test "countTrailingZeros32" {
    try testing.expectEqual(@as(u32, 0), countTrailingZeros32(1));
    try testing.expectEqual(@as(u32, 3), countTrailingZeros32(8));
}

test "countLeadingZeros32" {
    try testing.expectEqual(@as(u32, 31), countLeadingZeros32(1));
    try testing.expectEqual(@as(u32, 0), countLeadingZeros32(0x80000000));
}

test "nbCommonBytes" {
    if (@sizeOf(usize) == 8) {
        try testing.expectEqual(@as(u32, 0), nbCommonBytes(0x00FF00FF00FF00FF));
        try testing.expectEqual(@as(u32, 7), nbCommonBytes(0xFF00000000000000));
    } else {
        try testing.expectEqual(@as(u32, 0), nbCommonBytes(0x00FF00FF));
        try testing.expectEqual(@as(u32, 3), nbCommonBytes(0xFF000000));
    }
}

test "rotateRightU32" {
    try testing.expectEqual(@as(u32, 0xC0000000), rotateRightU32(0x80000001, 1));
    try testing.expectEqual(@as(u32, 1), rotateRightU32(1, 0));
}

test "rotateRightU64" {
    try testing.expectEqual(@as(u64, 2), rotateRightU64(1, 63));
    try testing.expectEqual(@as(u64, 0x8000000000000000), rotateRightU64(1, 1));
}
