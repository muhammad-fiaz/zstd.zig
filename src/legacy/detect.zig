const constants = @import("../common/constants.zig");

pub fn isLegacy(src: []const u8) bool {
    if (src.len < 4) return false;
    const magic = readLE32(src[0..4]);
    const legacy_magics = [_]u32{
        0xFD2FB521, 0xFD2FB522, 0xFD2FB523, 0xFD2FB524,
        0xFD2FB525, 0xFD2FB526, 0xFD2FB527,
    };
    for (legacy_magics) |m| if (magic == m) return true;
    return false;
}

pub fn legacyVersion(src: []const u8) ?u8 {
    if (src.len < 4) return null;
    const magic = readLE32(src[0..4]);
    return switch (magic) {
        0xFD2FB521 => 1,
        0xFD2FB522 => 2,
        0xFD2FB523 => 3,
        0xFD2FB524 => 4,
        0xFD2FB525 => 5,
        0xFD2FB526 => 6,
        0xFD2FB527 => 7,
        else => null,
    };
}

fn readLE32(p: []const u8) u32 {
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);
}

const testing = @import("std").testing;

test "isLegacy v01" {
    const data = [_]u8{ 0x21, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0 };
    try testing.expect(isLegacy(&data));
}

test "isLegacy v02" {
    const data = [_]u8{ 0x22, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0 };
    try testing.expect(isLegacy(&data));
}

test "isLegacy v03" {
    const data = [_]u8{ 0x23, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0 };
    try testing.expect(isLegacy(&data));
}

test "isLegacy v04" {
    const data = [_]u8{ 0x24, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0 };
    try testing.expect(isLegacy(&data));
}

test "isLegacy v05" {
    const data = [_]u8{ 0x25, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0 };
    try testing.expect(isLegacy(&data));
}

test "isLegacy v06" {
    const data = [_]u8{ 0x26, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0 };
    try testing.expect(isLegacy(&data));
}

test "isLegacy v07" {
    const data = [_]u8{ 0x27, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0 };
    try testing.expect(isLegacy(&data));
}

test "isLegacy false for modern" {
    const data = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD };
    try testing.expect(!isLegacy(&data));
}

test "isLegacy false for short" {
    const data = [_]u8{ 0x21, 0xB5 };
    try testing.expect(!isLegacy(&data));
}

test "legacyVersion v01" {
    const data = [_]u8{ 0x21, 0xB5, 0x2F, 0xFD };
    try testing.expectEqual(@as(?u8, 1), legacyVersion(&data));
}

test "legacyVersion v02" {
    const data = [_]u8{ 0x22, 0xB5, 0x2F, 0xFD };
    try testing.expectEqual(@as(?u8, 2), legacyVersion(&data));
}

test "legacyVersion v03" {
    const data = [_]u8{ 0x23, 0xB5, 0x2F, 0xFD };
    try testing.expectEqual(@as(?u8, 3), legacyVersion(&data));
}

test "legacyVersion v04" {
    const data = [_]u8{ 0x24, 0xB5, 0x2F, 0xFD };
    try testing.expectEqual(@as(?u8, 4), legacyVersion(&data));
}

test "legacyVersion v05" {
    const data = [_]u8{ 0x25, 0xB5, 0x2F, 0xFD };
    try testing.expectEqual(@as(?u8, 5), legacyVersion(&data));
}

test "legacyVersion v06" {
    const data = [_]u8{ 0x26, 0xB5, 0x2F, 0xFD };
    try testing.expectEqual(@as(?u8, 6), legacyVersion(&data));
}

test "legacyVersion v07" {
    const data = [_]u8{ 0x27, 0xB5, 0x2F, 0xFD };
    try testing.expectEqual(@as(?u8, 7), legacyVersion(&data));
}

test "legacyVersion null for modern" {
    const data = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD };
    try testing.expectEqual(@as(?u8, null), legacyVersion(&data));
}

test "legacyVersion null for short" {
    const data = [_]u8{ 0x21, 0xB5 };
    try testing.expectEqual(@as(?u8, null), legacyVersion(&data));
}
