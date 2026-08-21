const std = @import("std");
const i = @import("internal");

test "compressBlock empty" {
    var buf: [8]u8 = undefined;
    const written = try i.compress_block.compressBlock(&buf, "", true);
    try std.testing.expectEqual(@as(usize, 3), written);
}

test "compressBlock raw" {
    const src = "raw block data";
    var buf: [64]u8 = undefined;
    const written = try i.compress_block.compressBlock(&buf, src, false);
    try std.testing.expectEqual(3 + src.len, written);
}

test "compressBlock rle" {
    const src = [_]u8{ 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42 };
    var buf: [16]u8 = undefined;
    const written = try i.compress_block.compressBlock(&buf, &src, true);
    try std.testing.expectEqual(@as(usize, 4), written);
    try std.testing.expectEqual(@as(u8, 0x42), buf[3]);
}

test "compressBlock dst too small" {
    var buf: [2]u8 = undefined;
    const result = i.compress_block.compressBlock(&buf, "long data here", true);
    try std.testing.expectError(error.DstSizeTooSmall, result);
}

test "compressBlockWithStrategy" {
    const src = "strategy test";
    var buf: [64]u8 = undefined;
    const written = try i.compress_block.compressBlockWithStrategy(&buf, src, true, .fast, 1);
    try std.testing.expect(written > 0);
}

test "strategyFromLevel" {
    try std.testing.expectEqual(.fast, i.compress_strategy.strategyFromLevel(1));
    try std.testing.expectEqual(.fast, i.compress_strategy.strategyFromLevel(0));
    try std.testing.expectEqual(.dfast, i.compress_strategy.strategyFromLevel(2));
    try std.testing.expectEqual(.dfast, i.compress_strategy.strategyFromLevel(3));
    try std.testing.expectEqual(.greedy, i.compress_strategy.strategyFromLevel(4));
    try std.testing.expectEqual(.greedy, i.compress_strategy.strategyFromLevel(5));
    try std.testing.expectEqual(.lazy, i.compress_strategy.strategyFromLevel(6));
    try std.testing.expectEqual(.lazy, i.compress_strategy.strategyFromLevel(7));
    try std.testing.expectEqual(.lazy2, i.compress_strategy.strategyFromLevel(8));
    try std.testing.expectEqual(.lazy2, i.compress_strategy.strategyFromLevel(9));
    try std.testing.expectEqual(.btlazy2, i.compress_strategy.strategyFromLevel(10));
    try std.testing.expectEqual(.btlazy2, i.compress_strategy.strategyFromLevel(12));
    try std.testing.expectEqual(.btopt, i.compress_strategy.strategyFromLevel(13));
    try std.testing.expectEqual(.btopt, i.compress_strategy.strategyFromLevel(15));
    try std.testing.expectEqual(.btultra, i.compress_strategy.strategyFromLevel(16));
    try std.testing.expectEqual(.btultra, i.compress_strategy.strategyFromLevel(18));
    try std.testing.expectEqual(.btultra2, i.compress_strategy.strategyFromLevel(19));
    try std.testing.expectEqual(.btultra2, i.compress_strategy.strategyFromLevel(22));
}

test "HashTable init and deinit" {
    var ht = try i.compress_match_finder.HashTable.init(std.testing.allocator, 12);
    defer ht.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1 << 12), ht.table.len);
}

test "HashTable hashValue" {
    var ht = try i.compress_match_finder.HashTable.init(std.testing.allocator, 12);
    defer ht.deinit(std.testing.allocator);
    const data = [_]u8{ 1, 2, 3, 4, 5 };
    const h = ht.hashValue(&data, 0);
    try std.testing.expect(h < ht.table.len);
}

test "HashTable hashValue out of bounds" {
    var ht = try i.compress_match_finder.HashTable.init(std.testing.allocator, 12);
    defer ht.deinit(std.testing.allocator);
    const data = [_]u8{ 1, 2 };
    try std.testing.expectEqual(@as(u32, 0), ht.hashValue(&data, 0));
}

test "countMatchLength identical" {
    const a = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const b = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try std.testing.expectEqual(@as(usize, 10), i.compress_match_finder.countMatchLength(&a, &b));
}

