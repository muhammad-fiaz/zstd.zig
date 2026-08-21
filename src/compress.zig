const std = @import("std");
const errors = @import("errors.zig");
const constants = @import("constants.zig");
const ver = @import("version.zig");

pub const ZstdError = errors.ZstdError;

pub const CLevel = enum(i32) {
    fastest = 1,
    default = 3,
    best = 19,
    _,

    pub fn toInt(self: CLevel) i32 {
        return @intFromEnum(self);
    }

    pub fn fromInt(val: i32) CLevel {
        return @enumFromInt(@as(i32, @intCast(val)));
    }
};

pub const CompressOptions = struct {
    level: CLevel = .default,
    checksum: bool = false,
    dict_id: u32 = 0,
    use_dict_id: bool = false,
    strategy: ?Strategy = null,
    window_log: ?u32 = null,
};

pub const CParameter = enum(c_int) {
    compression_level = 100,
    window_log = 101,
    hash_log = 102,
    chain_log = 103,
    search_log = 104,
    min_match = 105,
    target_length = 106,
    strategy = 107,
    target_block_size = 130,
    enable_long_distance_matching = 160,
    ldm_hash_log = 161,
    ldm_min_match = 162,
    ldm_bucket_size_log = 163,
    ldm_hash_rate_log = 164,
    content_size_flag = 200,
    checksum_flag = 201,
    dict_id_flag = 202,
    nb_workers = 400,
    job_size = 401,
    overlap_log = 402,
};

pub const Strategy = enum(c_int) {
    fast = 1,
    dfast = 2,
    greedy = 3,
    lazy = 4,
    lazy2 = 5,
    btlazy2 = 6,
    btopt = 7,
    btultra = 8,
    btultra2 = 9,
};

pub const ResetDirective = enum(c_int) {
    session_only = 1,
    parameters = 2,
    session_and_parameters = 3,
};

pub const Bounds = struct {
    lower_bound: i32,
    upper_bound: i32,
};

pub fn cParamGetBounds(param: CParameter) ZstdError!Bounds {
    return switch (param) {
        .compression_level => .{ .lower_bound = ver.clevel_min, .upper_bound = ver.clevel_max },
        .window_log => .{ .lower_bound = 0, .upper_bound = 31 - (if (@sizeOf(usize) == 4) @as(i32, 0) else 27) },
        .hash_log => .{ .lower_bound = 0, .upper_bound = 31 },
        .chain_log => .{ .lower_bound = 0, .upper_bound = 31 - (if (@sizeOf(usize) == 4) @as(i32, 0) else 27) },
        .search_log => .{ .lower_bound = 0, .upper_bound = 31 },
        .min_match => .{ .lower_bound = 3, .upper_bound = 7 },
        .target_length => .{ .lower_bound = 0, .upper_bound = 128 * 1024 },
        .strategy => .{ .lower_bound = 1, .upper_bound = 9 },
        else => .{ .lower_bound = 0, .upper_bound = 0 },
    };
}

pub fn compressBound(src_size: usize) ZstdError!usize {
    if (src_size >= constants.max_input_size) return error.SrcSizeWrong;
    return src_size + (src_size >> 8) + (if (src_size < (128 << 10)) @as(usize, @intCast((128 << 10) - @min(src_size, 128 << 10))) >> 11 else 0) + 13;
}

