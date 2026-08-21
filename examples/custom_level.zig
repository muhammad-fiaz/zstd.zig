const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const data = "Text with moderate repetitiveness for level testing. " ** 20;
    for ([_]i32{ 1, 3, 6, 9, 15, 19 }) |level| {
        {
            const c = try zstd.compressWithLevel(allocator, data, level);
            defer allocator.free(c);
            std.debug.print("Level {d}: {d} -> {d} bytes ({d:.1}%)\n", .{ level, data.len, c.len, @as(f64, @floatFromInt(c.len)) / @as(f64, @floatFromInt(data.len)) * 100 });
            const d = try zstd.decompress(allocator, c);
            defer allocator.free(d);
            std.debug.assert(std.mem.eql(u8, data, d));
        }
    }
}
