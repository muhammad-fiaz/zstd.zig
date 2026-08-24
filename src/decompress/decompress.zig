const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const header_mod = @import("../frame/header.zig");
const block_mod = @import("../frame/block.zig");
const checksum_mod = @import("../frame/checksum.zig");
const block_decompress = @import("block.zig");
const entropy_mod = @import("entropy.zig");
const legacy_mod = @import("../legacy/decoder.zig");

pub fn decompressBound(src: []const u8) errors.ZstdError!usize {
    var total: usize = 0;
    var pos: usize = 0;
    while (pos < src.len) {
        if (src.len - pos < 4) return error.SrcSizeWrong;
        const magic = readLE32(src[pos..]);
        if ((magic & constants.magic_skippable_mask) == constants.magic_skippable_start) {
            if (src.len - pos < 8) return error.SrcSizeWrong;
            const sz = readLE32(src[pos + 4 ..]);
            const total_sz = @as(usize, sz) + 8;
            pos += total_sz;
            continue;
        }
        if (magic != constants.magic_number) {
            if (legacy_mod.isLegacy(src[pos..])) {
                const sz = try legacy_mod.findFrameSize(src[pos..]);
                pos += sz;
                total += 1 << 20;
                continue;
            }
            return error.PrefixUnknown;
        }
        const fh = try header_mod.getFrameHeader(src[pos..]);
        if (fh.frame_type == .skippable) {
            pos += fh.header_size + @as(usize, @intCast(fh.content_size));
            continue;
        }
        if (fh.content_size != constants.contentsize_unknown and fh.content_size != constants.contentsize_error) {
            total += @as(usize, @intCast(fh.content_size));
        } else {
            total += fh.block_size_max * 4;
        }
        const frame_size = try findFrameCompressedSize(src[pos..]);
        pos += frame_size;
    }
    return total;
}

pub fn findFrameCompressedSize(src: []const u8) errors.ZstdError!usize {
    if (src.len < 4) return error.SrcSizeWrong;
    const magic = readLE32(src[0..4]);
    if ((magic & constants.magic_skippable_mask) == constants.magic_skippable_start) {
        if (src.len < 8) return error.SrcSizeWrong;
        const sz = readLE32(src[4..8]);
        return @as(usize, sz) + 8;
    }
    if (magic != constants.magic_number) {
        if (legacy_mod.isLegacy(src)) return legacy_mod.findFrameSize(src);
        return error.PrefixUnknown;
    }
    const fh = try header_mod.getFrameHeader(src);
    var pos = fh.header_size;
    var last = false;
    while (!last) {
        if (src.len < pos + 3) return error.SrcSizeWrong;
        const prop = try block_mod.getBlockHeader(src[pos..]);
        last = prop.last_block;
        const csize = prop.orig_size;
        pos += 3;
        if (prop.block_type == .rle) {
            if (src.len < pos + 1) return error.SrcSizeWrong;
            pos += 1;
        } else {
            if (src.len < pos + csize) return error.SrcSizeWrong;
            pos += csize;
        }
    }
    if (fh.checksum_flag) pos += 4;
    return pos;
}

pub fn decompress(allocator: std.mem.Allocator, src: []const u8) anyerror![]u8 {
    const bound = try decompressBound(src);
    const safe_bound = if (bound == 0) src.len * 4 + 1024 else bound;
    const dst = try allocator.alloc(u8, safe_bound);
    errdefer allocator.free(dst);
    const out_size = try decompressInto(dst, src);
    if (out_size == dst.len) return dst;
    const trimmed = try allocator.realloc(dst, out_size);
    return trimmed;
}

