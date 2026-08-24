const std = @import("std");
const errors = @import("../common/errors.zig");
const detect = @import("detect.zig");
const v01 = @import("v01.zig");
const v02 = @import("v02.zig");
const v03 = @import("v03.zig");
const v04 = @import("v04.zig");
const v05 = @import("v05.zig");
const v06 = @import("v06.zig");
const v07 = @import("v07.zig");

pub const Result = struct { decoded: usize, consumed: usize };

pub fn isLegacy(src: []const u8) bool {
    return detect.isLegacy(src);
}

pub fn findFrameSize(src: []const u8) errors.ZstdError!usize {
    const ver = detect.legacyVersion(src) orelse return error.PrefixUnknown;
    return switch (ver) {
        1 => v01.findFrameSize(src),
        2 => v02.findFrameSize(src),
        3 => v03.findFrameSize(src),
        4 => v04.findFrameSize(src),
        5 => v05.findFrameSize(src),
        6 => v06.findFrameSize(src),
        7 => v07.findFrameSize(src),
        else => error.VersionUnsupported,
    };
}

pub fn decompressLegacy(dst: []u8, src: []const u8) errors.ZstdError!Result {
    const ver = detect.legacyVersion(src) orelse return error.PrefixUnknown;
    switch (ver) {
        1 => return v01.decompress(dst, src),
        2 => return v02.decompress(dst, src),
        3 => return v03.decompress(dst, src),
        4 => return v04.decompress(dst, src),
        5 => return v05.decompress(dst, src),
        6 => return v06.decompress(dst, src),
        7 => return v07.decompress(dst, src),
        else => return error.VersionUnsupported,
    }
}

const testing = std.testing;

test "decoder isLegacy" {
    const data = [_]u8{ 0x21, 0xB5, 0x2F, 0xFD };
    try testing.expect(isLegacy(&data));
}

test "decoder isLegacy false" {
    const data = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD };
    try testing.expect(!isLegacy(&data));
}

test "decoder findFrameSize v01 short" {
    const data = [_]u8{ 0x21, 0xB5, 0x2F, 0xFD };
    try testing.expectError(error.SrcSizeWrong, findFrameSize(&data));
}