pub const Compressor = struct {
    level: i32,
    checksum: bool,
    dict_id: u32,
    use_dict_id: bool,
    pledged_src_size: ?u64,

    pub fn init(opts: CompressOptions) Compressor {
        return .{
            .level = opts.level.toInt(),
            .checksum = opts.checksum,
            .dict_id = opts.dict_id,
            .use_dict_id = opts.use_dict_id,
            .pledged_src_size = null,
        };
    }

    pub fn deinit(self: *Compressor) void {
        self.* = undefined;
    }

    pub fn setParameter(self: *Compressor, param: CParameter, value: i32) ZstdError!void {
        switch (param) {
            .compression_level => self.level = value,
            .content_size_flag => {},
            .checksum_flag => self.checksum = value != 0,
            .dict_id_flag => self.use_dict_id = value != 0,
            else => {},
        }
    }

    pub fn setPledgedSrcSize(self: *Compressor, src_size: u64) ZstdError!void {
        self.pledged_src_size = src_size;
    }

    pub fn reset(self: *Compressor, directive: ResetDirective) ZstdError!void {
        switch (directive) {
            .session_only => {},
            .parameters, .session_and_parameters => {
                self.level = ver.clevel_default;
                self.checksum = false;
                self.dict_id = 0;
                self.use_dict_id = false;
                self.pledged_src_size = null;
            },
        }
    }

    pub fn compress2(self: *Compressor, dst: []u8, src: []const u8) ZstdError!usize {
        const content_size = self.pledged_src_size orelse src.len;
        var pos: usize = 0;

        pos += writeFrameHeader(dst[pos..], content_size, self.checksum);

        if (src.len == 0) {
            pos += writeRawBlock(dst[pos..], &.{}, true);
        } else {
            const max_block_size: usize = constants.block_size_max;
            var src_offset: usize = 0;

            while (src_offset < src.len) {
                const remaining = src.len - src_offset;
                const block_size = @min(remaining, max_block_size);
                const is_last = (src_offset + block_size >= src.len);
                const block_data = src[src_offset..][0..block_size];

                if (block_size <= 128) {
                    pos += writeRawBlock(dst[pos..], block_data, is_last);
                } else {
                    const compressed = compressBlock(block_data, self.level);
                    if (compressed.len < block_data.len) {
                        pos += writeRawBlock(dst[pos..], compressed, is_last);
                    } else {
                        pos += writeRawBlock(dst[pos..], block_data, is_last);
                    }
                }

                src_offset += block_size;
            }
        }

        if (self.checksum) {
            const xxh = xxh64Hash(src);
            std.mem.writeInt(u32, dst[pos..][0..4], @truncate(xxh), .little);
            pos += 4;
        }

        return pos;
    }

    pub fn compressAlloc(self: *Compressor, allocator: std.mem.Allocator, src: []const u8) ZstdError![]u8 {
        const bound = try compressBound(src.len);
        const dst = try allocator.alloc(u8, bound);
        errdefer allocator.free(dst);

        const written = try self.compress2(dst, src);
        return if (written < dst.len) (allocator.realloc(dst, written) catch dst) else dst;
    }

    pub fn sizeof(self: *const Compressor) usize {
        _ = self;
        return @sizeOf(Compressor);
    }
};

pub fn compress(allocator: std.mem.Allocator, src: []const u8, opts: CompressOptions) ZstdError![]u8 {
    var cctx = Compressor.init(opts);
    return cctx.compressAlloc(allocator, src);
}

pub fn compressSlice(dst: []u8, src: []const u8) usize {
    var pos: usize = 0;
    pos += writeFrameHeader(dst[pos..], src.len, false);
    if (src.len == 0) {
        pos += writeRawBlock(dst[pos..], &.{}, true);
    } else {
        pos += writeRawBlock(dst[pos..], src, true);
    }
    return pos;
}

fn writeFrameHeader(dst: []u8, content_size: u64, checksum: bool) usize {
    var pos: usize = 0;

    dst[pos] = @intCast(constants.magic_number & 0xFF);
    dst[pos + 1] = @intCast((constants.magic_number >> 8) & 0xFF);
    dst[pos + 2] = @intCast((constants.magic_number >> 16) & 0xFF);
    dst[pos + 3] = @intCast((constants.magic_number >> 24) & 0xFF);
    pos += 4;

    const fcs_flag: u8 = 3;
    const checksum_bit: u8 = if (checksum) @as(u8, 1) else @as(u8, 0);
    const descriptor: u8 = (fcs_flag & 0x3) | (checksum_bit << 2) | (1 << 6);
    dst[pos] = descriptor;
    pos += 1;

    std.mem.writeInt(u64, dst[pos..][0..8], content_size, .little);
    pos += 8;

    return pos;
}

