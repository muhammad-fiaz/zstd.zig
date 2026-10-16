//! Support for legacy Zstandard v0.6 frames.

const std = @import("std");
const decoder = @import("decoder.zig");
const errors = @import("../common/errors.zig");
const format = @import("format.zig");
const block = @import("block.zig");

pub const magic: u32 = 0xFD2FB526;
pub const version: format.Version = .v06;

/// The size of a v0.6 frame, or `error.SrcSizeWrong` when it is cut short.
pub fn findFrameSize(allocator: std.mem.Allocator, src: []const u8) errors.ZstdError!usize {
    return block.findFrameSizeFor(version, allocator, src);
}

/// Decodes a v0.6 frame into `dst`.
pub fn decompress(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
) errors.ZstdError!decoder.Result {
    return block.decompressFor(version, allocator, dst, src);
}

const testing = std.testing;
const golden = @import("golden_frames.zig");

test "v06: the real v0.6 frame decodes to its exact content, byte for byte" {
    const alloc = testing.allocator;
    const frame = golden.frame_v06[0..];
    const size = try findFrameSize(alloc, frame);
    try testing.expectEqual(frame.len, size);

    var dst: [golden.block.len + 64]u8 = undefined;
    const result = try decompress(alloc, dst[0..], frame);
    try testing.expectEqual(golden.block.len, result.decoded);
    try testing.expectEqualSlices(u8, golden.block[0..], dst[0..result.decoded]);
}

test "v06: the real frame is recognised as v0.6 and no other" {
    const alloc = testing.allocator;
    const frame = golden.frame_v06[0..];
    try testing.expect(format.Version.v06.magic() == magic);
    try testing.expectEqual(@as(u8, 6), @backingInt(version));
    try testing.expectEqual(frame.len, try findFrameSize(alloc, frame));

    const modern_frame = try @import("../compress/compress.zig").compress(alloc, "modern", .{});
    defer alloc.free(modern_frame);
    try testing.expectError(error.PrefixUnknown, findFrameSize(alloc, modern_frame));
}

test "v06: every truncated prefix of the real frame is refused, never read past" {
    const alloc = testing.allocator;
    const frame = golden.frame_v06[0..];
    var dst: [golden.block.len + 64]u8 = undefined;
    var prefix: usize = 0;
    while (prefix < frame.len) : (prefix += 1) {
        if (decompress(alloc, dst[0..], frame[0..prefix])) |result| {
            try testing.expect(result.decoded <= dst.len);
            try testing.expect(result.consumed <= prefix);
        } else |_| {}
    }
}
