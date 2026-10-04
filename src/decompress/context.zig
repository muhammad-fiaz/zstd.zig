const std = @import("std");
const constants = @import("../common/constants.zig");
const decompress_mod = @import("decompress.zig");
const streaming = @import("../streaming/decompress.zig");
const dictionary = @import("../dictionary/dictionary.zig");

pub const DecompressionContext = struct {
    allocator: std.mem.Allocator,
    stream: streaming.StreamingDecompressor,
    maxWindowSize: usize,
    /// Dictionary borrowed by the context; see `setDictionary`.
    dict: ?*const dictionary.Dictionary = null,

    pub fn init(allocator: std.mem.Allocator) DecompressionContext {
        return .{
            .allocator = allocator,
            .stream = streaming.StreamingDecompressor.init(allocator),
            .maxWindowSize = @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(constants.window_log_limit_default)),
        };
    }

    pub fn deinit(self: *DecompressionContext) void {
        self.stream.deinit();
    }

    /// Sets the dictionary this context decodes with. It is borrowed, not copied:
    /// it must outlive the context or be replaced before the next decompression.
    /// A frame naming a different dictionary is rejected with
    /// `error.DictionaryWrong`.
    pub fn setDictionary(self: *DecompressionContext, value: ?*const dictionary.Dictionary) void {
        self.dict = value;
    }

    /// The dictionary content in force, empty when there is none.
    fn dictContent(self: *const DecompressionContext) []const u8 {
        return if (self.dict) |d| d.content() else &.{};
    }

    /// The ID frames are required to declare, zero when no dictionary is set.
    fn dictId(self: *const DecompressionContext) u32 {
        return if (self.dict) |d| d.dictId() else 0;
    }

    pub fn decompress(self: *DecompressionContext, dst: []u8, src: []const u8) !usize {
        return decompress_mod.decompressIntoLimits(self.allocator, dst, src, self.dictContent(), .{
            .maxWindowSize = self.maxWindowSize,
            .dictId = self.dictId(),
        });
    }

    pub fn decompressAlloc(self: *DecompressionContext, src: []const u8) anyerror![]u8 {
        const bound = try decompress_mod.decompressBound(self.allocator, src);
        const safe_bound = if (bound == 0) src.len * 4 + 1024 else bound;
        const dst = try self.allocator.alloc(u8, safe_bound);
        errdefer self.allocator.free(dst);
        const out_size = try self.decompress(dst, src);
        if (out_size == dst.len) return dst;
        return try self.allocator.realloc(dst, out_size);
    }

    /// Limits the window a frame may declare. Frames that need more are
    /// rejected before any block is decoded, and the limit is applied to the
    /// one-shot helpers above as well as to the streaming path.
    pub fn setMaxWindowSize(self: *DecompressionContext, size: usize) void {
        self.maxWindowSize = size;
        self.stream.maxWindowSize = size;
    }

    pub fn reset(self: *DecompressionContext) void {
        self.stream.reset();
    }
};

pub const DecompressionOptions = struct {
    maxWindowSize: usize = 1 << 27,
    forceIgnoreChecksum: bool = false,
    /// Dictionary whose content logically precedes each frame, so matches in the
    /// first block(s) may reach back into it. `null` means no dictionary.
    dictionary: ?*const dictionary.Dictionary = null,
    /// When set, a frame whose dictionary ID is neither zero nor this
    /// dictionary's ID is rejected with `error.DictionaryMismatch` instead of
    /// being decoded, which is what stops a frame compressed for a different
    /// dictionary from decoding to plausible-looking rubbish.
    requireDictionaryMatch: bool = false,
};