fn writeRawBlock(dst: []u8, src: []const u8, is_last: bool) usize {
    var pos: usize = 0;
    const block_size: u32 = @intCast(src.len);
    const block_size_m1 = block_size -% 1;
    const last: u32 = if (is_last) @as(u32, 1) else @as(u32, 0);
    const header_val: u32 = (block_size_m1 << 3) | (@as(u32, block_type_raw) << 1) | last;

    dst[pos] = @intCast(header_val & 0xFF);
    dst[pos + 1] = @intCast((header_val >> 8) & 0xFF);
    dst[pos + 2] = @intCast((header_val >> 16) & 0xFF);
    pos += 3;

    if (src.len > 0) {
        @memcpy(dst[pos..][0..src.len], src);
        pos += src.len;
    }

    return pos;
}

fn writeCompressedBlockHeader(dst: []u8, block_size: u32, is_last: bool) usize {
    const block_size_m1 = block_size -% 1;
    const last: u32 = if (is_last) @as(u32, 1) else @as(u32, 0);
    const header_val: u32 = (block_size_m1 << 3) | (@as(u32, block_type_compressed) << 1) | last;

    dst[0] = @intCast(header_val & 0xFF);
    dst[1] = @intCast((header_val >> 8) & 0xFF);
    dst[2] = @intCast((header_val >> 16) & 0xFF);
    return 3;
}

const block_type_raw: u2 = 0;
const block_type_rle: u2 = 1;
const block_type_compressed: u2 = 2;

const max_match_len: usize = 128 + 5;
const min_match_len: usize = 3;
const max_literals_run: usize = 128;

fn compressBlock(src: []const u8, level: i32) []const u8 {
    _ = level;
    return src;
}

fn xxh64Hash(data: []const u8) u64 {
    var state: u64 = XXH_PRIME5;
    var i: usize = 0;

    while (i + 8 <= data.len) : (i += 8) {
        const lane = std.mem.readInt(u64, data[i..][0..8], .little);
        state +%= lane *% XXH_PRIME2;
        state = std.math.rotl(u64, state, 31);
        state *%= XXH_PRIME1;
    }

    while (i < data.len) : (i += 1) {
        state +%= @as(u64, data[i]) *% XXH_PRIME5;
        state = std.math.rotl(u64, state, 27);
        state *%= XXH_PRIME4;
    }

    state = state ^ (state >> 33);
    state *%= XXH_PRIME2;
    state = state ^ (state >> 29);
    state *%= XXH_PRIME3;
    state = state ^ (state >> 32);

    return state;
}

const XXH_PRIME1: u64 = 0x9E3779B185EBCA87;
const XXH_PRIME2: u64 = 0xC2B2AE3D27D4EB4F;
const XXH_PRIME3: u64 = 0x165667B19E3779F9;
const XXH_PRIME4: u64 = 0x85EBCA77C2B2AE63;
const XXH_PRIME5: u64 = 0x27D4EB2F165667C5;

test "compressBound" {
    const bound = try compressBound(1024);
    try std.testing.expect(bound >= 1024);
}

test "compress round trip" {
    const allocator = std.testing.allocator;
    const original = "Hello, native Zig zstd! This is a test of the compression library.";

    const compressed = try compress(allocator, original, .{});
    defer allocator.free(compressed);

    try std.testing.expect(compressed.len > 0);

    const decompress_mod = @import("decompress.zig");
    const decompressed = try decompress_mod.decompress(allocator, compressed, .{});
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(original, decompressed);
}

test "compressor lifecycle" {
    var c = Compressor.init(.{});
    defer c.deinit();

    try c.setParameter(.compression_level, 5);
    try std.testing.expectEqual(@as(i32, 5), c.level);

    try c.setParameter(.checksum_flag, 1);
    try std.testing.expect(c.checksum);

    try c.reset(.session_and_parameters);
    try std.testing.expectEqual(ver.clevel_default, c.level);
    try std.testing.expect(!c.checksum);
}

test "CLevel enum" {
    try std.testing.expectEqual(@as(i32, 1), CLevel.fastest.toInt());
    try std.testing.expectEqual(@as(i32, 3), CLevel.default.toInt());
    try std.testing.expectEqual(@as(i32, 19), CLevel.best.toInt());
    try std.testing.expectEqual(CLevel.default, CLevel.fromInt(3));
}

test "CompressOptions defaults" {
    const opts = CompressOptions{};
    try std.testing.expectEqual(CLevel.default, opts.level);
    try std.testing.expect(!opts.checksum);
    try std.testing.expectEqual(@as(u32, 0), opts.dict_id);
}
