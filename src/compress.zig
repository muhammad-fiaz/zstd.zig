const std = @import("std");
const errors = @import("errors.zig");
const constants = @import("constants.zig");
const ver = @import("version.zig");
const xxh64 = @import("xxh64.zig");

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
        .window_log => .{ .lower_bound = 0, .upper_bound = if (@sizeOf(usize) == 4) 27 else 31 },
        .hash_log => .{ .lower_bound = 0, .upper_bound = 31 },
        .chain_log => .{ .lower_bound = 0, .upper_bound = if (@sizeOf(usize) == 4) 27 else 31 },
        .search_log => .{ .lower_bound = 0, .upper_bound = 31 },
        .min_match => .{ .lower_bound = 3, .upper_bound = 7 },
        .target_length => .{ .lower_bound = 0, .upper_bound = 128 * 1024 },
        .strategy => .{ .lower_bound = 1, .upper_bound = 9 },
        else => .{ .lower_bound = 0, .upper_bound = 0 },
    };
}

pub fn compressBound(src_size: usize) ZstdError!usize {
    if (src_size >= constants.max_input_size) return error.SrcSizeWrong;
    const overhead: usize = if (src_size < (128 << 10))
        (128 << 10) - @min(src_size, 128 << 10)
    else
        0;
    return src_size + (src_size >> 8) + (overhead >> 11) + 13;
}

const block_type_raw: u2 = 0;
const block_type_rle: u2 = 1;
const block_type_compressed: u2 = 2;

