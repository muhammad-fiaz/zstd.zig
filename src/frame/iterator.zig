//! Frame iteration over a buffer that may hold several frames back to back, each
//! a regular compressed frame or a skippable frame carrying opaque bytes. Walking
//! that sequence splits a file into its frames, reports each one's metadata, or
//! skips the parts that are not compressed data. Each step reuses the decoder's
//! own frame parsing, so the sizes reported here cannot drift from the sizes the
//! decoder walks. Nothing is copied: the views handed out are only valid while the
//! input buffer is.

const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const bits = @import("../common/bits.zig");
const hdr = @import("header.zig");
const types = @import("../common/types.zig");
const decomp = @import("../decompress/decompress.zig");

/// What kind of frame a step found.
pub const FrameKind = enum {
    /// A Zstandard frame that decompresses to content.
    regular,
    /// A skippable frame: a header plus opaque bytes a decoder must not touch.
    skippable,
};

/// One frame within an iterated buffer.
///
/// `bytes` is a view of the frame in the input buffer, header and payload
/// together, so `src[offset + byteRange.start ..][0..byteRange.len]` is the same
/// bytes. The two views are both provided because callers usually want one of
/// them: payload bytes for re-encoding or checksumming, the whole frame for
/// handing to a decompressor.
pub const Frame = struct {
    kind: FrameKind,
    /// Index of the first byte of this frame within the input buffer.
    offset: usize,
    /// Total bytes the frame occupies, header and payload together. The next
    /// frame starts at `offset + totalSize`.
    totalSize: usize,
    /// The whole frame, header first, as a view of the input buffer. This is
    /// what a decompressor wants; it is exactly `totalSize` bytes.
    frameBytes: []const u8,
    /// The frame's header, starting at `offset`. Only the first `headerSize`
    /// bytes are meaningful for a regular frame, and all eight for a skippable
    /// one.
    headerBytes: []const u8,
    /// The frame's content after its header. Empty for a skippable frame with no
    /// payload.
    payloadBytes: []const u8,

    /// Parsed header. Meaningful only when `kind == .regular`.
    header: ?types.FrameHeader = null,
    /// Declared uncompressed size, `CONTENTSIZE_UNKNOWN` when the frame does not
    /// say. Only meaningful for a regular frame.
    contentSize: u64 = 0,
    /// Window the frame declared, which is the frame's entire content for a
    /// single-segment frame. Zero when unknown.
    windowSize: u64 = 0,
    /// Size of the frame header in bytes, including the magic number.
    headerSize: u32 = 0,

    /// Whether this frame holds content a decompressor should read.
    pub fn isSkippable(self: Frame) bool {
        return self.kind == .skippable;
    }

    /// The whole frame, header first, as a view of the input buffer. This is
    /// exactly `totalSize` bytes and is what a decompressor wants.
    pub fn bytes(self: Frame) []const u8 {
        return self.frameBytes;
    }
};

/// Walks the frames in a buffer. Holds no allocation of its own: it borrows the
/// input for its whole life and `deinit` releases nothing. Iteration stops at
/// the end of the input and reports an error rather than yielding a partial
/// frame, so a truncated tail is never mistaken for a complete one.
pub const FrameIterator = struct {
    src: []const u8,
    pos: usize = 0,

    pub const InitError = errors.ZstdError;

    /// Starts before the first frame. Nothing is validated here: an empty buffer
    /// is valid and simply yields no frames.
    pub fn init(src: []const u8) FrameIterator {
        return .{ .src = src };
    }

    /// The next frame, or null once the input is exhausted.
    pub fn next(self: *FrameIterator) InitError!?Frame {
        if (self.pos >= self.src.len) return null;
        const frame = try parseFrame(self.src, self.pos);
        self.pos += frame.totalSize;
        return frame;
    }

    /// Advances past the next frame and reports how many bytes it occupied,
    /// without building the full record. Useful when only the length matters.
    pub fn skipNext(self: *FrameIterator) InitError!?usize {
        const maybe = try self.next();
        return if (maybe) |frame| frame.totalSize else null;
    }

    /// Byte offset the next `next` call will report. After the final frame this
    /// equals the input length.
    pub fn offset(self: *const FrameIterator) usize {
        return self.pos;
    }

    /// Bytes not yet walked. Empty once iteration has finished.
    pub fn remaining(self: *const FrameIterator) usize {
        return self.src.len - self.pos;
    }

    /// Rewinds to the first frame.
    pub fn reset(self: *FrameIterator) void {
        self.pos = 0;
    }
};

