const std = @import("std");
const i = @import("internal");

test "StreamingCompressor init and deinit" {
    var sc = try i.streaming_compress.StreamingCompressor.init(std.testing.allocator, 3);
    defer sc.deinit();
}

test "StreamingCompressor initWithOptions" {
    const opts = i.compress_mod.CompressionOptions{ .level = 5 };
    var sc = i.streaming_compress.StreamingCompressor.initWithOptions(std.testing.allocator, opts);
    defer sc.deinit();
}

test "StreamingCompressor cont then end" {
    var sc = try i.streaming_compress.StreamingCompressor.init(std.testing.allocator, 3);
    defer sc.deinit();
    var buf: [4096]u8 = undefined;
    const r1 = try sc.compressStream(&buf, "hello ", .cont);
    try std.testing.expect(r1.in_consumed == 6 or r1.remaining > 0);
    const r2 = try sc.compressStream(&buf, "world", .end);
    try std.testing.expect(r2.out_produced > 0);
}

test "StreamingCompressor flush" {
    var sc = try i.streaming_compress.StreamingCompressor.init(std.testing.allocator, 3);
    defer sc.deinit();
    var buf: [4096]u8 = undefined;
    _ = try sc.compressStream(&buf, "data", .flush);
    try std.testing.expect(!sc.finished);
}

test "StreamingCompressor end writes empty block" {
    var sc = try i.streaming_compress.StreamingCompressor.init(std.testing.allocator, 3);
    defer sc.deinit();
    var buf: [4096]u8 = undefined;
    const r = try sc.compressStream(&buf, "", .end);
    try std.testing.expect(r.out_produced > 0);
    try std.testing.expect(sc.finished);
}

test "StreamingCompressor setChecksumFlag" {
    var sc = try i.streaming_compress.StreamingCompressor.init(std.testing.allocator, 3);
    defer sc.deinit();
    sc.setChecksumFlag(true);
    var buf: [4096]u8 = undefined;
    const r = try sc.compressStream(&buf, "checksum data", .end);
    try std.testing.expect(r.out_produced > 0);
}

test "StreamingCompressor setPledgedSrcSize" {
    var sc = try i.streaming_compress.StreamingCompressor.init(std.testing.allocator, 3);
    defer sc.deinit();
    sc.setPledgedSrcSize(100);
    var buf: [4096]u8 = undefined;
    _ = try sc.compressStream(&buf, "pledged", .end);
}

test "StreamingCompressor reset" {
    var sc = try i.streaming_compress.StreamingCompressor.init(std.testing.allocator, 3);
    defer sc.deinit();
    var buf: [4096]u8 = undefined;
    _ = try sc.compressStream(&buf, "first", .end);
    sc.reset();
    try std.testing.expect(!sc.finished);
    try std.testing.expect(!sc.header_written);
}

test "StreamingDecompressor init and deinit" {
    var sd = i.streaming_decompress.StreamingDecompressor.init(std.testing.allocator);
    defer sd.deinit();
}

test "StreamingDecompressor decompressAll" {
    var sd = i.streaming_decompress.StreamingDecompressor.init(std.testing.allocator);
    defer sd.deinit();
    const alloc = std.testing.allocator;
    const c = try i.compress_mod.compress(alloc, "decompress all test", .{});
    defer alloc.free(c);
    var out: [256]u8 = undefined;
    const n = try sd.decompressAll(&out, c);
    try std.testing.expectEqualStrings("decompress all test", out[0..n]);
}

test "StreamingDecompressor reset" {
    var sd = i.streaming_decompress.StreamingDecompressor.init(std.testing.allocator);
    defer sd.deinit();
    sd.reset();
}

test "StreamingDecompressor streaming" {
    var sd = i.streaming_decompress.StreamingDecompressor.init(std.testing.allocator);
    defer sd.deinit();
    const alloc = std.testing.allocator;
    const src = "streaming decomp test";
    const c = try i.compress_mod.compress(alloc, src, .{});
    defer alloc.free(c);
    var out: [256]u8 = undefined;
    var total: usize = 0;
    var pos: usize = 0;
    while (pos < c.len) {
        const chunk_size = @min(c.len - pos, 4);
        const r = try sd.decompressStream(out[total..], c[pos .. pos + chunk_size]);
        total += r.out_produced;
        pos += chunk_size;
        if (r.out_produced == 0 and !r.needs_more) break;
    }
    try std.testing.expectEqualStrings(src, out[0..total]);
}