pub fn decompressInto(dst: []u8, src: []const u8) errors.ZstdError!usize {
    var src_pos: usize = 0;
    var dst_pos: usize = 0;
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    var entropy_state = entropy_mod.State.init(gpa_state.allocator());
    defer entropy_state.deinit();
    while (src_pos < src.len) {
        if (src.len - src_pos < 4) return error.SrcSizeWrong;
        const magic = readLE32(src[src_pos..]);
        if ((magic & constants.magic_skippable_mask) == constants.magic_skippable_start) {
            if (src.len - src_pos < 8) return error.SrcSizeWrong;
            const sz = readLE32(src[src_pos + 4 ..]);
            src_pos += 8 + @as(usize, sz);
            continue;
        }
        if (magic != constants.magic_number) {
            if (legacy_mod.isLegacy(src[src_pos..])) {
                const consumed = try legacy_mod.decompressLegacy(dst[dst_pos..], src[src_pos..]);
                dst_pos += consumed.decoded;
                src_pos += consumed.consumed;
                continue;
            }
            return error.PrefixUnknown;
        }
        const fh = try header_mod.getFrameHeader(src[src_pos..]);
        if (fh.frame_type == .skippable) {
            src_pos += fh.header_size + @as(usize, @intCast(fh.content_size));
            continue;
        }
        var frame_src_pos = src_pos + fh.header_size;
        const frame_start_dst = dst_pos;
        entropy_state.resetFrame(); // frames are independent
        var checksum_state = checksum_mod.ChecksumState.init();
        var last = false;
        while (!last) {
            if (src.len < frame_src_pos + 3) return error.SrcSizeWrong;
            const prop = try block_mod.getBlockHeader(src[frame_src_pos..]);
            last = prop.last_block;
            const csize = prop.orig_size;
            frame_src_pos += 3;
            switch (prop.block_type) {
                .raw => {
                    if (src.len < frame_src_pos + csize) return error.SrcSizeWrong;
                    if (dst.len < dst_pos + csize) return error.DstSizeTooSmall;
                    @memcpy(dst[dst_pos .. dst_pos + csize], src[frame_src_pos .. frame_src_pos + csize]);
                    checksum_state.update(dst[dst_pos .. dst_pos + csize]);
                    dst_pos += csize;
                    frame_src_pos += csize;
                },
                .rle => {
                    if (src.len < frame_src_pos + 1) return error.SrcSizeWrong;
                    const byte = src[frame_src_pos];
                    frame_src_pos += 1;
                    if (dst.len < dst_pos + csize) return error.DstSizeTooSmall;
                    @memset(dst[dst_pos .. dst_pos + csize], byte);
                    checksum_state.update(dst[dst_pos .. dst_pos + csize]);
                    dst_pos += csize;
                },
                .compressed => {
                    if (src.len < frame_src_pos + csize) return error.SrcSizeWrong;
                    // Window: everything decoded so far within this frame.
                    const window = dst[frame_start_dst..dst_pos];
                    const decoded = block_decompress.decompressBlock(
                        &entropy_state,
                        dst[dst_pos..],
                        src[frame_src_pos - 3 .. frame_src_pos + csize],
                        window,
                    ) catch |e| {
                        return e;
                    };
                    checksum_state.update(dst[dst_pos .. dst_pos + decoded]);
                    dst_pos += decoded;
                    frame_src_pos += csize;
                },
                .reserved => return error.InvalidBlock,
            }
        }
        if (fh.checksum_flag) {
            if (src.len < frame_src_pos + 4) return error.ChecksumWrong;
            const expected = checksum_mod.readChecksum(src[frame_src_pos..]);
            const got = checksum_state.final();
            if (expected != got) return error.ChecksumWrong;
            frame_src_pos += 4;
        }
        if (fh.content_size != constants.contentsize_unknown and fh.content_size != constants.contentsize_error) {
            const frame_size = dst_pos - frame_start_dst;
            if (frame_size != fh.content_size) return error.ContentSizeMismatch;
        }
        src_pos = frame_src_pos;
    }
    if (src_pos != src.len) return error.SrcSizeWrong;
    return dst_pos;
}

pub fn decompressWithDict(dst: []u8, src: []const u8, dict: []const u8) errors.ZstdError!usize {
    _ = dict;
    return decompressInto(dst, src);
}

fn readLE32(p: []const u8) u32 {
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);
}

const testing = std.testing;
const compress_mod = @import("../compress/compress.zig");

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
    const bound = try decompressBound(c);
    try testing.expect(bound >= 10);
}

test "findFrameCompressedSize" {
    const alloc = testing.allocator;
    const c = try compress_mod.compress(alloc, "frame size", .{});
    defer alloc.free(c);
    const sz = try findFrameCompressedSize(c);
    try testing.expectEqual(c.len, sz);
}

test "decompress invalid magic" {
    const alloc = testing.allocator;
    const bad = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    const result = decompress(alloc, &bad);
    try testing.expectError(error.PrefixUnknown, result);
}
