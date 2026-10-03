const constants = @import("../common/constants.zig");
const bits = @import("../common/bits.zig");
const legacy = @import("../legacy/detect.zig");

pub const FrameKind = enum { zstd, skippable, legacy, unknown };

/// What kind of frame `src` starts with, if any. The kinds are told apart by
/// their first four bytes, so this only reads a magic and does not need the rest
/// of the frame to be present.
pub fn detectFrame(src: []const u8) FrameKind {
    if (src.len < 4) return .unknown;
    const magic = bits.readLe32(src[0..4]);
    if (magic == constants.magic_number) return .zstd;
    if ((magic & constants.magic_skippable_mask) == constants.magic_skippable_start) return .skippable;
    if (legacy.isLegacy(src)) return .legacy;
    return .unknown;
}

const testing = @import("std").testing;

test "detect zstd frame" {
    const buf = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0 };
    try testing.expectEqual(.zstd, detectFrame(&buf));
}

test "detect skippable frame" {
    const buf = [_]u8{ 0x50, 0x2A, 0x4D, 0x18, 0, 0, 0, 0 };
    try testing.expectEqual(.skippable, detectFrame(&buf));
}

test "detect unknown frame" {
    const buf = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0, 0, 0, 0 };
    try testing.expectEqual(.unknown, detectFrame(&buf));
}
