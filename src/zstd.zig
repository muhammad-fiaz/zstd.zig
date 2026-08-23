pub const version = "1.6.0";
pub const version_number: u32 = 1 * 100 * 100 + 6 * 100 + 0;

const std = @import("std");
const comp = @import("compress/compress.zig");
const decomp = @import("decompress/decompress.zig");
const hdr = @import("frame/header.zig");
const det = @import("frame/detect.zig");
const frame_mod = @import("decompress/frame.zig");
const dictionary = @import("dictionary/dictionary.zig");
const bld = @import("dictionary/builder.zig");
const streamComp = @import("streaming/compress.zig");
const streamDecomp = @import("streaming/decompress.zig");
const cctx = @import("compress/context.zig");
const dctx = @import("decompress/context.zig");
const constants = @import("common/constants.zig");
const errors = @import("common/errors.zig");
const types = @import("common/types.zig");
pub const legacy = @import("legacy/decoder.zig");
pub const legacy_detect = @import("legacy/detect.zig");

pub const CompressionOptions = comp.CompressionOptions;
pub const DecompressionOptions = dctx.DecompressionOptions;
pub const CompressionContext = cctx.CompressionContext;
pub const DecompressionContext = dctx.DecompressionContext;
pub const Dictionary = dictionary.Dictionary;
pub const DictionaryBuilder = bld.DictionaryBuilder;
pub const DictBuilderParams = bld.DictBuilderParams;
pub const StreamingCompressor = streamComp.StreamingCompressor;
pub const StreamingDecompressor = streamDecomp.StreamingDecompressor;
pub const CStream = streamComp.CStream;
pub const DStream = streamDecomp.DStream;
pub const EndDirective = streamComp.EndDirective;
pub const FrameHeader = types.FrameHeader;
pub const BlockType = types.BlockType;
pub const BlockProperties = types.BlockProperties;
pub const ZstdError = errors.ZstdError;
pub const Strategy = constants.Strategy;
pub const FrameOptions = struct { checksum: bool = false, content_size: ?u64 = null, dict_id: u32 = 0, window_log: u8 = 0 };

pub const MAGICNUMBER = constants.magic_number;
pub const MAGIC_DICTIONARY = constants.magic_dictionary;
pub const MAGIC_SKIPPABLE_START = constants.magic_skippable_start;
pub const MAGIC_SKIPPABLE_MASK = constants.magic_skippable_mask;
pub const BLOCKSIZE_MAX = constants.block_size_max;
pub const CONTENTSIZE_UNKNOWN = constants.contentsize_unknown;
pub const CONTENTSIZE_ERROR = constants.contentsize_error;
pub const CLEVEL_DEFAULT = constants.c_level_default;
pub const MAX_INPUT_SIZE = constants.max_input_size;

pub const compressBound = comp.compressBound;
pub const getCompressionParameters = comp.getCompressionParameters;
pub const loadDictionary = dictionary.loadDictionary;
pub const createDictionaryFromData = dictionary.createDictionaryFromData;

pub fn compress(allocator: std.mem.Allocator, src: []const u8) anyerror![]u8 {
    return comp.compress(allocator, src, .{});
}

pub fn decompress(allocator: std.mem.Allocator, src: []const u8) anyerror![]u8 {
    return decomp.decompress(allocator, src);
}

pub fn compressWithLevel(allocator: std.mem.Allocator, src: []const u8, level: i32) anyerror![]u8 {
    const opts = comp.getCompressionParameters(level, src.len, 0);
    return comp.compress(allocator, src, opts);
}

pub fn compressWithOptions(allocator: std.mem.Allocator, src: []const u8, options: CompressionOptions) anyerror![]u8 {
    return comp.compress(allocator, src, options);
}

pub fn compressInto(dst: []u8, src: []const u8, level: i32) ZstdError!usize {
    const opts = comp.getCompressionParameters(level, src.len, 0);
    return comp.compressInto(dst, src, opts);
}

/// Decompress exactly one Zstandard frame into `dst`.
/// Returns bytes written and total frame size consumed.
pub const FrameResult = frame_mod.FrameResult;

pub fn decompressFrame(dst: []u8, src: []const u8) ZstdError!FrameResult {
    var state = frame_mod.entropy_mod.State.init(std.heap.page_allocator);
    defer state.deinit();
    return frame_mod.decompressFrame(&state, dst, src);
}

