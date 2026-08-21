const std = @import("std");
const zstd = @import("zstd");

test "compress and decompress empty" {
    const alloc = std.testing.allocator;
    const c = try zstd.compress(alloc, "");
    defer alloc.free(c);
    try std.testing.expect(c.len > 0);
    const d = try zstd.decompress(alloc, c);
    defer alloc.free(d);
    try std.testing.expectEqual(@as(usize, 0), d.len);
}

test "compress and decompress single byte" {
    const alloc = std.testing.allocator;
    const src = [_]u8{0x42};
    const c = try zstd.compress(alloc, &src);
    defer alloc.free(c);
    const d = try zstd.decompress(alloc, c);
    defer alloc.free(d);
    try std.testing.expectEqualSlices(u8, &src, d);
}

test "compress and decompress small string" {
    const alloc = std.testing.allocator;
    const src = "Hello, Zstandard!";
    const c = try zstd.compress(alloc, src);
    defer alloc.free(c);
    try std.testing.expect(c.len > 0);
    const d = try zstd.decompress(alloc, c);
    defer alloc.free(d);
    try std.testing.expectEqualStrings(src, d);
}

test "compress and decompress repetitive data" {
    const alloc = std.testing.allocator;
    const src = "ABABABABABABABABABABABABABABABABABABABABABABABABABABABAB";
    const c = try zstd.compress(alloc, src);
    defer alloc.free(c);
    const d = try zstd.decompress(alloc, c);
    defer alloc.free(d);
    try std.testing.expectEqualStrings(src, d);
}

test "compress and decompress zeros" {
    const alloc = std.testing.allocator;
    var src: [1000]u8 = undefined;
    @memset(&src, 0);
    const c = try zstd.compress(alloc, &src);
    defer alloc.free(c);
    try std.testing.expect(c.len < src.len);
    const d = try zstd.decompress(alloc, c);
    defer alloc.free(d);
    try std.testing.expectEqualSlices(u8, &src, d);
}

test "compress and decompress all byte values" {
    const alloc = std.testing.allocator;
    var src: [256]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i);
    const c = try zstd.compress(alloc, &src);
    defer alloc.free(c);
    const d = try zstd.decompress(alloc, c);
    defer alloc.free(d);
    try std.testing.expectEqualSlices(u8, &src, d);
}

test "compress with level 1" {
    const alloc = std.testing.allocator;
    const src = "Test data for level 1 compression";
    const c = try zstd.compressWithLevel(alloc, src, 1);
    defer alloc.free(c);
    const d = try zstd.decompress(alloc, c);
    defer alloc.free(d);
    try std.testing.expectEqualStrings(src, d);
}

test "compress with level 22" {
    const alloc = std.testing.allocator;
    const src = "Test data for max level compression";
    const c = try zstd.compressWithLevel(alloc, src, 22);
    defer alloc.free(c);
    const d = try zstd.decompress(alloc, c);
    defer alloc.free(d);
    try std.testing.expectEqualStrings(src, d);
}

test "compress with all levels 1 to 22" {
    const alloc = std.testing.allocator;
    const src = "Level test data";
    var level: i32 = 1;
    while (level <= 22) : (level += 1) {
        {
            const c = try zstd.compressWithLevel(alloc, src, level);
            defer alloc.free(c);
            const d = try zstd.decompress(alloc, c);
            defer alloc.free(d);
            try std.testing.expectEqualStrings(src, d);
        }
    }
}

test "compress with checksum" {
    const alloc = std.testing.allocator;
    const src = "Checksum enabled data";
    const c = try zstd.compressWithOptions(alloc, src, .{ .checksum = true });
    defer alloc.free(c);
    const d = try zstd.decompress(alloc, c);
    defer alloc.free(d);
    try std.testing.expectEqualStrings(src, d);
}

test "compress into buffer" {
    var buf: [1024]u8 = undefined;
    const src = "Small data";
    const written = try zstd.compressInto(&buf, src, 1);
    try std.testing.expect(written > 0);
    var out: [1024]u8 = undefined;
    const dec = try zstd.decompressInto(&out, buf[0..written]);
    try std.testing.expectEqualStrings(src, out[0..dec]);
}

test "decompress bound" {
    const alloc = std.testing.allocator;
    const src = "Bound test data for decompression estimation";
    const c = try zstd.compress(alloc, src);
    defer alloc.free(c);
    const bound = try zstd.decompressBound(c);
    try std.testing.expect(bound >= src.len);
}

