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
