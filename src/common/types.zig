pub const FrameType = enum { regular, skippable };

pub const FrameHeader = struct {
    frameType: FrameType,
    headerSize: u32,
    windowSize: u64,
    blockSizeMax: u32,
    dictId: u32,
    checksumFlag: bool,
    contentSize: u64,
};

pub const BlockType = enum(u2) { raw = 0, rle = 1, compressed = 2, reserved = 3 };

pub const BlockProperties = struct {
    blockType: BlockType,
    lastBlock: bool,
    origSize: u32,
};

const testing = @import("std").testing;

test "types BlockType" {
    try testing.expectEqual(BlockType.raw, @as(BlockType, .raw));
    try testing.expectEqual(BlockType.rle, @as(BlockType, .rle));
    try testing.expectEqual(BlockType.compressed, @as(BlockType, .compressed));
}

test "types FrameHeader fields" {
    const h = FrameHeader{
        .frameType = .regular,
        .headerSize = 6,
        .windowSize = 1024,
        .blockSizeMax = 131072,
        .dictId = 0,
        .checksumFlag = false,
        .contentSize = 100,
    };
    try testing.expectEqual(FrameType.regular, h.frameType);
    try testing.expectEqual(@as(u64, 100), h.contentSize);
}

test "types BlockProperties fields" {
    const p = BlockProperties{ .blockType = .raw, .lastBlock = true, .origSize = 42 };
    try testing.expect(p.lastBlock);
    try testing.expectEqual(@as(u32, 42), p.origSize);
}