test "find frame compressed size" {
    const alloc = std.testing.allocator;
    const src = "Frame size test";
    const c = try zstd.compress(alloc, src);
    defer alloc.free(c);
    const sz = try zstd.findFrameCompressedSize(c);
    try std.testing.expectEqual(c.len, sz);
}

test "get frame header" {
    const alloc = std.testing.allocator;
    const src = "Header test";
    const c = try zstd.compress(alloc, src);
    defer alloc.free(c);
    const fh = try zstd.getFrameHeader(c);
    try std.testing.expect(fh.header_size > 0);
    try std.testing.expect(fh.content_size > 0);
}

test "get frame content size" {
    const alloc = std.testing.allocator;
    const src = "Content size test";
    const c = try zstd.compress(alloc, src);
    defer alloc.free(c);
    const cs = zstd.getFrameContentSize(c);
    try std.testing.expectEqual(@as(u64, src.len), cs);
}

test "isFrame valid" {
    const alloc = std.testing.allocator;
    const src = "isFrame test";
    const c = try zstd.compress(alloc, src);
    defer alloc.free(c);
    try std.testing.expect(zstd.isFrame(c));
}

test "isFrame invalid" {
    const buf = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expect(!zstd.isFrame(&buf));
}

test "skippable frame write and read" {
    const data = "skippable payload";
    var buf: [256]u8 = undefined;
    const written = zstd.writeSkippableFrame(&buf, data, 0);
    try std.testing.expect(written > 0);
    try std.testing.expect(zstd.isSkippableFrame(buf[0..written]));
    var out: [256]u8 = undefined;
    const read = try zstd.readSkippableFrame(&out, buf[0..written]);
    try std.testing.expectEqualStrings(data, out[0..read]);
}

test "skippable frame too small dst" {
    var buf: [4]u8 = undefined;
    const data = "payload";
    const written = zstd.writeSkippableFrame(&buf, data, 0);
    try std.testing.expectEqual(@as(usize, 0), written);
}

test "skippable read too small src" {
    var buf: [8]u8 = undefined;
    const result = zstd.readSkippableFrame(&buf, &[_]u8{ 0x50, 0x2A });
    try std.testing.expectError(error.SrcSizeWrong, result);
}

test "skippable read wrong magic" {
    var buf: [16]u8 = undefined;
    buf[0..4].* = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD };
    buf[4..8].* = [_]u8{ 0, 0, 0, 0 };
    const result = zstd.readSkippableFrame(&buf, buf[0..8]);
    try std.testing.expectError(error.PrefixUnknown, result);
}

test "version info" {
    try std.testing.expect(zstd.versionString().len > 0);
    try std.testing.expect(zstd.versionNumber() > 0);
    try std.testing.expect(zstd.maxCLevel() == 22);
    try std.testing.expect(zstd.minCLevel() < 0);
    try std.testing.expect(zstd.defaultCLevel() == 3);
}

test "constants exported" {
    try std.testing.expectEqual(@as(u32, 0xFD2FB528), zstd.MAGICNUMBER);
    try std.testing.expectEqual(@as(u32, 0xEC30A437), zstd.MAGIC_DICTIONARY);
    try std.testing.expectEqual(@as(u32, 0x184D2A50), zstd.MAGIC_SKIPPABLE_START);
}

test "large data roundtrip 64KB" {
    const alloc = std.testing.allocator;
    var src: [65536]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    prng.random().bytes(&src);
    const c = try zstd.compress(alloc, &src);
    defer alloc.free(c);
    const d = try zstd.decompress(alloc, c);
    defer alloc.free(d);
    try std.testing.expectEqualSlices(u8, &src, d);
}

test "concatenated frames" {
    const alloc = std.testing.allocator;
    const src1 = "first frame";
    const src2 = "second frame";
    const c1 = try zstd.compress(alloc, src1);
    defer alloc.free(c1);
    const c2 = try zstd.compress(alloc, src2);
    defer alloc.free(c2);
    var concat = try alloc.alloc(u8, c1.len + c2.len);
    defer alloc.free(concat);
    @memcpy(concat[0..c1.len], c1);
    @memcpy(concat[c1.len..], c2);
    const d = try zstd.decompress(alloc, concat);
    defer alloc.free(d);
    try std.testing.expectEqualStrings(src1, d[0..src1.len]);
    try std.testing.expectEqualStrings(src2, d[src1.len..]);
}

test "decompress invalid data" {
    const alloc = std.testing.allocator;
    const bad = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    const result = zstd.decompress(alloc, &bad);
    try std.testing.expectError(error.PrefixUnknown, result);
}

