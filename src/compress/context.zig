//! Compression context and encoder management.

const std = @import("std");
const constants = @import("../common/constants.zig");
const compress_mod = @import("compress.zig");
const streaming = @import("../streaming/compress.zig");
const dictionary_mod = @import("../dictionary/dictionary.zig");
const mt_mod = @import("mt.zig");

pub const CompressionContext = struct {
    allocator: std.mem.Allocator,
    options: compress_mod.CompressionOptions,
    stream: streaming.StreamingCompressor,
    mt_compressor: ?*mt_mod.MTCompressor = null,
    owned_threaded_io: ?*std.Io.Threaded = null,

    /// Creates a single-threaded compression context with default level 3.
    pub fn init(allocator: std.mem.Allocator) CompressionContext {
        return initWithLevel(allocator, constants.c_level_default);
    }

    /// Creates a single-threaded compression context with numeric level.
    pub fn initWithLevel(allocator: std.mem.Allocator, level: i32) CompressionContext {
        const opts = compress_mod.getCompressionParameters(level, 0, 0);
        return .{
            .allocator = allocator,
            .options = opts,
            .stream = streaming.StreamingCompressor.initWithOptions(allocator, opts),
            .mt_compressor = null,
            .owned_threaded_io = null,
        };
    }

    /// Creates a compression context with explicit options.
    /// If options.workers is 0, compression remains single-threaded.
    /// If options.workers is greater than 0, a dedicated worker pool is initialized.
    pub fn initWithOptions(allocator: std.mem.Allocator, options: compress_mod.CompressionOptions) !CompressionContext {
        var self: CompressionContext = .{
            .allocator = allocator,
            .options = options,
            .stream = streaming.StreamingCompressor.initWithOptions(allocator, options),
            .mt_compressor = null,
            .owned_threaded_io = null,
        };
        errdefer self.deinit();

        if (options.workers > 0) {
            const io = if (options.io) |user_io| user_io else blk: {
                const threaded = try allocator.create(std.Io.Threaded);
                errdefer allocator.destroy(threaded);
                threaded.* = std.Io.Threaded.init(allocator, .{});
                self.owned_threaded_io = threaded;
                break :blk threaded.io();
            };
            const mt = try allocator.create(mt_mod.MTCompressor);
            errdefer allocator.destroy(mt);
            mt.* = try mt_mod.MTCompressor.init(allocator, io, options, options.workers);
            if (options.jobSize > 0) mt.minJobSize = options.jobSize;
            self.mt_compressor = mt;
        }
        return self;
    }

    pub fn deinit(self: *CompressionContext) void {
        if (self.mt_compressor) |mt| {
            mt.deinit();
            self.allocator.destroy(mt);
            self.mt_compressor = null;
        }
        if (self.owned_threaded_io) |threaded| {
            threaded.deinit();
            self.allocator.destroy(threaded);
            self.owned_threaded_io = null;
        }
        self.stream.deinit();
    }

    pub fn setLevel(self: *CompressionContext, level: i32) void {
        self.options = compress_mod.getCompressionParameters(level, 0, 0);
        self.stream.options = self.options;
        if (self.mt_compressor) |mt| mt.options = self.options;
    }

    pub fn setChecksum(self: *CompressionContext, flag: bool) void {
        self.options.checksum = flag;
        self.stream.setChecksumFlag(flag);
        if (self.mt_compressor) |mt| mt.options.checksum = flag;
    }

    pub fn setWindowLog(self: *CompressionContext, log: u8) void {
        self.options.windowLog = log;
        if (self.mt_compressor) |mt| mt.options.windowLog = log;
    }

    pub fn setLongDistanceMatching(self: *CompressionContext, enable: bool) void {
        self.options.longDistanceMatching = enable;
        if (self.mt_compressor) |mt| mt.options.longDistanceMatching = enable;
    }

    pub fn setPledgedSrcSize(self: *CompressionContext, size: ?u64) void {
        self.options.contentSize = size;
        self.stream.setPledgedSrcSize(size);
        if (self.mt_compressor) |mt| mt.options.contentSize = size;
    }

    pub fn setStrategy(self: *CompressionContext, strategy: constants.Strategy) void {
        self.options.strategy = strategy;
        if (self.mt_compressor) |mt| mt.options.strategy = strategy;
    }

    pub fn setOptions(self: *CompressionContext, options: compress_mod.CompressionOptions) !void {
        self.options = options;
        self.stream.options = options;
        try self.setWorkers(options.workers);
        if (self.mt_compressor) |mt| {
            mt.options = options;
            if (options.jobSize > 0) mt.minJobSize = options.jobSize;
        }
    }

    pub fn setWorkers(self: *CompressionContext, count: usize) !void {
        if (count == 0) {
            if (self.mt_compressor) |mt| {
                mt.deinit();
                self.allocator.destroy(mt);
                self.mt_compressor = null;
            }
            if (self.owned_threaded_io) |threaded| {
                threaded.deinit();
                self.allocator.destroy(threaded);
                self.owned_threaded_io = null;
            }
            self.options.workers = 0;
            return;
        }

        if (self.mt_compressor) |mt| {
            try mt.setWorkers(count);
            self.options.workers = count;
        } else {
            const io = if (self.options.io) |user_io| user_io else blk: {
                const threaded = try self.allocator.create(std.Io.Threaded);
                errdefer self.allocator.destroy(threaded);
                threaded.* = std.Io.Threaded.init(self.allocator, .{});
                self.owned_threaded_io = threaded;
                break :blk threaded.io();
            };
            const mt = try self.allocator.create(mt_mod.MTCompressor);
            errdefer self.allocator.destroy(mt);
            mt.* = try mt_mod.MTCompressor.init(self.allocator, io, self.options, count);
            if (self.options.jobSize > 0) mt.minJobSize = self.options.jobSize;
            self.mt_compressor = mt;
            self.options.workers = count;
        }
    }

    pub fn setDictionary(self: *CompressionContext, dictionary: ?*const dictionary_mod.Dictionary) void {
        self.options.dictionary = dictionary;
        self.options.dictId = if (dictionary) |d| d.dictId() else 0;
        self.stream.setDictionary(dictionary);
        if (self.mt_compressor) |mt| {
            mt.options.dictionary = dictionary;
            mt.options.dictId = self.options.dictId;
        }
    }

    pub fn compress(self: *CompressionContext, dst: []u8, src: []const u8) !usize {
        if (self.mt_compressor) |mt| {
            return mt.compressInto(dst, src);
        }
        return compress_mod.compressInto(self.allocator, dst, src, self.options);
    }

    pub fn compressAlloc(self: *CompressionContext, src: []const u8) anyerror![]u8 {
        if (self.mt_compressor) |mt| {
            return mt.compressAlloc(src);
        }
        return compress_mod.compress(self.allocator, src, self.options);
    }

    pub fn reset(self: *CompressionContext) void {
        self.stream.reset();
        if (self.mt_compressor) |mt| {
            mt.reset();
        }
    }
};