/// Parses the single frame at `offset`, or reports why it cannot. This is the one
/// place a frame's boundaries are established, which is why `FrameIterator` and
/// `decompressInto` cannot disagree about them.
pub fn parseFrame(src: []const u8, offset: usize) errors.ZstdError!Frame {
    if (offset >= src.len) return error.SrcSizeWrong;
    const body = src[offset..];

    // A skippable frame is a header plus an opaque length, so its extent is
    // known from the header alone.
    if (body.len < 4) return error.SrcSizeWrong;
    const magic = bits.readLe32(body[0..4]);
    if ((magic & constants.magic_skippable_mask) == constants.magic_skippable_start) {
        if (body.len < constants.skippable_header_size) return error.SrcSizeWrong;
        const payload = @as(usize, bits.readLe32(body[4..8]));
        // The length is attacker-controlled, so the addition is checked rather
        // than allowed to wrap into a small, passing total.
        const total = std.math.add(usize, payload, constants.skippable_header_size) catch
            return error.SrcSizeWrong;
        if (body.len < total) return error.SrcSizeWrong;
        return .{
            .kind = .skippable,
            .offset = offset,
            .totalSize = total,
            .frameBytes = body[0..total],
            .headerBytes = body[0..constants.skippable_header_size],
            .payloadBytes = body[constants.skippable_header_size..total],
        };
    }

    if (magic != constants.magic_number) return error.InvalidMagic;
    const header = try hdr.getFrameHeader(body);
    // `findFrameCompressedSize` walks the blocks, which is what makes a
    // truncated body detectable rather than assumed complete.
    const total = try decomp.findFrameCompressedSizeFrom(header, body);
    if (total > body.len) return error.SrcSizeWrong;
    return .{
        .kind = .regular,
        .offset = offset,
        .totalSize = total,
        .frameBytes = body[0..total],
        .headerBytes = body[0..header.headerSize],
        .payloadBytes = body[header.headerSize..total],
        .header = header,
        .contentSize = header.contentSize,
        .windowSize = header.windowSize,
        .headerSize = header.headerSize,
    };
}

// Tests

const testing = std.testing;
const comp = @import("../compress/compress.zig");

fn compressed(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    return comp.compress(allocator, payload, .{});
}

test "iterates a single frame and reports its parts" {
    const alloc = testing.allocator;
    const payload = "single frame payload, repeated so it actually compresses";
    const frame_bytes = try compressed(alloc, payload);
    defer alloc.free(frame_bytes);

    var it = FrameIterator.init(frame_bytes);
    const frame = (try it.next()).?;
    try testing.expectEqual(FrameKind.regular, frame.kind);
    try testing.expectEqual(@as(usize, 0), frame.offset);
    try testing.expectEqual(frame_bytes.len, frame.totalSize);
    try testing.expectEqual(frame_bytes.len, frame.bytes().len);
    try testing.expect(!frame.isSkippable());

    // The views must describe the same bytes as the input, not copies.
    try testing.expectEqualSlices(u8, frame_bytes, frame.bytes());
    try testing.expectEqualSlices(
        u8,
        frame_bytes[frame.headerSize..],
        frame.payloadBytes,
    );
    try testing.expectEqual(@as(usize, payload.len), frame.contentSize);
    try testing.expectEqual(@as(usize, 0), it.remaining());
    try testing.expectEqual(@as(?Frame, null), try it.next());
}