test "decompress truncated data" {
    const alloc = std.testing.allocator;
    const src = "Truncate this after compress";
    const c = try zstd.compress(alloc, src);
    defer alloc.free(c);
    if (c.len > 4) {
        const result = zstd.decompress(alloc, c[0 .. c.len - 4]);
        if (result) |v| {
            alloc.free(v);
        } else |_| {}
    }
}

test "compression context init and deinit" {
    var ctx = zstd.CompressionContext.init(std.testing.allocator);
    defer ctx.deinit();
}

test "compression context with level" {
    var ctx = zstd.CompressionContext.initWithLevel(std.testing.allocator, 5);
    defer ctx.deinit();
    const src = "Context level test";
    const c = try ctx.compressAlloc(src);
    defer std.testing.allocator.free(c);
    try std.testing.expect(c.len > 0);
}

test "compression context set level" {
    var ctx = zstd.CompressionContext.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setLevel(10);
    const src = "Set level test";
    const c = try ctx.compressAlloc(src);
    defer std.testing.allocator.free(c);
    try std.testing.expect(c.len > 0);
}

test "compression context set checksum" {
    var ctx = zstd.CompressionContext.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setChecksum(true);
    const src = "Checksum context test";
    const c = try ctx.compressAlloc(src);
    defer std.testing.allocator.free(c);
    const d = try zstd.decompress(std.testing.allocator, c);
    defer std.testing.allocator.free(d);
    try std.testing.expectEqualStrings(src, d);
}

test "compression context compress into buffer" {
    var ctx = zstd.CompressionContext.init(std.testing.allocator);
    defer ctx.deinit();
    const src = "Buffer compress test";
    var buf: [512]u8 = undefined;
    const written = try ctx.compress(&buf, src);
    try std.testing.expect(written > 0);
}

test "compression context reset" {
    var ctx = zstd.CompressionContext.init(std.testing.allocator);
    defer ctx.deinit();
    const src = "Reset test";
    const c1 = try ctx.compressAlloc(src);
    defer std.testing.allocator.free(c1);
    ctx.reset();
    const c2 = try ctx.compressAlloc(src);
    defer std.testing.allocator.free(c2);
    try std.testing.expectEqual(c1.len, c2.len);
}

test "decompression context init and deinit" {
    var ctx = zstd.DecompressionContext.init(std.testing.allocator);
    defer ctx.deinit();
}

test "decompression context decompress" {
    var ctx = zstd.DecompressionContext.init(std.testing.allocator);
    defer ctx.deinit();
    const src = "Decompress context test";
    const c = try zstd.compress(std.testing.allocator, src);
    defer std.testing.allocator.free(c);
    const d = try ctx.decompressAlloc(c);
    defer std.testing.allocator.free(d);
    try std.testing.expectEqualStrings(src, d);
}

test "decompression context decompress into buffer" {
    var ctx = zstd.DecompressionContext.init(std.testing.allocator);
    defer ctx.deinit();
    const src = "Buffer decompress test";
    const c = try zstd.compress(std.testing.allocator, src);
    defer std.testing.allocator.free(c);
    var buf: [512]u8 = undefined;
    const written = try ctx.decompress(&buf, c);
    try std.testing.expectEqualStrings(src, buf[0..written]);
}

test "decompression context set max window size" {
    var ctx = zstd.DecompressionContext.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setMaxWindowSize(1024 * 1024);
}

test "decompression context reset" {
    var ctx = zstd.DecompressionContext.init(std.testing.allocator);
    defer ctx.deinit();
    const src = "Reset decompress test";
    const c = try zstd.compress(std.testing.allocator, src);
    defer std.testing.allocator.free(c);
    const d1 = try ctx.decompressAlloc(c);
    defer std.testing.allocator.free(d1);
    ctx.reset();
    const d2 = try ctx.decompressAlloc(c);
    defer std.testing.allocator.free(d2);
    try std.testing.expectEqualStrings(d1, d2);
}

test "decompression options defaults" {
    const opts = zstd.DecompressionOptions{};
    try std.testing.expect(opts.max_window_size > 0);
    try std.testing.expect(!opts.force_ignore_checksum);
}

test "dictionary load and dict id" {
    const alloc = std.testing.allocator;
    const raw = "dictionary content data";
    var dict = try zstd.createDictionaryFromData(alloc, raw, 42);
    defer dict.deinit();
    try std.testing.expectEqual(@as(u32, 42), dict.dictId());
    try std.testing.expect(dict.data.len > raw.len);
}

