const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // One allocator for the whole program; the library never creates its own.
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, "Hello, Zstandard! This is a basic compression example with some repetitive data. ");
    for (0..5) |_| try input.appendSlice(allocator, "Hello, Zstandard! ");

    const compressed = try zstd.compress(allocator, input.items);
    defer allocator.free(compressed);
    std.debug.print("Original: {d} bytes\nCompressed: {d} bytes\nRatio: {d:.2}%\n", .{ input.items.len, compressed.len, @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(input.items.len)) * 100 });
    const decompressed = try zstd.decompress(allocator, compressed);
    defer allocator.free(decompressed);
    std.debug.assert(std.mem.eql(u8, input.items, decompressed));
    std.debug.print("Round-trip verified: {d} bytes\n", .{decompressed.len});
}
