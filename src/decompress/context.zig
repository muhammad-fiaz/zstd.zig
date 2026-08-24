const std = @import("std");
const constants = @import("../common/constants.zig");
const decompress_mod = @import("decompress.zig");
const streaming = @import("../streaming/decompress.zig");

pub const DecompressionContext = struct {
    allocator: std.mem.Allocator,
    stream: streaming.StreamingDecompressor,
    max_window_size: usize,

    pub fn init(allocator: std.mem.Allocator) DecompressionContext {
        return .{
            .allocator = allocator,
            .stream = streaming.StreamingDecompressor.init(allocator),
            .max_window_size = @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(constants.window_log_limit_default)),
        };
    }

    pub fn deinit(self: *DecompressionContext) void {
        self.stream.deinit();
    }

    pub fn decompress(self: *DecompressionContext, dst: []u8, src: []const u8) !usize {
        _ = self;
        return decompress_mod.decompressInto(dst, src);
    }

    pub fn decompressAlloc(self: *DecompressionContext, src: []const u8) anyerror![]u8 {
        return decompress_mod.decompress(self.allocator, src);
    }

    pub fn setMaxWindowSize(self: *DecompressionContext, size: usize) void {
        self.max_window_size = size;
    }

    pub fn reset(self: *DecompressionContext) void {
        self.stream.reset();
    }
};

pub const DecompressionOptions = struct {
    max_window_size: usize = 1 << 27,
    force_ignore_checksum: bool = false,
};

const testing = std.testing;

test "DecompressionContext init" {
    var ctx = DecompressionContext.init(testing.allocator);
    ctx.deinit();
}

test "DecompressionContext decompress" {
    var ctx = DecompressionContext.init(testing.allocator);
    defer ctx.deinit();
    const alloc = testing.allocator;
    const comp_mod = @import("../compress/compress.zig");
    const c = try comp_mod.compress(alloc, "ctx decompress test", .{});
    defer alloc.free(c);
    const d = try ctx.decompressAlloc(c);
    defer alloc.free(d);
    try testing.expectEqualStrings("ctx decompress test", d);
}

test "DecompressionOptions defaults" {
    const opts = DecompressionOptions{};
    try testing.expect(opts.max_window_size > 0);
    try testing.expect(!opts.force_ignore_checksum);
}