test "dictionary load from data" {
    const alloc = std.testing.allocator;
    const raw = "load dictionary test";
    var dict = try zstd.loadDictionary(alloc, raw);
    defer dict.deinit();
    try std.testing.expectEqual(@as(u32, 0), dict.dictId());
}

test "dictionary builder train" {
    const alloc = std.testing.allocator;
    const s1 = "The quick brown fox jumps over the lazy dog";
    const s2 = "Pack my box with five dozen liquor jugs";
    const s3 = "How vexingly quick daft zebras jump";
    const samples = [_][]const u8{ s1, s2, s3 };
    var builder = zstd.DictionaryBuilder.init(alloc, .{ .dict_size = 256, .dict_id = 99 });
    var dict = try builder.train(&samples);
    defer dict.deinit();
    try std.testing.expectEqual(@as(u32, 99), dict.dictId());
    try std.testing.expect(dict.data.len > 0);
}

test "compress bound monotonic" {
    const b1 = zstd.compressBound(100);
    const b2 = zstd.compressBound(1000);
    const b3 = zstd.compressBound(10000);
    try std.testing.expect(b2 > b1);
    try std.testing.expect(b3 > b2);
}

test "compress bound larger than input" {
    const src = "test";
    const bound = zstd.compressBound(src.len);
    try std.testing.expect(bound > src.len);
}

test "raw block compression" {
    const src = "raw block test data that is not repetitive";
    var buf: [256]u8 = undefined;
    const written = try zstd.compressInto(&buf, src, 1);
    try std.testing.expect(written > 0);
}

test "get compression parameters level 1" {
    const p = zstd.getCompressionParameters(1, 1000, 0);
    try std.testing.expect(p.level >= 1);
}

test "get compression parameters level 22" {
    const p = zstd.getCompressionParameters(22, 1000, 0);
    try std.testing.expect(p.level >= 22);
}

test "compress large repetitive" {
    const alloc = std.testing.allocator;
    var src: [4096]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i % 26 + 'A');
    const c = try zstd.compress(alloc, &src);
    defer alloc.free(c);
    const d = try zstd.decompress(alloc, c);
    defer alloc.free(d);
    try std.testing.expectEqualSlices(u8, &src, d);
}

test "streaming compress init" {
    var sc = try zstd.StreamingCompressor.init(std.testing.allocator, 3);
    defer sc.deinit();
}

test "streaming compress and decompress" {
    var sc = try zstd.StreamingCompressor.init(std.testing.allocator, 3);
    defer sc.deinit();
    var buf: [4096]u8 = undefined;
    sc.setPledgedSrcSize(24);
    const r = try sc.compressStream(&buf, "first chunk second chunk", .end);
    try std.testing.expect(r.out_produced > 0);
    var out: [4096]u8 = undefined;
    const dec = try zstd.decompressInto(&out, buf[0..r.out_produced]);
    try std.testing.expectEqualStrings("first chunk second chunk", out[0..dec]);
}

test "streaming compress with checksum" {
    var sc = try zstd.StreamingCompressor.init(std.testing.allocator, 3);
    defer sc.deinit();
    sc.setChecksumFlag(true);
    var buf: [4096]u8 = undefined;
    const r = try sc.compressStream(&buf, "checksum data", .end);
    try std.testing.expect(r.out_produced > 0);
}

test "streaming decompress init" {
    var sd = zstd.StreamingDecompressor.init(std.testing.allocator);
    defer sd.deinit();
}

test "streaming decompress all" {
    const alloc = std.testing.allocator;
    const src = "streaming all test";
    const c = try zstd.compress(alloc, src);
    defer alloc.free(c);
    var sd = zstd.StreamingDecompressor.init(alloc);
    defer sd.deinit();
    var out: [256]u8 = undefined;
    const n = try sd.decompressAll(&out, c);
    try std.testing.expectEqualStrings(src, out[0..n]);
}

test "streaming decompress reset" {
    var sd = zstd.StreamingDecompressor.init(std.testing.allocator);
    defer sd.deinit();
    sd.reset();
}

test "block type raw detection" {
    try std.testing.expectEqual(zstd.BlockType.raw, @as(zstd.BlockType, .raw));
    try std.testing.expectEqual(zstd.BlockType.rle, @as(zstd.BlockType, .rle));
    try std.testing.expectEqual(zstd.BlockType.compressed, @as(zstd.BlockType, .compressed));
    try std.testing.expectEqual(zstd.BlockType.reserved, @as(zstd.BlockType, .reserved));
}
