const std = @import("std");
const i = @import("internal");

test "Dictionary load and dictId" {
    const alloc = std.testing.allocator;
    const raw = "test dictionary data";
    var dict = try i.dictionary_mod.loadDictionary(alloc, raw);
    defer dict.deinit();
    try std.testing.expectEqual(@as(u32, 0), dict.dictId());
}

test "createDictionaryFromData" {
    const alloc = std.testing.allocator;
    var dict = try i.dictionary_mod.createDictionaryFromData(alloc, "dict content", 42);
    defer dict.deinit();
    try std.testing.expectEqual(@as(u32, 42), dict.dictId());
    try std.testing.expect(dict.data.len > 8);
}

test "Dictionary content with magic" {
    const alloc = std.testing.allocator;
    var dict = try i.dictionary_mod.createDictionaryFromData(alloc, "content test", 99);
    defer dict.deinit();
    const content = dict.content();
    try std.testing.expectEqual(@as(usize, 12), content.len);
}

test "Dictionary content without magic" {
    const alloc = std.testing.allocator;
    var dict = try i.dictionary_mod.loadDictionary(alloc, "no magic");
    defer dict.deinit();
    const content = dict.content();
    try std.testing.expectEqual(@as(usize, 8), content.len);
}

test "Dictionary content too small" {
    const alloc = std.testing.allocator;
    var dict = try i.dictionary_mod.loadDictionary(alloc, "ab");
    defer dict.deinit();
    const content = dict.content();
    try std.testing.expectEqual(@as(usize, 0), content.len);
}

test "trainFromSamples basic" {
    const alloc = std.testing.allocator;
    const s1 = "The quick brown fox jumps over the lazy dog";
    const s2 = "Pack my box with five dozen liquor jugs";
    const s3 = "How vexingly quick daft zebras jump";
    const samples = [_][]const u8{ s1, s2, s3 };
    var dict = try i.dictionary_builder.trainFromSamples(alloc, &samples, .{ .dict_size = 256, .dict_id = 1 });
    defer dict.deinit();
    try std.testing.expect(dict.data.len > 0);
    try std.testing.expectEqual(@as(u32, 1), dict.dictId());
}

test "trainFromSamples empty samples" {
    const alloc = std.testing.allocator;
    const samples = [_][]const u8{};
    try std.testing.expectError(error.InvalidDictionary, i.dictionary_builder.trainFromSamples(alloc, &samples, .{ .dict_size = 256 }));
}

test "trainFromSamples empty content" {
    const alloc = std.testing.allocator;
    const samples = [_][]const u8{""};
    try std.testing.expectError(error.InvalidDictionary, i.dictionary_builder.trainFromSamples(alloc, &samples, .{ .dict_size = 256 }));
}

test "trainCoverImpl delegates" {
    const alloc = std.testing.allocator;
    const samples = [_][]const u8{"cover training data sample"};
    var dict = try i.dictionary_builder.trainCoverImpl(alloc, &samples, .{ .dict_size = 128 }, 4, 8);
    defer dict.deinit();
    try std.testing.expect(dict.data.len > 0);
}

test "trainFastCoverImpl delegates" {
    const alloc = std.testing.allocator;
    const samples = [_][]const u8{"fast cover training sample"};
    var dict = try i.dictionary_builder.trainFastCoverImpl(alloc, &samples, .{ .dict_size = 128 }, 4, 8, 2, 1);
    defer dict.deinit();
    try std.testing.expect(dict.data.len > 0);
}

test "DictionaryBuilder init" {
    const builder = i.dictionary_builder.DictionaryBuilder.init(std.testing.allocator, .{ .dict_size = 512, .dict_id = 7 });
    try std.testing.expectEqual(@as(usize, 512), builder.params.dict_size);
    try std.testing.expectEqual(@as(u32, 7), builder.params.dict_id);
}

test "DictionaryBuilder train" {
    var builder = i.dictionary_builder.DictionaryBuilder.init(std.testing.allocator, .{ .dict_size = 256, .dict_id = 55 });
    const samples = [_][]const u8{ "builder training sample one", "builder training sample two" };
    var dict = try builder.train(&samples);
    defer dict.deinit();
    try std.testing.expectEqual(@as(u32, 55), dict.dictId());
}

test "DictionaryBuilder trainCover" {
    var builder = i.dictionary_builder.DictionaryBuilder.init(std.testing.allocator, .{ .dict_size = 256 });
    const samples = [_][]const u8{"cover builder sample"};
    var dict = try builder.trainCover(&samples, 4, 8);
    defer dict.deinit();
    try std.testing.expect(dict.data.len > 0);
}

test "DictionaryBuilder trainFastCover" {
    var builder = i.dictionary_builder.DictionaryBuilder.init(std.testing.allocator, .{ .dict_size = 256 });
    const samples = [_][]const u8{"fast cover builder sample"};
    var dict = try builder.trainFastCover(&samples, 4, 8, 2, 1);
    defer dict.deinit();
    try std.testing.expect(dict.data.len > 0);
}

test "DictBuilderParams defaults" {
    const p = i.dictionary_builder.DictBuilderParams{};
    try std.testing.expect(p.dict_size > 0);
    try std.testing.expectEqual(@as(u32, 0), p.dict_id);
}
