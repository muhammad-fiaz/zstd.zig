const std = @import("std");
const bits = @import("../common/bits.zig");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const header_mod = @import("../frame/header.zig");
const types = @import("../common/types.zig");
const block_mod = @import("../frame/block.zig");
const checksum_mod = @import("../frame/checksum.zig");
const block_decompress = @import("block.zig");
const entropy_mod = @import("entropy.zig");
const legacy_mod = @import("../legacy/decoder.zig");
/// Upper bound on the decompressed size of every frame in `src`. Frames declaring
/// their content size use it directly; otherwise the bound comes from walking
/// blocks, counting a compressed block as at most one maximum-size block.
/// Skippable frames contribute nothing and legacy frames a conservative 1 MiB.
pub fn decompressBound(allocator: std.mem.Allocator, src: []const u8) errors.ZstdError!usize {
    var total: usize = 0;
    var pos: usize = 0;
    while (pos < src.len) {
        if (src.len - pos < 4) return error.SrcSizeWrong;
        const magic = bits.readLe32(src[pos..]);
        if ((magic & constants.magic_skippable_mask) == constants.magic_skippable_start) {
            pos += try header_mod.readSkippableFrameSize(src[pos..]);
            continue;
        }
        if (magic != constants.magic_number) {
            if (legacy_mod.isLegacy(src[pos..])) {
                const sz = try legacy_mod.findFrameSize(allocator, src[pos..]);
                pos += sz;
                total += 1 << 20;
                continue;
            }
            return error.PrefixUnknown;
        }
        const fh = try header_mod.getFrameHeader(src[pos..]);
        if (fh.frameType == .skippable) {
            pos += fh.headerSize + @as(usize, @intCast(fh.contentSize));
            continue;
        }
        if (fh.contentSize != constants.contentsize_unknown and fh.contentSize != constants.contentsize_error) {
            total += @as(usize, @intCast(fh.contentSize));
        } else {
            total += try unknownFrameBound(src[pos..], fh.headerSize);
        }
        const frame_size = try findFrameCompressedSize(allocator, src[pos..]);
        pos += frame_size;
    }
    return total;
}
/// Walks the blocks of a frame whose content size is unknown and sums the
/// per-block decompressed upper bounds.
fn unknownFrameBound(src: []const u8, headerSize: usize) errors.ZstdError!usize {
    var bound: usize = 0;
    var pos = headerSize;
    var last = false;
    while (!last) {
        if (src.len < pos + 3) return error.SrcSizeWrong;
        const prop = try block_mod.getBlockHeader(src[pos..]);
        last = prop.lastBlock;
        const cSize = prop.origSize;
        pos += 3;
        switch (prop.blockType) {
            .raw, .rle => {
                bound += cSize;
                pos += if (prop.blockType == .raw) cSize else @as(usize, 1);
            },
            .compressed => {
                bound += constants.block_size_max;
                pos += cSize;
            },
            .reserved => return error.InvalidBlock,
        }
        if (src.len < pos) return error.SrcSizeWrong;
    }
    return bound;
}
/// Walks the blocks of a regular frame to its end, then over its checksum. This
/// is the single place a regular frame's extent is calculated, so the size a
/// caller is told about is the size the decoder will actually walk.
fn findFrameSizeBlocks(src: []const u8, fh: types.FrameHeader) errors.ZstdError!usize {
    var pos: usize = fh.headerSize;
    var last = false;
    while (!last) {
        if (src.len < pos + 3) return error.SrcSizeWrong;
        const prop = try block_mod.getBlockHeader(src[pos..]);
        last = prop.lastBlock;
        const cSize = prop.origSize;
        pos += 3;
        if (prop.blockType == .rle) {
            if (src.len < pos + 1) return error.SrcSizeWrong;
            pos += 1;
        } else {
            // `pos + cSize` cannot wrap: cSize is bounded by the 21-bit block
            // size field and pos is within src.
            if (src.len < pos + cSize) return error.SrcSizeWrong;
            pos += cSize;
        }
    }
    if (fh.checksumFlag) {
        // The four checksum bytes must be present, matching upstream
        // ZSTD_findFrameSizeInfo: a truncated checksum is srcSize_wrong.
        if (src.len < pos + 4) return error.SrcSizeWrong;
        pos += 4;
    }
    return pos;
}
/// `findFrameCompressedSize` for a frame whose header the caller has already
/// parsed and knows to be a regular frame, so no allocator is needed and the
/// magic is not re-read.
pub fn findFrameCompressedSizeFrom(fh: types.FrameHeader, src: []const u8) errors.ZstdError!usize {
    return findFrameSizeBlocks(src, fh);
}
pub fn findFrameCompressedSize(allocator: std.mem.Allocator, src: []const u8) errors.ZstdError!usize {
    if (src.len < 4) return error.SrcSizeWrong;
    const magic = bits.readLe32(src[0..4]);
    if ((magic & constants.magic_skippable_mask) == constants.magic_skippable_start) {
        return header_mod.readSkippableFrameSize(src);
    }
    if (magic != constants.magic_number) {
        if (legacy_mod.isLegacy(src)) return legacy_mod.findFrameSize(allocator, src);
        return error.PrefixUnknown;
    }
    const fh = try header_mod.getFrameHeader(src);
    return findFrameSizeBlocks(src, fh);
}
/// Safety limits applied while decoding. `maxWindowSize` rejects frames
/// declaring a window larger than the caller will buffer, keeping a hostile
/// header from demanding a huge allocation. `forceIgnoreChecksum` skips the
/// trailing digest. `dictId` is the ID of the dictionary content supplied: a
/// frame declaring a different non-zero ID was compressed for a different
/// dictionary and is rejected rather than decoded against the wrong content.
pub const Limits = struct {
    maxWindowSize: usize = @as(usize, 1) << @intCast(constants.window_log_limit_default),
    forceIgnoreChecksum: bool = false,
    dictId: u32 = 0,
};
pub fn decompress(allocator: std.mem.Allocator, src: []const u8) anyerror![]u8 {
    return decompressWithLimits(allocator, src, .{});
}
/// Like `decompress`, but honours the caller's safety limits.
pub fn decompressWithLimits(allocator: std.mem.Allocator, src: []const u8, limits: Limits) anyerror![]u8 {
    const bound = try decompressBound(allocator, src);
    const safe_bound = if (bound == 0) src.len * 4 + 1024 else bound;
    const dst = try allocator.alloc(u8, safe_bound);
    errdefer allocator.free(dst);
    const out_size = try decompressIntoLimits(allocator, dst, src, &.{}, limits);
    if (out_size == dst.len) return dst;
    const trimmed = try allocator.realloc(dst, out_size);
    return trimmed;
}
/// Decompresses every frame in `src` into `dst`. `allocator` backs the
/// transient entropy tables only; nothing allocated from it escapes.
pub fn decompressInto(allocator: std.mem.Allocator, dst: []u8, src: []const u8) errors.ZstdError!usize {
    return decompressIntoDict(allocator, dst, src, &.{});
}
/// Like `decompressInto`, but `dict` supplies the dictionary content that
/// logically precedes each frame. Matches in the first block(s) may reach
/// back into it, which is what makes dictionary-compressed frames decodable.
/// An empty `dict` behaves exactly like `decompressInto`.
pub fn decompressIntoDict(allocator: std.mem.Allocator, dst: []u8, src: []const u8, dict: []const u8) errors.ZstdError!usize {
    return decompressIntoLimits(allocator, dst, src, dict, .{});
}
/// `decompressIntoDict` with explicit safety limits, for callers that also want
/// to name the dictionary the frame must have been compressed with.
pub fn decompressIntoDictLimits(allocator: std.mem.Allocator, dst: []u8, src: []const u8, dict: []const u8, limits: Limits) errors.ZstdError!usize {
    return decompressIntoLimits(allocator, dst, src, dict, limits);
}
/// The decoding core: every one-shot entry point funnels through here, so the
/// window limit and the checksum policy are enforced in exactly one place.
pub fn decompressIntoLimits(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
    dict: []const u8,
    limits: Limits,
) errors.ZstdError!usize {
    var srcPos: usize = 0;
    var dstPos: usize = 0;
    var entropyState = entropy_mod.State.init(allocator);
    defer entropyState.deinit();
    while (srcPos < src.len) {
        if (src.len - srcPos < 4) return error.SrcSizeWrong;
        const magic = bits.readLe32(src[srcPos..]);
        if ((magic & constants.magic_skippable_mask) == constants.magic_skippable_start) {
            srcPos += try header_mod.readSkippableFrameSize(src[srcPos..]);
            continue;
        }
        if (magic != constants.magic_number) {
            if (legacy_mod.isLegacy(src[srcPos..])) {
                const consumed = try legacy_mod.decompressLegacy(allocator, dst[dstPos..], src[srcPos..]);
                dstPos += consumed.decoded;
                srcPos += consumed.consumed;
                continue;
            }
            return error.PrefixUnknown;
        }
        const fh = try header_mod.getFrameHeader(src[srcPos..]);
        if (fh.frameType == .skippable) {
            srcPos += fh.headerSize + @as(usize, @intCast(fh.contentSize));
            continue;
        }
        // A frame that declares a window larger than the caller allows is
        // rejected before a single block is decoded, so a hostile header cannot
        // make the decoder buffer more than the caller budgeted for.
        if (fh.windowSize > limits.maxWindowSize) return error.WindowTooLarge;
        // A frame that names a dictionary must be decoded with that dictionary:
        // its matches reach back into the dictionary content, so decoding it
        // against a different one (or none) would produce plausible-looking
        // rubbish rather than an obvious failure.
        if (fh.dictId != 0 and fh.dictId != limits.dictId) return error.DictionaryWrong;
        var frameSrcPos = srcPos + fh.headerSize;
        const frameStartDst = dstPos;
        entropyState.resetFrame(); // frames are independent
        var checksumState = checksum_mod.ChecksumState.init();
        var last = false;
        while (!last) {
            if (src.len < frameSrcPos + 3) return error.SrcSizeWrong;
            const prop = try block_mod.getBlockHeader(src[frameSrcPos..]);
            last = prop.lastBlock;
            const cSize = prop.origSize;
            frameSrcPos += 3;
            switch (prop.blockType) {
                .raw => {
                    if (src.len < frameSrcPos + cSize) return error.SrcSizeWrong;
                    if (dst.len < dstPos + cSize) return error.DstSizeTooSmall;
                    std.mem.copyForwards(u8, dst[dstPos .. dstPos + cSize], src[frameSrcPos .. frameSrcPos + cSize]);
                    checksumState.update(dst[dstPos .. dstPos + cSize]);
                    dstPos += cSize;
                    frameSrcPos += cSize;
                },
                .rle => {
                    if (src.len < frameSrcPos + 1) return error.SrcSizeWrong;
                    const byte = src[frameSrcPos];
                    frameSrcPos += 1;
                    if (dst.len < dstPos + cSize) return error.DstSizeTooSmall;
                    @memset(dst[dstPos .. dstPos + cSize], byte);
                    checksumState.update(dst[dstPos .. dstPos + cSize]);
                    dstPos += cSize;
                },
                .compressed => {
                    if (src.len < frameSrcPos + cSize) return error.SrcSizeWrong;
                    // Window: everything decoded so far within this frame,
                    // preceded by the dictionary content when present.
                    const window = dst[frameStartDst..dstPos];
                    // A match reaches at most `dict.len + windowSize` back: the
                    // dictionary sits in front of the window and is fully
                    // addressable, which is what lets a small window still use a
                    // large dictionary. That a match cannot reach bytes the frame
                    // has not produced yet is enforced per copy. Both lengths are
                    // target-width, so the sum is done in usize and clamped: it
                    // would not fit a 32-bit usize.
                    const max_offset: u32 = @intCast(@min(
                        @as(usize, dict.len) + @as(usize, @intCast(fh.windowSize)),
                        @as(usize, std.math.maxInt(u32)),
                    ));
                    const decoded = block_decompress.decompressBlockLimits(
                        &entropyState,
                        dst[dstPos..],
                        src[frameSrcPos - 3 .. frameSrcPos + cSize],
                        window,
                        .{ .dict = dict, .max_offset = max_offset },
                    ) catch |e| {
                        return e;
                    };
                    checksumState.update(dst[dstPos .. dstPos + decoded]);
                    dstPos += decoded;
                    frameSrcPos += cSize;
                },
                .reserved => return error.InvalidBlock,
            }
        }
        if (fh.checksumFlag and !limits.forceIgnoreChecksum) {
            if (src.len < frameSrcPos + 4) return error.ChecksumWrong;
            const expected = checksum_mod.readChecksum(src[frameSrcPos..]);
            const got = checksumState.final();
            if (expected != got) return error.ChecksumWrong;
            frameSrcPos += 4;
        } else if (fh.checksumFlag) {
            if (src.len < frameSrcPos + 4) return error.ChecksumWrong;
            frameSrcPos += 4;
        }
        if (fh.contentSize != constants.contentsize_unknown and fh.contentSize != constants.contentsize_error) {
            const frame_size = dstPos - frameStartDst;
            if (frame_size != fh.contentSize) return error.ContentSizeMismatch;
        }
        srcPos = frameSrcPos;
    }
    if (srcPos != src.len) return error.SrcSizeWrong;
    return dstPos;
}
pub fn decompressWithDict(allocator: std.mem.Allocator, dst: []u8, src: []const u8, dict: []const u8) errors.ZstdError!usize {
    return decompressIntoDict(allocator, dst, src, dict);
}
const testing = std.testing;
const compress_mod = @import("../compress/compress.zig");
// The window-size limit
//
// A frame header states the window it wants; honouring that blindly would let a
// hostile header demand an enormous buffer, so the decoder refuses frames above a
// caller-supplied limit. The limit must be exact: a frame one byte over is
// refused, one exactly on it accepted, and it applies per frame, not per stream.
// These pin the boundary from both sides on every path that can enforce it.
// ---------------------------------------------------------------------------

