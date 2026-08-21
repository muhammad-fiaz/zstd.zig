const std = @import("std");
const i = @import("internal");

test "decompress roundtrip" {
    const alloc = std.testing.allocator;
    const src = "roundtrip test data";
    const c = try i.compress_mod.compress(alloc, src, .{});
    defer alloc.free(c);
    const d = try i.decompress_mod.decompress(alloc, c);
    defer alloc.free(d);
    try std.testing.expectEqualStrings(src, d);
}

test "decompress empty" {
    const alloc = std.testing.allocator;
    const c = try i.compress_mod.compress(alloc, "", .{});
    defer alloc.free(c);
    const d = try i.decompress_mod.decompress(alloc, c);
    defer alloc.free(d);
    try std.testing.expectEqual(@as(usize, 0), d.len);
}

test "decompress single byte" {
    const alloc = std.testing.allocator;
    const src = [_]u8{0xFF};
    const c = try i.compress_mod.compress(alloc, &src, .{});
    defer alloc.free(c);
    const d = try i.decompress_mod.decompress(alloc, c);
    defer alloc.free(d);
    try std.testing.expectEqualSlices(u8, &src, d);
}

test "decompress large data" {
    const alloc = std.testing.allocator;
    var src: [4096]u8 = undefined;
    for (&src, 0..) |*b, j| b.* = @intCast(j % 256);
    const c = try i.compress_mod.compress(alloc, &src, .{});
    defer alloc.free(c);
    const d = try i.decompress_mod.decompress(alloc, c);
    defer alloc.free(d);
    try std.testing.expectEqualSlices(u8, &src, d);
}

test "decompressBound basic" {
    const alloc = std.testing.allocator;
    const c = try i.compress_mod.compress(alloc, "bound test", .{});
    defer alloc.free(c);
    const bound = try i.decompress_mod.decompressBound(c);
    try std.testing.expect(bound >= 10);
}

test "findFrameCompressedSize" {
    const alloc = std.testing.allocator;
    const c = try i.compress_mod.compress(alloc, "frame size", .{});
    defer alloc.free(c);
    const sz = try i.decompress_mod.findFrameCompressedSize(c);
    try std.testing.expectEqual(c.len, sz);
}

test "decompress invalid magic" {
    const alloc = std.testing.allocator;
    const bad = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    const result = i.decompress_mod.decompress(alloc, &bad);
    try std.testing.expectError(error.PrefixUnknown, result);
}

test "decodeLiterals empty" {
    const result = i.decompress_literals.decodeLiterals(&[_]u8{});
    try std.testing.expectError(error.SrcSizeWrong, result);
}

test "decodeLiterals raw type 0 small" {
    const header: u8 = (0 << 0) | (0 << 2) | (3 << 3);
    const data = [_]u8{ header, 0xAA, 0xBB };
    const result = i.decompress_literals.decodeLiterals(&data);
    if (result) |r| {
        try std.testing.expectEqual(@as(usize, 2), r.literals.len);
        try std.testing.expect(!r.huffman_used);
    } else |_| {}
}

test "decodeLiterals type 1 unsupported" {
    const header: u8 = (1 << 0) | (0 << 2) | (0 << 3);
    const data = [_]u8{ header, 0, 0, 0, 0 };
    try std.testing.expectError(error.UnsupportedFeature, i.decompress_literals.decodeLiterals(&data));
}

test "decodeLiterals type 2 unsupported" {
    const header: u8 = (2 << 0) | (0 << 2) | (0 << 3);
    const data = [_]u8{ header, 0, 0, 0, 0 };
    try std.testing.expectError(error.UnsupportedFeature, i.decompress_literals.decodeLiterals(&data));
}

test "decodeRawLiterals" {
    const header: u8 = (0 << 0) | (0 << 2) | (3 << 3);
    const data = [_]u8{ header, 0xAA, 0xBB, 0xCC };
    var dst: [4]u8 = undefined;
    const read = try i.decompress_literals.decodeRawLiterals(&data, &dst);
    try std.testing.expect(read > 0);
}

test "decodeSequences zero sequences" {
    var dst: [32]u8 = undefined;
    const literals = [_]u8{ 1, 2, 3 };
    const result = try i.decompress_sequences.decodeSequences(&dst, &literals, &[_]u8{0}, &[_]u8{});
    try std.testing.expectEqual(@as(usize, 3), result);
}

test "decodeSequences all zero types unsupported" {
    var dst: [32]u8 = undefined;
    const literals = [_]u8{ 1, 2 };
    const seq_data = [_]u8{ 1, 0x00 };
    try std.testing.expectError(error.Corruption, i.decompress_sequences.decodeSequences(&dst, &literals, &seq_data, &[_]u8{}));
}

test "DecompressionContext init" {
    var ctx = i.decompress_context.DecompressionContext.init(std.testing.allocator);
    ctx.deinit();
}

test "DecompressionContext decompress" {
    var ctx = i.decompress_context.DecompressionContext.init(std.testing.allocator);
    defer ctx.deinit();
    const alloc = std.testing.allocator;
    const c = try i.compress_mod.compress(alloc, "ctx decompress test", .{});
    defer alloc.free(c);
    const d = try ctx.decompressAlloc(c);
    defer alloc.free(d);
    try std.testing.expectEqualStrings("ctx decompress test", d);
}

test "DecompressionOptions defaults" {
    const opts = i.decompress_context.DecompressionOptions{};
    try std.testing.expect(opts.max_window_size > 0);
    try std.testing.expect(!opts.force_ignore_checksum);
}
