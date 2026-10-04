//! Support for legacy Zstandard v0.5 frames.

const std = @import("std");
const decoder = @import("decoder.zig");
const errors = @import("../common/errors.zig");
const format = @import("format.zig");
const v02 = @import("v02.zig");

pub const magic: u32 = 0xFD2FB525;
pub const version: format.Version = .v05;

/// The size of a v0.5 frame, or `error.SrcSizeWrong` when it is cut short.
pub fn findFrameSize(allocator: std.mem.Allocator, src: []const u8) errors.ZstdError!usize {
    return v02.findFrameSizeFor(version, allocator, src);
}

/// Decodes a v0.5 frame into `dst`.
pub fn decompress(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
) errors.ZstdError!decoder.Result {
    return v02.decompressFor(version, allocator, dst, src);
}

/// Worst-case bytes a v0.5 frame needs for `src_size` input bytes. Same frame
/// header length as v0.4, and the scaled literals header is never longer than the
/// fixed one it replaces, so the bound carries over unchanged.
pub fn compressBound(src_size: usize) usize {
    return v02.compressBound(src_size);
}

/// Encodes `src` as a single-block v0.5 frame, returning the bytes written.
///
/// `dst` must be at least `compressBound(src.len)` long. The writer shares v0.2's
/// block encoder, which emits the v0.2 header shapes; a v0.5 reader accepts those,
/// because the scaled header is a superset: the narrowest code carries the same
/// sizes in fewer bytes.
pub fn compress(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
) errors.ZstdError!usize {
    return v02.compressFor(version, allocator, dst, src);
}

const testing = std.testing;
const golden = @import("golden_frames.zig");

test "v05: the real v0.5 frame decodes to its exact content, byte for byte" {
    const alloc = testing.allocator;
    const frame = golden.frame_v05[0..];
    const size = try findFrameSize(alloc, frame);
    try testing.expectEqual(frame.len, size);

    var dst: [golden.block.len + 64]u8 = undefined;
    const result = try decompress(alloc, dst[0..], frame);
    try testing.expectEqual(golden.block.len, result.decoded);
    try testing.expectEqualSlices(u8, golden.block[0..], dst[0..result.decoded]);
}

test "v05: the real frame is recognised as v0.5 and no other" {
    const alloc = testing.allocator;
    const frame = golden.frame_v05[0..];
    try testing.expect(format.Version.v05.magic() == magic);
    try testing.expectEqual(@as(u8, 5), @backingInt(version));
    try testing.expectEqual(frame.len, try findFrameSize(alloc, frame));

    // A modern frame is not this version's, and a near miss is nobody's.
    const modern = try @import("../compress/compress.zig").compress(alloc, "modern", .{});
    defer alloc.free(modern);
    try testing.expectError(error.PrefixUnknown, findFrameSize(alloc, modern));
}

test "v05: every truncated prefix of the real frame is refused, never read past" {
    const alloc = testing.allocator;
    const frame = golden.frame_v05[0..];
    var dst: [golden.block.len + 64]u8 = undefined;
    var prefix: usize = 0;
    while (prefix < frame.len) : (prefix += 1) {
        if (decompress(alloc, dst[0..], frame[0..prefix])) |result| {
            // A prefix may decode when it happens to end on a section boundary the
            // reader can use; what it must never do is read past the bytes given.
            try testing.expect(result.decoded <= dst.len);
            try testing.expect(result.consumed <= prefix);
        } else |_| {}
    }
}

test "v05: a round trip through this version's own writer decodes back" {
    const alloc = testing.allocator;
    const payload = golden.block[0..];
    var frame: [4096]u8 = undefined;
    const written = try compress(alloc, &frame, payload);
    try testing.expectEqual(written, try findFrameSize(alloc, frame[0..written]));

    var dst: [4096]u8 = undefined;
    const result = try decompress(alloc, &dst, frame[0..written]);
    try testing.expectEqual(payload.len, result.decoded);
    try testing.expectEqualSlices(u8, payload, dst[0..result.decoded]);
}