const window_dict = @import("../dictionary/dictionary.zig");
const stream_decompress = @import("../streaming/decompress.zig");

/// The widest window this decoder will accept, which is the default limit.
const widest_window: usize = @as(usize, 1) << @intCast(constants.window_log_limit_default);

/// A frame that declares `window_log`, built by compressing enough content that
/// the encoder must use a window of at least that size.
fn frameWithWindow(allocator: std.mem.Allocator, window_log: u8, payload_size: usize) ![]u8 {
    var payload: [300000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(@as(u32, window_log) *% 7919 +% @as(u32, @truncate(payload_size)));
    // Semi-compressible content, so a large window is genuinely used rather than
    // the encoder falling back to a raw block.
    for (payload[0..payload_size]) |*b| {
        b.* = if (prng.random().boolean()) 'a' else 'b';
    }
    return compress_mod.compress(allocator, payload[0..payload_size], .{ .windowLog = window_log });
}

/// The window a frame declares, as the decoder will see it.
fn declaredWindow(allocator: std.mem.Allocator, frame: []const u8) !usize {
    _ = allocator;
    const fh = try header_mod.getFrameHeader(frame);
    return @intCast(fh.windowSize);
}

fn decompressWithLimit(allocator: std.mem.Allocator, src: []const u8, limit: usize) ![]u8 {
    return decompressWithLimits(allocator, src, .{ .maxWindowSize = limit });
}

fn decompressWithOptionsAndLimit(
    allocator: std.mem.Allocator,
    src: []const u8,
    limit: usize,
    dict: *const window_dict.Dictionary,
) ![]u8 {
    const bound = try decompressBound(allocator, src);
    const out = try allocator.alloc(u8, bound);
    errdefer allocator.free(out);
    // A frame that names a dictionary is only decodable with that same
    // dictionary, so the id has to travel with the content.
    const n = try decompressIntoDictLimits(allocator, out, src, dict.content(), .{
        .maxWindowSize = limit,
        .dictId = dict.dictId(),
    });
    return allocator.realloc(out, n) catch out;
}

fn decompressStreamingWithLimit(allocator: std.mem.Allocator, src: []const u8, limit: usize) ![]u8 {
    var sd = stream_decompress.StreamingDecompressor.init(allocator);
    defer sd.deinit();
    sd.setMaxWindowSize(limit);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var scratch: [8192]u8 = undefined;

    // Feed in awkward chunk sizes and take output in awkward pieces, so the
    // limit is exercised through the path clients actually use rather than a
    // single whole-frame push. The loop continues while the stream reports it
    // needs more input, since one call may consume everything and still have
    // output pending.
    var chunk: usize = 1;
    var pos: usize = 0;
    while (pos < src.len) {
        const take: usize = @min(chunk, src.len - pos);
        const r = try sd.decompressStream(scratch[0..], src[pos .. pos + take]);
        try out.appendSlice(allocator, scratch[0..r.outProduced]);
        pos += r.inConsumed;
        chunk = chunk *% 3 +% 1;
        // Drain any output the stream still holds before feeding more input.
        if (r.inConsumed == 0 and !r.needsMore) {
            const tail = try sd.decompressStream(scratch[0..], &.{});
            try out.appendSlice(allocator, scratch[0..tail.outProduced]);
            if (tail.inConsumed != 0 or tail.outProduced != 0) continue;
        }
    }
    // Flush anything left once the input is consumed.
    while (true) {
        const tail = try sd.decompressStream(scratch[0..], &.{});
        if (tail.outProduced == 0) break;
        try out.appendSlice(allocator, scratch[0..tail.outProduced]);
    }
    return out.toOwnedSlice(allocator);
}

fn expectWindowTooLarge(allocator: std.mem.Allocator, src: []const u8, limit: usize) !void {
    if (decompressWithLimit(allocator, src, limit)) |out| {
        allocator.free(out);
        return error.TestExpectedError;
    } else |e| switch (e) {
        error.WindowTooLarge => {},
        else => return e,
    }
}

fn expectWindowTooLargeWithDict(
    allocator: std.mem.Allocator,
    src: []const u8,
    limit: usize,
    dict: *const window_dict.Dictionary,
) !void {
    if (decompressWithOptionsAndLimit(allocator, src, limit, dict)) |out| {
        allocator.free(out);
        return error.TestExpectedError;
    } else |e| switch (e) {
        error.WindowTooLarge => {},
        else => return e,
    }
}

fn expectStreamingWindowTooLarge(allocator: std.mem.Allocator, src: []const u8, limit: usize) !void {
    if (decompressStreamingWithLimit(allocator, src, limit)) |out| {
        allocator.free(out);
        return error.TestExpectedError;
    } else |e| switch (e) {
        error.WindowTooLarge => {},
        else => return e,
    }
}

test "one-shot: the boundary is exact" {
    const alloc = testing.allocator;
    const frame = try frameWithWindow(alloc, 17, 200000);
    defer alloc.free(frame);
    const window = try declaredWindow(alloc, frame);

    // The frame's own window, and anything above it, must be accepted: the
    // limit is a ceiling, not a requirement to be met exactly.
    for ([_]usize{ window, window + 1, window * 2 }) |limit| {
        const out = try decompressWithLimit(alloc, frame, limit);
        defer alloc.free(out);
        try testing.expectEqual(@as(usize, 200000), out.len);
    }

    // One byte below the declared window must be refused. This is the off-by-one
    // that matters: a frame needing exactly `window` bytes of history has no
    // slack.
    try expectWindowTooLarge(alloc, frame, window - 1);
}

test "one-shot: far below the window is refused, not merely smaller" {
    const alloc = testing.allocator;
    const frame = try frameWithWindow(alloc, 18, 250000);
    defer alloc.free(frame);
    const window = try declaredWindow(alloc, frame);

    for ([_]usize{ 0, 1, 1024, window / 2 }) |limit| {
        try expectWindowTooLarge(alloc, frame, limit);
    }
}

test "a limit at the maximum supported value accepts everything it can" {
    const alloc = testing.allocator;
    const frame = try frameWithWindow(alloc, 17, 100000);
    defer alloc.free(frame);
    const out = try decompressWithLimit(alloc, frame, widest_window);
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 100000), out.len);
}

