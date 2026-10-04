const std = @import("std");
const bits = @import("../common/bits.zig");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const types = @import("../common/types.zig");

pub fn isSkippableFrame(src: []const u8) bool {
    if (src.len < 4) return false;
    const magic = bits.readLe32(src[0..4]);
    return (magic & constants.magic_skippable_mask) == constants.magic_skippable_start;
}

pub fn isZstdFrame(src: []const u8) bool {
    if (src.len < 4) return false;
    const magic = bits.readLe32(src[0..4]);
    if (magic == constants.magic_number) return true;
    if ((magic & constants.magic_skippable_mask) == constants.magic_skippable_start) return true;
    return false;
}

pub fn getFrameHeader(src: []const u8) errors.ZstdError!types.FrameHeader {
    if (src.len < 4) return error.PrefixUnknown;
    const magic = bits.readLe32(src[0..4]);
    if ((magic & constants.magic_skippable_mask) == constants.magic_skippable_start) {
        if (src.len < 8) return error.SrcSizeWrong;
        const size = bits.readLe32(src[4..8]);
        return types.FrameHeader{
            .frameType = .skippable,
            .headerSize = 8,
            .windowSize = 0,
            .blockSizeMax = 0,
            .dictId = magic -% constants.magic_skippable_start,
            .checksumFlag = false,
            .contentSize = size,
        };
    }
    if (magic != constants.magic_number) return error.PrefixUnknown;
    if (src.len < 5) return error.SrcSizeWrong;
    const fhd = src[4];
    if ((fhd & 0x08) != 0) return error.FrameParameterUnsupported;
    const dict_id_code = fhd & 0x03;
    const checksum_flag = (fhd >> 2) & 1;
    const singleSegment = (fhd >> 5) & 1;
    const fcs_code = fhd >> 6;
    var pos: usize = 5;
    var windowSize: u64 = 0;
    if (singleSegment == 0) {
        if (src.len <= pos) return error.SrcSizeWrong;
        const wl_byte = src[pos];
        pos += 1;
        const windowLog: u8 = @intCast((wl_byte >> 3) + constants.window_log_absolutemin);
        if (windowLog > constants.window_log_max) return error.WindowTooLarge;
        windowSize = @as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(windowLog));
        windowSize += (windowSize >> 3) * @as(u64, wl_byte & 7);
    }
    var dictId: u32 = 0;
    const did_size = constants.did_field_size[dict_id_code];
    if (src.len < pos + did_size) return error.SrcSizeWrong;
    switch (dict_id_code) {
        0 => {},
        1 => {
            dictId = src[pos];
            pos += 1;
        },
        2 => {
            dictId = bits.readLe16(src[pos..]);
            pos += 2;
        },
        3 => {
            dictId = bits.readLe32(src[pos..]);
            pos += 4;
        },
        else => unreachable,
    }
    var contentSize: u64 = constants.contentsize_unknown;
    const fcs_size = constants.fcs_field_size[fcs_code];
    if (singleSegment != 0 and fcs_code == 0) {
        if (src.len <= pos) return error.SrcSizeWrong;
        contentSize = src[pos];
        pos += 1;
    } else {
        if (fcs_size > 0) {
            if (src.len < pos + fcs_size) return error.SrcSizeWrong;
            switch (fcs_code) {
                0 => contentSize = constants.contentsize_unknown,
                1 => contentSize = @as(u64, bits.readLe16(src[pos..])) + 256,
                2 => contentSize = bits.readLe32(src[pos..]),
                3 => contentSize = bits.readLe64(src[pos..]),
                else => unreachable,
            }
            pos += fcs_size;
        } else {
            contentSize = constants.contentsize_unknown;
        }
    }
    if (singleSegment != 0) windowSize = contentSize;
    if (windowSize == constants.contentsize_unknown) windowSize = 0;
    const block_max_raw: u64 = @min(windowSize, constants.block_size_max);
    const blockMax: u32 = if (block_max_raw > 0xFFFFFFFF) 0xFFFFFFFF else @intCast(block_max_raw);
    const effective_block_max = if (blockMax == 0 and singleSegment == 0) @as(u32, constants.block_size_max) else blockMax;
    return types.FrameHeader{
        .frameType = .regular,
        .headerSize = @intCast(pos),
        .windowSize = windowSize,
        .blockSizeMax = effective_block_max,
        .dictId = dictId,
        .checksumFlag = checksum_flag != 0,
        .contentSize = contentSize,
    };
}

