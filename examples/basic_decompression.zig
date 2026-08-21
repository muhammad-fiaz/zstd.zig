const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const original = "Example data to compress and then decompress using zstd.zig";
    const compressed = try zstd.compress(allocator, original);
    defer allocator.free(compressed);
    const decompressed = try zstd.decompress(allocator, compressed);
    defer allocator.free(decompressed);
    std.debug.assert(std.mem.eql(u8, original, decompressed));
    std.debug.print("Decompression successful: {s}\n", .{decompressed});
}
