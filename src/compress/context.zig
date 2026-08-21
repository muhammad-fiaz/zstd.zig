const std = @import("std");
const constants = @import("../common/constants.zig");
const compress_mod = @import("compress.zig");
const streaming = @import("../streaming/compress.zig");

pub const CompressionContext = struct {
    allocator: std.mem.Allocator,
    options: compress_mod.CompressionOptions,
    stream: streaming.StreamingCompressor,

    pub fn init(allocator: std.mem.Allocator) CompressionContext {
        return initWithLevel(allocator, constants.c_level_default);
    }

    pub fn initWithLevel(allocator: std.mem.Allocator, level: i32) CompressionContext {
        const opts = compress_mod.getCompressionParameters(level, 0, 0);
        return .{
            .allocator = allocator,
            .options = opts,
            .stream = streaming.StreamingCompressor.initWithOptions(allocator, opts),
        };
    }

    pub fn deinit(self: *CompressionContext) void {
        self.stream.deinit();
    }

    pub fn setLevel(self: *CompressionContext, level: i32) void {
        self.options = compress_mod.getCompressionParameters(level, 0, 0);
        self.stream.options = self.options;
    }

    pub fn setChecksum(self: *CompressionContext, flag: bool) void {
        self.options.checksum = flag;
        self.stream.setChecksumFlag(flag);
    }

    pub fn setWindowLog(self: *CompressionContext, log: u8) void {
        self.options.window_log = log;
    }

    pub fn setPledgedSrcSize(self: *CompressionContext, size: ?u64) void {
        self.options.content_size = size;
        self.stream.setPledgedSrcSize(size);
    }

    pub fn compress(self: *CompressionContext, dst: []u8, src: []const u8) !usize {
        return compress_mod.compressInto(dst, src, self.options);
    }

    pub fn compressAlloc(self: *CompressionContext, src: []const u8) anyerror![]u8 {
        return compress_mod.compress(self.allocator, src, self.options);
    }

    pub fn reset(self: *CompressionContext) void {
        self.stream.reset();
    }
};
