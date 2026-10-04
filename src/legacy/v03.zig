//! Support for legacy Zstandard v0.3 frames.

const std = @import("std");
const decoder = @import("decoder.zig");
const errors = @import("../common/errors.zig");
const format = @import("format.zig");
const v02 = @import("v02.zig");

pub const magic: u32 = 0xFD2FB523;
pub const version: format.Version = .v03;

/// The size of a v0.3 frame, or `error.SrcSizeWrong` when it is cut short.
pub fn findFrameSize(allocator: std.mem.Allocator, src: []const u8) errors.ZstdError!usize {
    return v02.findFrameSizeFor(version, allocator, src);
}

/// Decodes a v0.3 frame into `dst`.
pub fn decompress(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
) errors.ZstdError!decoder.Result {
    return v02.decompressFor(version, allocator, dst, src);
}

/// Worst-case bytes a v0.3 frame needs for `src_size` input bytes. Shared with v0.2:
/// the block layout is identical, so only the frame header differs and it is the
/// same size.
pub fn compressBound(src_size: usize) usize {
    return v02.compressBound(src_size);
}

/// Encodes `src` as a single-block v0.3 frame, returning the bytes written.
///
/// `dst` must be at least `compressBound(src.len)` long.
pub fn compress(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
) errors.ZstdError!usize {
    return v02.compressFor(version, allocator, dst, src);
}

const testing = std.testing;
const golden = @import("golden_frames.zig");

test "v03: the real v0.3 frame decodes to its exact content, byte for byte" {
    // A frame produced by the v0.03 encoder. Decoding it exercises the shared reader
    // against bytes this project did not write.
    var dst: [1024]u8 = undefined;
    const result = try decompress(testing.allocator, &dst, golden.frame_v03[0..]);
    try testing.expectEqual(golden.block.len, result.decoded);
    try testing.expectEqualSlices(u8, golden.block[0..], dst[0..result.decoded]);
    try testing.expectEqual(golden.frame_v03.len, result.consumed);
}

test "v03: the frame is walked to the same length the decoder reports" {
    try testing.expectEqual(
        try findFrameSize(testing.allocator, golden.frame_v03[0..]),
        golden.frame_v03.len,
    );
}

test "v03: a v0.2 frame is not accepted as v0.3" {
    // The two differ only in their magic, so getting this wrong would silently
    // decode a v0.2 frame with v0.3's repeat-offset start. It must be rejected.
    var dst: [1024]u8 = undefined;
    try testing.expectError(
        error.PrefixUnknown,
        decompress(testing.allocator, &dst, golden.frame_v02[0..]),
    );
}

test "v03: the encoder's frame decodes back to its input" {
    // The shapes that switch between a raw fallback and a compressed block, since
    // the block writer's threshold is where a version difference would show first.
    var repeated: [64]u8 = undefined;
    @memset(&repeated, 'a');
    var alternating: [128]u8 = undefined;
    for (&alternating, 0..) |*b, i| b.* = if (i % 2 == 0) 'a' else 'b';
    const cases = [_][]const u8{
        "",
        "a",
        "ab",
        "abcabcabcabcabcabc",
        repeated[0..],
        &alternating,
        golden.block[0..],
    };
    for (cases) |src| {
        const frame = try testing.allocator.alloc(u8, compressBound(src.len));
        defer testing.allocator.free(frame);
        const n = try compress(testing.allocator, frame, src);
        try testing.expect(n <= frame.len);

        // The magic is the version's own, not v0.2's.
        try testing.expectEqualSlices(u8, &[_]u8{
            @truncate(magic),
            @truncate(magic >> 8),
            @truncate(magic >> 16),
            @truncate(magic >> 24),
        }, frame[0..4]);

        const out = try testing.allocator.alloc(u8, src.len + 16);
        defer testing.allocator.free(out);
        const result = try decompress(testing.allocator, out, frame[0..n]);
        try testing.expectEqual(src.len, result.decoded);
        try testing.expectEqualSlices(u8, src, out[0..result.decoded]);
        try testing.expectEqual(n, result.consumed);
    }
}

test "v03: the repeat offset starts at 4, not at 1" {
    // The one behavioural difference from v0.2, stated directly: a first sequence
    // whose offset code is the repeat marker resolves to 4 here and to 1 in v0.2.
    // Built by hand, because an encoder that spells out every distance never emits
    // a repeat and so cannot demonstrate this.
    const sequences_mod = @import("sequences.zig");
    try testing.expectEqual(@as(usize, 4), sequences_mod.initialRepeatOffset(.v03));
    try testing.expectEqual(@as(usize, 1), sequences_mod.initialRepeatOffset(.v02));
}