/// High-level client encoder with explicit configuration and lifecycle control.
pub const Encoder = struct {
    context: CompressionContext,

    pub fn init(allocator: std.mem.Allocator, options: compress_mod.CompressionOptions) !Encoder {
        return .{ .context = try CompressionContext.initWithOptions(allocator, options) };
    }

    pub fn deinit(self: *Encoder) void {
        self.context.deinit();
    }

    pub fn reset(self: *Encoder) void {
        self.context.reset();
    }

    pub fn compress(self: *Encoder, src: []const u8) ![]u8 {
        return self.context.compressAlloc(src);
    }

    pub fn compressInto(self: *Encoder, dst: []u8, src: []const u8) !usize {
        return self.context.compress(dst, src);
    }

    pub fn setLevel(self: *Encoder, level: i32) void {
        self.context.setLevel(level);
    }

    pub fn setChecksum(self: *Encoder, flag: bool) void {
        self.context.setChecksum(flag);
    }

    pub fn setWorkers(self: *Encoder, count: usize) !void {
        try self.context.setWorkers(count);
    }
};

const testing = std.testing;

test "CompressionContext init deinit" {
    var ctx = CompressionContext.init(testing.allocator);
    ctx.deinit();
}

test "CompressionContext setLevel" {
    var ctx = CompressionContext.init(testing.allocator);
    defer ctx.deinit();
    ctx.setLevel(10);
    try testing.expectEqual(@as(i32, 10), ctx.options.level);
}

test "CompressionContext setChecksum" {
    var ctx = CompressionContext.init(testing.allocator);
    defer ctx.deinit();
    ctx.setChecksum(true);
    try testing.expect(ctx.options.checksum);
}

test "CompressionContext setWindowLog" {
    var ctx = CompressionContext.init(testing.allocator);
    defer ctx.deinit();
    ctx.setWindowLog(20);
    try testing.expectEqual(@as(u8, 20), ctx.options.windowLog);
}

test "Encoder default single-threaded operation" {
    var encoder = try Encoder.init(testing.allocator, .{});
    defer encoder.deinit();

    try testing.expectEqual(@as(usize, 0), encoder.context.options.workers);
    try testing.expect(encoder.context.mt_compressor == null);

    const input = "testing single-threaded encoder default without workers";
    const compressed = try encoder.compress(input);
    defer testing.allocator.free(compressed);

    const decompressed = try @import("../decompress/decompress.zig").decompress(testing.allocator, compressed);
    defer testing.allocator.free(decompressed);

    try testing.expectEqualSlices(u8, input, decompressed);
}

test "Encoder explicit multithreaded operation" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var encoder = try Encoder.init(testing.allocator, .{
        .level = 3,
        .workers = 2,
        .io = testing.io,
    });
    defer encoder.deinit();

    try testing.expectEqual(@as(usize, 2), encoder.context.options.workers);
    try testing.expect(encoder.context.mt_compressor != null);

    const input = "testing explicit multithreaded encoder with dedicated workers";
    const compressed = try encoder.compress(input);
    defer testing.allocator.free(compressed);

    const decompressed = try @import("../decompress/decompress.zig").decompress(testing.allocator, compressed);
    defer testing.allocator.free(decompressed);

    try testing.expectEqualSlices(u8, input, decompressed);
}
