//! Single-block decompression dispatch. Raw and RLE blocks are self-contained;
//! compressed blocks delegate to the entropy layer, which resolves matches
//! against `window` (frame-local prior output) and, when present, `dict`
//! (dictionary content that logically precedes the frame).

const std = @import("std");
const errors = @import("../common/errors.zig");
const block_header = @import("../frame/block.zig");
const entropy_mod = @import("entropy.zig");

/// Bounds a single block's match resolution to what the frame allows.
/// `max_offset` is the frame's declared window plus any dictionary content that
/// logically precedes the frame; passing it down makes an over-reaching distance
/// a decoding error rather than a silent read of whatever sits in the buffer.
pub const BlockLimits = struct {
    /// Content that logically precedes the frame, i.e. a dictionary.
    dict: []const u8 = &.{},
    /// Largest legal distance. `std.math.maxInt(usize)` disables the check for
    /// callers that deliberately decode a block in isolation.
    max_offset: usize = std.math.maxInt(usize),
};

pub fn decompressBlock(
    state: *entropy_mod.State,
    dst: []u8,
    src: []const u8,
    window: []const u8,
) errors.ZstdError!usize {
    return decompressBlockLimits(state, dst, src, window, .{});
}

pub fn decompressBlockDict(
    state: *entropy_mod.State,
    dst: []u8,
    src: []const u8,
    window: []const u8,
    dict: []const u8,
) errors.ZstdError!usize {
    return decompressBlockLimits(state, dst, src, window, .{ .dict = dict });
}

pub fn decompressBlockLimits(
    state: *entropy_mod.State,
    dst: []u8,
    src: []const u8,
    window: []const u8,
    limits: BlockLimits,
) errors.ZstdError!usize {
    if (src.len < 3) return error.SrcSizeWrong;
    const props = try block_header.getBlockHeader(src);
    const cSize = props.origSize;
    if (3 + cSize > src.len and props.blockType != .rle) return error.SrcSizeWrong;
    switch (props.blockType) {
        .raw => {
            if (cSize > dst.len) return error.DstSizeTooSmall;
            if (src.len < 3 + cSize) return error.SrcSizeWrong;
            std.mem.copyForwards(u8, dst[0..cSize], src[3 .. 3 + cSize]);
            return cSize;
        },
        .rle => {
            if (src.len < 4) return error.SrcSizeWrong;
            const val = src[3];
            if (cSize > dst.len) return error.DstSizeTooSmall;
            @memset(dst[0..cSize], val);
            return cSize;
        },
        .compressed => {
            const block_src = src[3 .. 3 + cSize];
            return decompressCompressedBlock(state, dst, block_src, window, limits);
        },
        .reserved => return error.InvalidBlock,
    }
}

fn decompressCompressedBlock(
    state: *entropy_mod.State,
    dst: []u8,
    src: []const u8,
    window: []const u8,
    limits: BlockLimits,
) errors.ZstdError!usize {
    if (src.len < 1) return error.SrcSizeWrong;

    var lit = try entropy_mod.decodeLiterals(state, src, constants_block_max);
    defer lit.section.deinit(state.allocator);

    if (lit.bytes_read >= src.len) {
        // No sequences section.
        if (lit.section.data.len > dst.len) return error.DstSizeTooSmall;
        std.mem.copyForwards(u8, dst[0..lit.section.data.len], lit.section.data);
        return lit.section.data.len;
    }

    return entropy_mod.decodeSequences(
        state,
        dst,
        lit.section.data,
        src[lit.bytes_read..],
        .{ .history = window, .dict = limits.dict, .max_offset = limits.max_offset },
    );
}

// The format caps literals at one block (1 << 17 bytes).
const constants_block_max: usize = 1 << 17;

pub fn decompressBlockStreaming(
    state: *entropy_mod.State,
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
    history: *std.ArrayList(u8),
    max_offset: usize,
) errors.ZstdError!usize {
    const hist_slice = history.items;
    const decoded = try decompressBlockLimits(
        state,
        dst,
        src,
        hist_slice,
        .{ .max_offset = @min(max_offset, history.items.len) },
    );
    try history.appendSlice(allocator, dst[0..decoded]);
    if (history.items.len > 1 << 27) {
        const keep = 1 << 27;
        const excess = history.items.len - keep;
        std.mem.copyForwards(u8, history.items[0..keep], history.items[excess .. excess + keep]);
        history.shrinkRetainingCapacity(keep);
    }
    return decoded;
}