/// Total size of the skippable frame at the start of `src`.
pub fn skipFrame(src: []const u8) ZstdError!usize {
    return frame_mod.skipFrame(src);
}

pub fn decompressInto(dst: []u8, src: []const u8) ZstdError!usize {
    return decomp.decompressInto(dst, src);
}

pub fn decompressBound(src: []const u8) ZstdError!usize {
    return decomp.decompressBound(src);
}

pub fn findFrameCompressedSize(src: []const u8) ZstdError!usize {
    return decomp.findFrameCompressedSize(src);
}

pub fn getFrameContentSize(src: []const u8) u64 {
    if (src.len < 4) return CONTENTSIZE_ERROR;
    const fh = hdr.getFrameHeader(src) catch return CONTENTSIZE_ERROR;
    if (fh.frame_type == .skippable) return 0;
    return fh.content_size;
}

pub fn getFrameHeader(src: []const u8) ZstdError!FrameHeader {
    return hdr.getFrameHeader(src);
}

pub fn isFrame(src: []const u8) bool {
    return det.detectFrame(src) != .unknown;
}

pub fn isSkippableFrame(src: []const u8) bool {
    return hdr.isSkippableFrame(src);
}

pub fn writeSkippableFrame(dst: []u8, data: []const u8, magic_variant: u32) usize {
    if (dst.len < 8 + data.len) return 0;
    const magic = MAGIC_SKIPPABLE_START + (magic_variant & 0xF);
    dst[0] = @truncate(magic);
    dst[1] = @truncate(magic >> 8);
    dst[2] = @truncate(magic >> 16);
    dst[3] = @truncate(magic >> 24);
    const size: u32 = @intCast(data.len);
    dst[4] = @truncate(size);
    dst[5] = @truncate(size >> 8);
    dst[6] = @truncate(size >> 16);
    dst[7] = @truncate(size >> 24);
    @memcpy(dst[8 .. 8 + data.len], data);
    return 8 + data.len;
}

pub fn readSkippableFrame(dst: []u8, src: []const u8) ZstdError!usize {
    if (src.len < 8) return error.SrcSizeWrong;
    if (!isSkippableFrame(src)) return error.PrefixUnknown;
    const size: u32 = @as(u32, src[4]) | (@as(u32, src[5]) << 8) | (@as(u32, src[6]) << 16) | (@as(u32, src[7]) << 24);
    if (src.len < 8 + size) return error.SrcSizeWrong;
    if (dst.len < size) return error.DstSizeTooSmall;
    @memcpy(dst[0..size], src[8 .. 8 + size]);
    return size;
}

pub fn versionString() []const u8 {
    return version;
}

pub fn versionNumber() u32 {
    return version_number;
}

pub fn maxCLevel() i32 {
    return constants.c_level_max;
}

pub fn minCLevel() i32 {
    return constants.c_level_min;
}

pub fn defaultCLevel() i32 {
    return constants.c_level_default;
}

const testing = std.testing;

test "compress and decompress empty" {
    const alloc = testing.allocator;
    const c = try compress(alloc, "");
    defer alloc.free(c);
    try testing.expect(c.len > 0);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqual(@as(usize, 0), d.len);
}

test "compress and decompress single byte" {
    const alloc = testing.allocator;
    const src = [_]u8{0x42};
    const c = try compress(alloc, &src);
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualSlices(u8, &src, d);
}

test "compress and decompress small string" {
    const alloc = testing.allocator;
    const src = "Hello, Zstandard!";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    try testing.expect(c.len > 0);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualStrings(src, d);
}

test "compress and decompress repetitive data" {
    const alloc = testing.allocator;
    const src = "ABABABABABABABABABABABABABABABABABABABABABABABABABABABAB";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualStrings(src, d);
}

test "compress and decompress zeros" {
    const alloc = testing.allocator;
    var src: [1000]u8 = undefined;
    @memset(&src, 0);
    const c = try compress(alloc, &src);
    defer alloc.free(c);
    try testing.expect(c.len < src.len);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualSlices(u8, &src, d);
}

test "compress and decompress all byte values" {
    const alloc = testing.allocator;
    var src: [256]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i);
    const c = try compress(alloc, &src);
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualSlices(u8, &src, d);
}

test "compress with level 1" {
    const alloc = testing.allocator;
    const src = "Test data for level 1 compression";
    const c = try compressWithLevel(alloc, src, 1);
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualStrings(src, d);
}

