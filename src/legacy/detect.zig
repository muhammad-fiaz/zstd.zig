const std = @import("std");
const bits = @import("../common/bits.zig");

/// Magic numbers of the pre-1.0 formats, keyed by the version they came from.
///
/// v01 is stored big-endian, v02 and later little-endian, which is the one thing
/// about these headers that is easy to get wrong: a detector that reads them all
/// one way silently recognises nothing.
const Version = struct {
    number: u8,
    magic: u32,
    big_endian: bool,
    /// Whether a reader for this version exists here. Detection does not depend
    /// on it: every version is recognised, decoded or not.
    decodes: bool,
};

const versions = [_]Version{
    .{ .number = 1, .magic = 0xFD2FB51E, .big_endian = true, .decodes = true },
    .{ .number = 2, .magic = 0xFD2FB522, .big_endian = false, .decodes = true },
    .{ .number = 3, .magic = 0xFD2FB523, .big_endian = false, .decodes = true },
    .{ .number = 4, .magic = 0xFD2FB524, .big_endian = false, .decodes = true },
    .{ .number = 5, .magic = 0xFD2FB525, .big_endian = false, .decodes = true },
    .{ .number = 6, .magic = 0xFD2FB526, .big_endian = false, .decodes = false },
    .{ .number = 7, .magic = 0xFD2FB527, .big_endian = false, .decodes = false },
};

/// The version whose header `src` starts with, or null when it is not a frame
/// this decoder handles. A modern frame, a skippable frame and a short buffer all
/// report null.
pub fn legacyVersion(src: []const u8) ?u8 {
    if (src.len < 4) return null;
    const little = bits.readLe32(src[0..4]);
    const big = std.mem.readInt(u32, src[0..4], .big);
    for (versions) |v| {
        if (v.magic == (if (v.big_endian) big else little)) return v.number;
    }
    return null;
}

pub fn isLegacy(src: []const u8) bool {
    return legacyVersion(src) != null;
}

/// Whether `version` has a reader here, as opposed to being recognised and
/// refused. All seven pre-1.0 magics are recognised regardless, so "is this a
/// historic frame" and "can this be decoded" are separate questions.
pub fn supportsDecode(version: u8) bool {
    for (versions) |v| {
        if (v.number == version) return v.decodes;
    }
    return false;
}

const testing = std.testing;
const golden = @import("golden_frames.zig");

test "legacyVersion recognises every historic frame" {
    try testing.expectEqual(@as(?u8, 1), legacyVersion(&golden.frame_v01));
    try testing.expectEqual(@as(?u8, 2), legacyVersion(&golden.frame_v02));
    try testing.expectEqual(@as(?u8, 3), legacyVersion(&golden.frame_v03));
    try testing.expectEqual(@as(?u8, 4), legacyVersion(&golden.frame_v04));
    try testing.expectEqual(@as(?u8, 5), legacyVersion(&golden.frame_v05));
    try testing.expectEqual(@as(?u8, 6), legacyVersion(&golden.frame_v06));
    try testing.expectEqual(@as(?u8, 7), legacyVersion(&golden.frame_v07));
}

test "isLegacy agrees with legacyVersion on the historic frames" {
    for ([_][]const u8{
        &golden.frame_v01, &golden.frame_v02, &golden.frame_v03, &golden.frame_v04,
        &golden.frame_v05, &golden.frame_v06, &golden.frame_v07,
    }) |frame| {
        try testing.expect(isLegacy(frame));
    }
}

test "legacyVersion is null for a modern frame" {
    // A modern frame's magic, 0xFD2FB528 stored little-endian.
    try testing.expectEqual(@as(?u8, null), legacyVersion(&[_]u8{ 0x28, 0xB5, 0x2F, 0xFD }));
}

test "legacyVersion is null for a skippable frame" {
    try testing.expectEqual(@as(?u8, null), legacyVersion(&[_]u8{ 0x50, 0x2A, 0x4D, 0x18 }));
}

test "legacyVersion is null for short input" {
    try testing.expectEqual(@as(?u8, null), legacyVersion(&[_]u8{ 0x1E, 0xB5, 0x2F }));
    try testing.expectEqual(@as(?u8, null), legacyVersion(&[_]u8{}));
    try testing.expect(!isLegacy(&[_]u8{ 0x1E, 0xB5 }));
}

test "legacyVersion rejects a near miss" {
    // One bit off from v02's magic is not a legacy frame.
    var frame = golden.frame_v02;
    frame[3] ^= 1;
    try testing.expectEqual(@as(?u8, null), legacyVersion(&frame));
}

test "v01 is not confused with the versions around it" {
    // 0xFD2FB521 is not a magic any encoder ever wrote; a detector that accepts
    // it is guessing.
    try testing.expectEqual(@as(?u8, null), legacyVersion(&[_]u8{ 0x21, 0xB5, 0x2F, 0xFD }));
}
