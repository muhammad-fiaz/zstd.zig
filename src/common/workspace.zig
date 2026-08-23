const std = @import("std");
pub const Workspace = struct {
    buffer: []u8,
    allocator: std.mem.Allocator,
    pub fn init(a: std.mem.Allocator, s: usize) !Workspace {
        return .{ .buffer = try a.alloc(u8, s), .allocator = a };
    }
    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.buffer);
    }
};

const testing = @import("std").testing;

test "workspace init and deinit" {
    var ws = try Workspace.init(testing.allocator, 1024);
    defer ws.deinit();
    try testing.expectEqual(@as(usize, 1024), ws.buffer.len);
}
