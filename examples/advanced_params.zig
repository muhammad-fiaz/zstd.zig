const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const data = "Advanced parameters example: custom window, checksum, and strategy tuning. " ** 30;
    var base = zstd.getCompressionParameters(12, data.len, 20);
    base.checksum = true;
    const compressed = try zstd.compressWithOptions(allocator, data, base);
    defer allocator.free(compressed);
    std.debug.print("Advanced compress: {d} -> {d} (strategy={s}, window_log={d})\n", .{ data.len, compressed.len, @tagName(base.strategy), base.window_log });
    const hdr = try zstd.getFrameHeader(compressed);
    std.debug.assert(hdr.checksum_flag);
    std.debug.assert(hdr.window_size >= data.len);
    const decompressed = try zstd.decompress(allocator, compressed);
    defer allocator.free(decompressed);
    std.debug.assert(std.mem.eql(u8, data, decompressed));
    std.debug.print("Decompressed {d} bytes, checksum validated\n", .{decompressed.len});
}
