//! Recognition and rejection handlers for unsupported historic frame formats (v0.6 and v0.7).

const std = @import("std");
const bits = @import("../common/bits.zig");
const errors = @import("../common/errors.zig");
const decoder = @import("decoder.zig");

const testing = std.testing;

/// The size of a frame of the version named by `magic`, or
/// `error.VersionUnsupported`. `allocator` is unused: nothing is sized.
pub fn findFrameSize(magic: u32, allocator: std.mem.Allocator, src: []const u8) errors.ZstdError!usize {
    _ = allocator;
    if (src.len < 4) return error.SrcSizeWrong;
    if (bits.readLe32(src[0..4]) != magic) return error.PrefixUnknown;
    return error.VersionUnsupported;
}

/// Decodes a frame of the version named by `magic`. `dst` is left untouched.
pub fn decompress(magic: u32, allocator: std.mem.Allocator, dst: []u8, src: []const u8) errors.ZstdError!decoder.Result {
    _ = allocator;
    _ = dst;
    if (src.len < 4) return error.SrcSizeWrong;
    if (bits.readLe32(src[0..4]) != magic) return error.PrefixUnknown;
    return error.VersionUnsupported;
}

test "findFrameSize refuses its own magic and only its own" {
    const alloc = testing.allocator;
    const magic: u32 = 0xFD2FB525;
    var frame: [16]u8 = undefined;
    std.mem.writeInt(u32, frame[0..4], magic, .little);
    @memset(frame[4..], 0xAB);

    try testing.expectError(error.VersionUnsupported, findFrameSize(magic, alloc, &frame));
    // The same bytes under any other magic are a different version's frame.
    try testing.expectError(error.PrefixUnknown, findFrameSize(magic +% 1, alloc, &frame));
    // A buffer too short to even hold a magic is a size problem, not a version.
    try testing.expectError(error.SrcSizeWrong, findFrameSize(magic, alloc, frame[0..3]));
}

test "decompress refuses its own magic and writes nothing" {
    const alloc = testing.allocator;
    const magic: u32 = 0xFD2FB526;
    var frame: [16]u8 = undefined;
    std.mem.writeInt(u32, frame[0..4], magic, .little);
    @memset(frame[4..], 0xCD);

    var dst: [32]u8 = @splat(0x5A);
    try testing.expectError(error.VersionUnsupported, decompress(magic, alloc, &dst, &frame));
    // A refused frame yields no bytes at all, so the output buffer is untouched.
    for (dst) |byte| try testing.expectEqual(@as(u8, 0x5A), byte);

    try testing.expectError(error.PrefixUnknown, decompress(magic +% 2, alloc, &dst, &frame));
    try testing.expectError(error.SrcSizeWrong, decompress(magic, alloc, &dst, frame[0..2]));
    for (dst) |byte| try testing.expectEqual(@as(u8, 0x5A), byte);
}