pub fn writeFrameHeader(buf: []u8, contentSize: ?u64, windowSize: u64, dictId: u32, checksum: bool, singleSegment: bool) usize {
    var pos: usize = 0;
    bits.writeLe32(buf[pos..], constants.magic_number);
    pos += 4;
    var fhd: u8 = 0;
    var did_code: u8 = 0;
    if (dictId == 0) did_code = 0 else if (dictId < 256) did_code = 1 else if (dictId < 65536) did_code = 2 else did_code = 3;
    fhd |= did_code;
    if (checksum) fhd |= 0x04;
    if (singleSegment) fhd |= 0x20;
    var fcs_code: u8 = 0;
    if (contentSize) |cs| {
        if (singleSegment and cs < 256) {
            fcs_code = 0;
        } else if (cs < 65792 and cs >= 256) {
            fcs_code = 1;
        } else if (cs < 0x100000000) {
            fcs_code = 2;
        } else {
            fcs_code = 3;
        }
    } else {
        fcs_code = 0;
    }
    fhd |= (fcs_code << 6);
    if (!singleSegment) {
        const ws = if (windowSize == 0) @as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(constants.window_log_limit_default)) else windowSize;
        var windowLog: u8 = @intCast(@min(@as(u64, 63 - @clz(ws)), @as(u64, constants.window_log_max)));
        if (windowLog < constants.window_log_absolutemin) windowLog = constants.window_log_absolutemin;
        const wl_byte: u8 = @as(u8, (windowLog - constants.window_log_absolutemin) << 3);
        buf[pos] = fhd;
        pos += 1;
        buf[pos] = wl_byte;
        pos += 1;
    } else {
        buf[pos] = fhd;
        pos += 1;
    }
    switch (did_code) {
        0 => {},
        1 => {
            buf[pos] = @truncate(dictId);
            pos += 1;
        },
        2 => {
            bits.writeLe16(buf[pos..], @truncate(dictId));
            pos += 2;
        },
        3 => {
            bits.writeLe32(buf[pos..], dictId);
            pos += 4;
        },
        else => unreachable,
    }
    if (contentSize) |cs| {
        switch (fcs_code) {
            0 => {
                if (singleSegment) {
                    buf[pos] = @truncate(cs);
                    pos += 1;
                }
            },
            1 => {
                bits.writeLe16(buf[pos..], @truncate(cs -% 256));
                pos += 2;
            },
            2 => {
                bits.writeLe32(buf[pos..], @truncate(cs));
                pos += 4;
            },
            3 => {
                bits.writeLe64(buf[pos..], cs);
                pos += 8;
            },
            else => unreachable,
        }
    }
    return pos;
}

/// The total size of the skippable frame at `src[0..]`, header included. This is
/// the only place a skippable frame's declared `u32` length becomes a total: the
/// addition is checked because `0xFFFFFFF8 + 8` wraps to zero on a 32-bit host,
/// which would let a walk continue inside attacker-chosen bytes.
pub fn readSkippableFrameSize(src: []const u8) errors.ZstdError!usize {
    if (src.len < 8) return error.SrcSizeWrong;
    const size = bits.readLe32(src[4..8]);
    const total = std.math.add(usize, size, constants.skippable_header_size) catch
        return error.SrcSizeWrong;
    if (total > src.len) return error.SrcSizeWrong;
    return total;
}

pub fn frameHeaderSize(src: []const u8) errors.ZstdError!usize {
    const h = try getFrameHeader(src);
    return h.headerSize;
}