test "multi-frame: each frame is checked against the limit independently" {
    // The limit applies to a frame, not to the stream. A small frame followed by
    // a large one must fail on the large one even though the small one passed,
    // and the failure must not be silently swallowed.
    const alloc = testing.allocator;
    const small = try frameWithWindow(alloc, 10, 5000);
    defer alloc.free(small);
    const large = try frameWithWindow(alloc, 18, 250000);
    defer alloc.free(large);

    const small_window = try declaredWindow(alloc, small);
    const large_window = try declaredWindow(alloc, large);
    try testing.expect(large_window > small_window);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);

    // small then large: the second frame trips the limit.
    try joined.appendSlice(alloc, small);
    try joined.appendSlice(alloc, large);
    try expectWindowTooLarge(alloc, joined.items, small_window + 1);

    // large then small: the first frame trips it, so nothing is decoded at all.
    joined.clearRetainingCapacity();
    try joined.appendSlice(alloc, large);
    try joined.appendSlice(alloc, small);
    try expectWindowTooLarge(alloc, joined.items, small_window + 1);

    // Both frames within the limit: the whole concatenation decodes, and the
    // output is the concatenation of both contents.
    joined.clearRetainingCapacity();
    try joined.appendSlice(alloc, small);
    try joined.appendSlice(alloc, large);
    const out = try decompressWithLimit(alloc, joined.items, large_window);
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 255000), out.len);
}

