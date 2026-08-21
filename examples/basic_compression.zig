const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const input = "Hello, Zstandard! This is a basic compression example with some repetitive data. " ++ "Hello, Zstandard! " ** 5;
    const compressed = try zstd.compress(allocator, input);
    defer allocator.free(compressed);
    std.debug.print("Original: {d} bytes\nCompressed: {d} bytes\nRatio: {d:.2}%\n", .{ input.len, compressed.len, @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(input.len)) * 100 });
    const decompressed = try zstd.decompress(allocator, compressed);
    defer allocator.free(decompressed);
    std.debug.assert(std.mem.eql(u8, input, decompressed));
    std.debug.print("Round-trip verified: {d} bytes\n", .{decompressed.len});
}