test "countMatchLength partial" {
    const a = [_]u8{ 1, 2, 3, 4, 5 };
    const b = [_]u8{ 1, 2, 3, 99, 100 };
    try std.testing.expectEqual(@as(usize, 3), i.compress_match_finder.countMatchLength(&a, &b));
}

test "countMatchLength none" {
    const a = [_]u8{ 1, 2, 3 };
    const b = [_]u8{ 9, 8, 7 };
    try std.testing.expectEqual(@as(usize, 0), i.compress_match_finder.countMatchLength(&a, &b));
}

test "countMatchLength empty" {
    const a = [_]u8{};
    const b = [_]u8{ 1, 2, 3 };
    try std.testing.expectEqual(@as(usize, 0), i.compress_match_finder.countMatchLength(&a, &b));
}

test "getParams level 1" {
    const p = i.compress_parameters.getParams(1, 1000, 0);
    try std.testing.expectEqual(.fast, p.strategy);
}

test "getParams level 22" {
    const p = i.compress_parameters.getParams(22, 1000, 0);
    try std.testing.expectEqual(.btultra2, p.strategy);
}

test "getParams small src adjusts window" {
    const p = i.compress_parameters.getParams(1, 100, 0);
    try std.testing.expect(p.window_log <= 19);
    try std.testing.expect(p.window_log >= 10);
}

test "compressFast" {
    const src = "fast data";
    var buf: [32]u8 = undefined;
    const written = i.compress_fast.compressFast(&buf, src);
    try std.testing.expectEqual(3 + src.len, written);
    try std.testing.expectEqualSlices(u8, src, buf[3 .. 3 + src.len]);
}

test "compressFast dst too small" {
    var buf: [2]u8 = undefined;
    const written = i.compress_fast.compressFast(&buf, "long data");
    try std.testing.expectEqual(@as(usize, 0), written);
}

test "ldm defaults" {
    const p = i.compress_ldm.LdmParams{};
    try std.testing.expectEqual(@as(u8, 20), p.hash_log);
    try std.testing.expectEqual(@as(u32, 64), p.min_match);
}

test "ldm enable" {
    try std.testing.expect(i.compress_ldm.enableLdm(true));
    try std.testing.expect(!i.compress_ldm.enableLdm(false));
}

test "compressLiterals" {
    const src = "literal data";
    var buf: [32]u8 = undefined;
    const written = i.compress_literals.compressLiterals(&buf, src);
    try std.testing.expectEqual(1 + src.len, written);
    try std.testing.expectEqualSlices(u8, src, buf[1 .. 1 + src.len]);
}

test "compressLiterals empty" {
    var buf: [4]u8 = undefined;
    const written = i.compress_literals.compressLiterals(&buf, "");
    try std.testing.expectEqual(@as(usize, 1), written);
}

test "compressLiterals dst too small" {
    var buf: [2]u8 = undefined;
    const written = i.compress_literals.compressLiterals(&buf, "long literal data here");
    try std.testing.expectEqual(@as(usize, 0), written);
}

test "CompressionOptions defaults" {
    const opts = i.compress_mod.CompressionOptions{};
    try std.testing.expectEqual(@as(i32, 3), opts.level);
    try std.testing.expect(!opts.checksum);
}

test "compressBound returns value" {
    const b = i.compress_mod.compressBound(100);
    try std.testing.expect(b > 100);
}

test "CompressionContext init deinit" {
    var ctx = i.compress_context.CompressionContext.init(std.testing.allocator);
    ctx.deinit();
}

test "CompressionContext setLevel" {
    var ctx = i.compress_context.CompressionContext.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setLevel(10);
    try std.testing.expectEqual(@as(i32, 10), ctx.options.level);
}

test "CompressionContext setChecksum" {
    var ctx = i.compress_context.CompressionContext.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setChecksum(true);
    try std.testing.expect(ctx.options.checksum);
}

test "CompressionContext setWindowLog" {
    var ctx = i.compress_context.CompressionContext.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.setWindowLog(20);
    try std.testing.expectEqual(@as(u8, 20), ctx.options.window_log);
}
