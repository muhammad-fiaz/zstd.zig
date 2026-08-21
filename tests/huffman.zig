const std = @import("std");
const i = @import("internal");

test "huffman maxTableLog" {
    try std.testing.expectEqual(@as(u8, 11), i.huff_common.maxTableLog);
}

test "compressHuffman unsupported" {
    var dst: [256]u8 = undefined;
    const src = [_]u8{ 1, 2, 3 };
    const result = i.huff_compress.compressHuffman(&dst, &src);
    try std.testing.expectError(error.UnsupportedFeature, result);
}

test "buildWeights unsupported" {
    var weights: [256]u8 = undefined;
    const counts = [_]u32{ 10, 5, 3 };
    const result = i.huff_compress.buildWeights(&weights, &counts, 2);
    try std.testing.expectError(error.UnsupportedFeature, result);
}

test "buildTableFromWeights unsupported" {
    const weights = [_]u8{ 4, 3, 2, 1 };
    const result = i.huff_table.buildTableFromWeights(std.testing.allocator, &weights, 4);
    try std.testing.expectError(error.UnsupportedFeature, result);
}

test "buildDecoder simple" {
    const weights = [_]u8{ 2, 1, 1 };
    var dec = try i.huff_decompress.buildDecoder(std.testing.allocator, &weights);
    defer dec.deinit();
    try std.testing.expectEqual(@as(u8, 2), dec.max_bits);
    try std.testing.expect(dec.table.len == 4);
}

test "buildDecoder single weight" {
    const weights = [_]u8{3};
    var dec = try i.huff_decompress.buildDecoder(std.testing.allocator, &weights);
    defer dec.deinit();
    try std.testing.expectEqual(@as(u8, 3), dec.max_bits);
}

test "buildDecoder empty" {
    const weights = [_]u8{};
    const result = i.huff_decompress.buildDecoder(std.testing.allocator, &weights);
    try std.testing.expectError(error.InvalidHuffmanTable, result);
}

test "buildDecoder all zero" {
    const weights = [_]u8{ 0, 0, 0 };
    const result = i.huff_decompress.buildDecoder(std.testing.allocator, &weights);
    try std.testing.expectError(error.InvalidHuffmanTable, result);
}

test "buildDecoder weight too large" {
    const weights = [_]u8{ 12, 1 };
    const result = i.huff_decompress.buildDecoder(std.testing.allocator, &weights);
    try std.testing.expectError(error.InvalidHuffmanTable, result);
}

test "buildDecoder symbols populated" {
    const weights = [_]u8{ 2, 1, 1 };
    var dec = try i.huff_decompress.buildDecoder(std.testing.allocator, &weights);
    defer dec.deinit();
    var found = [_]bool{ false, false, false };
    for (dec.table) |e| {
        if (e.symbol < 3) found[e.symbol] = true;
    }
    try std.testing.expect(found[0]);
    try std.testing.expect(found[1]);
    try std.testing.expect(found[2]);
}

test "decompressHuffmanBlock unsupported" {
    var dst: [4]u8 = undefined;
    const src = [_]u8{0x00};
    const result = i.huff_decompress.decompressHuffmanBlock(std.testing.allocator, &dst, &src);
    try std.testing.expectError(error.UnsupportedFeature, result);
}

test "decompressHuffmanBlock empty" {
    var dst: [4]u8 = undefined;
    const result = i.huff_decompress.decompressHuffmanBlock(std.testing.allocator, &dst, &[_]u8{});
    try std.testing.expectError(error.SrcSizeWrong, result);
}

test "decodeSingleStream" {
    const weights = [_]u8{ 2, 1, 1 };
    var dec = try i.huff_decompress.buildDecoder(std.testing.allocator, &weights);
    defer dec.deinit();
    var dst: [4]u8 = undefined;
    var src: [4]u8 = undefined;
    @memset(&src, 0);
    i.huff_decompress.decodeSingleStream(&dst, &src, &dec) catch {};
}
