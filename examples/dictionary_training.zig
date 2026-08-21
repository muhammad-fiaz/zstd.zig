const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var samples: std.ArrayList([]const u8) = .empty;
    defer samples.deinit(allocator);
    for (0..100) |i| {
        const s = try std.fmt.allocPrint(allocator, "sample {d}: common header and payload with id {d} and some repetitive text", .{ i, i % 10 });
        try samples.append(allocator, s);
    }
    defer for (samples.items) |s| allocator.free(s);
    var builder = zstd.DictionaryBuilder.init(allocator, .{ .dict_size = 8192 });
    var d = try builder.train(samples.items);
    defer d.deinit();
    std.debug.print("Trained dictionary: {d} bytes from {d} samples\n", .{ d.data.len, samples.items.len });
    std.debug.assert(d.data.len > 0);
    var cd = try builder.trainCover(samples.items, 6, 8);
    defer cd.deinit();
    std.debug.print("COVER dict: {d} bytes\n", .{cd.data.len});
    std.debug.assert(cd.data.len > 0);
    var fd = try builder.trainFastCover(samples.items, 6, 8, 6, 2);
    defer fd.deinit();
    std.debug.print("FastCover dict: {d} bytes\n", .{fd.data.len});
    std.debug.assert(fd.data.len > 0);
}