test "a later frame cannot bypass the limit by following a small one" {
    const alloc = testing.allocator;
    const tiny = try frameWithWindow(alloc, 10, 1000);
    defer alloc.free(tiny);
    const huge = try frameWithWindow(alloc, 20, 280000);
    defer alloc.free(huge);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    try joined.appendSlice(alloc, tiny);
    try joined.appendSlice(alloc, huge);

    // A limit that comfortably admits the first frame but not the second must
    // still reject the stream: the decoder may not stop after the first success.
    const tiny_window = try declaredWindow(alloc, tiny);
    try expectWindowTooLarge(alloc, joined.items, tiny_window * 2);
}

test "streaming: the boundary is exact" {
    const alloc = testing.allocator;
    const frame = try frameWithWindow(alloc, 17, 200000);
    defer alloc.free(frame);
    const window = try declaredWindow(alloc, frame);

    const exact = try decompressStreamingWithLimit(alloc, frame, window);
    defer alloc.free(exact);
    try testing.expectEqual(@as(usize, 200000), exact.len);

    const above = try decompressStreamingWithLimit(alloc, frame, window + 1);
    defer alloc.free(above);
    try testing.expectEqual(@as(usize, 200000), above.len);

    try expectStreamingWindowTooLarge(alloc, frame, window - 1);
}

