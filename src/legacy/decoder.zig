const std = @import("std");
const errors = @import("../common/errors.zig");
const detect = @import("detect.zig");
const v01 = @import("v01.zig");
const v02 = @import("v02.zig");
const v03 = @import("v03.zig");
pub const v04 = @import("v04.zig");
const v05 = @import("v05.zig");
const v06 = @import("v06.zig");
const v07 = @import("v07.zig");

pub const Result = struct { decoded: usize, consumed: usize };

/// A historic frame is a four-byte magic plus at least one three-byte block
/// header, so anything shorter cannot be one.
const min_legacy_frame_size = 7;

pub fn isLegacy(src: []const u8) bool {
    return detect.isLegacy(src);
}

pub fn findFrameSize(allocator: std.mem.Allocator, src: []const u8) errors.ZstdError!usize {
    if (src.len < min_legacy_frame_size) return error.SrcSizeWrong;
    const ver = detect.legacyVersion(src) orelse return error.PrefixUnknown;
    return switch (ver) {
        1 => v01.findFrameSize(allocator, src),
        2 => v02.findFrameSize(allocator, src),
        3 => v03.findFrameSize(allocator, src),
        4 => v04.findFrameSize(allocator, src),
        5 => v05.findFrameSize(allocator, src),
        6 => v06.findFrameSize(allocator, src),
        7 => v07.findFrameSize(allocator, src),
        else => error.VersionUnsupported,
    };
}

pub fn decompressLegacy(allocator: std.mem.Allocator, dst: []u8, src: []const u8) errors.ZstdError!Result {
    if (src.len < min_legacy_frame_size) return error.SrcSizeWrong;
    const ver = detect.legacyVersion(src) orelse return error.PrefixUnknown;
    switch (ver) {
        1 => return v01.decompress(allocator, dst, src),
        2 => return v02.decompress(allocator, dst, src),
        3 => return v03.decompress(allocator, dst, src),
        4 => return v04.decompress(allocator, dst, src),
        5 => return v05.decompress(allocator, dst, src),
        6 => return v06.decompress(allocator, dst, src),
        7 => return v07.decompress(allocator, dst, src),
        else => return error.VersionUnsupported,
    }
}

const testing = std.testing;
const golden = @import("golden_frames.zig");

test "decoder recognises every historic frame" {
    for ([_][]const u8{
        &golden.frame_v01, &golden.frame_v02, &golden.frame_v03, &golden.frame_v04,
        &golden.frame_v05, &golden.frame_v06, &golden.frame_v07,
    }) |frame| {
        try testing.expect(isLegacy(frame));
    }
}

test "decoder isLegacy false for a modern frame" {
    const data = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD };
    try testing.expect(!isLegacy(&data));
}

test "decoder findFrameSize rejects a frame that is only its magic" {
    // A magic number alone is not a frame: the sizes below are what stops a
    // four-byte buffer from being treated as a whole historic frame.
    for ([_][]const u8{
        &[_]u8{ 0x1E, 0xB5, 0x2F, 0xFD },
        &[_]u8{ 0x22, 0xB5, 0x2F, 0xFD },
    }) |data| {
        try testing.expectError(error.SrcSizeWrong, findFrameSize(testing.allocator, data));
    }
}

test "decoder findFrameSize rejects short input" {
    try testing.expectError(error.SrcSizeWrong, findFrameSize(testing.allocator, &[_]u8{ 0x1E, 0xB5 }));
    try testing.expectError(error.SrcSizeWrong, findFrameSize(testing.allocator, &[_]u8{}));
}

test "decoder decompressLegacy rejects a modern frame" {
    const data = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0 };
    try testing.expectError(error.PrefixUnknown, decompressLegacy(testing.allocator, &.{}, &data));
}
