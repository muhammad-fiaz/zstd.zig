const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const good = try zstd.compress(allocator, "valid data");
    defer allocator.free(good);
    var bad = try allocator.dupe(u8, good);
    defer allocator.free(bad);
    bad[0] ^= 0xFF;
    const result = zstd.decompress(allocator, bad);
    if (result) |data| {
        defer allocator.free(data);
        std.debug.print("Unexpected success: {d} bytes\n", .{data.len});
        return error.TestFailed;
    } else |err| {
        std.debug.print("Correctly caught error: {s}\n", .{@errorName(err)});
    }
    const truncated = good[0 .. good.len / 2];
    const r2 = zstd.decompress(allocator, truncated);
    if (r2) |data| {
        defer allocator.free(data);
        std.debug.print("Unexpected success on truncated\n", .{});
        return error.TestFailed;
    } else |err| {
        std.debug.print("Truncated correctly failed: {s}\n", .{@errorName(err)});
    }
    var small: [2]u8 = undefined;
    const r3 = zstd.decompressInto(&small, good);
    if (r3) |sz| {
        std.debug.print("Unexpected success small buf {d}\n", .{sz});
        return error.TestFailed;
    } else |err| {
        std.debug.print("Small buffer correctly failed: {s}\n", .{@errorName(err)});
    }
    std.debug.print("Error handling example complete\n", .{});
}
