//! Single-frame decompression entry point.
//!
//! Parses one Zstandard frame (magic, frame header, block loop, optional
//! XXH64 checksum) and writes decoded bytes into `dst`.

const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const header_mod = @import("../frame/header.zig");
const block_header = @import("../frame/block.zig");
const checksum_mod = @import("../frame/checksum.zig");
const entropy_mod = @import("entropy.zig");
const block_decompress = @import("block.zig");

pub const FrameResult = struct {
    written: usize,
    consumed: usize,
};

/// Decompress exactly one regular Zstandard frame starting at `src[0]`.
/// `state` carries entropy tables across the frame's blocks; callers should
/// reset it between frames.
pub fn decompressFrame(
    state: *entropy_mod.State,
    dst: []u8,
    src: []const u8,
) errors.ZstdError!FrameResult {
    if (src.len < 4) return error.SrcSizeWrong;
    const magic = std.mem.readInt(u32, src[0..4], .little);
    if ((magic & constants.magic_skippable_mask) == constants.magic_skippable_start) {
        return error.InvalidFrameHeader; // use skipFrame() for skippable frames
    }
    if (magic != constants.magic_number) return error.PrefixUnknown;

    const fh = try header_mod.getFrameHeader(src);
    var src_pos: usize = fh.header_size;
    var dst_pos: usize = 0;
    state.resetFrame();

    var checksum_state = checksum_mod.ChecksumState.init();
    var last = false;
    while (!last) {
        if (src.len < src_pos + 3) return error.SrcSizeWrong;
        const props = try block_header.getBlockHeader(src[src_pos..]);
        last = props.last_block;
        const csize = props.orig_size;
        src_pos += 3;

        switch (props.block_type) {
            .raw => {
                if (src.len < src_pos + csize) return error.SrcSizeWrong;
                if (dst.len < dst_pos + csize) return error.DstSizeTooSmall;
                @memcpy(dst[dst_pos .. dst_pos + csize], src[src_pos .. src_pos + csize]);
                checksum_state.update(dst[dst_pos .. dst_pos + csize]);
                dst_pos += csize;
                src_pos += csize;
            },
            .rle => {
                if (src.len < src_pos + 1) return error.SrcSizeWrong;
                const value = src[src_pos];
                src_pos += 1;
                if (dst.len < dst_pos + csize) return error.DstSizeTooSmall;
                @memset(dst[dst_pos .. dst_pos + csize], value);
                checksum_state.update(dst[dst_pos .. dst_pos + csize]);
                dst_pos += csize;
            },
            .compressed => {
                if (src.len < src_pos + csize) return error.SrcSizeWrong;
                // Window: everything decoded so far in this frame.
                const decoded = try block_decompress.decompressBlock(
                    state,
                    dst[dst_pos..],
                    src[src_pos - 3 .. src_pos + csize],
                    dst[0..dst_pos],
                );
                checksum_state.update(dst[dst_pos .. dst_pos + decoded]);
                dst_pos += decoded;
                src_pos += csize;
            },
            .reserved => return error.InvalidBlock,
        }
    }

    if (fh.checksum_flag) {
        if (src.len < src_pos + 4) return error.SrcSizeWrong;
        const expected = checksum_mod.readChecksum(src[src_pos..]);
        if (expected != checksum_state.final()) return error.ChecksumWrong;
        src_pos += 4;
    }

    if (fh.content_size != constants.contentsize_unknown and fh.content_size != constants.contentsize_error) {
        if (dst_pos != @as(usize, @intCast(fh.content_size))) return error.ContentSizeMismatch;
    }

    return .{ .written = dst_pos, .consumed = src_pos };
}

/// Skip over one skippable frame, returning its total size.
pub fn skipFrame(src: []const u8) errors.ZstdError!usize {
    if (src.len < 8) return error.SrcSizeWrong;
    const magic = std.mem.readInt(u32, src[0..4], .little);
    if ((magic & constants.magic_skippable_mask) != constants.magic_skippable_start) return error.PrefixUnknown;
    const size = std.mem.readInt(u32, src[4..8], .little);
    const total = @as(usize, size) + 8;
    if (src.len < total) return error.SrcSizeWrong;
    return total;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "decompressFrame round trip and consumed size" {
    const compress_mod = @import("../compress/compress.zig");
    const alloc = testing.allocator;
    var state = entropy_mod.State.init(alloc);
    defer state.deinit();

    const payload = "frame-level round trip payload " ** 20;
    const comp = try compress_mod.compress(alloc, payload, .{});
    defer alloc.free(comp);

    const dst = try alloc.alloc(u8, payload.len);
    defer alloc.free(dst);

    const res = try decompressFrame(&state, dst, comp);
    try testing.expectEqual(payload.len, res.written);
    try testing.expectEqual(comp.len, res.consumed);
    try testing.expectEqualSlices(u8, payload, dst);
}

test "decompressFrame rejects skippable and unknown magic" {
    var state = entropy_mod.State.init(testing.allocator);
    defer state.deinit();
    var dst: [16]u8 = undefined;

    // Skippable magic is not a regular frame.
    try testing.expectError(error.InvalidFrameHeader, decompressFrame(&state, &dst, &[_]u8{
        0x50, 0x2A, 0x4D, 0x18, 0, 0, 0, 0,
    }));
    // Unknown magic.
    try testing.expectError(error.PrefixUnknown, decompressFrame(&state, &dst, &[_]u8{ 0, 0, 0, 0 }));
}

test "skipFrame sizes" {
    const zstd_top = @import("../zstd.zig");
    var buf: [32]u8 = undefined;
    const n = zstd_top.writeSkippableFrame(&buf, "meta", 2);
    try testing.expectEqual(n, try skipFrame(buf[0..n]));
}
