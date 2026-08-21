const std = @import("std");
const i = @import("internal");

test "highbit32 power of two" {
    try std.testing.expectEqual(@as(u32, 0), i.bits.highbit32(1));
    try std.testing.expectEqual(@as(u32, 1), i.bits.highbit32(2));
    try std.testing.expectEqual(@as(u32, 2), i.bits.highbit32(4));
    try std.testing.expectEqual(@as(u32, 31), i.bits.highbit32(0x80000000));
}

test "highbit32 non power of two" {
    try std.testing.expectEqual(@as(u32, 2), i.bits.highbit32(7));
    try std.testing.expectEqual(@as(u32, 3), i.bits.highbit32(15));
}

test "countTrailingZeros32" {
    try std.testing.expectEqual(@as(u32, 0), i.bits.countTrailingZeros32(1));
    try std.testing.expectEqual(@as(u32, 3), i.bits.countTrailingZeros32(8));
}

test "countLeadingZeros32" {
    try std.testing.expectEqual(@as(u32, 31), i.bits.countLeadingZeros32(1));
    try std.testing.expectEqual(@as(u32, 0), i.bits.countLeadingZeros32(0x80000000));
}

test "nbCommonBytes" {
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@as(u32, 0), i.bits.nbCommonBytes(0x00FF00FF00FF00FF));
        try std.testing.expectEqual(@as(u32, 7), i.bits.nbCommonBytes(0xFF00000000000000));
    } else {
        try std.testing.expectEqual(@as(u32, 0), i.bits.nbCommonBytes(0x00FF00FF));
        try std.testing.expectEqual(@as(u32, 3), i.bits.nbCommonBytes(0xFF000000));
    }
}

test "rotateRightU32" {
    try std.testing.expectEqual(@as(u32, 0xC0000000), i.bits.rotateRightU32(0x80000001, 1));
    try std.testing.expectEqual(@as(u32, 1), i.bits.rotateRightU32(1, 0));
}

test "rotateRightU64" {
    try std.testing.expectEqual(@as(u64, 2), i.bits.rotateRightU64(1, 63));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), i.bits.rotateRightU64(1, 1));
}

test "copy8" {
    var src = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var dst: [8]u8 = undefined;
    i.memory.copy8(&dst, &src);
    try std.testing.expectEqualSlices(u8, &src, &dst);
}

test "copy16" {
    var src: [16]u8 = undefined;
    for (&src, 0..) |*b, j| b.* = @intCast(j);
    var dst: [16]u8 = undefined;
    i.memory.copy16(&dst, &src);
    try std.testing.expectEqualSlices(u8, &src, &dst);
}

test "constants magic" {
    try std.testing.expectEqual(@as(u32, 0xFD2FB528), i.constants.magic_number);
    try std.testing.expectEqual(@as(u32, 0xEC30A437), i.constants.magic_dictionary);
    try std.testing.expectEqual(@as(u32, 0x184D2A50), i.constants.magic_skippable_start);
}

test "constants limits" {
    try std.testing.expect(i.constants.block_size_max == 1 << 17);
    try std.testing.expect(i.constants.window_log_min == 10);
    try std.testing.expect(i.constants.c_level_default == 3);
    try std.testing.expect(i.constants.c_level_max == 22);
}

test "compressBound" {
    const b1 = i.constants.compressBound(100);
    const b2 = i.constants.compressBound(1000);
    try std.testing.expect(b1 > 100);
    try std.testing.expect(b2 > b1);
}

test "errors all strings non-empty" {
    const errs = [_]i.errors.ZstdError{
        error.Corruption,                error.ChecksumWrong,               error.DictionaryCorrupted,
        error.DictionaryWrong,           error.ParameterOutOfBound,         error.TableLogTooLarge,
        error.MaxSymbolValueTooLarge,    error.MaxSymbolValueTooSmall,      error.StageWrong,
        error.InitMissing,               error.MemoryAllocation,            error.WorkspaceTooSmall,
        error.DstSizeTooSmall,           error.SrcSizeWrong,                error.DstBufferNull,
        error.NoForwardProgressDestFull, error.NoForwardProgressInputEmpty, error.FrameIndexTooLarge,
        error.PrefixUnknown,             error.VersionUnsupported,          error.FrameParameterUnsupported,
        error.WindowTooLarge,            error.UnsupportedFeature,          error.InvalidMagic,
        error.InvalidFrameHeader,        error.InvalidBlock,                error.InvalidBlockSize,
        error.InvalidDictionary,         error.InvalidFseTable,             error.InvalidHuffmanTable,
        error.InvalidSequence,           error.InvalidOffset,               error.ContentSizeMismatch,
        error.AllocationFailure,         error.GenericError,                error.OutOfMemory,
    };
    for (errs) |e| {
        const s = i.errors.errorToString(e);
        try std.testing.expect(s.len > 0);
    }
}

