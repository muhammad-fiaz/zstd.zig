const std = @import("std");

pub const Workspace = struct {
    buffer: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: usize) !Workspace {
        const buf = try allocator.alloc(u8, size);
        return .{ .buffer = buf, .allocator = allocator };
    }

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.buffer);
    }
};
