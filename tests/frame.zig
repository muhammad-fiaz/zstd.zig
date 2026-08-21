const std = @import("std");
const i = @import("internal");

test "frame header write and parse roundtrip" {
    var buf: [18]u8 = undefined;
    const n = i.frame_header.writeFrameHeader(&buf, 256, 1 << 20, 0, false, false);
    try std.testing.expect(n >= 5);
    const fh = try i.frame_header.getFrameHeader(buf[0..n]);
    try std.testing.expectEqual(@as(u64, 256), fh.content_size);
    try std.testing.expect(fh.block_size_max > 0);
    try std.testing.expect(!fh.checksum_flag);
}

test "frame header with checksum" {
    var buf: [18]u8 = undefined;
    const n = i.frame_header.writeFrameHeader(&buf, 100, 1 << 20, 0, true, false);
    const fh = try i.frame_header.getFrameHeader(buf[0..n]);
    try std.testing.expect(fh.checksum_flag);
}

test "frame header unknown content size" {
    var buf: [18]u8 = undefined;
    const n = i.frame_header.writeFrameHeader(&buf, 0, 1 << 20, 0, false, true);
    try std.testing.expect(n >= 5);
}

test "frame header dictionary id" {
    var buf: [18]u8 = undefined;
    const n = i.frame_header.writeFrameHeader(&buf, 50, 1 << 20, 42, false, false);
    const fh = try i.frame_header.getFrameHeader(buf[0..n]);
    try std.testing.expectEqual(@as(u32, 42), fh.dict_id);
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
    @memcpy(buf[8..13], "hello");
    try std.testing.expect(i.frame_header.isSkippableFrame(buf[0..13]));
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
    try std.testing.expect(!i.frame_header.isSkippableFrame(&buf));
}

test "block header roundtrip raw" {
    var buf: [3]u8 = undefined;
    i.frame_block.writeBlockHeader(&buf, true, .raw, 123);
    const p = try i.frame_block.getBlockHeader(&buf);
    try std.testing.expect(p.last_block);
    try std.testing.expectEqual(i.types.BlockType.raw, p.block_type);
    try std.testing.expectEqual(@as(u32, 123), p.orig_size);
}

test "block header roundtrip rle" {
    var buf: [3]u8 = undefined;
    i.frame_block.writeBlockHeader(&buf, false, .rle, 1000);
    const p = try i.frame_block.getBlockHeader(&buf);
    try std.testing.expectEqual(i.types.BlockType.rle, p.block_type);
    try std.testing.expect(!p.last_block);
}

test "block header roundtrip compressed" {
    var buf: [3]u8 = undefined;
    i.frame_block.writeBlockHeader(&buf, true, .compressed, 50);
    const p = try i.frame_block.getBlockHeader(&buf);
    try std.testing.expectEqual(i.types.BlockType.compressed, p.block_type);
}

test "checksum deterministic" {
    const a = i.frame_checksum.computeChecksum("hello world");
    const b = i.frame_checksum.computeChecksum("hello world");
    try std.testing.expectEqual(a, b);
}

test "checksum different inputs" {
    const a = i.frame_checksum.computeChecksum("hello");
    const b = i.frame_checksum.computeChecksum("world");
    try std.testing.expect(a != b);
}

test "checksum read" {
    const buf = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
    try std.testing.expectEqual(@as(u32, 0x12345678), i.frame_checksum.readChecksum(&buf));
}

test "detect zstd frame" {
    const buf = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0 };
    try std.testing.expectEqual(.zstd, i.frame_detect.detectFrame(&buf));
}

test "detect skippable frame" {
    const buf = [_]u8{ 0x50, 0x2A, 0x4D, 0x18, 0, 0, 0, 0 };
    try std.testing.expectEqual(.skippable, i.frame_detect.detectFrame(&buf));
}

test "detect unknown frame" {
    const buf = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0, 0, 0, 0 };
    try std.testing.expectEqual(.unknown, i.frame_detect.detectFrame(&buf));
}

test "skippable isSkippable" {
    try std.testing.expect(i.frame_skippable.isSkippable(0x184D2A50));
    try std.testing.expect(i.frame_skippable.isSkippable(0x184D2A5F));
    try std.testing.expect(!i.frame_skippable.isSkippable(0xFD2FB528));
}