test "compress with level 22" {
    const alloc = testing.allocator;
    const src = "Test data for max level compression";
    const c = try compressWithLevel(alloc, src, 22);
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualStrings(src, d);
}

test "compress with all levels 1 to 22" {
    const alloc = testing.allocator;
    const src = "Level test data";
    var level: i32 = 1;
    while (level <= 22) : (level += 1) {
        {
            const c = try compressWithLevel(alloc, src, level);
            defer alloc.free(c);
            const d = try decompress(alloc, c);
            defer alloc.free(d);
            try testing.expectEqualStrings(src, d);
        }
    }
}

test "compress with checksum" {
    const alloc = testing.allocator;
    const src = "Checksum enabled data";
    const c = try compressWithOptions(alloc, src, .{ .checksum = true });
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualStrings(src, d);
}

test "compress into buffer" {
    var buf: [1024]u8 = undefined;
    const src = "Small data";
    const written = try compressInto(&buf, src, 1);
    try testing.expect(written > 0);
    var out: [1024]u8 = undefined;
    const dec = try decompressInto(&out, buf[0..written]);
    try testing.expectEqualStrings(src, out[0..dec]);
}

test "decompress bound" {
    const alloc = testing.allocator;
    const src = "Bound test data for decompression estimation";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    const bound = try decompressBound(c);
    try testing.expect(bound >= src.len);
}

test "find frame compressed size" {
    const alloc = testing.allocator;
    const src = "Frame size test";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    const sz = try findFrameCompressedSize(c);
    try testing.expectEqual(c.len, sz);
}

test "get frame header" {
    const alloc = testing.allocator;
    const src = "Header test";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    const fh = try getFrameHeader(c);
    try testing.expect(fh.header_size > 0);
    try testing.expect(fh.content_size > 0);
}

test "get frame content size" {
    const alloc = testing.allocator;
    const src = "Content size test";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    const cs = getFrameContentSize(c);
    try testing.expectEqual(@as(u64, src.len), cs);
}

test "isFrame valid" {
    const alloc = testing.allocator;
    const src = "isFrame test";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    try testing.expect(isFrame(c));
}

test "isFrame invalid" {
    const buf = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try testing.expect(!isFrame(&buf));
}

test "skippable frame write and read" {
    const data = "skippable payload";
    var buf: [256]u8 = undefined;
    const written = writeSkippableFrame(&buf, data, 0);
    try testing.expect(written > 0);
    try testing.expect(isSkippableFrame(buf[0..written]));
    var out: [256]u8 = undefined;
    const read = try readSkippableFrame(&out, buf[0..written]);
    try testing.expectEqualStrings(data, out[0..read]);
}

test "skippable frame too small dst" {
    var buf: [4]u8 = undefined;
    const data = "payload";
    const written = writeSkippableFrame(&buf, data, 0);
    try testing.expectEqual(@as(usize, 0), written);
}

test "skippable read too small src" {
    var buf: [8]u8 = undefined;
    const result = readSkippableFrame(&buf, &[_]u8{ 0x50, 0x2A });
    try testing.expectError(error.SrcSizeWrong, result);
}

test "skippable read wrong magic" {
    var buf: [16]u8 = undefined;
    buf[0..4].* = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD };
    buf[4..8].* = [_]u8{ 0, 0, 0, 0 };
    const result = readSkippableFrame(&buf, buf[0..8]);
    try testing.expectError(error.PrefixUnknown, result);
}

test "version info" {
    try testing.expect(versionString().len > 0);
    try testing.expect(versionNumber() > 0);
    try testing.expect(maxCLevel() == 22);
    try testing.expect(minCLevel() < 0);
    try testing.expect(defaultCLevel() == 3);
}

test "constants exported" {
    try testing.expectEqual(@as(u32, 0xFD2FB528), MAGICNUMBER);
    try testing.expectEqual(@as(u32, 0xEC30A437), MAGIC_DICTIONARY);
    try testing.expectEqual(@as(u32, 0x184D2A50), MAGIC_SKIPPABLE_START);
}

test "large data roundtrip 64KB" {
    const alloc = testing.allocator;
    var src: [65536]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    prng.random().bytes(&src);
    const c = try compress(alloc, &src);
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualSlices(u8, &src, d);
}