test "iterates concatenated frames with exact offsets" {
    const alloc = testing.allocator;
    const a = try compressed(alloc, "first frame content here");
    defer alloc.free(a);
    const b = try compressed(alloc, "second frame content, different text");
    defer alloc.free(b);
    const c = try compressed(alloc, "third and final frame");
    defer alloc.free(c);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    try joined.appendSlice(alloc, a);
    try joined.appendSlice(alloc, b);
    try joined.appendSlice(alloc, c);

    var it = FrameIterator.init(joined.items);
    var expected_offset: usize = 0;
    var count: usize = 0;
    while (try it.next()) |frame| {
        // Each frame must start exactly where the previous one ended: no gaps,
        // no overlap.
        try testing.expectEqual(expected_offset, frame.offset);
        try testing.expectEqual(FrameKind.regular, frame.kind);
        expected_offset += frame.totalSize;
        count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqual(joined.items.len, expected_offset);
}

test "empty input yields no frames" {
    var it = FrameIterator.init("");
    try testing.expectEqual(@as(?Frame, null), try it.next());
    try testing.expectEqual(@as(usize, 0), it.remaining());
}

test "skippable frames are identified and stepped over" {
    var buf: [8 + 5 + 8]u8 = undefined;
    bits.writeLe32(buf[0..4], constants.magic_skippable_start);
    bits.writeLe32(buf[4..8], 5);
    for (buf[8..13], 0..) |*b, i| b.* = @intCast('a' + i);
    bits.writeLe32(buf[13..17], constants.magic_skippable_start + 1);
    bits.writeLe32(buf[17..21], 0);

    var it = FrameIterator.init(&buf);
    const first = (try it.next()).?;
    try testing.expect(first.isSkippable());
    try testing.expectEqual(FrameKind.skippable, first.kind);
    try testing.expectEqual(@as(usize, 13), first.totalSize);
    try testing.expectEqual(@as(usize, 5), first.payloadBytes.len);
    try testing.expectEqualStrings("abcde", first.payloadBytes);

    // A zero-length payload is legal and still occupies its eight header bytes.
    const second = (try it.next()).?;
    try testing.expect(second.isSkippable());
    try testing.expectEqual(@as(usize, 8), second.totalSize);
    try testing.expectEqual(@as(usize, 0), second.payloadBytes.len);
    try testing.expectEqual(@as(usize, 13), second.offset);

    try testing.expectEqual(@as(?Frame, null), try it.next());
}

test "a large skippable payload is measured exactly" {
    var header: [8]u8 = undefined;
    bits.writeLe32(header[0..4], constants.magic_skippable_start);
    bits.writeLe32(header[4..8], 100000);

    var it = FrameIterator.init(&header);
    // The declared payload is not present, so this is truncated rather than a
    // frame of 100000 bytes. header holds only the 8 header bytes.
    try testing.expectError(error.SrcSizeWrong, it.next());
}

test "regular and skippable frames interleave in order" {
    const alloc = testing.allocator;
    const real = try compressed(alloc, "a regular frame between skippable ones");
    defer alloc.free(real);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var skippable: [8 + 3]u8 = undefined;
    bits.writeLe32(skippable[0..4], constants.magic_skippable_start);
    bits.writeLe32(skippable[4..8], 3);
    @memset(skippable[8..11], 'z');
    try buf.appendSlice(alloc, &skippable);
    try buf.appendSlice(alloc, real);
    try buf.appendSlice(alloc, &skippable);

    var it = FrameIterator.init(buf.items);
    try testing.expect((try it.next()).?.isSkippable());
    try testing.expectEqual(FrameKind.regular, (try it.next()).?.kind);
    try testing.expect((try it.next()).?.isSkippable());
    try testing.expectEqual(@as(?Frame, null), try it.next());
    // Regular frames in the middle are still readable through the iterator.
    try testing.expectEqual(buf.items.len, it.offset());
}

test "truncated frames are reported instead of yielded" {
    const alloc = testing.allocator;
    const frame_bytes = try compressed(alloc, "content that will be cut short here");
    defer alloc.free(frame_bytes);

    // Walk every proper prefix. Each one must either fail outright or describe a
    // frame that really is complete within it; what must never happen is a frame
    // reported as complete while bytes are still missing, because a caller would
    // then start decoding at the wrong offset.
    var len: usize = 0;
    while (len < frame_bytes.len) : (len += 1) {
        var it = FrameIterator.init(frame_bytes[0..len]);
        const step = it.next() catch |e| switch (e) {
            // A prefix too short to hold a magic, or with a header that needs
            // bytes the prefix does not have, is simply incomplete.
            error.SrcSizeWrong, error.InvalidMagic, error.PrefixUnknown => continue,
            else => return e,
        };
        if (step) |frame| {
            try testing.expect(frame.totalSize <= len);
            // Whatever it reported, walking on must consume exactly that much.
            try testing.expectEqual(frame.offset + frame.totalSize, it.offset());
            try testing.expectEqual(@as(?Frame, null), try it.next());
        }
    }

    // The whole frame is the prefix that yields exactly itself, once.
    var full = FrameIterator.init(frame_bytes);
    const only = (try full.next()).?;
    try testing.expectEqual(frame_bytes.len, only.totalSize);
    try testing.expectEqual(@as(?Frame, null), try full.next());
}

test "a truncated skippable frame is not mistaken for a complete one" {
    var buf: [8 + 4]u8 = undefined;
    bits.writeLe32(buf[0..4], constants.magic_skippable_start);
    bits.writeLe32(buf[4..8], 4);
    // One byte short of the declared payload.
    var it = FrameIterator.init(buf[0..11]);
    try testing.expectError(error.SrcSizeWrong, it.next());
}

test "invalid and unknown magics are rejected" {
    const junk = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    var it = FrameIterator.init(&junk);
    try testing.expectError(error.InvalidMagic, it.next());

    // Too short to even hold a magic number.
    const tiny = [_]u8{0x28};
    var tiny_it = FrameIterator.init(&tiny);
    try testing.expectError(error.SrcSizeWrong, tiny_it.next());
}

test "skipNext and reset match next" {
    const alloc = testing.allocator;
    const one = try compressed(alloc, "first");
    defer alloc.free(one);
    const two = try compressed(alloc, "second");
    defer alloc.free(two);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    try joined.appendSlice(alloc, one);
    try joined.appendSlice(alloc, two);

    var it = FrameIterator.init(joined.items);
    const a = (try it.next()).?.totalSize;
    it.reset();
    try testing.expectEqual(@as(usize, 0), it.offset());
    const b = (try it.skipNext()).?;
    try testing.expectEqual(a, b);
    const c = (try it.skipNext()).?;
    try testing.expectEqual(two.len, c);
    try testing.expectEqual(@as(?usize, null), try it.skipNext());
}

test "randomized frame sequences iterate exactly once each" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(4242);

    for (0..40) |_| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        var expected_kinds: usize = 0;
        var expected_end: usize = 0;

        const frame_count = prng.random().intRangeAtMost(usize, 1, 5);
        for (0..frame_count) |i| {
            if (prng.random().boolean()) {
                const payload_len = prng.random().intRangeAtMost(usize, 0, 64);
                var skippable: [8 + 64]u8 = undefined;
                bits.writeLe32(skippable[0..4], constants.magic_skippable_start + @as(u32, @intCast(i % 16)));
                bits.writeLe32(skippable[4..8], @intCast(payload_len));
                prng.random().bytes(skippable[8 .. 8 + payload_len]);
                const total = 8 + payload_len;
                try buf.appendSlice(alloc, skippable[0..total]);
                expected_end += total;
            } else {
                var payload: [128]u8 = undefined;
                const payload_len = prng.random().intRangeAtMost(usize, 0, 128);
                prng.random().bytes(payload[0..payload_len]);
                const c = try compressed(alloc, payload[0..payload_len]);
                defer alloc.free(c);
                try buf.appendSlice(alloc, c);
                expected_end += c.len;
            }
            expected_kinds += 1;
        }

        var it = FrameIterator.init(buf.items);
        var seen: usize = 0;
        var cursor: usize = 0;
        while (try it.next()) |frame| {
            try testing.expectEqual(cursor, frame.offset);
            try testing.expect(frame.totalSize > 0);
            cursor += frame.totalSize;
            seen += 1;
            // The iterator must always move forward, or a malformed frame would
            // loop forever.
            try testing.expect(frame.offset + frame.totalSize > frame.offset);
        }
        try testing.expectEqual(expected_kinds, seen);
        try testing.expectEqual(expected_end, cursor);
        try testing.expectEqual(buf.items.len, it.offset());
        try testing.expectEqual(@as(usize, 0), it.remaining());
    }
}