pub const Compressor = struct {
    level: i32,
    checksum: bool,
    dict_id: u32,
    use_dict_id: bool,
    pledged_src_size: ?u64,
    window_log: u32,
    hash_log: u32,
    chain_log: u32,
    strategy: Strategy,

    pub fn init(opts: CompressOptions) Compressor {
        const level = opts.level.toInt();
        const window_log: u32 = if (opts.window_log) |wl| wl else blk: {
            const wl_val: i32 = 18 + @divTrunc(level - 3, 6);
            break :blk @intCast(@max(1, @min(27, wl_val)));
        };
        const hash_log: u32 = @intCast(@max(4, @min(17, @as(i32, @intCast(window_log)) + 1)));
        const chain_log: u32 = @intCast(@max(4, @min(27, @as(i32, @intCast(window_log)))));

        const strat: Strategy = opts.strategy orelse switch (level) {
            1 => .fast,
            2, 3, 4 => .dfast,
            5, 6, 7 => .greedy,
            8, 9, 10 => .lazy,
            11, 12, 13 => .lazy2,
            14, 15, 16 => .btlazy2,
            17, 18, 19 => .btopt,
            20, 21, 22 => .btultra,
            else => .fast,
        };

        return .{
            .level = level,
            .checksum = opts.checksum,
            .dict_id = opts.dict_id,
            .use_dict_id = opts.use_dict_id,
            .pledged_src_size = null,
            .window_log = window_log,
            .hash_log = hash_log,
            .chain_log = chain_log,
            .strategy = strat,
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
            .window_log => {
                if (value < 0 or value > 31) return error.ParameterOutOfBound;
                self.window_log = @intCast(value);
            },
            .hash_log => {
                if (value < 0 or value > 31) return error.ParameterOutOfBound;
                self.hash_log = @intCast(value);
            },
            .chain_log => {
                if (value < 0 or value > 31) return error.ParameterOutOfBound;
                self.chain_log = @intCast(value);
            },
            .strategy => {
                if (value < 1 or value > 9) return error.ParameterOutOfBound;
                self.strategy = @enumFromInt(@as(c_int, @intCast(value)));
            },
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
                self.window_log = 18;
                self.hash_log = 19;
                self.chain_log = 18;
                self.strategy = .greedy;
            },
        }
    }

    pub fn compress2(self: *Compressor, dst: []u8, src: []const u8) ZstdError!usize {
        const content_size = self.pledged_src_size orelse src.len;
        var pos: usize = 0;

        pos += writeFrameHeader(dst[pos..], content_size, self.checksum, self.window_log, self.use_dict_id, self.dict_id);

        if (src.len == 0) {
            if (self.checksum) {
                const xxh = xxh64.hash(src);
                std.mem.writeInt(u32, dst[pos..][0..4], @truncate(xxh), .little);
                pos += 4;
            }
            return pos;
        }

        const max_block: usize = constants.block_size_max;
        var src_offset: usize = 0;
        while (src_offset < src.len) {
            const remaining = src.len - src_offset;
            const block_size = @min(remaining, max_block);
            const is_last = (src_offset + block_size >= src.len);
            const block_data = src[src_offset..][0..block_size];

            // Reference lib/compress/zstd_compress.c: try RLE first (cheapest), then raw vs compressed.
            // RLE detection per lib/compress/zstd_compress_literals.c:allBytesIdentical
            if (block_data.len > 0 and isRLE(block_data)) {
                const rle_block_size: u32 = 1; // payload is 1 byte, header stores decompressed size
                // For RLE block, block header's size field is decompressed size, payload is 1 byte (the value)
                // Per lib/compress/zstd_compress_internal.h:ZSTD_rleCompressBlock
                pos += writeBlockHeader(dst[pos..], @intCast(block_data.len), block_type_rle, is_last);
                dst[pos] = block_data[0];
                pos += 1;
                // Note: we encode decompressed size in header, not compressed size (1)
                // Our writeBlockHeader currently writes passed size directly; for RLE we passed decompressed size, payload 1.
                // That's spec compliant: header>>3 gives decompressed size.
                _ = rle_block_size;
            } else {
                // For now, emit raw blocks (bt_raw) per lib/compress/zstd_compress_internal.h:ZSTD_noCompressBlock
                // Future: try LZ77 via hash chain (lib/compress/zstd_fast.c) and emit bt_compressed with spec literals+seq.
                // Minimal spec compressed block would be literals raw + nbSeq 0 (1 byte), but raw is always smaller, so we keep raw.
                // The infrastructure for compressed blocks is below (writeCompressedBlockSpec) and will be enabled when matches found.
                const use_compressed = false; // TODO: enable when hash chain finds matches with gain > ZSTD_minGain
                if (use_compressed) {
                    const csize = writeCompressedBlockSpec(dst[pos + 3 ..], block_data);
                    if (csize < block_data.len) {
                        pos += writeBlockHeader(dst[pos..], @intCast(csize), block_type_compressed, is_last);
                        pos += csize;
                    } else {
                        pos += writeBlockHeader(dst[pos..], @intCast(block_size), block_type_raw, is_last);
                        @memcpy(dst[pos..][0..block_size], block_data);
                        pos += block_size;
                    }
                } else {
                    pos += writeBlockHeader(dst[pos..], @intCast(block_size), block_type_raw, is_last);
                    @memcpy(dst[pos..][0..block_size], block_data);
                    pos += block_size;
                }
            }

            src_offset += block_size;
        }

        if (self.checksum) {
            const xxh = xxh64.hash(src);
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

fn writeFrameHeader(dst: []u8, content_size: u64, checksum: bool, window_log: u32, use_dict_id: bool, dict_id: u32) usize {
    var pos: usize = 0;

    dst[pos] = @intCast(constants.magic_number & 0xFF);
    dst[pos + 1] = @intCast((constants.magic_number >> 8) & 0xFF);
    dst[pos + 2] = @intCast((constants.magic_number >> 16) & 0xFF);
    dst[pos + 3] = @intCast((constants.magic_number >> 24) & 0xFF);
    pos += 4;

    const fcs_flag: u8 = if (content_size == 0) 0 else if (content_size <= 0xFF) 1 else if (content_size <= 0xFFFF) 2 else 3;
    const checksum_bit: u8 = if (checksum) @as(u8, 1) else @as(u8, 0);
    const dict_id_flag: u8 = if (use_dict_id) @as(u8, 1) else @as(u8, 0);
    const single_segment: u8 = if (!use_dict_id) @as(u8, 1) else @as(u8, 0);
    const descriptor: u8 = (fcs_flag & 0x3) | (checksum_bit << 2) | (dict_id_flag << 3) | (single_segment << 6);
    dst[pos] = descriptor;
    pos += 1;

    if (single_segment == 0) {
        const window_desc: u8 = encodeWindowDescriptor(window_log);
        dst[pos] = window_desc;
        pos += 1;
    }

    if (use_dict_id) {
        std.mem.writeInt(u32, dst[pos..][0..4], dict_id, .little);
        pos += 4;
    }

    switch (fcs_flag) {
        1 => {
            dst[pos] = @intCast(content_size);
            pos += 1;
        },
        2 => {
            std.mem.writeInt(u16, dst[pos..][0..2], @truncate(content_size), .little);
            pos += 2;
        },
        3 => {
            std.mem.writeInt(u64, dst[pos..][0..8], content_size, .little);
            pos += 8;
        },
        else => {},
    }

    return pos;
}

fn isRLE(src: []const u8) bool {
    if (src.len == 0) return false;
    const first = src[0];
    for (src[1..]) |b| if (b != first) return false;
    return true;
}

// lib/compress/zstd_compress_literals.c:ZSTD_noCompressLiterals – raw literals header per spec
// Encoding: flSize = 1 + (srcSize>31) + (srcSize>4095)
//   flSize 1: byte0 = set_basic (0) | (size<<3)   ; 5 bits size
//   flSize 2: LE16 = set_basic | (1<<2) | (size<<4) ; 12 bits
//   flSize 3: LE32 = set_basic | (3<<2) | (size<<4) ; 20 bits
fn writeLiteralsRawSpec(dst: []u8, src: []const u8) usize {
    const srcSize = src.len;
    const flSize: usize = 1 + @as(usize, if (srcSize > 31) 1 else 0) + @as(usize, if (srcSize > 4095) 1 else 0);
    switch (flSize) {
        1 => {
            dst[0] = @intCast((@as(u32, 0) + (@as(u32, @intCast(srcSize)) << 3)) & 0xFF);
        },
        2 => {
            const v: u16 = @intCast(@as(u32, 0) + (1 << 2) + (@as(u32, @intCast(srcSize)) << 4));
            std.mem.writeInt(u16, dst[0..2], v, .little);
        },
        3 => {
            const v: u32 = @as(u32, 0) + (3 << 2) + (@as(u32, @intCast(srcSize)) << 4);
            std.mem.writeInt(u32, dst[0..4], v, .little);
        },
        else => unreachable,
    }
    @memcpy(dst[flSize..][0..srcSize], src);
    return flSize + srcSize;
}

// Minimal spec-compliant compressed block: raw literals + nbSeq=0
// See lib/decompress/zstd_decompress_block.c:ZSTD_decodeLiteralsBlock (set_basic path) + ZSTD_decodeSeqHeaders (nbSeq==0)
// This produces a valid bt_compressed block that is decompressible by both Zig and C reference.
fn writeCompressedBlockSpec(dst: []u8, src: []const u8) usize {
    var pos: usize = 0;
    pos += writeLiteralsRawSpec(dst[pos..], src);
    // Sequences section header: nbSeq = 0 => single byte 0x00 per lib/decompress/zstd_decompress_block.c:707
    dst[pos] = 0;
    pos += 1;
    return pos;
}

// Hash functions mirroring lib/compress/zstd_compress_internal.h:ZSTD_hash4Ptr / ZSTD_hash5Ptr
// Used for LZ77 match finding (lib/compress/zstd_fast.c, zstd_lazy.c). Prime constants from lib.
const prime4bytes: u32 = 2654435761;
const prime3bytes: u32 = 506832829;

fn hash4(val: u32, hashLog: u32) u32 {
    return (val *% prime4bytes) >> @intCast(32 - hashLog);
}

fn hash3(val: u32, hashLog: u32) u32 {
    return (((val << @intCast(32 - 24)) *% prime3bytes) >> @intCast(32 - hashLog));
}

fn hash4Ptr(p: []const u8, hashLog: u32) u32 {
    if (p.len < 4) return 0;
    const v = std.mem.readInt(u32, p[0..4], .little);
    return hash4(v, hashLog);
}

fn encodeWindowDescriptor(window_log: u32) u8 {
    const wl = @min(window_log, 27);
    if (wl <= 10) return 0;
    return @intCast(wl - 10);
}

fn writeBlockHeader(dst: []u8, block_size: u32, block_type: u2, is_last: bool) usize {
    const last: u32 = if (is_last) @as(u32, 1) else @as(u32, 0);
    const header_val: u32 = (@as(u32, block_size) << 3) | (@as(u32, block_type) << 1) | last;

    dst[0] = @intCast(header_val & 0xFF);
    dst[1] = @intCast((header_val >> 8) & 0xFF);
    dst[2] = @intCast((header_val >> 16) & 0xFF);
    return 3;
}

test "compressBound" {
    const bound = try compressBound(1024);
    try std.testing.expect(bound >= 1024);
}

test "compress round trip" {
    const allocator = std.testing.allocator;
    const original = "Hello, native Zig zstd! This is a test of the compression library with enough data for compression.";

    const compressed = try compress(allocator, original, .{});
    defer allocator.free(compressed);

    try std.testing.expect(compressed.len > 0);

    const decompress_mod = @import("decompress.zig");
    const decompressed = try decompress_mod.decompress(allocator, compressed, .{});
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(original, decompressed);
}

test "compress empty" {
    const allocator = std.testing.allocator;
    const original = "";

    const compressed = try compress(allocator, original, .{});
    defer allocator.free(compressed);

    try std.testing.expect(compressed.len > 0);

    const decompress_mod = @import("decompress.zig");
    const decompressed = try decompress_mod.decompress(allocator, compressed, .{});
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(original, decompressed);
}

test "compress with checksum" {
    const allocator = std.testing.allocator;
    const original = "Test data with checksum enabled for verification purposes.";

    const compressed = try compress(allocator, original, .{ .checksum = true });
    defer allocator.free(compressed);

    const decompress_mod = @import("decompress.zig");
    const decompressed = try decompress_mod.decompress(allocator, compressed, .{});
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(original, decompressed);
}

test "compress large data" {
    const allocator = std.testing.allocator;

    var original: [1024]u8 = undefined;
    for (&original, 0..) |*ch, i| {
        ch.* = @truncate(i % 256);
    }

    const compressed = try compress(allocator, &original, .{});
    defer allocator.free(compressed);

    try std.testing.expect(compressed.len > 0);

    const decompress_mod = @import("decompress.zig");
    const decompressed = try decompress_mod.decompress(allocator, compressed, .{});
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(&original, decompressed);
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

test "cParamGetBounds" {
    const bounds = try cParamGetBounds(.compression_level);
    try std.testing.expect(bounds.lower_bound < bounds.upper_bound);
}

test "rle block round trip" {
    const allocator = std.testing.allocator;
    var data: [256]u8 = undefined;
    @memset(&data, 'X');
    const comp = try compress(allocator, &data, .{});
    defer allocator.free(comp);
    // RLE should be highly compressible (< 20 bytes header+1 payload+frame)
    try std.testing.expect(comp.len < data.len);
    const decomp = try @import("decompress.zig").decompress(allocator, comp, .{});
    defer allocator.free(decomp);
    try std.testing.expectEqualSlices(u8, &data, decomp);
}

test "spec literals raw compress" {
    // Small block that will go via spec literals raw + nbSeq0 path when emitting compressed
    const data = "hello world spec test";
    var buf: [1024]u8 = undefined;
    const n = writeLiteralsRawSpec(&buf, data);
    try std.testing.expect(n == 1 + data.len or n == 2 + data.len or n == 3 + data.len);
}