/// High-level client decoder with explicit options, window bounds, and dictionary control.
pub const Decoder = struct {
    context: DecompressionContext,
    options: DecompressionOptions,

    pub fn init(allocator: std.mem.Allocator, options: DecompressionOptions) Decoder {
        var ctx = DecompressionContext.init(allocator);
        ctx.setMaxWindowSize(options.maxWindowSize);
        if (options.dictionary) |d| {
            ctx.setDictionary(d);
        }
        return .{
            .context = ctx,
            .options = options,
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.context.deinit();
    }

    pub fn reset(self: *Decoder) void {
        self.context.reset();
    }

    pub fn setMaxWindowSize(self: *Decoder, size: usize) void {
        self.options.maxWindowSize = size;
        self.context.setMaxWindowSize(size);
    }

    pub fn setDictionary(self: *Decoder, dict: ?*const dictionary.Dictionary) void {
        self.options.dictionary = dict;
        self.context.setDictionary(dict);
    }

    pub fn decompress(self: *Decoder, dst: []u8, src: []const u8) !usize {
        if (self.options.requireDictionaryMatch and self.options.dictionary == null and src.len > 0) {
            return error.DictionaryWrong;
        }
        return decompress_mod.decompressIntoDictLimits(self.context.allocator, dst, src, self.context.dictContent(), .{
            .maxWindowSize = self.context.maxWindowSize,
            .forceIgnoreChecksum = self.options.forceIgnoreChecksum,
            .dictId = self.context.dictId(),
        });
    }

    pub fn decompressAlloc(self: *Decoder, src: []const u8) anyerror![]u8 {
        if (self.options.requireDictionaryMatch and self.options.dictionary == null and src.len > 0) {
            return error.DictionaryWrong;
        }
        const bound = try decompress_mod.decompressBound(self.context.allocator, src);
        const safe_bound = if (bound == 0) src.len * 4 + 1024 else bound;
        const dst = try self.context.allocator.alloc(u8, safe_bound);
        errdefer self.context.allocator.free(dst);
        const out_size = try self.decompress(dst, src);
        if (out_size == dst.len) return dst;
        return try self.context.allocator.realloc(dst, out_size);
    }
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
    try testing.expect(opts.maxWindowSize > 0);
    try testing.expect(!opts.forceIgnoreChecksum);
}

test "DecompressionContext enforces the window limit" {
    const alloc = testing.allocator;
    const comp_mod = @import("../compress/compress.zig");
    var payload: [70000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(11);
    const random = prng.random();
    for (&payload) |*b| b.* = random.intRangeAtMost(u8, 0, 3);
    // A window this small forces the frame header to advertise a window well
    // below the default limit, so a smaller limit rejects the frame.
    const compressed = try comp_mod.compress(alloc, &payload, .{ .level = 3, .windowLog = 10 });
    defer alloc.free(compressed);

    var ok = DecompressionContext.init(alloc);
    defer ok.deinit();
    const restored = try ok.decompressAlloc(compressed);
    defer alloc.free(restored);
    try testing.expectEqualSlices(u8, &payload, restored);

    var limited = DecompressionContext.init(alloc);
    defer limited.deinit();
    limited.setMaxWindowSize(512);
    try testing.expectError(error.WindowTooLarge, limited.decompressAlloc(compressed));
    var out: [70000]u8 = undefined;
    try testing.expectError(error.WindowTooLarge, limited.decompress(&out, compressed));
}

test "decompressWithOptions enforces the window limit" {
    const alloc = testing.allocator;
    const comp_mod = @import("../compress/compress.zig");
    var payload: [20000]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i % 7);
    const compressed = try comp_mod.compress(alloc, &payload, .{ .level = 3, .windowLog = 12 });
    defer alloc.free(compressed);
    try testing.expectError(
        error.WindowTooLarge,
        @import("../zstd.zig").decompressWithOptions(alloc, compressed, .{ .maxWindowSize = 1024 }),
    );
    const ok = try @import("../zstd.zig").decompressWithOptions(alloc, compressed, .{});
    defer alloc.free(ok);
    try testing.expectEqualSlices(u8, &payload, ok);
}

test "streaming decompressor enforces the window limit" {
    const alloc = testing.allocator;
    const comp_mod = @import("../compress/compress.zig");
    const stream_mod = @import("../streaming/decompress.zig");
    var payload: [30000]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i % 11);
    const compressed = try comp_mod.compress(alloc, &payload, .{ .level = 3, .windowLog = 15 });
    defer alloc.free(compressed);

    var sd = stream_mod.StreamingDecompressor.init(alloc);
    defer sd.deinit();
    sd.setMaxWindowSize(1024);
    var out: [30000]u8 = undefined;
    try testing.expectError(error.WindowTooLarge, sd.decompressStream(&out, compressed));
}

test "Decoder lifecycle and decompression" {
    const alloc = testing.allocator;
    const comp_mod = @import("../compress/compress.zig");
    const test_str = "Decoder client-side API test string payload";
    const compressed = try comp_mod.compress(alloc, test_str, .{});
    defer alloc.free(compressed);

    var decoder = Decoder.init(alloc, .{});
    defer decoder.deinit();

    const decompressed = try decoder.decompressAlloc(compressed);
    defer alloc.free(decompressed);
    try testing.expectEqualStrings(test_str, decompressed);

    var dst_buf: [128]u8 = undefined;
    const written = try decoder.decompress(&dst_buf, compressed);
    try testing.expectEqualStrings(test_str, dst_buf[0..written]);

    decoder.reset();
}
