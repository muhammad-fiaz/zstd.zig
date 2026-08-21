const std = @import("std");
const i = @import("internal");

test "isLegacy v01" {
    const data = [_]u8{ 0x21, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0 };
    try std.testing.expect(i.legacy_detect.isLegacy(&data));
}

test "isLegacy v02" {
    const data = [_]u8{ 0x22, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0 };
    try std.testing.expect(i.legacy_detect.isLegacy(&data));
}

test "isLegacy v03" {
    const data = [_]u8{ 0x23, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0 };
    try std.testing.expect(i.legacy_detect.isLegacy(&data));
}

test "isLegacy v04" {
    const data = [_]u8{ 0x24, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0 };
    try std.testing.expect(i.legacy_detect.isLegacy(&data));
}

test "isLegacy v05" {
    const data = [_]u8{ 0x25, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0 };
    try std.testing.expect(i.legacy_detect.isLegacy(&data));
}

test "isLegacy v06" {
    const data = [_]u8{ 0x26, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0 };
    try std.testing.expect(i.legacy_detect.isLegacy(&data));
}

test "isLegacy v07" {
    const data = [_]u8{ 0x27, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0 };
    try std.testing.expect(i.legacy_detect.isLegacy(&data));
}

test "isLegacy false for modern" {
    const data = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD };
    try std.testing.expect(!i.legacy_detect.isLegacy(&data));
}

test "isLegacy false for short" {
    const data = [_]u8{ 0x21, 0xB5 };
    try std.testing.expect(!i.legacy_detect.isLegacy(&data));
}

test "legacyVersion v01" {
    const data = [_]u8{ 0x21, 0xB5, 0x2F, 0xFD };
    try std.testing.expectEqual(@as(?u8, 1), i.legacy_detect.legacyVersion(&data));
}

test "legacyVersion v02" {
    const data = [_]u8{ 0x22, 0xB5, 0x2F, 0xFD };
    try std.testing.expectEqual(@as(?u8, 2), i.legacy_detect.legacyVersion(&data));
}

test "legacyVersion v03" {
    const data = [_]u8{ 0x23, 0xB5, 0x2F, 0xFD };
    try std.testing.expectEqual(@as(?u8, 3), i.legacy_detect.legacyVersion(&data));
}

test "legacyVersion v04" {
    const data = [_]u8{ 0x24, 0xB5, 0x2F, 0xFD };
    try std.testing.expectEqual(@as(?u8, 4), i.legacy_detect.legacyVersion(&data));
}

test "legacyVersion v05" {
    const data = [_]u8{ 0x25, 0xB5, 0x2F, 0xFD };
    try std.testing.expectEqual(@as(?u8, 5), i.legacy_detect.legacyVersion(&data));
}

test "legacyVersion v06" {
    const data = [_]u8{ 0x26, 0xB5, 0x2F, 0xFD };
    try std.testing.expectEqual(@as(?u8, 6), i.legacy_detect.legacyVersion(&data));
}

test "legacyVersion v07" {
    const data = [_]u8{ 0x27, 0xB5, 0x2F, 0xFD };
    try std.testing.expectEqual(@as(?u8, 7), i.legacy_detect.legacyVersion(&data));
}

test "legacyVersion null for modern" {
    const data = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD };
    try std.testing.expectEqual(@as(?u8, null), i.legacy_detect.legacyVersion(&data));
}

test "legacyVersion null for short" {
    const data = [_]u8{ 0x21, 0xB5 };
    try std.testing.expectEqual(@as(?u8, null), i.legacy_detect.legacyVersion(&data));
}

test "decoder isLegacy" {
    const data = [_]u8{ 0x21, 0xB5, 0x2F, 0xFD };
    try std.testing.expect(i.legacy_decoder.isLegacy(&data));
}

test "decoder isLegacy false" {
    const data = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD };
    try std.testing.expect(!i.legacy_decoder.isLegacy(&data));
}

test "decoder findFrameSize v01 short" {
    const data = [_]u8{ 0x21, 0xB5, 0x2F, 0xFD };
    try std.testing.expectError(error.SrcSizeWrong, i.legacy_decoder.findFrameSize(&data));
}