test "streaming and one-shot agree on the same limit" {
    // Two paths enforcing the same rule must reach the same verdict, otherwise a
    // caller gets different answers depending on how it happens to read the data.
    const alloc = testing.allocator;
    const frame = try frameWithWindow(alloc, 16, 150000);
    defer alloc.free(frame);
    const window = try declaredWindow(alloc, frame);

    var limit: usize = 1024;
    while (limit <= window) : (limit *= 2) {
        const one_shot_rejects = blk: {
            const r = decompressWithLimit(alloc, frame, limit) catch break :blk true;
            alloc.free(r);
            break :blk false;
        };
        const streaming_rejects = blk: {
            const r = decompressStreamingWithLimit(alloc, frame, limit) catch break :blk true;
            alloc.free(r);
            break :blk false;
        };
        try testing.expectEqual(one_shot_rejects, streaming_rejects);
    }
}

test "dictionary frames interact with the window limit" {
    // A dictionary sits in front of the frame's output, so a frame that needs a
    // large window is still refused when the limit is smaller - the dictionary
    // does not grant extra window.
    const alloc = testing.allocator;
    var dict = try window_dict.createDictionaryFromData(alloc, "dictionary content that repeats a lot of times over", 4242);
    defer dict.deinit();

    var payload: [200000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    for (&payload) |*b| {
        b.* = if (prng.random().boolean()) 'a' else 'b';
    }
    const frame = try compress_mod.compress(alloc, &payload, .{ .windowLog = 17, .dictionary = &dict });
    defer alloc.free(frame);

    const window = try declaredWindow(alloc, frame);

    const out = try decompressWithOptionsAndLimit(alloc, frame, window, &dict);
    defer alloc.free(out);
    try testing.expectEqual(payload.len, out.len);

    try expectWindowTooLargeWithDict(alloc, frame, window - 1, &dict);
}

test "a skippable frame is stepped over regardless of the limit" {
    // Skippable frames carry opaque bytes and declare no window, so the limit has
    // nothing to check against them. They must not be the reason a stream fails.
    const alloc = testing.allocator;
    const frame = try frameWithWindow(alloc, 10, 5000);
    defer alloc.free(frame);
    const window = try declaredWindow(alloc, frame);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    var skippable: [8 + 4]u8 = undefined;
    std.mem.writeInt(u32, skippable[0..4], 0x184D2A50, .little);
    std.mem.writeInt(u32, skippable[4..8], 4, .little);
    @memset(skippable[8..12], 0xAB);
    try joined.appendSlice(alloc, &skippable);
    try joined.appendSlice(alloc, frame);

    const out = try decompressWithLimit(alloc, joined.items, window);
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 5000), out.len);
}
test "decompress roundtrip" {
    const alloc = testing.allocator;
    const src = "roundtrip test data";
    const c = try compress_mod.compress(alloc, src, .{});
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualStrings(src, d);
}
test "decompress empty" {
    const alloc = testing.allocator;
    const c = try compress_mod.compress(alloc, "", .{});
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqual(@as(usize, 0), d.len);
}
test "decompress single byte" {
    const alloc = testing.allocator;
    const src = [_]u8{0xFF};
    const c = try compress_mod.compress(alloc, &src, .{});
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualSlices(u8, &src, d);
}
test "decompress large data" {
    const alloc = testing.allocator;
    var src: [4096]u8 = undefined;
    for (&src, 0..) |*b, j| b.* = @intCast(j % 256);
    const c = try compress_mod.compress(alloc, &src, .{});
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualSlices(u8, &src, d);
}
test "decompressBound basic" {
    const alloc = testing.allocator;
    const c = try compress_mod.compress(alloc, "bound test", .{});
    defer alloc.free(c);
    const bound = try decompressBound(alloc, c);
    try testing.expect(bound >= 10);
}
test "findFrameCompressedSize" {
    const alloc = testing.allocator;
    const c = try compress_mod.compress(alloc, "frame size", .{});
    defer alloc.free(c);
    const sz = try findFrameCompressedSize(alloc, c);
    try testing.expectEqual(c.len, sz);
}
test "decompress invalid magic" {
    const alloc = testing.allocator;
    const bad = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    const result = decompress(alloc, &bad);
    try testing.expectError(error.PrefixUnknown, result);
}
