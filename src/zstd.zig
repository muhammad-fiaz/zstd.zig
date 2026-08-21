pub const version = "1.6.0";
pub const version_number: u32 = 1 * 100 * 100 + 6 * 100 + 0;

const std = @import("std");
const comp = @import("compress/compress.zig");
const decomp = @import("decompress/decompress.zig");
const hdr = @import("frame/header.zig");
const det = @import("frame/detect.zig");
const dictionary = @import("dictionary/dictionary.zig");
const bld = @import("dictionary/builder.zig");
const streamComp = @import("streaming/compress.zig");
const streamDecomp = @import("streaming/decompress.zig");
const cctx = @import("compress/context.zig");
const dctx = @import("decompress/context.zig");
const constants = @import("common/constants.zig");
const errors = @import("common/errors.zig");
const types = @import("common/types.zig");
pub const legacy = @import("legacy/decoder.zig");
pub const legacy_detect = @import("legacy/detect.zig");

pub const CompressionOptions = comp.CompressionOptions;
pub const DecompressionOptions = dctx.DecompressionOptions;
pub const CompressionContext = cctx.CompressionContext;
pub const DecompressionContext = dctx.DecompressionContext;
pub const Dictionary = dictionary.Dictionary;
pub const DictionaryBuilder = bld.DictionaryBuilder;
pub const DictBuilderParams = bld.DictBuilderParams;
pub const StreamingCompressor = streamComp.StreamingCompressor;
pub const StreamingDecompressor = streamDecomp.StreamingDecompressor;
pub const CStream = streamComp.CStream;
pub const DStream = streamDecomp.DStream;
pub const EndDirective = streamComp.EndDirective;
pub const FrameHeader = types.FrameHeader;
pub const BlockType = types.BlockType;
pub const BlockProperties = types.BlockProperties;
pub const ZstdError = errors.ZstdError;
pub const Strategy = constants.Strategy;
pub const FrameOptions = struct { checksum: bool = false, content_size: ?u64 = null, dict_id: u32 = 0, window_log: u8 = 0 };

pub const MAGICNUMBER = constants.magic_number;
pub const MAGIC_DICTIONARY = constants.magic_dictionary;
pub const MAGIC_SKIPPABLE_START = constants.magic_skippable_start;
pub const MAGIC_SKIPPABLE_MASK = constants.magic_skippable_mask;
pub const BLOCKSIZE_MAX = constants.block_size_max;
pub const CONTENTSIZE_UNKNOWN = constants.contentsize_unknown;
pub const CONTENTSIZE_ERROR = constants.contentsize_error;
pub const CLEVEL_DEFAULT = constants.c_level_default;
pub const MAX_INPUT_SIZE = constants.max_input_size;

pub const compressBound = comp.compressBound;
pub const getCompressionParameters = comp.getCompressionParameters;
pub const loadDictionary = dictionary.loadDictionary;
pub const createDictionaryFromData = dictionary.createDictionaryFromData;

pub fn compress(allocator: std.mem.Allocator, src: []const u8) anyerror![]u8 {
    return comp.compress(allocator, src, .{});
}

pub fn decompress(allocator: std.mem.Allocator, src: []const u8) anyerror![]u8 {
    return decomp.decompress(allocator, src);
}

pub fn compressWithLevel(allocator: std.mem.Allocator, src: []const u8, level: i32) anyerror![]u8 {
    const opts = comp.getCompressionParameters(level, src.len, 0);
    return comp.compress(allocator, src, opts);
}

pub fn compressWithOptions(allocator: std.mem.Allocator, src: []const u8, options: CompressionOptions) anyerror![]u8 {
    return comp.compress(allocator, src, options);
}

pub fn compressInto(dst: []u8, src: []const u8, level: i32) ZstdError!usize {
    const opts = comp.getCompressionParameters(level, src.len, 0);
    return comp.compressInto(dst, src, opts);
}

pub fn decompressInto(dst: []u8, src: []const u8) ZstdError!usize {
    return decomp.decompressInto(dst, src);
}

pub fn decompressBound(src: []const u8) ZstdError!usize {
    return decomp.decompressBound(src);
}

pub fn findFrameCompressedSize(src: []const u8) ZstdError!usize {
    return decomp.findFrameCompressedSize(src);
}

pub fn getFrameContentSize(src: []const u8) u64 {
    if (src.len < 4) return CONTENTSIZE_ERROR;
    const fh = hdr.getFrameHeader(src) catch return CONTENTSIZE_ERROR;
    if (fh.frame_type == .skippable) return 0;
    return fh.content_size;
}

pub fn getFrameHeader(src: []const u8) ZstdError!FrameHeader {
    return hdr.getFrameHeader(src);
}

pub fn isFrame(src: []const u8) bool {
    return det.detectFrame(src) != .unknown;
}

pub fn isSkippableFrame(src: []const u8) bool {
    return hdr.isSkippableFrame(src);
}

pub fn writeSkippableFrame(dst: []u8, data: []const u8, magic_variant: u32) usize {
    if (dst.len < 8 + data.len) return 0;
    const magic = MAGIC_SKIPPABLE_START + (magic_variant & 0xF);
    dst[0] = @truncate(magic);
    dst[1] = @truncate(magic >> 8);
    dst[2] = @truncate(magic >> 16);
    dst[3] = @truncate(magic >> 24);
    const size: u32 = @intCast(data.len);
    dst[4] = @truncate(size);
    dst[5] = @truncate(size >> 8);
    dst[6] = @truncate(size >> 16);
    dst[7] = @truncate(size >> 24);
    @memcpy(dst[8 .. 8 + data.len], data);
    return 8 + data.len;
}

pub fn readSkippableFrame(dst: []u8, src: []const u8) ZstdError!usize {
    if (src.len < 8) return error.SrcSizeWrong;
    if (!isSkippableFrame(src)) return error.PrefixUnknown;
    const size: u32 = @as(u32, src[4]) | (@as(u32, src[5]) << 8) | (@as(u32, src[6]) << 16) | (@as(u32, src[7]) << 24);
    if (src.len < 8 + size) return error.SrcSizeWrong;
    if (dst.len < size) return error.DstSizeTooSmall;
    @memcpy(dst[0..size], src[8 .. 8 + size]);
    return size;
}

pub fn versionString() []const u8 {
    return version;
}

pub fn versionNumber() u32 {
    return version_number;
}

pub fn maxCLevel() i32 {
    return constants.c_level_max;
}

pub fn minCLevel() i32 {
    return constants.c_level_min;
}

pub fn defaultCLevel() i32 {
    return constants.c_level_default;
}
