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
pub const entropy_mod = @import("entropy.zig");
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
    var srcPos: usize = fh.headerSize;
    var dstPos: usize = 0;
    state.resetFrame();

    var checksumState = checksum_mod.ChecksumState.init();
    var last = false;
    while (!last) {
        if (src.len < srcPos + 3) return error.SrcSizeWrong;
        const props = try block_header.getBlockHeader(src[srcPos..]);
        last = props.lastBlock;
        const cSize = props.origSize;
        srcPos += 3;

        switch (props.blockType) {
            .raw => {
                if (src.len < srcPos + cSize) return error.SrcSizeWrong;
                if (dst.len < dstPos + cSize) return error.DstSizeTooSmall;
                std.mem.copyForwards(u8, dst[dstPos .. dstPos + cSize], src[srcPos .. srcPos + cSize]);
                checksumState.update(dst[dstPos .. dstPos + cSize]);
                dstPos += cSize;
                srcPos += cSize;
            },
            .rle => {
                if (src.len < srcPos + 1) return error.SrcSizeWrong;
                const value = src[srcPos];
                srcPos += 1;
                if (dst.len < dstPos + cSize) return error.DstSizeTooSmall;
                @memset(dst[dstPos .. dstPos + cSize], value);
                checksumState.update(dst[dstPos .. dstPos + cSize]);
                dstPos += cSize;
            },
            .compressed => {
                if (src.len < srcPos + cSize) return error.SrcSizeWrong;
                // Window: everything decoded so far in this frame.
                const decoded = try block_decompress.decompressBlock(
                    state,
                    dst[dstPos..],
                    src[srcPos - 3 .. srcPos + cSize],
                    dst[0..dstPos],
                );
                checksumState.update(dst[dstPos .. dstPos + decoded]);
                dstPos += decoded;
                srcPos += cSize;
            },
            .reserved => return error.InvalidBlock,
        }
    }

    if (fh.checksumFlag) {
        if (src.len < srcPos + 4) return error.SrcSizeWrong;
        const expected = checksum_mod.readChecksum(src[srcPos..]);
        if (expected != checksumState.final()) return error.ChecksumWrong;
        srcPos += 4;
    }

    if (fh.contentSize != constants.contentsize_unknown and fh.contentSize != constants.contentsize_error) {
        if (dstPos != @as(usize, @intCast(fh.contentSize))) return error.ContentSizeMismatch;
    }

    return .{ .written = dstPos, .consumed = srcPos };
}

/// Skip over one skippable frame, returning its total size. The declared payload
/// length is attacker-controlled, so the total comes from the helper that
/// checks the addition rather than being recomputed here.
pub fn skipFrame(src: []const u8) errors.ZstdError!usize {
    if (src.len < 8) return error.SrcSizeWrong;
    const magic = std.mem.readInt(u32, src[0..4], .little);
    if ((magic & constants.magic_skippable_mask) != constants.magic_skippable_start) return error.PrefixUnknown;
    return header_mod.readSkippableFrameSize(src);
}

// Tests

const testing = std.testing;

test "decompressFrame round trip and consumed size" {
    const compress_mod = @import("../compress/compress.zig");
    const alloc = testing.allocator;
    var state = entropy_mod.State.init(alloc);
    defer state.deinit();

    const unit = "frame-level round trip payload ";
    var payload_buf: [unit.len * 20]u8 = undefined;
    for (0..20) |i| std.mem.copyForwards(u8, payload_buf[i * unit.len ..][0..unit.len], unit);
    const payload: []const u8 = &payload_buf;
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
