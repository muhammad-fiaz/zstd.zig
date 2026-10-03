//! Recognition and refusal for unsupported legacy Zstandard v0.7 frames.

const std = @import("std");
const errors = @import("../common/errors.zig");
const decoder = @import("decoder.zig");
const refused = @import("refused.zig");

const testing = std.testing;

pub const magic: u32 = 0xFD2FB527;
pub const version: u8 = 7;

/// The size of a v0.7 frame, or `error.VersionUnsupported`.
pub fn findFrameSize(allocator: std.mem.Allocator, src: []const u8) errors.ZstdError!usize {
    return refused.findFrameSize(magic, allocator, src);
}

/// Decodes a v0.7 frame, or returns `error.VersionUnsupported`.
pub fn decompress(allocator: std.mem.Allocator, dst: []u8, src: []const u8) errors.ZstdError!decoder.Result {
    return refused.decompress(magic, allocator, dst, src);
}

test "the version reports its own magic and refuses its own frames" {
    const alloc = testing.allocator;
    var frame: [16]u8 = undefined;
    std.mem.writeInt(u32, frame[0..4], magic, .little);
    @memset(frame[4..], 0x77);

    var dst: [16]u8 = @splat(0x11);
    try testing.expectEqual(@as(u8, 7), version);
    try testing.expectError(error.VersionUnsupported, findFrameSize(alloc, &frame));
    try testing.expectError(error.VersionUnsupported, decompress(alloc, &dst, &frame));
    // Nothing was decoded, so nothing was written.
    for (dst) |byte| try testing.expectEqual(@as(u8, 0x11), byte);
}

test "a neighbouring version's magic is not this version's frame" {
    const alloc = testing.allocator;
    var frame: [8]u8 = undefined;
    std.mem.writeInt(u32, frame[0..4], magic +% 1, .little);
    try testing.expectError(error.PrefixUnknown, findFrameSize(alloc, &frame));
    try testing.expectError(error.PrefixUnknown, decompress(alloc, &frame, &frame));
}
