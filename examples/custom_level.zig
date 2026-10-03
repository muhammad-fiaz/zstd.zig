const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    for (0..20) |_| try data.appendSlice(allocator, "Text with moderate repetitiveness for level testing. ");

    for ([_]i32{ 1, 3, 6, 9, 15, 19 }) |level| {
        const c = try zstd.compressWithLevel(allocator, data.items, level);
        defer allocator.free(c);
        std.debug.print("Level {d}: {d} -> {d} bytes ({d:.1}%)\n", .{ level, data.items.len, c.len, @as(f64, @floatFromInt(c.len)) / @as(f64, @floatFromInt(data.items.len)) * 100 });
        const d = try zstd.decompress(allocator, c);
        defer allocator.free(d);
        std.debug.assert(std.mem.eql(u8, data.items, d));
    }
}