test "types BlockType" {
    try std.testing.expectEqual(i.types.BlockType.raw, @as(i.types.BlockType, .raw));
    try std.testing.expectEqual(i.types.BlockType.rle, @as(i.types.BlockType, .rle));
    try std.testing.expectEqual(i.types.BlockType.compressed, @as(i.types.BlockType, .compressed));
}

test "BitReader init and getBits" {
    const data = [_]u8{ 0xFF, 0x00, 0xAA, 0x55, 0, 0, 0, 0 };
    var br = i.bitstream.BitReader.init(&data);
    try std.testing.expectEqual(@as(u64, 0xFF), br.getBits(8));
    try std.testing.expectEqual(@as(u64, 0x00), br.getBits(8));
}

test "BitReader getBits zero" {
    const data = [_]u8{ 0xFF, 0, 0, 0, 0, 0, 0, 0 };
    var br = i.bitstream.BitReader.init(&data);
    try std.testing.expectEqual(@as(u64, 0), br.getBits(0));
}

test "BitReader peekBits" {
    const data = [_]u8{ 0xAB, 0xCD, 0, 0, 0, 0, 0, 0 };
    const br = i.bitstream.BitReader.init(&data);
    try std.testing.expectEqual(@as(u64, 0xAB), br.peekBits(8));
}

test "BitReader skipBits" {
    const data = [_]u8{ 0xFF, 0x00, 0, 0, 0, 0, 0, 0 };
    var br = i.bitstream.BitReader.init(&data);
    br.skipBits(8);
    try std.testing.expectEqual(@as(u64, 0x00), br.getBits(8));
}

test "BitWriter addBits and flush" {
    var buf: [8]u8 = undefined;
    var bw = i.bitstream.BitWriter.init(&buf);
    bw.addBits(0xFF, 8);
    const written = bw.flush();
    try std.testing.expectEqual(@as(usize, 1), written);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[0]);
}

test "BitWriter multiple adds" {
    var buf: [8]u8 = undefined;
    var bw = i.bitstream.BitWriter.init(&buf);
    bw.addBits(0x0F, 4);
    bw.addBits(0x0A, 4);
    const written = bw.flush();
    try std.testing.expectEqual(@as(usize, 1), written);
}

test "xxhash64 empty" {
    try std.testing.expectEqual(@as(u64, 0xEF46DB3751D8E999), i.xxhash.xxhash64("", 0));
}

test "xxhash64 deterministic" {
    const a = i.xxhash.xxhash64("hello", 0);
    const b = i.xxhash.xxhash64("hello", 0);
    try std.testing.expectEqual(a, b);
}

test "xxhash64 different inputs" {
    const a = i.xxhash.xxhash64("hello", 0);
    const b = i.xxhash.xxhash64("world", 0);
    try std.testing.expect(a != b);
}

test "XxHash64State" {
    var st = i.xxhash.XxHash64State.init(0);
    st.update("hello");
    try std.testing.expectEqual(i.xxhash.xxhash64("hello", 0), st.digest());
}

test "XxHash64State multi update" {
    var st1 = i.xxhash.XxHash64State.init(0);
    st1.update("hel");
    st1.update("lo");
    var st2 = i.xxhash.XxHash64State.init(0);
    st2.update("hello");
    try std.testing.expectEqual(st1.digest(), st2.digest());
}

test "cpu functions" {
    const _bmi2 = i.cpu.supportsBmi2();
    const _features = i.cpu.getCpuFeatures();
    _ = _bmi2;
    _ = _features;
}

test "workspace init and deinit" {
    var ws = try i.workspace_common.Workspace.init(std.testing.allocator, 1024);
    defer ws.deinit();
    try std.testing.expectEqual(@as(usize, 1024), ws.buffer.len);
}
