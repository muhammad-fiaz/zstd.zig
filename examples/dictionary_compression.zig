const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const dict_data = "common dictionary content for small message compression example";
    var dict = try zstd.createDictionaryFromData(allocator, dict_data, 12345);
    defer dict.deinit();
    std.debug.print("Dictionary ID: {d}, size: {d}\n", .{ dict.dictId(), dict.data.len });
    const samples = [_][]const u8{ "small message 1 with common prefix", "small message 2 with common prefix", "small message 3 with common prefix" };
    var builder = zstd.DictionaryBuilder.init(allocator, .{ .dict_size = 4096, .dict_id = 999 });
    var trained = try builder.train(&samples);
    defer trained.deinit();
    std.debug.print("Trained dictionary size: {d}\n", .{trained.data.len});
    std.debug.assert(trained.data.len > 0);
    const data = "small message 4 with common prefix and extra content";
    // Demonstrate compression with dictionary ID in frame header (dictionary-aware API)
    const opts = zstd.CompressionOptions{ .dict_id = dict.dictId() };
    const cs = try zstd.compressWithOptions(allocator, data, opts);
    defer allocator.free(cs);
    const dec = try zstd.decompress(allocator, cs);
    defer allocator.free(dec);
    std.debug.assert(std.mem.eql(u8, data, dec));
    std.debug.print("Dictionary example: {s} -> {d} bytes -> {s}\n", .{ data, cs.len, dec });
}