test "concatenated frames" {
    const alloc = testing.allocator;
    const src1 = "first frame";
    const src2 = "second frame";
    const c1 = try compress(alloc, src1);
    defer alloc.free(c1);
    const c2 = try compress(alloc, src2);
    defer alloc.free(c2);
    var concat = try alloc.alloc(u8, c1.len + c2.len);
    defer alloc.free(concat);
    @memcpy(concat[0..c1.len], c1);
    @memcpy(concat[c1.len..], c2);
    const d = try decompress(alloc, concat);
    defer alloc.free(d);
    try testing.expectEqualStrings(src1, d[0..src1.len]);
    try testing.expectEqualStrings(src2, d[src1.len..]);
}

test "decompress invalid data" {
    const alloc = testing.allocator;
    const bad = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    const result = decompress(alloc, &bad);
    try testing.expectError(error.PrefixUnknown, result);
}

test "decompress truncated data" {
    const alloc = testing.allocator;
    const src = "Truncate this after compress";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    if (c.len > 4) {
        const result = decompress(alloc, c[0 .. c.len - 4]);
        if (result) |v| {
            alloc.free(v);
        } else |_| {}
    }
}

test "compression context init and deinit" {
    var ctx = CompressionContext.init(testing.allocator);
    defer ctx.deinit();
}

test "compression context with level" {
    var ctx = CompressionContext.initWithLevel(testing.allocator, 5);
    defer ctx.deinit();
    const src = "Context level test";
    const c = try ctx.compressAlloc(src);
    defer testing.allocator.free(c);
    try testing.expect(c.len > 0);
}

test "compression context set level" {
    var ctx = CompressionContext.init(testing.allocator);
    defer ctx.deinit();
    ctx.setLevel(10);
    const src = "Set level test";
    const c = try ctx.compressAlloc(src);
    defer testing.allocator.free(c);
    try testing.expect(c.len > 0);
}

test "compression context set checksum" {
    var ctx = CompressionContext.init(testing.allocator);
    defer ctx.deinit();
    ctx.setChecksum(true);
    const src = "Checksum context test";
    const c = try ctx.compressAlloc(src);
    defer testing.allocator.free(c);
    const d = try decompress(testing.allocator, c);
    defer testing.allocator.free(d);
    try testing.expectEqualStrings(src, d);
}

test "compression context compress into buffer" {
    var ctx = CompressionContext.init(testing.allocator);
    defer ctx.deinit();
    const src = "Buffer compress test";
    var buf: [512]u8 = undefined;
    const written = try ctx.compress(&buf, src);
    try testing.expect(written > 0);
}

test "compression context reset" {
    var ctx = CompressionContext.init(testing.allocator);
    defer ctx.deinit();
    const src = "Reset test";
    const c1 = try ctx.compressAlloc(src);
    defer testing.allocator.free(c1);
    ctx.reset();
    const c2 = try ctx.compressAlloc(src);
    defer testing.allocator.free(c2);
    try testing.expectEqual(c1.len, c2.len);
}

test "decompression context init and deinit" {
    var ctx = DecompressionContext.init(testing.allocator);
    defer ctx.deinit();
}

test "decompression context decompress" {
    var ctx = DecompressionContext.init(testing.allocator);
    defer ctx.deinit();
    const src = "Decompress context test";
    const c = try compress(testing.allocator, src);
    defer testing.allocator.free(c);
    const d = try ctx.decompressAlloc(c);
    defer testing.allocator.free(d);
    try testing.expectEqualStrings(src, d);
}

test "decompression context decompress into buffer" {
    var ctx = DecompressionContext.init(testing.allocator);
    defer ctx.deinit();
    const src = "Buffer decompress test";
    const c = try compress(testing.allocator, src);
    defer testing.allocator.free(c);
    var buf: [512]u8 = undefined;
    const written = try ctx.decompress(&buf, c);
    try testing.expectEqualStrings(src, buf[0..written]);
}

test "decompression context set max window size" {
    var ctx = DecompressionContext.init(testing.allocator);
    defer ctx.deinit();
    ctx.setMaxWindowSize(1024 * 1024);
}

test "decompression context reset" {
    var ctx = DecompressionContext.init(testing.allocator);
    defer ctx.deinit();
    const src = "Reset decompress test";
    const c = try compress(testing.allocator, src);
    defer testing.allocator.free(c);
    const d1 = try ctx.decompressAlloc(c);
    defer testing.allocator.free(d1);
    ctx.reset();
    const d2 = try ctx.decompressAlloc(c);
    defer testing.allocator.free(d2);
    try testing.expectEqualStrings(d1, d2);
}

