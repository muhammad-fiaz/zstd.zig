//! Support for legacy Zstandard v0.4 frames.

const std = @import("std");
const decoder = @import("decoder.zig");
const errors = @import("../common/errors.zig");
const format = @import("format.zig");
const v02 = @import("v02.zig");

pub const magic: u32 = 0xFD2FB524;
pub const version: format.Version = .v04;

/// The size of a v0.4 frame, or `error.SrcSizeWrong` when it is cut short.
pub fn findFrameSize(allocator: std.mem.Allocator, src: []const u8) errors.ZstdError!usize {
    return v02.findFrameSizeFor(version, allocator, src);
}

/// Decodes a v0.4 frame into `dst`.
pub fn decompress(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
) errors.ZstdError!decoder.Result {
    return v02.decompressFor(version, allocator, dst, src);
}

/// Worst-case bytes a v0.4 frame needs for `src_size` input bytes. The frame header
/// is one byte longer than v0.2's, but `compressBound` already leaves room for the
/// header it does not know about, and the extra byte is covered by its margin.
pub fn compressBound(src_size: usize) usize {
    return v02.compressBound(src_size) + 1;
}

/// Encodes `src` as a single-block v0.4 frame, returning the bytes written.
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

test "v04: the real v0.4 frame decodes to its exact content, byte for byte" {
    // A frame produced by the v0.04 encoder: a five-byte frame header, then the
    // block. Decoding it exercises the shared reader against bytes this project did
    // not write.
    var dst: [1024]u8 = undefined;
    const result = try decompress(testing.allocator, &dst, golden.frame_v04[0..]);
    try testing.expectEqual(golden.block.len, result.decoded);
    try testing.expectEqualSlices(u8, golden.block[0..], dst[0..result.decoded]);
    try testing.expectEqual(golden.frame_v04.len, result.consumed);
}

test "v04: the frame header is five bytes and carries a window log" {
    const header = try format.readFrameHeader(.v04, golden.frame_v04[0..]);
    try testing.expectEqual(@as(usize, 5), header.size);
    // The low nibble is the window log above this version's floor, which the
    // reference names ZSTD_WINDOWLOG_ABSOLUTEMIN and sets to 11.
    try testing.expect(header.window_log != null);
    try testing.expectEqual(@as(u8, 11), format.Version.v04.windowLogBase());
    try testing.expect(header.window_log.? >= format.Version.v04.windowLogBase());
    try testing.expectEqual(golden.frame_v04.len, try findFrameSize(testing.allocator, golden.frame_v04[0..]));
}

test "v04: a frame header with a reserved bit set is refused" {
    // The fifth byte's high nibble is reserved. Reading it as a window log would
    // silently accept a frame no encoder could have written.
    var frame = golden.frame_v04;
    frame[4] |= 0x10;
    try testing.expectError(error.FrameParameterUnsupported, decompress(testing.allocator, &.{}, &frame));
}

test "v04: a v0.3 frame is not accepted as v0.4" {
    var dst: [1024]u8 = undefined;
    try testing.expectError(
        error.PrefixUnknown,
        decompress(testing.allocator, &dst, golden.frame_v03[0..]),
    );
}

test "v04: the encoder's frame decodes back to its input" {
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

        // The magic is this version's, and the frame header is five bytes with a
        // reserved high nibble of zero.
        try testing.expectEqualSlices(u8, &[_]u8{
            @truncate(magic),
            @truncate(magic >> 8),
            @truncate(magic >> 16),
            @truncate(magic >> 24),
        }, frame[0..4]);
        try testing.expectEqual(@as(u8, 0), frame[4] & 0xF0);

        const out = try testing.allocator.alloc(u8, src.len + 16);
        defer testing.allocator.free(out);
        const result = try decompress(testing.allocator, out, frame[0..n]);
        try testing.expectEqual(src.len, result.decoded);
        try testing.expectEqualSlices(u8, src, out[0..result.decoded]);
        try testing.expectEqual(n, result.consumed);
    }
}

test "v04: literal section type 3 is refused" {
    // v0.1 to v0.3 decode type 3 as compressed because their switch's `default`
    // label sits on the compressed arm. v0.4 gave it an explicit `default` that
    // reports corruption. The predicate is what the reader branches on, so it is
    // asserted directly; the frame below then shows the refusal end to end.
    try testing.expect(!format.Version.v02.rejectsLiteralType3());
    try testing.expect(!format.Version.v03.rejectsLiteralType3());
    try testing.expect(format.Version.v04.rejectsLiteralType3());
    try testing.expect(format.Version.v05.rejectsLiteralType3());

    // A minimal frame: the magic, a five-byte header naming a window log, then a
    // block whose literal section declares type 3. A block header carries its
    // 19-bit size little-endian with the type in the top two bits of the first
    // byte, so a size of 12 is `00 00 0C` and the end block is `C0 00 00`.
    //
    // The literal section names two bytes stored verbatim: the 20-bit size and
    // 24-bit compressed size share bytes 2-5, so size 2 / csize 2 is
    // `0B 00 40 00 00 00` followed by the two literal bytes. The sequence section
    // is a zero count, which the reader takes from a single byte.
    const frame = [_]u8{
        0x24, 0xb5, 0x2f, 0xfd, // magic
        0x00, // window log, at the floor
        0x00, 0x00, 0x0c, // compressed block, 12 bytes
        0x0b, 0x00, 0x40, 0x00, 0x00, 0x00, // type 3, 2 literals, csize 2
        0x41, 0x42, // the two literal bytes
        0x00, 0x00, 0x00, 0x00, 0x00, // zero sequences
        0xc0, 0x00, 0x00, // end block
    };
    var dst: [64]u8 = @splat(0);
    try testing.expectError(error.Corruption, decompress(testing.allocator, &dst, &frame));
}

test "v04: the repeat offset is stored after the offset resolves" {
    // The rule that differs from v0.3, stated through the version predicates the
    // sequence reader uses rather than through a hand-built bitstream.
    try testing.expect(format.Version.v04.storesRepeatOffsetAfterDecode());
    try testing.expect(format.Version.v05.storesRepeatOffsetAfterDecode());
    try testing.expect(!format.Version.v02.storesRepeatOffsetAfterDecode());
    try testing.expect(!format.Version.v03.storesRepeatOffsetAfterDecode());
    try testing.expect(format.Version.v04.hasSingleRepeatOffset());
    try testing.expect(!format.Version.v06.hasSingleRepeatOffset());
    try testing.expect(!format.Version.v07.hasSingleRepeatOffset());
}
