const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const header_mod = @import("../frame/header.zig");
const checksum_mod = @import("../frame/checksum.zig");
const block_mod = @import("block.zig");

pub const CompressionOptions = struct {
    level: i32 = 3,
    window_log: u8 = 0,
    hash_log: u8 = 0,
    chain_log: u8 = 0,
    search_log: u8 = 0,
    min_match: u8 = 0,
    target_length: u32 = 0,
    strategy: constants.Strategy = .fast,
    checksum: bool = false,
    dict_id: u32 = 0,
    content_size: ?u64 = null,
    enable_ldm: bool = false,
};

pub fn compressBound(src_size: usize) usize {
    return constants.compressBound(src_size) + 18 + 3 + 4;
}

pub fn compress(allocator: std.mem.Allocator, src: []const u8, options: CompressionOptions) anyerror![]u8 {
    const bound = compressBound(src.len);
    const dst = try allocator.alloc(u8, bound);
    errdefer allocator.free(dst);
    const written = try compressInto(dst, src, options);
    if (written == dst.len) return dst;
    const trimmed = try allocator.realloc(dst, written);
    return trimmed;
}

pub fn compressInto(dst: []u8, src: []const u8, options: CompressionOptions) errors.ZstdError!usize {
    if (dst.len < compressBound(src.len)) return error.DstSizeTooSmall;
    var pos: usize = 0;
    const content_size: ?u64 = options.content_size orelse @as(?u64, src.len);
    const window_size: u64 = if (options.window_log != 0) @as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(options.window_log)) else if (src.len == 0) 1024 else @max(@as(u64, src.len), 1024);
    const single_segment = window_size >= @as(u64, src.len) and src.len < 256 * 1024;
    const header_size = header_mod.writeFrameHeader(dst[pos..], content_size, window_size, options.dict_id, options.checksum, single_segment);
    pos += header_size;
    const block_max = constants.block_size_max;
    var src_pos: usize = 0;
    while (src_pos < src.len) {
        const remaining = src.len - src_pos;
        const chunk = @min(remaining, block_max);
        const is_last = src_pos + chunk >= src.len;
        const written = try block_mod.compressBlockWithStrategy(dst[pos..], src[src_pos .. src_pos + chunk], is_last, options.strategy, options.level);
        pos += written;
        src_pos += chunk;
    }
    if (src.len == 0) {
        const written = try block_mod.compressBlockWithStrategy(dst[pos..], src, true, options.strategy, options.level);
        pos += written;
    }
    if (options.checksum) {
        if (dst.len < pos + 4) return error.DstSizeTooSmall;
        const chk = checksum_mod.computeChecksum(src);
        checksum_mod.writeChecksum(dst[pos..], chk);
        pos += 4;
    }
    return pos;
}

pub fn getCompressionParameters(level: i32, src_size: usize, window_log: u8) CompressionOptions {
    const params = @import("parameters.zig").getParams(level, src_size, 0);
    var opts = CompressionOptions{
        .level = @max(constants.c_level_min, @min(constants.c_level_max, level)),
        .window_log = params.window_log,
        .hash_log = params.hash_log,
        .chain_log = params.chain_log,
        .search_log = params.search_log,
        .min_match = params.min_match,
        .target_length = params.target_length,
        .strategy = params.strategy,
    };
    if (window_log != 0) opts.window_log = @max(constants.window_log_min, @min(constants.window_log_max, window_log));
    return opts;
}

const testing = std.testing;

test "CompressionOptions defaults" {
    const opts = CompressionOptions{};
    try testing.expectEqual(@as(i32, 3), opts.level);
    try testing.expect(!opts.checksum);
}

test "compressBound returns value" {
    const b = compressBound(100);
    try testing.expect(b > 100);
}