test "decompression options defaults" {
    const opts = DecompressionOptions{};
    try testing.expect(opts.max_window_size > 0);
    try testing.expect(!opts.force_ignore_checksum);
}

test "dictionary load and dict id" {
    const alloc = testing.allocator;
    const raw = "dictionary content data";
    var dict = try createDictionaryFromData(alloc, raw, 42);
    defer dict.deinit();
    try testing.expectEqual(@as(u32, 42), dict.dictId());
    try testing.expect(dict.data.len > raw.len);
}

test "dictionary load from data" {
    const alloc = testing.allocator;
    const raw = "load dictionary test";
    var dict = try loadDictionary(alloc, raw);
    defer dict.deinit();
    try testing.expectEqual(@as(u32, 0), dict.dictId());
}

test "dictionary builder train" {
    const alloc = testing.allocator;
    const s1 = "The quick brown fox jumps over the lazy dog";
    const s2 = "Pack my box with five dozen liquor jugs";
    const s3 = "How vexingly quick daft zebras jump";
    const samples = [_][]const u8{ s1, s2, s3 };
    var builder = DictionaryBuilder.init(alloc, .{ .dict_size = 256, .dict_id = 99 });
    var dict = try builder.train(&samples);
    defer dict.deinit();
    try testing.expectEqual(@as(u32, 99), dict.dictId());
    try testing.expect(dict.data.len > 0);
}

test "compress bound monotonic" {
    const b1 = compressBound(100);
    const b2 = compressBound(1000);
    const b3 = compressBound(10000);
    try testing.expect(b2 > b1);
    try testing.expect(b3 > b2);
}

test "compress bound larger than input" {
    const src = "test";
    const bound = compressBound(src.len);
    try testing.expect(bound > src.len);
}

test "raw block compression" {
    const src = "raw block test data that is not repetitive";
    var buf: [256]u8 = undefined;
    const written = try compressInto(&buf, src, 1);
    try testing.expect(written > 0);
}

test "get compression parameters level 1" {
    const p = getCompressionParameters(1, 1000, 0);
    try testing.expect(p.level >= 1);
}

test "get compression parameters level 22" {
    const p = getCompressionParameters(22, 1000, 0);
    try testing.expect(p.level >= 22);
}

test "compress large repetitive" {
    const alloc = testing.allocator;
    var src: [4096]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i % 26 + 'A');
    const c = try compress(alloc, &src);
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualSlices(u8, &src, d);
}

test "streaming compress init" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
}

test "streaming compress and decompress" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
    var buf: [4096]u8 = undefined;
    sc.setPledgedSrcSize(24);
    const r = try sc.compressStream(&buf, "first chunk second chunk", .end);
    try testing.expect(r.out_produced > 0);
    var out: [4096]u8 = undefined;
    const dec = try decompressInto(&out, buf[0..r.out_produced]);
    try testing.expectEqualStrings("first chunk second chunk", out[0..dec]);
}

test "streaming compress with checksum" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
    sc.setChecksumFlag(true);
    var buf: [4096]u8 = undefined;
    const r = try sc.compressStream(&buf, "checksum data", .end);
    try testing.expect(r.out_produced > 0);
}

test "streaming decompress init" {
    var sd = StreamingDecompressor.init(testing.allocator);
    defer sd.deinit();
}

test "streaming decompress all" {
    const alloc = testing.allocator;
    const src = "streaming all test";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    var sd = StreamingDecompressor.init(alloc);
    defer sd.deinit();
    var out: [256]u8 = undefined;
    const n = try sd.decompressAll(&out, c);
    try testing.expectEqualStrings(src, out[0..n]);
}

test "streaming decompress reset" {
    var sd = StreamingDecompressor.init(testing.allocator);
    defer sd.deinit();
    sd.reset();
}

test "block type raw detection" {
    try testing.expectEqual(BlockType.raw, @as(BlockType, .raw));
    try testing.expectEqual(BlockType.rle, @as(BlockType, .rle));
    try testing.expectEqual(BlockType.compressed, @as(BlockType, .compressed));
    try testing.expectEqual(BlockType.reserved, @as(BlockType, .reserved));
}

test "frame module surface" {
    std.testing.refAllDecls(frame_mod);
}
