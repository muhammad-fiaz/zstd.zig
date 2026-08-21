const std = @import("std");
const i = @import("internal");

test "fse maxTableLog" {
    try std.testing.expectEqual(@as(u8, 9), i.fse_common.maxTableLog);
}

test "countFrequencies basic" {
    var counts: [256]u32 = undefined;
    const src = [_]u8{ 0, 0, 1, 2, 2, 2, 3 };
    const max_sym = i.fse_compress.countFrequencies(&counts, &src, 3);
    try std.testing.expectEqual(@as(usize, 3), max_sym);
    try std.testing.expectEqual(@as(u32, 2), counts[0]);
    try std.testing.expectEqual(@as(u32, 1), counts[1]);
    try std.testing.expectEqual(@as(u32, 3), counts[2]);
    try std.testing.expectEqual(@as(u32, 1), counts[3]);
}

test "countFrequencies empty" {
    var counts: [256]u32 = undefined;
    const src = [_]u8{};
    const max_sym = i.fse_compress.countFrequencies(&counts, &src, 5);
    try std.testing.expectEqual(@as(usize, 0), max_sym);
}

test "countFrequencies single symbol" {
    var counts: [256]u32 = undefined;
    const src = [_]u8{ 42, 42, 42 };
    const max_sym = i.fse_compress.countFrequencies(&counts, &src, 42);
    try std.testing.expectEqual(@as(usize, 42), max_sym);
    try std.testing.expectEqual(@as(u32, 3), counts[42]);
}

test "normalizeCounts basic" {
    var normalized: [32]i16 = undefined;
    const counts = [_]u32{ 10, 5, 3 };
    try i.fse_compress.normalizeCounts(&normalized, &counts, 5, 18);
    try std.testing.expect(normalized[0] > 0);
    try std.testing.expect(normalized[1] > 0);
    try std.testing.expect(normalized[2] > 0);
}

test "buildDecoder simple" {
    const normalized = [_]i16{ 2, 1, 1 };
    var dec = try i.fse_decompress.buildDecoder(std.testing.allocator, &normalized, 2, 2);
    defer dec.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), dec.table_log);
    try std.testing.expectEqual(@as(usize, 4), dec.table_size);
}

test "buildDecoder table_log_3" {
    const normalized = [_]i16{ 4, 2, 1, 1 };
    var dec = try i.fse_decompress.buildDecoder(std.testing.allocator, &normalized, 3, 3);
    defer dec.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 3), dec.table_log);
    try std.testing.expectEqual(@as(usize, 8), dec.table_size);
}

test "buildDecoder symbols cover all" {
    const normalized = [_]i16{ 2, 1, 1 };
    var dec = try i.fse_decompress.buildDecoder(std.testing.allocator, &normalized, 2, 2);
    defer dec.deinit(std.testing.allocator);
    var found = [_]bool{ false, false, false };
    for (dec.symbols) |s| {
        if (s < 3) found[s] = true;
    }
    try std.testing.expect(found[0]);
    try std.testing.expect(found[1]);
    try std.testing.expect(found[2]);
}

test "buildDecoder tableLogTooLarge" {
    const normalized = [_]i16{ 2, 1 };
    const result = i.fse_decompress.buildDecoder(std.testing.allocator, &normalized, 10, 1);
    try std.testing.expectError(error.TableLogTooLarge, result);
}

test "BitStream getBits" {
    const data = [_]u8{ 0xFF, 0x00, 0x00, 0x00 };
    var bs = i.fse_decompress.BitStream.init(&data);
    try std.testing.expectEqual(@as(u32, 0xFF), bs.getBits(8));
}

test "BitStream getBits zero" {
    const data = [_]u8{ 0xFF, 0, 0, 0 };
    var bs = i.fse_decompress.BitStream.init(&data);
    try std.testing.expectEqual(@as(u32, 0), bs.getBits(0));
}

test "BitStream peekBits" {
    const data = [_]u8{ 0xAB, 0xCD, 0, 0 };
    const bs = i.fse_decompress.BitStream.init(&data);
    try std.testing.expectEqual(@as(u32, 0xAB), bs.peekBits(8));
}

test "BitStream consumeBits" {
    const data = [_]u8{ 0xFF, 0x00, 0, 0 };
    var bs = i.fse_decompress.BitStream.init(&data);
    bs.consumeBits(8);
    try std.testing.expectEqual(@as(u32, 0x00), bs.getBits(8));
}

test "decodeFseTable empty" {
    const result = i.fse_decompress.decodeFseTable(std.testing.allocator, &[_]u8{}, 9, 255);
    try std.testing.expectError(error.InvalidFseTable, result);
}

test "decodeFseTable zero first byte" {
    const data = [_]u8{0};
    const result = i.fse_decompress.decodeFseTable(std.testing.allocator, &data, 9, 255);
    try std.testing.expectError(error.InvalidFseTable, result);
}

test "fse table buildFseTable" {
    const normalized = [_]i16{ 2, 1, 1 };
    var t = try i.fse_table.buildFseTable(std.testing.allocator, &normalized, 2, 2);
    defer t.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), t.table_log);
    try std.testing.expectEqual(@as(usize, 4), t.table_size);
}