const testing = std.testing;

test "a skippable frame size that would wrap is refused" {
    // `0xFFFFFFF8` declared payload bytes plus an 8-byte header is exactly
    // `2^32`, which wraps to zero on a 32-bit host, so a reader that trusted the
    // addition would report zero and decode whatever followed.
    var frame: [8]u8 = undefined;
    std.mem.writeInt(u32, frame[0..4], constants.magic_skippable_start, .little);
    std.mem.writeInt(u32, frame[4..8], 0xFFFF_FFF8, .little);
    try testing.expectError(error.SrcSizeWrong, readSkippableFrameSize(&frame));

    // The nearest value that cannot wrap, at 0xFFFF_FFF0, is still far larger
    // than the eight bytes present, so it is refused as truncated rather than
    // accepted.
    std.mem.writeInt(u32, frame[4..8], 0xFFFF_FFF0, .little);
    try testing.expectError(error.SrcSizeWrong, readSkippableFrameSize(&frame));
}

test "a skippable frame size is exact at the boundary" {
    // The declared payload is present exactly, one byte short, and one byte long.
    var frame: [8 + 4]u8 = undefined;
    std.mem.writeInt(u32, frame[0..4], constants.magic_skippable_start, .little);
    std.mem.writeInt(u32, frame[4..8], 4, .little);

    try testing.expectEqual(@as(usize, 12), try readSkippableFrameSize(frame[0..12]));
    try testing.expectError(error.SrcSizeWrong, readSkippableFrameSize(frame[0..11]));
    // Bytes belonging to whatever follows are not part of this frame, so the
    // total is the frame's own, not the remaining input.
    var with_trailer: [13]u8 = undefined;
    @memcpy(with_trailer[0..12], &frame);
    with_trailer[12] = 0xFF;
    try testing.expectEqual(@as(usize, 12), try readSkippableFrameSize(&with_trailer));
}

test "frame header write and parse roundtrip" {
    var buf: [18]u8 = undefined;
    const n = writeFrameHeader(&buf, 256, 1 << 20, 0, false, false);
    try testing.expect(n >= 5);
    const fh = try getFrameHeader(buf[0..n]);
    try testing.expectEqual(@as(u64, 256), fh.contentSize);
    try testing.expect(fh.blockSizeMax > 0);
    try testing.expect(!fh.checksumFlag);
}

test "frame header with checksum" {
    var buf: [18]u8 = undefined;
    const n = writeFrameHeader(&buf, 100, 1 << 20, 0, true, false);
    const fh = try getFrameHeader(buf[0..n]);
    try testing.expect(fh.checksumFlag);
}

test "frame header unknown content size" {
    var buf: [18]u8 = undefined;
    const n = writeFrameHeader(&buf, 0, 1 << 20, 0, false, true);
    try testing.expect(n >= 5);
}

test "frame header dictionary id" {
    var buf: [18]u8 = undefined;
    const n = writeFrameHeader(&buf, 50, 1 << 20, 42, false, false);
    const fh = try getFrameHeader(buf[0..n]);
    try testing.expectEqual(@as(u32, 42), fh.dictId);
}

test "isSkippableFrame valid" {
    var buf: [16]u8 = undefined;
    buf[0] = 0x50;
    buf[1] = 0x2A;
    buf[2] = 0x4D;
    buf[3] = 0x18;
    buf[4] = 5;
    buf[5] = 0;
    buf[6] = 0;
    buf[7] = 0;
    std.mem.copyForwards(u8, buf[8..13], "hello");
    try testing.expect(isSkippableFrame(buf[0..13]));
}

test "isSkippableFrame false for zstd" {
    var buf: [8]u8 = undefined;
    buf[0] = 0x28;
    buf[1] = 0xB5;
    buf[2] = 0x2F;
    buf[3] = 0xFD;
    buf[4] = 0;
    buf[5] = 0;
    buf[6] = 0;
    buf[7] = 0;
    try testing.expect(!isSkippableFrame(&buf));
}