const testing = std.testing;

test "a match is bounded by the frame's declared window" {
    // A frame that declares a window of W may reference a distance up to W, and
    // no further, even when the bytes at that distance are sitting right there.
    // Without this bound a hostile frame could name any earlier byte in the
    // caller's buffer and have it copied into the output as if it were frame
    // content.
    var state = entropy_mod.State.init(testing.allocator);
    defer state.deinit();

    var dst: [16]u8 = undefined;
    @memset(dst[0..8], 'a');
    @memset(dst[8..16], 'b');

    // distance 4 is within an 8-byte window
    const limits_ok = entropy_mod.SeqLimits{ .history = dst[0..8], .max_offset = 8 };
    try testing.expectEqual(@as(usize, 4), try entropy_mod.testResolveMatch(&state, &dst, 0, 4, 4, limits_ok));
    try testing.expectEqualStrings("aaaa", dst[0..4]);

    // the same distance is out of range for a 2-byte window
    const limits_tight = entropy_mod.SeqLimits{ .history = dst[0..8], .max_offset = 2 };
    try testing.expectError(error.Corruption, entropy_mod.testResolveMatch(&state, &dst, 0, 4, 4, limits_tight));
}

test "a match never reaches past the output produced so far" {
    var state = entropy_mod.State.init(testing.allocator);
    defer state.deinit();
    var dst: [16]u8 = undefined;
    @memset(dst[0..16], 'x');
    // max_offset counts real reach, so a distance cannot exceed the bytes that
    // exist even when the window would have allowed it.
    const limits = entropy_mod.SeqLimits{ .history = dst[0..4], .max_offset = 4 };
    try testing.expectEqual(@as(usize, 4), try entropy_mod.testResolveMatch(&state, &dst, 0, 4, 4, limits));
    try testing.expectError(error.InvalidOffset, entropy_mod.testResolveMatch(&state, &dst, 0, 5, 4, limits));
}

test "raw block passes through" {
    const block_header_mod = @import("../frame/block.zig");
    var src: [8]u8 = undefined;
    block_header_mod.writeBlockHeader(src[0..3], true, .raw, 5);
    std.mem.copyForwards(u8, src[3..8], "hello");
    var state = entropy_mod.State.init(testing.allocator);
    defer state.deinit();
    var dst: [8]u8 = undefined;
    const n = try decompressBlock(&state, &dst, &src, &.{});
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqualStrings("hello", dst[0..n]);
}

test "rle block expands" {
    const block_header_mod = @import("../frame/block.zig");
    var src: [4]u8 = undefined;
    block_header_mod.writeBlockHeader(src[0..3], true, .rle, 6);
    src[3] = 'Z';
    var state = entropy_mod.State.init(testing.allocator);
    defer state.deinit();
    var dst: [8]u8 = undefined;
    const n = try decompressBlock(&state, &dst, &src, &.{});
    try testing.expectEqual(@as(usize, 6), n);
    try testing.expectEqualStrings("ZZZZZZ", dst[0..n]);
}

test "reserved block is rejected" {
    const block_header_mod = @import("../frame/block.zig");
    var src: [4]u8 = undefined;
    block_header_mod.writeBlockHeader(src[0..3], true, .reserved, 1);
    src[3] = 0;
    var state = entropy_mod.State.init(testing.allocator);
    defer state.deinit();
    var dst: [8]u8 = undefined;
    try testing.expectError(error.InvalidBlock, decompressBlock(&state, &dst, &src, &.{}));
}

test "truncated block header is rejected" {
    var state = entropy_mod.State.init(testing.allocator);
    defer state.deinit();
    var dst: [8]u8 = undefined;
    try testing.expectError(error.SrcSizeWrong, decompressBlock(&state, &dst, &[_]u8{ 1, 2 }, &.{}));
}
