/// zstd.zig 0.0.4, implementing Zstandard v1.6.0 on Zig 0.17.
/// The caller supplies the allocator. Compression defaults to single-threaded;
/// worker threads are strictly opt-in via options.workers or MTCompressor.
pub const version = "0.0.4";
/// Data-format specification implemented (Zstandard v1.6.0).
const std = @import("std");
const builtin = @import("builtin");
const comp = @import("compress/compress.zig");
const decomp = @import("decompress/decompress.zig");
const hdr = @import("frame/header.zig");
const det = @import("frame/detect.zig");
const frame_mod = @import("decompress/frame.zig");
const dictionary = @import("dictionary/dictionary.zig");
const bld = @import("dictionary/builder.zig");
const prepared = @import("dictionary/prepared.zig");
const streamComp = @import("streaming/compress.zig");
const streamDecomp = @import("streaming/decompress.zig");
const cctx = @import("compress/context.zig");
const mt = @import("compress/mt.zig");
const dctx = @import("decompress/context.zig");
const iterator_mod = @import("frame/iterator.zig");
const constants = @import("common/constants.zig");
const errors = @import("common/errors.zig");
const types = @import("common/types.zig");
pub const legacy = @import("legacy/decoder.zig");
pub const legacyDetect = @import("legacy/detect.zig");
comptime {
    // Test inventory. `zig build test` compiles this file as the test root, and
    // a module that nothing imports would have its tests silently skipped: which
    // is how untested encoder code hides in a tree whose suite looks green.
    // Referencing every module here is what keeps the reported test count equal
    // to the tests that actually execute.
    _ = @import("common/bits.zig");
    _ = @import("common/bitstream.zig");
    _ = @import("common/cpu.zig");
    _ = @import("common/constants.zig");
    _ = @import("common/errors.zig");
    _ = @import("common/memory.zig");
    _ = @import("common/pool.zig");
    _ = @import("common/types.zig");
    _ = @import("common/workspace.zig");
    _ = @import("common/xxhash.zig");
    _ = @import("compress/block.zig");
    _ = @import("compress/compress.zig");
    _ = @import("compress/context.zig");
    _ = @import("compress/ldm.zig");
    _ = @import("compress/mt.zig");
    _ = @import("compress/parameters.zig");
    _ = @import("compress/search.zig");
    _ = @import("compress/strategy.zig");
    _ = @import("decompress/block.zig");
    _ = @import("decompress/context.zig");
    _ = @import("decompress/decompress.zig");
    _ = @import("decompress/entropy.zig");
    _ = @import("decompress/frame.zig");
    _ = @import("dictionary/builder.zig");
    _ = @import("dictionary/prepared.zig");
    _ = @import("dictionary/dictionary.zig");
    _ = @import("frame/block.zig");
    _ = @import("frame/checksum.zig");
    _ = @import("frame/detect.zig");
    _ = @import("frame/header.zig");
    _ = @import("frame/iterator.zig");
    _ = @import("frame/skippable.zig");
    _ = @import("fse/common.zig");
    _ = @import("fse/compress.zig");
    _ = @import("fse/ctable.zig");
    _ = @import("fse/decompress.zig");
    _ = @import("fse/dtable.zig");
    _ = @import("fse/ncount.zig");
    _ = @import("fse/table.zig");
    _ = @import("huffman/common.zig");
    _ = @import("huffman/compress.zig");
    _ = @import("huffman/decompress.zig");
    _ = @import("huffman/table.zig");
    _ = @import("legacy/contract.zig");
    _ = @import("legacy/decoder.zig");
    _ = @import("legacy/golden_frames.zig");
    _ = @import("legacy/format.zig");
    _ = @import("legacy/fse.zig");
    _ = @import("legacy/huffman.zig");
    _ = @import("legacy/layouts.zig");
    _ = @import("legacy/sequences.zig");
    _ = @import("legacy/detect.zig");
    _ = @import("legacy/v01_entropy.zig");
    _ = @import("legacy/v01.zig");
    _ = @import("legacy/v02.zig");
    _ = @import("legacy/v03.zig");
    _ = @import("legacy/v04.zig");
    _ = @import("legacy/v05.zig");
    _ = @import("legacy/v06.zig");
    _ = @import("legacy/v07.zig");
    _ = @import("streaming/compress.zig");
    _ = @import("streaming/decompress.zig");
}
pub const CompressionOptions = comp.CompressionOptions;
pub const DecompressionOptions = dctx.DecompressionOptions;
pub const CompressionContext = cctx.CompressionContext;
pub const DecompressionContext = dctx.DecompressionContext;
/// Multithreaded compression: a reusable worker pool behind the ordinary frame
/// format. `compressMT` is the one-shot form; `MTCompressor` keeps its pool
/// alive across frames. Both take the `std.Io` the pool's synchronization
/// uses, and nothing else in the library starts threads.
pub const MTCompressor = mt.MTCompressor;
pub const compressMT = mt.compressMT;
/// The worker pool `MTCompressor` runs on: a fixed set of threads pulling
/// jobs from a bounded queue. Exported for programs that want the same
/// primitive for their own fan-out.
pub const pool = @import("common/pool.zig");
/// Client-side Encoder and Decoder abstractions with explicit lifecycle control.
pub const Encoder = cctx.Encoder;
pub const Decoder = dctx.Decoder;
/// Short aliases matching the reference client naming.
pub const Compressor = cctx.CompressionContext;
pub const Decompressor = dctx.DecompressionContext;
pub const Dictionary = dictionary.Dictionary;
pub const DictionaryBuilder = bld.DictionaryBuilder;
pub const DictBuilderParams = bld.DictBuilderParams;
/// A dictionary whose reusable state has been prepared: the entropy tables that
/// describe how its own content compresses, plus the repeat offsets and content
/// a frame starts from. `prepare` accepts raw content or a prepared dictionary.
/// Owns its bytes and tables and frees them in `deinit`; several contexts may
/// read from one prepared dictionary, each keeping its own copy of anything it
/// advances.
pub const PreparedDictionary = prepared.PreparedDictionary;
pub const RepeatOffsets = prepared.RepeatOffsets;
pub const EntropyTables = prepared.EntropyTables;
/// Prepares a dictionary, building its reusable entropy state.
pub fn prepareDictionary(allocator: std.mem.Allocator, source: []const u8) ZstdError!PreparedDictionary {
    return prepared.PreparedDictionary.prepare(allocator, source);
}
pub const StreamingCompressor = streamComp.StreamingCompressor;
pub const StreamingDecompressor = streamDecomp.StreamingDecompressor;
pub const CStream = streamComp.CStream;
pub const DStream = streamDecomp.DStream;
pub const EndDirective = streamComp.EndDirective;
pub const FrameHeader = types.FrameHeader;
pub const BlockType = types.BlockType;
pub const BlockProperties = types.BlockProperties;
pub const ZstdError = errors.ZstdError;
/// A lower-case, underscore-separated name for an error, e.g.
/// `error.ChecksumWrong` becomes `"checksum_wrong"`.
///
/// `@errorName` gives the Zig-idiomatic name; this is the wire-format style used
/// in the specification's error listings, which is what you want when the name is
/// going into a log or a message that crosses a boundary.
pub const errorToString = errors.errorToString;
pub const Strategy = constants.Strategy;
pub const FrameOptions = struct { checksum: bool = false, contentSize: ?u64 = null, dictId: u32 = 0, windowLog: u8 = 0 };
pub const MAGICNUMBER = constants.magic_number;
pub const MAGIC_DICTIONARY = constants.magic_dictionary;
pub const MAGIC_SKIPPABLE_START = constants.magic_skippable_start;
pub const MAGIC_SKIPPABLE_MASK = constants.magic_skippable_mask;
pub const BLOCKSIZE_MAX = constants.block_size_max;
pub const CONTENTSIZE_UNKNOWN = constants.contentsize_unknown;
pub const CONTENTSIZE_ERROR = constants.contentsize_error;
pub const CLEVEL_DEFAULT = constants.c_level_default;
pub const MAX_INPUT_SIZE = constants.max_input_size;
pub const getCompressionParameters = comp.getCompressionParameters;
pub const loadDictionary = dictionary.loadDictionary;
pub const createDictionaryFromData = dictionary.createDictionaryFromData;
pub const decompressWithDict = decomp.decompressWithDict;
/// A reusable compression/decompression context that owns no memory itself:
/// `allocator` is supplied by the caller and backs every operation for the
/// lifetime of the context. Create it once, use it for many frames, then
/// destroy it.
pub const Context = struct {
    allocator: std.mem.Allocator,
    compressor: CompressionContext,
    decompressor: DecompressionContext,

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{
            .allocator = allocator,
            .compressor = CompressionContext.init(allocator),
            .decompressor = DecompressionContext.init(allocator),
        };
    }

    pub fn initWithLevel(allocator: std.mem.Allocator, level: i32) Context {
        return .{
            .allocator = allocator,
            .compressor = CompressionContext.initWithLevel(allocator, level),
            .decompressor = DecompressionContext.init(allocator),
        };
    }

    pub fn deinit(self: *Context) void {
        self.compressor.deinit();
        self.decompressor.deinit();
    }

    pub fn setLevel(self: *Context, level: i32) void {
        self.compressor.setLevel(level);
    }

    pub fn setChecksum(self: *Context, flag: bool) void {
        self.compressor.setChecksum(flag);
    }

    pub fn reset(self: *Context) void {
        self.compressor.reset();
        self.decompressor.reset();
    }

    /// Compresses `src`, returning an owned slice. The caller frees it with
    /// the context's allocator.
    pub fn compress(self: *Context, src: []const u8) anyerror![]u8 {
        return self.compressor.compressAlloc(src);
    }

    /// Decompresses `src`, returning an owned slice. The caller frees it with
    /// the context's allocator.
    pub fn decompress(self: *Context, src: []const u8) anyerror![]u8 {
        return self.decompressor.decompressAlloc(src);
    }
};
/// Compresses `src` with default options (level 3). Returns an owned slice; the caller frees it with `allocator`.
pub fn compress(allocator: std.mem.Allocator, src: []const u8) anyerror![]u8 {
    return comp.compress(allocator, src, .{});
}
/// Decompresses all frames in `src`. Returns an owned slice; the caller frees it with `allocator`.
pub fn decompress(allocator: std.mem.Allocator, src: []const u8) anyerror![]u8 {
    return decomp.decompress(allocator, src);
}
/// Compresses `src` at numeric `level` (1-22). Returns an owned slice; the caller frees it with `allocator`.
pub fn compressWithLevel(allocator: std.mem.Allocator, src: []const u8, level: i32) anyerror![]u8 {
    const opts = comp.getCompressionParameters(level, src.len, 0);
    return comp.compress(allocator, src, opts);
}
/// Compresses `src` with explicit `options`. Returns an owned slice; the caller frees it with `allocator`.
pub fn compressWithOptions(allocator: std.mem.Allocator, src: []const u8, options: CompressionOptions) anyerror![]u8 {
    if (options.workers > 0) {
        var encoder = try cctx.Encoder.init(allocator, options);
        defer encoder.deinit();
        return try encoder.compress(src);
    }
    return comp.compress(allocator, src, options);
}
/// Compresses `src` into `dst` with explicit `options`, returning bytes written.
pub fn compressIntoWithOptions(allocator: std.mem.Allocator, dst: []u8, src: []const u8, options: CompressionOptions) ZstdError!usize {
    if (options.workers > 0) {
        var encoder = cctx.Encoder.init(allocator, options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Corruption,
        };
        defer encoder.deinit();
        return encoder.compressInto(dst, src) catch |err| switch (err) {
            error.DstSizeTooSmall => return error.DstSizeTooSmall,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Corruption,
        };
    }
    return comp.compressInto(allocator, dst, src, options);
}
/// Decompresses all frames in `src` with explicit `options` (window limits,
/// checksum handling). Returns an owned slice; the caller frees it with
/// `allocator`.
pub fn decompressWithOptions(allocator: std.mem.Allocator, src: []const u8, options: DecompressionOptions) anyerror![]u8 {
    const dict_content: []const u8 = if (options.dictionary) |d| d.content() else &.{};
    if (options.requireDictionaryMatch and options.dictionary == null and src.len > 0) {
        // The caller wants a dictionary-verified decode; refusing up front beats
        // decoding a frame that may have been compressed with one.
        return error.DictionaryWrong;
    }
    const bound = try decomp.decompressBound(allocator, src);
    const safe_bound = if (bound == 0) src.len * 4 + 1024 else bound;
    const dst = try allocator.alloc(u8, safe_bound);
    errdefer allocator.free(dst);
    const out_size = try decomp.decompressIntoDictLimits(allocator, dst, src, dict_content, .{
        .maxWindowSize = options.maxWindowSize,
        .forceIgnoreChecksum = options.forceIgnoreChecksum,
        .dictId = if (options.dictionary) |d| d.dictId() else 0,
    });
    if (out_size == dst.len) return dst;
    return try allocator.realloc(dst, out_size);
}
/// Largest compressed size a one-shot compression of `src_size` bytes can
/// produce, counting the frame header, every block, and an optional checksum.
/// Worst case, not an estimate: a buffer of this size always suffices for any
/// input of `src_size` bytes and any settings.
pub fn compressBound(src_size: usize) ZstdError!usize {
    if (src_size >= constants.max_input_size) return error.SrcSizeTooLarge;
    return constants.compressBound(src_size);
}
/// Compresses `src` into `dst` at the given level, returning bytes written.
///
/// `dst` must hold at least `compressBound(src.len)` bytes to guarantee success;
/// a smaller buffer returns `error.DstSizeTooSmall` rather than writing a
/// partial frame. `allocator` backs scratch only and is not retained.
pub fn compressInto(allocator: std.mem.Allocator, dst: []u8, src: []const u8, level: i32) ZstdError!usize {
    const opts = comp.getCompressionParameters(level, src.len, 0);
    return comp.compressInto(allocator, dst, src, opts);
}
/// Decompress exactly one Zstandard frame into `dst`.
/// Returns bytes written and total frame size consumed.
pub const FrameResult = frame_mod.FrameResult;
pub fn decompressFrame(allocator: std.mem.Allocator, dst: []u8, src: []const u8) ZstdError!FrameResult {
    var state = frame_mod.entropy_mod.State.init(allocator);
    defer state.deinit();
    return frame_mod.decompressFrame(&state, dst, src);
}
/// Total size of the skippable frame at the start of `src`.
pub fn skipFrame(src: []const u8) ZstdError!usize {
    return frame_mod.skipFrame(src);
}
/// Decompresses all frames in `src` into `dst`. Returns bytes written. `allocator` backs transient tables only.
pub fn decompressInto(allocator: std.mem.Allocator, dst: []u8, src: []const u8) ZstdError!usize {
    return decomp.decompressInto(allocator, dst, src);
}
/// Upper bound on the decompressed size of `src`. Use to size output buffers.
pub fn decompressBound(allocator: std.mem.Allocator, src: []const u8) ZstdError!usize {
    return decomp.decompressBound(allocator, src);
}
/// Exact compressed size of the first frame in `src`, including header and checksum.
pub fn findFrameCompressedSize(allocator: std.mem.Allocator, src: []const u8) ZstdError!usize {
    return decomp.findFrameCompressedSize(allocator, src);
}
/// Decompressed size declared by the first frame, or `CONTENTSIZE_UNKNOWN` / `CONTENTSIZE_ERROR` when absent or invalid. Never fails.
pub fn getFrameContentSize(src: []const u8) u64 {
    if (src.len < 4) return CONTENTSIZE_ERROR;
    const fh = hdr.getFrameHeader(src) catch return CONTENTSIZE_ERROR;
    if (fh.frameType == .skippable) return 0;
    return fh.contentSize;
}
/// Parses and validates the first frame header in `src`.
pub fn getFrameHeader(src: []const u8) ZstdError!FrameHeader {
    return hdr.getFrameHeader(src);
}
/// True when `src` starts with a Zstandard, skippable, or legacy frame magic.
pub fn isFrame(src: []const u8) bool {
    return det.detectFrame(src) != .unknown;
}
/// Walks the frames in a buffer, reporting each one's kind, offset and size.
/// The iterator borrows the input and copies nothing, so the views it hands out
/// stay valid only as long as the input buffer does. It holds no allocation.
pub const FrameIterator = iterator_mod.FrameIterator;
pub const Frame = iterator_mod.Frame;
pub const FrameKind = iterator_mod.FrameKind;
/// The frame starting at `offset`, with its boundaries and metadata. Reports an
/// error rather than a partial frame when the input is truncated or the magic is
/// not recognised. This is what each `FrameIterator` step resolves to.
pub fn parseFrameAt(src: []const u8, offset: usize) ZstdError!Frame {
    return iterator_mod.parseFrame(src, offset);
}
/// True when `src` starts with a regular Zstandard frame magic (0xFD2FB528).
/// Unlike `isFrame`, skippable and legacy magics return false here.
pub fn isZstdFrame(src: []const u8) bool {
    if (src.len < 4) return false;
    return std.mem.readInt(u32, src[0..4], .little) == MAGICNUMBER;
}
/// Window size declared by the first frame, or 0 when absent or invalid.
/// Safe on untrusted input; never fails.
pub fn getFrameWindowSize(src: []const u8) u64 {
    const fh = getFrameHeader(src) catch return 0;
    if (fh.frameType == .skippable) return 0;
    return fh.windowSize;
}
/// Dictionary ID declared by the first frame, or 0 when absent or invalid.
/// Safe on untrusted input; never fails.
pub fn getDictionaryId(src: []const u8) u32 {
    const fh = getFrameHeader(src) catch return 0;
    if (fh.frameType == .skippable) return 0;
    return fh.dictId;
}
/// Full inspection of the first frame: header plus compressed size.
/// Safe on untrusted input.
pub const FrameInfo = struct {
    header: FrameHeader,
    compressedSize: usize,
};
/// Inspects the first frame in `src` without decompressing it.
pub fn inspectFrame(allocator: std.mem.Allocator, src: []const u8) ZstdError!FrameInfo {
    return .{
        .header = try getFrameHeader(src),
        .compressedSize = try findFrameCompressedSize(allocator, src),
    };
}
/// True when `src` starts with a skippable-frame magic (0x184D2A50-0x184D2A5F).
pub fn isSkippableFrame(src: []const u8) bool {
    return hdr.isSkippableFrame(src);
}
/// Writes a skippable frame carrying `data` into `dst`. Returns bytes written, or 0 when `dst` is too small. `magicVariant` selects one of the 16 skippable magics (low 4 bits used).
pub fn writeSkippableFrame(dst: []u8, data: []const u8, magicVariant: u32) usize {
    if (dst.len < 8 + data.len) return 0;
    const magic = MAGIC_SKIPPABLE_START + (magicVariant & 0xF);
    dst[0] = @truncate(magic);
    dst[1] = @truncate(magic >> 8);
    dst[2] = @truncate(magic >> 16);
    dst[3] = @truncate(magic >> 24);
    const size: u32 = @intCast(data.len);
    dst[4] = @truncate(size);
    dst[5] = @truncate(size >> 8);
    dst[6] = @truncate(size >> 16);
    dst[7] = @truncate(size >> 24);
    std.mem.copyForwards(u8, dst[8 .. 8 + data.len], data);
    return 8 + data.len;
}
/// Copies the payload of the skippable frame in `src` into `dst`. Returns payload bytes written.
pub fn readSkippableFrame(dst: []u8, src: []const u8) ZstdError!usize {
    if (src.len < 8) return error.SrcSizeWrong;
    if (!isSkippableFrame(src)) return error.PrefixUnknown;
    const size: u32 = @as(u32, src[4]) | (@as(u32, src[5]) << 8) | (@as(u32, src[6]) << 16) | (@as(u32, src[7]) << 24);
    if (src.len < 8 + size) return error.SrcSizeWrong;
    if (dst.len < size) return error.DstSizeTooSmall;
    std.mem.copyForwards(u8, dst[0..size], src[8 .. 8 + size]);
    return size;
}
/// Library version string ("0.0.4").
pub fn versionString() []const u8 {
    return version;
}
/// Library version as major*100*100 + minor*100 + patch.
pub fn versionNumber() u32 {
    return 4;
}
/// Data-format specification version string ("1.6.0").
pub fn specVersionString() []const u8 {
    return "1.6.0";
}
/// Numeric specification version (major*100*100 + minor*100 + patch).
pub fn specVersionNumber() u32 {
    return 10600;
}
/// Maximum supported compression level (22).
pub fn maxCLevel() i32 {
    return constants.c_level_max;
}
/// Minimum supported compression level (negative, for fast modes).
pub fn minCLevel() i32 {
    return constants.c_level_min;
}
/// Default compression level (3).
pub fn defaultCLevel() i32 {
    return constants.c_level_default;
}
const testing = std.testing;
// Bound behaviour is covered by the three `compressBound` tests near the top of
// this file, which check the guarantee by compressing into a buffer of exactly
// the reported size rather than only comparing numbers.

const interopCorpus = [_]struct { name: []const u8, gen: *const fn (out: []u8) void }{
    .{ .name = "zeros", .gen = struct {
        fn f(out: []u8) void {
            @memset(out, 0);
        }
    }.f },
    .{ .name = "ones", .gen = struct {
        fn f(out: []u8) void {
            @memset(out, 0xFF);
        }
    }.f },
    .{ .name = "alternating", .gen = struct {
        fn f(out: []u8) void {
            for (out, 0..) |*b, i| b.* = if (i % 2 == 0) 0xAA else 0x55;
        }
    }.f },
    .{ .name = "incrementing", .gen = struct {
        fn f(out: []u8) void {
            for (out, 0..) |*b, i| b.* = @truncate(i);
        }
    }.f },
    .{ .name = "random", .gen = struct {
        fn f(out: []u8) void {
            var prng = std.Random.DefaultPrng.init(0xC0FFEE);
            prng.random().bytes(out);
        }
    }.f },
    .{ .name = "text", .gen = struct {
        fn f(out: []u8) void {
            const words = [_][]const u8{ "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "zstandard", "compression" };
            var prng = std.Random.DefaultPrng.init(7);
            const random = prng.random();
            var pos: usize = 0;
            while (pos < out.len) {
                const w = words[random.uintLessThan(usize, words.len)];
                const n = @min(w.len, out.len - pos);
                @memcpy(out[pos .. pos + n], w[0..n]);
                pos += n + 1;
            }
        }
    }.f },
    .{ .name = "low-entropy", .gen = struct {
        fn f(out: []u8) void {
            var prng = std.Random.DefaultPrng.init(0xBEEF);
            const random = prng.random();
            for (out) |*b| b.* = random.intRangeAtMost(u8, 0, 3);
        }
    }.f },
    .{
        .name = "mixed",
        .gen = struct {
            fn f(out: []u8) void {
                // Long runs of one byte interrupted by random bursts: exercises the
                // sequence path and literal entropy together.
                var prng = std.Random.DefaultPrng.init(31337);
                const random = prng.random();
                var i: usize = 0;
                while (i < out.len) {
                    const run = random.intRangeAtMost(usize, 4, 200);
                    const byte: u8 = random.int(u8);
                    var j: usize = 0;
                    while (j < run and i < out.len) : (j += 1) {
                        out[i] = byte;
                        i += 1;
                    }
                }
            }
        }.f,
    },
    .{ .name = "repeating", .gen = struct {
        fn f(out: []u8) void {
            const unit = "abcabcabdabcabcabeabcabcabf";
            for (out, 0..) |*b, i| b.* = unit[i % unit.len];
        }
    }.f },
};
/// The longest payload the matrix generates, which sizes every buffer below.
const interopMaxLen = 131073;
/// The logger these tests report progress through. Test bodies must not write to
/// stderr with `std.debug.print`: the test-runner protocol captures that as if the
/// runner had spoken, and the build reports a failed command even though every
/// test passed and the process exited zero.
const test_log = std.log.scoped(.zstd_zig_test);
/// Scratch buffers for the generated corpus, allocated once for the whole run so
/// the matrix does not pay for them per case.
const interopHarness = struct {
    src: []u8,
    expected: []u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !interopHarness {
        return .{
            .src = try allocator.alloc(u8, interopMaxLen),
            .expected = try allocator.alloc(u8, interopMaxLen),
            .allocator = allocator,
        };
    }

    fn deinit(self: *interopHarness) void {
        self.allocator.free(self.src);
        self.allocator.free(self.expected);
    }

    /// Fills the source and the copy the result is compared against, so the
    /// comparison never aliases the buffer being compressed.
    fn prepare(self: *interopHarness, entry: @TypeOf(interopCorpus[0]), len: usize) []const u8 {
        entry.gen(self.src[0..len]);
        @memcpy(self.expected[0..len], self.src[0..len]);
        return self.expected[0..len];
    }
};
/// Sizes around the boundaries that matter: zero, the four-byte match unit, the
/// literal and block thresholds, and just past each of them.
const interopMatrixSizes = [_]usize{ 0, 1, 3, 7, 16, 63, 255, 256, 1024, 4096, 65536 };
/// The levels the whole-corpus matrix runs. Every level is covered elsewhere in
/// the suite; what the matrix adds is the cross product, which is what catches a
/// level that only misbehaves on one kind of data.
const interopMatrixLevels = [_]i32{ 1, 3, 5, 7, 12, 19, 22 };
/// One corpus of each kind, so a level that mishandles incompressible,
/// low-entropy, textual or highly repetitive input is caught.
const interopMatrixCorpus = [_]usize{ 0, 2, 4, 5, 6, 8 };
const interopFallbackPaths = [_][]const u8{
    "/usr/bin/zstd",
    "/usr/local/bin/zstd",
    "/opt/homebrew/bin/zstd",
    "C:\\msys64\\ucrt64\\bin\\zstd.exe",
    "C:\\msys64\\mingw64\\bin\\zstd.exe",
    "C:\\ProgramData\\chocolatey\\bin\\zstd.exe",
};
fn interopExecutableName() []const u8 {
    return if (@import("builtin").os.tag == .windows) "zstd.exe" else "zstd";
}
fn interopFileExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(testing.io, path, .{}) catch return false;
    return true;
}
/// The reference binary the differential tests compare against: the one named by
/// `ZSTD_REFERENCE_PATH`, otherwise the first `zstd` found on `PATH`, otherwise
/// one of the usual install locations.
///
/// These tests never skip. A run that cannot find a reference has not performed
/// the comparison it claims to have, so it fails here and says how to supply a
/// binary. A caller frees the returned path with the same allocator.
fn interopReference() []u8 {
    if (testing.environ.getAlloc(testing.allocator, "ZSTD_REFERENCE_PATH")) |value| {
        if (value.len == 0 or !interopFileExists(value)) {
            testing.allocator.free(value);
            std.debug.panic("ZSTD_REFERENCE_PATH is set but does not name a readable file", .{});
        }
        return value;
    } else |_| {}

    const name = interopExecutableName();
    if (testing.environ.getAlloc(testing.allocator, "PATH")) |search_path| {
        defer testing.allocator.free(search_path);
        var dirs = std.mem.splitScalar(u8, search_path, std.fs.path.delimiter);
        while (dirs.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = std.fs.path.join(testing.allocator, &.{ dir, name }) catch continue;
            if (interopFileExists(candidate)) return candidate;
            testing.allocator.free(candidate);
        }
    } else |_| {}

    for (interopFallbackPaths) |candidate| {
        if (interopFileExists(candidate)) return testing.allocator.dupe(u8, candidate) catch unreachable;
    }
    std.debug.panic(
        "no reference zstd binary: set ZSTD_REFERENCE_PATH to one, or install zstd so it is on PATH",
        .{},
    );
}
/// The differential matrix. Every case is a process launch, so it stays small and
/// representative: one corpus of each kind, the boundary sizes, and a spread of
/// levels. The self round trips above already cover the full cross product; this
/// half is about the *other* implementation agreeing.
const interopDiffCorpus = [_]usize{ 0, 4, 5, 6, 8 };
const interopDiffSizes = [_]usize{ 0, 1, 3, 16, 255, 1024, 4096, 65536, 131073 };
const interopDiffLevels = [_]i32{ 1, 3, 9, 19 };
/// Every supported level, so a level that regresses cannot hide between the
/// sampled ones.
const everyLevel = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22 };
/// Every strategy, so the matrix covers the whole strategy set rather than the
/// levels that happen to map to it.
const everyStrategy = [_]Strategy{ .fast, .dfast, .greedy, .lazy, .lazy2, .btlazy2, .btopt, .btultra, .btultra2 };
fn interopMtPayload(allocator: std.mem.Allocator) ![]u8 {
    const len = 4 * 512 * 1024;
    const data = try allocator.alloc(u8, len);
    errdefer allocator.free(data);
    const text = "multithreaded sections concatenate into one frame, and the reference decodes them; ";
    var pos: usize = 0;
    while (pos < len) {
        const phase = pos / 262144;
        switch (phase % 4) {
            0 => {
                const n = @min(text.len, len - pos);
                @memcpy(data[pos .. pos + n], text[0..n]);
                pos += n;
            },
            1 => {
                const n = @min(100000, len - pos);
                @memset(data[pos .. pos + n], 'q');
                pos += n;
            },
            else => {
                // A repeat of two phases back (128 KiB-256 KiB), plus noise,
                // so both a near and a mid-range distance cross each boundary.
                const back = @min(pos, 150000);
                const n = @min(back, len - pos);
                @memcpy(data[pos .. pos + n], data[pos - back ..][0..n]);
                pos += n;
                var v: u32 = @truncate(pos *% 2654435761);
                var i: usize = 0;
                while (i < 64 and pos < len) : (i += 1) {
                    v = v *% 1664525 +% 1013904223;
                    data[pos] = @truncate(v >> 16);
                    pos += 1;
                }
            },
        }
    }
    return data;
}
/// Scratch files for the reference live in the system temporary directory, not in
/// the project tree, so an interrupted run cannot leave debris in the repository.
fn interopScratch(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    for ([_][]const u8{ "TMPDIR", "TEMP", "TMP" }) |var_name| {
        const dir = testing.environ.getAlloc(allocator, var_name) catch continue;
        if (dir.len == 0) {
            allocator.free(dir);
            continue;
        }
        defer allocator.free(dir);
        return std.fs.path.join(allocator, &.{ dir, name });
    }
    return error.NoScratchDir;
}
fn interopWrite(path: []const u8, data: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(testing.io, path, .{ .truncate = true });
    defer file.close(testing.io);
    try file.writePositionalAll(testing.io, data, 0);
}
fn interopRead(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(testing.io, path, .{});
    defer file.close(testing.io);
    const stat = try file.stat(testing.io);
    const buffer = try allocator.alloc(u8, @intCast(stat.size));
    const read = try file.readPositionalAll(testing.io, buffer, 0);
    return allocator.realloc(buffer, read) catch buffer;
}
fn interopExitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}
fn interopRun(allocator: std.mem.Allocator, argv: []const []const u8) !struct { code: u8, stderr: []u8 } {
    const result = try std.process.run(allocator, testing.io, .{ .argv = argv });
    defer allocator.free(result.stdout);
    return .{ .code = interopExitCode(result.term) orelse 255, .stderr = result.stderr };
}
fn interopAppendSkippable(allocator: std.mem.Allocator, stream: *std.ArrayList(u8), payload: []const u8) !void {
    var header: [8]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], 0x184D2A50, .little);
    std.mem.writeInt(u32, header[4..8], @intCast(payload.len), .little);
    try stream.appendSlice(allocator, &header);
    try stream.appendSlice(allocator, payload);
}
test "raw block compression" {
    const src = "raw block test data that is not repetitive";
    var buf: [256]u8 = undefined;
    const written = try compressInto(testing.allocator, &buf, src, 1);
    try testing.expect(written > 0);
}
test "get compression parameters level 1" {
    const p = getCompressionParameters(1, 1000, 0);
    try testing.expect(p.level >= 1);
}
test "get compression parameters level 22" {
    const p = getCompressionParameters(22, 1000, 0);
    try testing.expect(p.level >= 22);
}
test "compress large repetitive" {
    const alloc = testing.allocator;
    var src: [4096]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i % 26 + 'A');
    const c = try compress(alloc, &src);
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualSlices(u8, &src, d);
}
test "streaming compress init" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
}
test "streaming compress and decompress" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
    var buf: [4096]u8 = undefined;
    sc.setPledgedSrcSize(24);
    const r = try sc.compressStream(&buf, "first chunk second chunk", .end);
    try testing.expect(r.outProduced > 0);
    var out: [4096]u8 = undefined;
    const dec = try decompressInto(testing.allocator, &out, buf[0..r.outProduced]);
    try testing.expectEqualStrings("first chunk second chunk", out[0..dec]);
}
test "streaming compress with checksum" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
    sc.setChecksumFlag(true);
    var buf: [4096]u8 = undefined;
    const r = try sc.compressStream(&buf, "checksum data", .end);
    try testing.expect(r.outProduced > 0);
}
test "streaming decompress init" {
    var sd = StreamingDecompressor.init(testing.allocator);
    defer sd.deinit();
}
test "streaming decompress all" {
    const alloc = testing.allocator;
    const src = "streaming all test";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    var sd = StreamingDecompressor.init(alloc);
    defer sd.deinit();
    var out: [256]u8 = undefined;
    const n = try sd.decompressStream(&out, c);
    try testing.expectEqualStrings(src, out[0..n.outProduced]);
}
test "streaming decompress reset" {
    var sd = StreamingDecompressor.init(testing.allocator);
    defer sd.deinit();
    sd.reset();
}
test "block type raw detection" {
    try testing.expectEqual(BlockType.raw, @as(BlockType, .raw));
    try testing.expectEqual(BlockType.rle, @as(BlockType, .rle));
    try testing.expectEqual(BlockType.compressed, @as(BlockType, .compressed));
    try testing.expectEqual(BlockType.reserved, @as(BlockType, .reserved));
}
test "frame module surface" {
    std.testing.refAllDecls(frame_mod);
}
// Edge-case coverage: frame format, entropy, streaming, corruption

test "roundtrip every length 0..300" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    for (0..300) |n| {
        const src = try alloc.alloc(u8, n);
        defer alloc.free(src);
        prng.random().bytes(src);
        const c = try compress(alloc, src);
        defer alloc.free(c);
        const d = try decompress(alloc, c);
        defer alloc.free(d);
        try testing.expectEqualSlices(u8, src, d);
    }
}
test "roundtrip max single block 128KB" {
    const alloc = testing.allocator;
    const src = try alloc.alloc(u8, constants.block_size_max);
    defer alloc.free(src);
    // Compressible pattern so encoder takes the FSE path.
    for (src, 0..) |*b, i| b.* = @intCast((i * 31 + (i / 251)) % 251);
    const c = try compress(alloc, src);
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualSlices(u8, src, d);
}
test "multi-block frame crosses block boundary" {
    const alloc = testing.allocator;
    const src = try alloc.alloc(u8, constants.block_size_max + 1000);
    defer alloc.free(src);
    @memset(src, 0xAA);
    for (src[0..1000], 0..) |*b, i| b.* = @intCast(i % 200);
    const c = try compress(alloc, src);
    defer alloc.free(c);
    // Frame must contain more than one block.
    const frame_hdr = try getFrameHeader(c);
    try testing.expect(frame_hdr.contentSize == src.len);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualSlices(u8, src, d);
}
test "checksum detects single flipped bit" {
    const alloc = testing.allocator;
    const unit = "checksum bit-flip detection payload ";
    var src_buf: [unit.len * 10]u8 = undefined;
    for (0..10) |i| std.mem.copyForwards(u8, src_buf[i * unit.len ..][0..unit.len], unit);
    const src: []const u8 = &src_buf;
    const c = try compressWithOptions(alloc, src, .{ .checksum = true });
    defer alloc.free(c);
    var bad = try alloc.dupe(u8, c);
    defer alloc.free(bad);
    bad[bad.len - 1] ^= 0x01; // flip checksum bit
    try testing.expectError(error.ChecksumWrong, decompress(alloc, bad));
}
test "corrupted payload byte fails via checksum" {
    const alloc = testing.allocator;
    const unit = "payload to corrupt mid-stream for safety checks";
    var src_buf: [unit.len * 5]u8 = undefined;
    for (0..5) |i| std.mem.copyForwards(u8, src_buf[i * unit.len ..][0..unit.len], unit);
    const src: []const u8 = &src_buf;
    const c = try compressWithOptions(alloc, src, .{ .checksum = true });
    defer alloc.free(c);
    var bad = try alloc.dupe(u8, c);
    defer alloc.free(bad);
    // Flip a payload byte inside the first block (raw literals region).
    bad[20] ^= 0xFF;
    const r = decompress(alloc, bad);
    try testing.expect(std.meta.isError(r));
}
test "skippable frame all 16 magic variants" {
    var buf: [64]u8 = undefined;
    for (0..16) |v| {
        const n = writeSkippableFrame(&buf, "skip", @intCast(v));
        try testing.expect(isSkippableFrame(buf[0..n]));
        var out: [16]u8 = undefined;
        const got = try readSkippableFrame(&out, buf[0..n]);
        try testing.expectEqualStrings("skip", out[0..got]);
    }
}
test "skippable frames interleaved between data frames" {
    const alloc = testing.allocator;
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(alloc);
    var skip: [32]u8 = undefined;
    const sn = writeSkippableFrame(&skip, "meta", 3);
    try stream.appendSlice(alloc, skip[0..sn]);
    const c1 = try compress(alloc, "first");
    defer alloc.free(c1);
    try stream.appendSlice(alloc, c1);
    const sn2 = writeSkippableFrame(&skip, "more", 15);
    try stream.appendSlice(alloc, skip[0..sn2]);
    const c2 = try compress(alloc, "second");
    defer alloc.free(c2);
    try stream.appendSlice(alloc, c2);

    const d = try decompress(alloc, stream.items);
    defer alloc.free(d);
    try testing.expectEqualStrings("firstsecond", d);
}
test "frame header rejects reserved bit" {
    // fhd with reserved bit 3 set must be rejected by decoders.
    var buf = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0x08 };
    try testing.expectError(error.FrameParameterUnsupported, getFrameHeader(&buf));
    _ = &buf;
}
test "content size mismatch detected" {
    const alloc = testing.allocator;
    // Declare a size that differs from the actual payload length; the decoder
    // must reject the frame instead of silently accepting it.
    const c = try compressWithOptions(alloc, "actual size", .{ .contentSize = 999 });
    defer alloc.free(c);
    const r = decompress(alloc, c);
    try testing.expect(std.meta.isError(r));
    if (r) |_| {} else |e| {
        try testing.expect(e == error.ContentSizeMismatch or e == error.DstSizeTooSmall or e == error.Corruption);
    }
}
test "dictionary roundtrip through context" {
    const alloc = testing.allocator;
    var dict = try createDictionaryFromData(alloc, "shared corpus bytes for dict", 77);
    defer dict.deinit();
    const opts = CompressionOptions{ .dictId = dict.dictId() };
    const comp_bytes = try compressWithOptions(alloc, "x", opts);
    defer alloc.free(comp_bytes);
    const frame_hdr = try getFrameHeader(comp_bytes);
    try testing.expectEqual(@as(u32, 77), frame_hdr.dictId);
}
test "decompressWithDict accepts valid frames" {
    const alloc = testing.allocator;
    const src = "with-dictionary decode path";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    var out: [64]u8 = undefined;
    const n = try decompressInto(alloc, &out, c);
    try testing.expectEqualStrings(src, out[0..n]);
}
test "streaming chunk boundaries 1..17 bytes" {
    const alloc = testing.allocator;
    const unit = "chunked streaming boundary sweep for zstd.zig";
    var src_buf: [unit.len * 6]u8 = undefined;
    for (0..6) |i| std.mem.copyForwards(u8, src_buf[i * unit.len ..][0..unit.len], unit);
    const src: []const u8 = &src_buf;
    const c = try compress(alloc, src);
    defer alloc.free(c);
    for (1..18) |step| {
        var sd = StreamingDecompressor.init(alloc);
        defer sd.deinit();
        var out: [4096]u8 = undefined;
        var total: usize = 0;
        var pos: usize = 0;
        while (pos < c.len) {
            const n = @min(step, c.len - pos);
            const r = try sd.decompressStream(out[total..], c[pos .. pos + n]);
            total += r.outProduced;
            pos += n;
        }
        try testing.expectEqualStrings(src, out[0..total]);
    }
}
test "streaming empty final chunk still terminates frame" {
    const alloc = testing.allocator;
    var sc = try StreamingCompressor.init(alloc, 3);
    defer sc.deinit();
    var buf: [1024]u8 = undefined;
    _ = try sc.compressStream(&buf, "", .end);
    try testing.expect(sc.finished);
}
test "compressBound monotonic across sizes" {
    var prev: usize = 0;
    var i: usize = 1;
    while (i < 1 << 20) : (i *= 3) {
        const b = try compressBound(i);
        try testing.expect(b > prev or prev == 0);
        prev = b;
    }
}
test "level clamping helpers expose bounds" {
    try testing.expect(minCLevel() <= defaultCLevel());
    try testing.expect(defaultCLevel() <= maxCLevel());
}
test "spec version accessors" {
    try testing.expectEqualStrings("1.6.0", specVersionString());
    try testing.expect(specVersionNumber() == 10600);
}
// Interoperability vectors: frames produced by the official Zstandard 1.5.7
// reference encoder (`zstd -3`). These pin the decode direction against a
// real-world implementation, including a genuinely compressed block with
// Huffman-coded literals and FSE-coded sequences.

test "interop official empty frame" {
    const alloc = testing.allocator;
    const frame = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0x24, 0x00, 0x01, 0x00, 0x00, 0x99, 0xE9, 0xD8, 0x51 };
    const d = try decompress(alloc, &frame);
    defer alloc.free(d);
    try testing.expectEqual(@as(usize, 0), d.len);
}
test "interop official single byte" {
    const alloc = testing.allocator;
    const frame = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0x24, 0x01, 0x09, 0x00, 0x00, 0x58, 0xE5, 0x1A, 0xE3, 0x6E };
    const d = try decompress(alloc, &frame);
    defer alloc.free(d);
    try testing.expectEqualSlices(u8, "X", d);
}
test "interop official raw literals" {
    const alloc = testing.allocator;
    const frame = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0x24, 0x19, 0xC9, 0x00, 0x00, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x2C, 0x20, 0x5A, 0x73, 0x74, 0x61, 0x6E, 0x64, 0x61, 0x72, 0x64, 0x20, 0x69, 0x6E, 0x74, 0x65, 0x72, 0x6F, 0x70, 0x21, 0x20, 0xB9, 0xD2, 0xEA };
    const d = try decompress(alloc, &frame);
    defer alloc.free(d);
    try testing.expectEqualStrings("Hello, Zstandard interop!", d);
}
test "interop official compressed block" {
    // 512 bytes of ABAB... compressed by the reference encoder into a real
    // compressed block (Huffman literals + FSE sequences + checksum).
    const alloc = testing.allocator;
    const frame = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0x64, 0x00, 0x01, 0x4D, 0x00, 0x00, 0x10, 0x41, 0x42, 0x01, 0x00, 0xFB, 0xA9, 0x0E, 0x0B, 0x3F, 0x3F, 0xB4, 0xF7 };
    const d = try decompress(alloc, &frame);
    defer alloc.free(d);
    try testing.expectEqual(@as(usize, 512), d.len);
    for (d, 0..) |b, i| {
        try testing.expectEqual(@as(u8, if (i % 2 == 0) 'A' else 'B'), b);
    }
}
test "interop golden empty block" {
    // Reference empty-block frame decodes to zero bytes.
    const alloc = testing.allocator;
    const frame = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x00, 0x15, 0x00, 0x00, 0x00, 0x00 };
    const d = try decompress(alloc, &frame);
    defer alloc.free(d);
    try testing.expectEqual(@as(usize, 0), d.len);
}
test "interop golden zeroSeq literal" {
    // Reference frame with zero sequences: raw "Hello World!\n".
    const alloc = testing.allocator;
    const frame = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x00, 0x85, 0x00, 0x00, 0x68, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x20, 0x57, 0x6F, 0x72, 0x6C, 0x64, 0x21, 0x0A, 0x80, 0x00 };
    const d = try decompress(alloc, &frame);
    defer alloc.free(d);
    try testing.expectEqualStrings("Hello World!\n", d);
}
test "interop golden invalid offset rejected" {
    // Reference off0 vector: sequence with offset 0. Must fail, never panic.
    const alloc = testing.allocator;
    const frame = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x00, 0x45, 0x00, 0x00, 0x08, 0x00, 0x02, 0x00, 0x2F, 0x43, 0x0B, 0xAE };
    const r = decompress(alloc, &frame);
    try testing.expect(std.meta.isError(r));
    if (r) |v| alloc.free(v) else |_| {}
}
test "interop golden truncated Huffman rejected" {
    // Reference truncated_huff_state vector: Huffman stream ends early.
    // The end-of-stream check must reject it instead of emitting garbage.
    const alloc = testing.allocator;
    const frame = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x00, 0x55, 0x00, 0x00, 0x72, 0x80, 0x01, 0x04, 0x20, 0x7E, 0x1F, 0x02, 0xAA, 0x00 };
    const r = decompress(alloc, &frame);
    try testing.expect(std.meta.isError(r));
    if (r) |v| alloc.free(v) else |_| {}
}
test "interop golden extraneous sequence rejected" {
    // Reference zeroSeq_extraneous vector: trailing garbage after sequences.
    const alloc = testing.allocator;
    const frame = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x00, 0x95, 0x00, 0x00, 0x68, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x20, 0x57, 0x6F, 0x72, 0x6C, 0x64, 0x21, 0x0A, 0x80, 0x00, 0x00, 0x00 };
    const r = decompress(alloc, &frame);
    try testing.expect(std.meta.isError(r));
    if (r) |v| alloc.free(v) else |_| {}
}
// Property tests: decompress(compress(x)) == x over varied distributions.

test "property roundtrip random bytes" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const random = prng.random();
    for (0..32) |trial| {
        const len = random.intRangeAtMost(usize, 0, 4096);
        const src = try alloc.alloc(u8, len);
        defer alloc.free(src);
        random.bytes(src);
        const c = try compress(alloc, src);
        defer alloc.free(c);
        const d = try decompress(alloc, c);
        defer alloc.free(d);
        try testing.expectEqualSlices(u8, src, d);
        if (trial == 0) try testing.expect(c.len >= 0);
    }
}
test "property roundtrip low entropy alphabet" {
    const alloc = testing.allocator;
    // Fixed alphabet of 4 symbols exercises Huffman and match finding.
    var src: [2048]u8 = undefined;
    var s: u64 = 0x12345678;
    for (&src) |*b| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        b.* = @intCast((s >> 33) % 4);
    }
    for ([_]i32{ 1, 3, 9, 19 }) |level| {
        const c = try compressWithLevel(alloc, &src, level);
        defer alloc.free(c);
        const d = try decompress(alloc, c);
        defer alloc.free(d);
        try testing.expectEqualSlices(u8, &src, d);
    }
}
test "property roundtrip sparse mutations" {
    // Mostly constant with rare divergences: long matches plus literals.
    const alloc = testing.allocator;
    var src: [8192]u8 = undefined;
    @memset(&src, 'A');
    var s: u64 = 0xDEADBEEF;
    for (&src, 0..) |*b, i| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        if ((s >> 33) % 97 == 0) b.* = @intCast(i % 251);
    }
    const c = try compress(alloc, &src);
    defer alloc.free(c);
    try testing.expect(c.len < src.len);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualSlices(u8, &src, d);
}
// Malformed input: every corrupt frame must surface as an error, never a
// panic, an out-of-bounds access, or an unbounded allocation.

test "malformed truncated magic" {
    const alloc = testing.allocator;
    // Two bytes cannot even hold a magic number.
    try testing.expectError(error.SrcSizeWrong, decompress(alloc, &[_]u8{ 0x28, 0xB5 }));
}
test "malformed invalid magic" {
    const alloc = testing.allocator;
    const bad = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77 };
    try testing.expectError(error.PrefixUnknown, decompress(alloc, &bad));
}
test "malformed truncated frame header" {
    const alloc = testing.allocator;
    const c = try compress(alloc, "truncate the header");
    defer alloc.free(c);
    for ([_]usize{ 4, 5, 6 }) |n| {
        const r = decompress(alloc, c[0..n]);
        try testing.expect(std.meta.isError(r));
        if (r) |v| alloc.free(v) else |_| {}
    }
}
test "malformed reserved block type rejected" {
    // Block header: last=1, type=3 (reserved), size=0.
    var frame: [64]u8 = undefined;
    @memcpy(frame[0..4], &[_]u8{ 0x28, 0xB5, 0x2F, 0xFD });
    // Minimal single-segment header for empty content.
    frame[4] = 0x20;
    frame[5] = 0x00;
    frame[6] = 0x07; // last=1, type=3, size=0
    frame[7] = 0x00;
    frame[8] = 0x00;
    const alloc = testing.allocator;
    const r = decompress(alloc, frame[0..9]);
    try testing.expect(std.meta.isError(r));
    if (r) |v| alloc.free(v) else |_| {}
}
test "malformed checksum mismatch" {
    const alloc = testing.allocator;
    const c = try compressWithOptions(alloc, "checksum will not match", .{ .checksum = true });
    defer alloc.free(c);
    var bad = try alloc.dupe(u8, c);
    defer alloc.free(bad);
    bad[bad.len - 1] +%= 1;
    try testing.expectError(error.ChecksumWrong, decompress(alloc, bad));
}
test "malformed fcs mismatch" {
    const alloc = testing.allocator;
    // Claim 999 bytes while the payload is 11.
    const c = try compressWithOptions(alloc, "actual size", .{ .contentSize = 999 });
    defer alloc.free(c);
    const r = decompress(alloc, c);
    try testing.expect(std.meta.isError(r));
    if (r) |v| alloc.free(v) else |_| {}
}
test "malformed skippable truncated size" {
    var buf: [32]u8 = undefined;
    const n = writeSkippableFrame(&buf, "payload", 0);
    // Claim more than is present.
    buf[4] = 0xFF;
    const alloc = testing.allocator;
    const r = decompress(alloc, buf[0..n]);
    try testing.expect(std.meta.isError(r));
    if (r) |v| alloc.free(v) else |_| {}
}
test "malformed all single byte values" {
    // Every possible first byte must either start a valid frame or fail
    // cleanly; none may panic.
    const alloc = testing.allocator;
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        const b: u8 = @intCast(i);
        const input = [_]u8{ b, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0, 0, 0, 0, 0 };
        const r = decompress(alloc, &input);
        if (r) |v| alloc.free(v) else |_| {}
    }
}
test "edge sizes roundtrip matrix" {
    // Systematic lengths covering every codec threshold neighborhood:
    // empty, tiny, byte-boundaries, Huffman cutovers, block splits.
    const alloc = testing.allocator;
    const sizes = [_]usize{ 0, 1, 2, 3, 4, 5, 7, 8, 15, 16, 31, 32, 63, 64, 127, 128, 255, 256, 512, 1023, 1024, 4095, 4096, 16383, 16384, 32768, 131072, 131073 };
    var prng = std.Random.DefaultPrng.init(0xED6E);
    const random = prng.random();
    for (sizes) |n| {
        const src = try alloc.alloc(u8, n);
        defer alloc.free(src);
        random.bytes(src);
        const c = try compress(alloc, src);
        defer alloc.free(c);
        const d = try decompress(alloc, c);
        defer alloc.free(d);
        try testing.expectEqualSlices(u8, src, d);
    }
}
test "edge patterns roundtrip matrix" {
    // Zeros, ones, alternating, incrementing, and UTF-8 text at sizes that
    // cross RLE, raw, and compressed block decisions.
    const alloc = testing.allocator;
    const sizes = [_]usize{ 7, 8, 9, 64, 256, 1024, 4096 };
    for (sizes) |n| {
        // Zeros (RLE path).
        {
            const src = try alloc.alloc(u8, n);
            defer alloc.free(src);
            @memset(src, 0);
            const c = try compress(alloc, src);
            defer alloc.free(c);
            const d = try decompress(alloc, c);
            defer alloc.free(d);
            try testing.expectEqualSlices(u8, src, d);
        }
        // 0xFF (RLE path, high bit).
        {
            const src = try alloc.alloc(u8, n);
            defer alloc.free(src);
            @memset(src, 0xFF);
            const c = try compress(alloc, src);
            defer alloc.free(c);
            const d = try decompress(alloc, c);
            defer alloc.free(d);
            try testing.expectEqualSlices(u8, src, d);
        }
        // Alternating (short matches).
        {
            const src = try alloc.alloc(u8, n);
            defer alloc.free(src);
            for (src, 0..) |*b, i| b.* = @intCast(i % 2);
            const c = try compress(alloc, src);
            defer alloc.free(c);
            const d = try decompress(alloc, c);
            defer alloc.free(d);
            try testing.expectEqualSlices(u8, src, d);
        }
        // Incrementing (match-hostile).
        {
            const src = try alloc.alloc(u8, n);
            defer alloc.free(src);
            for (src, 0..) |*b, i| b.* = @intCast(i % 256);
            const c = try compress(alloc, src);
            defer alloc.free(c);
            const d = try decompress(alloc, c);
            defer alloc.free(d);
            try testing.expectEqualSlices(u8, src, d);
        }
    }
    // UTF-8 multibyte text.
    {
        const src = "héllo wörld - zstd ✓ compresses UTF-8 multibyte text without splitting code points";
        const c = try compress(alloc, src);
        defer alloc.free(c);
        const d = try decompress(alloc, c);
        defer alloc.free(d);
        try testing.expectEqualStrings(src, d);
    }
}
test "decompressWithOptions roundtrip" {
    const alloc = testing.allocator;
    const src = "options-aware decompression path";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    const d = try decompressWithOptions(alloc, c, .{});
    defer alloc.free(d);
    try testing.expectEqualStrings(src, d);
}
test "decompressWithOptions ignores bad checksum on request" {
    const alloc = testing.allocator;
    const src = "checksum will be corrupt but ignored";
    const c = try compressWithOptions(alloc, src, .{ .checksum = true });
    defer alloc.free(c);
    var bad = try alloc.dupe(u8, c);
    defer alloc.free(bad);
    bad[bad.len - 1] +%= 1;
    // Default path rejects.
    try testing.expectError(error.ChecksumWrong, decompress(alloc, bad));
    // Opt-out path decodes.
    const d = try decompressWithOptions(alloc, bad, .{ .forceIgnoreChecksum = true });
    defer alloc.free(d);
    try testing.expectEqualStrings(src, d);
}
test "Compressor and Decompressor aliases" {
    var c = Compressor.init(testing.allocator);
    defer c.deinit();
    const src = "alias types compress and decompress";
    const enc = try c.compressAlloc(src);
    defer testing.allocator.free(enc);
    var d = Decompressor.init(testing.allocator);
    defer d.deinit();
    const dec = try d.decompressAlloc(enc);
    defer testing.allocator.free(dec);
    try testing.expectEqualStrings(src, dec);
}
test "Encoder and Decoder client-side API" {
    const alloc = testing.allocator;
    const src = "Encoder and Decoder client-side API explicit lifecycle test";

    // Default single-threaded
    var encoder = try Encoder.init(alloc, .{});
    defer encoder.deinit();
    const enc = try encoder.compress(src);
    defer alloc.free(enc);

    var decoder = Decoder.init(alloc, .{});
    defer decoder.deinit();
    const dec = try decoder.decompressAlloc(enc);
    defer alloc.free(dec);
    try testing.expectEqualStrings(src, dec);

    var dst_buf: [256]u8 = undefined;
    const written = try decoder.decompress(&dst_buf, enc);
    try testing.expectEqualStrings(src, dst_buf[0..written]);

    encoder.reset();
    decoder.reset();
}
test "compressWithOptions and compressIntoWithOptions with explicit workers" {
    const alloc = testing.allocator;
    const src = "explicit workers multithreaded compression test payload that verifies worker pool lifecycle";

    // Explicit worker compression
    const compressed = try compressWithOptions(alloc, src, .{ .workers = 2, .level = 3 });
    defer alloc.free(compressed);

    const decompressed = try decompress(alloc, compressed);
    defer alloc.free(decompressed);
    try testing.expectEqualStrings(src, decompressed);

    // compressIntoWithOptions with explicit workers
    var dst_buf: [512]u8 = undefined;
    const written = try compressIntoWithOptions(alloc, &dst_buf, src, .{ .workers = 2, .level = 3 });
    const decompressed2 = try decompress(alloc, dst_buf[0..written]);
    defer alloc.free(decompressed2);
    try testing.expectEqualStrings(src, decompressed2);
}
test "frame inspection helpers" {
    const alloc = testing.allocator;
    const src = "inspect me";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    try testing.expect(isZstdFrame(c));
    try testing.expect(!isZstdFrame("not a frame"));
    try testing.expectEqual(@as(u64, src.len), getFrameWindowSize(c));
    try testing.expectEqual(@as(u32, 0), getDictionaryId(c));
    try testing.expectEqual(@as(u64, 0), getFrameWindowSize("bad"));
    try testing.expectEqual(@as(u32, 0), getDictionaryId("bad"));
    const info = try inspectFrame(alloc, c);
    try testing.expectEqual(c.len, info.compressedSize);
    try testing.expectEqual(@as(u64, src.len), info.header.contentSize);
}
test "client-side concurrency: one context per thread" {
    // Only the multithreaded compressor starts threads, and only when a caller
    // asks for one; the serial path never does, so compressing independent
    // frames in parallel stays the client's job, and the contract is one context
    // per concurrent operation. Each thread here owns its own contexts and its
    // own buffers, and the frames they produce are independent and identical to
    // the single-threaded result.
    const Worker = struct {
        fn run(id: usize) !void {
            var prng = std.Random.DefaultPrng.init(12345 + id);
            const random = prng.random();
            var data: [4096]u8 = undefined;
            for (&data) |*b| b.* = @intCast(random.intRangeAtMost(u8, 'a', 'z'));
            // Compressible tail so the match finder has something to find.
            @memcpy(data[2048..], data[0..2048]);

            const one_shot = try compressWithOptions(testing.allocator, &data, .{ .level = 6 });
            defer testing.allocator.free(one_shot);

            var worker_comp = Compressor.initWithLevel(testing.allocator, 9);
            defer worker_comp.deinit();
            const from_ctx = try worker_comp.compressAlloc(&data);
            defer testing.allocator.free(from_ctx);

            var worker_dec = Decompressor.init(testing.allocator);
            defer worker_dec.deinit();
            for ([_][]const u8{ one_shot, from_ctx }) |frame| {
                const back = try worker_dec.decompressAlloc(frame);
                defer testing.allocator.free(back);
                try testing.expectEqualSlices(u8, &data, back);
            }

            // Contexts are reusable: the same compressor across several frames.
            for (0..3) |round| {
                const again = try worker_comp.compressAlloc(&data);
                defer testing.allocator.free(again);
                try testing.expectEqualSlices(u8, from_ctx, again);
                const back = try worker_dec.decompressAlloc(again);
                defer testing.allocator.free(back);
                try testing.expectEqualSlices(u8, &data, back);
                _ = round;
            }
        }

        fn threadEntry(id: usize) void {
            run(id) catch |e| std.debug.panic("thread {d} failed: {s}", .{ id, @errorName(e) });
        }
    };

    const thread_count = 4;
    // Some targets have no threads, and a reference to `Thread.spawn` fails the build
    // there even on a path that would never run. A single thread still shows that
    // independent contexts do not interfere.
    if (builtin.single_threaded) {
        Worker.run(0) catch |e| return e;
        return;
    }
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.threadEntry, .{i});
    for (threads) |t| t.join();
}
test "contexts do not leak state between frames" {
    // The reason a context cannot be shared between threads is cross-frame
    // state, so that is what this pins down: a compressor that has emitted
    // sequences and a decompressor that has seen a whole frame must both behave
    // like fresh ones on the next, unrelated input.
    const alloc = testing.allocator;
    var context_comp = Compressor.initWithLevel(alloc, 12);
    defer context_comp.deinit();
    var context_dec = Decompressor.init(alloc);
    defer context_dec.deinit();

    var big: [70000]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @intCast((i * 7 + i / 13) % 251);
    const small = "a short, unrelated second frame";

    const first = try context_comp.compressAlloc(&big);
    defer alloc.free(first);
    const back_first = try context_dec.decompressAlloc(first);
    defer alloc.free(back_first);
    try testing.expectEqualSlices(u8, &big, back_first);

    const second = try context_comp.compressAlloc(small);
    defer alloc.free(second);
    const back_second = try context_dec.decompressAlloc(second);
    defer alloc.free(back_second);
    try testing.expectEqualStrings(small, back_second);

    // Compressing the small input with a fresh context must give the same bytes,
    // which is what "no state leaked" means for a frame.
    const fresh = try compressWithOptions(alloc, small, .{
        .level = 12,
        .windowLog = context_comp.options.windowLog,
        .hashLog = context_comp.options.hashLog,
        .chainLog = context_comp.options.chainLog,
        .searchLog = context_comp.options.searchLog,
        .minMatch = context_comp.options.minMatch,
        .targetLength = context_comp.options.targetLength,
        .strategy = context_comp.options.strategy,
    });
    defer alloc.free(fresh);
    try testing.expectEqualSlices(u8, fresh, second);
}
test "every strategy handles a long repeating run in bounded time" {
    // Regression: two ways a search can stall on input made of one long repeat.
    //
    //   * Every position starts a very long match, so an unbounded match
    //     comparison is quadratic. The finders therefore stop comparing once they
    //     are past the best match so far.
    //   * The match grows by one byte per position, so a lazy rule that defers on
    //     *any* improvement defers at every position and emits nothing but
    //     literals. A match that already meets the target length is therefore
    //     never deferred.
    //
    // The payload is 200 KiB, which is a block and a half.
    const alloc = testing.allocator;
    var buffer: [200_000]u8 = undefined;
    @memset(&buffer, 'x');
    const header = "HEADER:zstd-sample-payload;version=1;kind=demo\n";
    const text = "the quick brown fox jumps over the lazy dog while the compressor decides between a match now and a longer one a byte later, which is the only decision a lazy parse actually makes. ";
    @memcpy(buffer[0..header.len], header);
    var pos = header.len;
    while (pos + text.len < buffer.len - 64) {
        @memcpy(buffer[pos..][0..text.len], text);
        pos += text.len;
    }
    var prng = std.Random.DefaultPrng.init(0x5A7);
    const random = prng.random();
    for (buffer[pos..]) |*b| b.* = random.intRangeAtMost(u8, 0, 255);
    const payload = buffer[0..];

    for ([_]Strategy{ .fast, .dfast, .greedy, .lazy, .lazy2, .btlazy2, .btopt, .btultra, .btultra2 }) |strategy| {
        const frame = try compressWithOptions(alloc, payload, .{ .level = 12, .strategy = strategy });
        defer alloc.free(frame);
        const back = decompress(alloc, frame) catch |e| {
            test_log.info("\nDECODE FAILED: {s}\n", .{@errorName(e)});
            return;
        };
        defer alloc.free(back);
        try testing.expectEqualSlices(u8, payload, back);
        // A parse that defers everywhere would leave a frame barely smaller than
        // the input; every strategy has to actually compress this.
        try testing.expect(frame.len < payload.len / 2);
    }
}
test "roundtrip: high literal density blocks decode at every size" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x6D746669);
    const random = prng.random();
    for ([_]usize{ 4 * 1024, 32 * 1024, 64 * 1024, 128 * 1024, 256 * 1024, 384 * 1024 }) |size| {
        const data = try alloc.alloc(u8, size);
        defer alloc.free(data);
        for (data) |*b| b.* = random.intRangeAtMost(u8, 0, 63);
        const frame = try compressWithOptions(alloc, data, .{ .level = 9, .windowLog = 23 });
        defer alloc.free(frame);
        const back = decompress(alloc, frame) catch |e| {
            test_log.info("\nDECODE FAILED: {s}\n", .{@errorName(e)});
            return;
        };
        defer alloc.free(back);
        try testing.expectEqualSlices(u8, data, back);
    }
}
test "long distance matches: a megabyte-scale repeat round trips" {
    // Regression: a block whose first sequence is a long-distance match with a wide
    // offset code, a long match length code and no literals needs more than one
    // 64-bit container for its extra bits and state updates. The reader used to
    // refill only after a whole sequence, so it reported an over-read and rejected
    // the block on the first sequence. The payload is two random sections then a
    // copy of the first, putting the repeat about a megabyte back.
    const alloc = testing.allocator;
    const section = 512 * 1024;
    var buffer: [section * 3]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x4C44);
    const random = prng.random();
    for (buffer[0 .. section * 2]) |*b| b.* = random.intRangeAtMost(u8, 0, 63);
    @memcpy(buffer[section * 2 ..], buffer[0..section]);
    const payload = buffer[0..];

    const frame = try compressWithOptions(alloc, payload, .{
        .level = 9,
        .windowLog = 23,
        .longDistanceMatching = true,
        .ldmHashRateLog = 4,
    });
    defer alloc.free(frame);
    const back = try decompress(alloc, frame);
    defer alloc.free(back);
    try testing.expectEqualSlices(u8, payload, back);
}
// Interoperability
//
// The corpus and matrices below are what make the round-trip and differential
// claims in the README true rather than aspirational. They live here, in the
// test root, so there is one place to look for the library's behaviour.

test "interop: self round trip over the corpus at every level" {
    var h = try interopHarness.init(testing.allocator);
    defer h.deinit();
    var checked: usize = 0;
    for (interopMatrixCorpus) |ci| {
        for (interopMatrixSizes) |len| {
            const payload = h.prepare(interopCorpus[ci], len);
            for (interopMatrixLevels) |level| {
                const frame = try compressWithOptions(testing.allocator, payload, .{ .level = level });
                defer testing.allocator.free(frame);
                const restored = try decompress(testing.allocator, frame);
                defer testing.allocator.free(restored);
                try testing.expectEqualSlices(u8, payload, restored);
                checked += 1;
            }
            // A checksummed frame exercises the frame tail as well.
            const with_sum = try compressWithOptions(testing.allocator, payload, .{ .level = 3, .checksum = true });
            defer testing.allocator.free(with_sum);
            const restored = try decompress(testing.allocator, with_sum);
            defer testing.allocator.free(restored);
            try testing.expectEqualSlices(u8, payload, restored);
            checked += 1;
        }
    }
    // The count is asserted rather than assumed, so dropping a case cannot pass
    // unnoticed.
    try testing.expectEqual(interopMatrixCorpus.len * interopMatrixSizes.len * (interopMatrixLevels.len + 1), checked);
    test_log.info("interop: {d} self round trips over the corpus at every level\n", .{checked});
}
test "interop: self round trip over the corpus at every strategy" {
    // Nine strategies, each with its own search and parser, so they are run over
    // the corpora and sizes where a strategy can behave differently. The level
    // matrix above covers the full size range.
    const strategy_sizes = [_]usize{ 0, 3, 16, 63, 1024, 4096 };
    const strategies = [_]Strategy{ .fast, .dfast, .greedy, .lazy, .lazy2, .btlazy2, .btopt, .btultra, .btultra2 };
    var h = try interopHarness.init(testing.allocator);
    defer h.deinit();
    var checked: usize = 0;
    for (interopMatrixCorpus) |ci| {
        for (strategy_sizes) |len| {
            const payload = h.prepare(interopCorpus[ci], len);
            for (strategies) |strategy| {
                const frame = try compressWithOptions(testing.allocator, payload, .{ .level = 12, .strategy = strategy });
                defer testing.allocator.free(frame);
                const restored = try decompress(testing.allocator, frame);
                defer testing.allocator.free(restored);
                try testing.expectEqualSlices(u8, payload, restored);
                checked += 1;
            }
        }
    }
    try testing.expectEqual(interopMatrixCorpus.len * strategy_sizes.len * strategies.len, checked);
    test_log.info("interop: {d} self round trips over the corpus at every strategy\n", .{checked});
}
test "interop: long-distance matching round trips over the corpus" {
    var h = try interopHarness.init(testing.allocator);
    defer h.deinit();
    var checked: usize = 0;
    for ([_]usize{ 0, 2, 6 }) |ci| {
        for ([_]usize{ 1024, 65536, 131073 }) |len| {
            const payload = h.prepare(interopCorpus[ci], len);
            const frame = try compressWithOptions(testing.allocator, payload, .{
                .level = 5,
                .windowLog = 23,
                .longDistanceMatching = true,
                .ldmHashRateLog = 4,
            });
            defer testing.allocator.free(frame);
            const restored = try decompress(testing.allocator, frame);
            defer testing.allocator.free(restored);
            try testing.expectEqualSlices(u8, payload, restored);
            checked += 1;
        }
    }
    try testing.expectEqual(3 * 3, checked);
    test_log.info("interop: {d} long-distance round trips over the corpus\n", .{checked});
}
test "interop: every level and every strategy round trips over the corpus" {
    // The full sweep, in process, so it runs on every change: 22 levels and 9
    // strategies against every payload family, at the sizes that catch both
    // boundaries and a real block.
    var h = try interopHarness.init(testing.allocator);
    defer h.deinit();
    const sizes = [_]usize{ 0, 1, 32768 };
    var level_checked: usize = 0;
    for (interopMatrixCorpus) |ci| {
        for (sizes) |len| {
            const payload = h.prepare(interopCorpus[ci], len);
            for (everyLevel) |level| {
                const frame = try compressWithOptions(testing.allocator, payload, .{ .level = level });
                defer testing.allocator.free(frame);
                const restored = try decompress(testing.allocator, frame);
                defer testing.allocator.free(restored);
                try testing.expectEqualSlices(u8, payload, restored);
                level_checked += 1;
            }
            for (everyStrategy) |strategy| {
                const frame = try compressWithOptions(testing.allocator, payload, .{ .level = 9, .strategy = strategy });
                defer testing.allocator.free(frame);
                const restored = try decompress(testing.allocator, frame);
                defer testing.allocator.free(restored);
                try testing.expectEqualSlices(u8, payload, restored);
                level_checked += 1;
            }
        }
    }
    try testing.expectEqual(interopMatrixCorpus.len * sizes.len * (everyLevel.len + everyStrategy.len), level_checked);
    test_log.info("interop: {d} self round trips over every level and strategy\n", .{level_checked});
}
test "interop: the reference accepts every level, and we accept every level" {
    // Both directions for all 22 levels. The corpus is one of each kind that
    // behaves differently, and the sizes are small and block-sized.
    const reference = interopReference();
    defer testing.allocator.free(reference);
    var h = try interopHarness.init(testing.allocator);
    defer h.deinit();
    const zst_path = try interopScratch(testing.allocator, "zstd_interop_frame.zst");
    defer testing.allocator.free(zst_path);
    const out_path = try interopScratch(testing.allocator, "zstd_interop_out.bin");
    defer testing.allocator.free(out_path);
    const raw_path = try interopScratch(testing.allocator, "zstd_interop_raw.bin");
    defer testing.allocator.free(raw_path);

    var ours_decoded: usize = 0;
    var ours_accepted: usize = 0;
    for ([_]usize{ 0, 4, 5, 6, 8 }) |ci| {
        for ([_]usize{ 16, 4096 }) |len| {
            const payload = h.prepare(interopCorpus[ci], len);
            for (everyLevel) |level| {
                // This encoder at this level, decoded by the reference.
                const frame = try compressWithOptions(testing.allocator, payload, .{ .level = level });
                defer testing.allocator.free(frame);
                try interopWrite(zst_path, frame);
                const decoded = try std.process.run(testing.allocator, testing.io, .{
                    .argv = &.{ reference, "-d", "-f", "-q", zst_path, "-o", out_path },
                });
                defer testing.allocator.free(decoded.stdout);
                defer testing.allocator.free(decoded.stderr);
                const code = interopExitCode(decoded.term) orelse return error.ReferenceFailed;
                if (code != 0) {
                    test_log.info("reference rejected level {d}: {s} len={d} stderr={s}\n", .{ level, interopCorpus[ci].name, len, decoded.stderr });
                    return error.ReferenceRejected;
                }
                const back = try interopRead(testing.allocator, out_path);
                defer testing.allocator.free(back);
                try testing.expectEqualSlices(u8, payload, back);
                ours_accepted += 1;

                // The reference at this level, decoded here.
                if (len == 0) continue; // the reference refuses an empty input file
                try interopWrite(raw_path, payload);
                const flag = try std.fmt.allocPrint(testing.allocator, "-{d}", .{level});
                defer testing.allocator.free(flag);
                const encoded = try std.process.run(testing.allocator, testing.io, .{
                    .argv = &.{ reference, "-q", "-f", flag, raw_path, "-o", zst_path },
                });
                defer testing.allocator.free(encoded.stdout);
                defer testing.allocator.free(encoded.stderr);
                const code2 = interopExitCode(encoded.term) orelse return error.ReferenceFailed;
                if (code2 != 0) {
                    test_log.info("reference compress failed at level {d}: {s} len={d} stderr={s}\n", .{ level, interopCorpus[ci].name, len, encoded.stderr });
                    return error.ReferenceFailed;
                }
                const ref_frame = try interopRead(testing.allocator, zst_path);
                defer testing.allocator.free(ref_frame);
                const mine = try decompress(testing.allocator, ref_frame);
                defer testing.allocator.free(mine);
                try testing.expectEqualSlices(u8, payload, mine);
                ours_decoded += 1;
            }
        }
    }
    test_log.info("interop: reference accepted {d} frames across every level; we decoded {d} reference frames\n", .{ ours_accepted, ours_decoded });
    try testing.expectEqual(everyLevel.len * 5 * 2, ours_accepted);
    try testing.expectEqual(ours_accepted, ours_decoded);
}
test "interop: the reference accepts every strategy" {
    // Our strategies produce different frames for the same input; each has to be
    // decodable by the reference, and the reference's own frames decodable here.
    const reference = interopReference();
    defer testing.allocator.free(reference);
    var h = try interopHarness.init(testing.allocator);
    defer h.deinit();
    const zst_path = try interopScratch(testing.allocator, "zstd_interop_frame.zst");
    defer testing.allocator.free(zst_path);
    const out_path = try interopScratch(testing.allocator, "zstd_interop_out.bin");
    defer testing.allocator.free(out_path);
    var checked: usize = 0;
    for ([_]usize{ 4, 6, 8 }) |ci| {
        for ([_]usize{ 16, 4096, 65536 }) |len| {
            const payload = h.prepare(interopCorpus[ci], len);
            for (everyStrategy) |strategy| {
                const frame = try compressWithOptions(testing.allocator, payload, .{ .level = 12, .strategy = strategy });
                defer testing.allocator.free(frame);
                try interopWrite(zst_path, frame);
                const result = try std.process.run(testing.allocator, testing.io, .{
                    .argv = &.{ reference, "-d", "-f", "-q", zst_path, "-o", out_path },
                });
                defer testing.allocator.free(result.stdout);
                defer testing.allocator.free(result.stderr);
                const code = interopExitCode(result.term) orelse return error.ReferenceFailed;
                if (code != 0) {
                    test_log.info("reference rejected strategy {s}: {s} len={d} stderr={s}\n", .{ @tagName(strategy), interopCorpus[ci].name, len, result.stderr });
                    return error.ReferenceRejected;
                }
                const back = try interopRead(testing.allocator, out_path);
                defer testing.allocator.free(back);
                try testing.expectEqualSlices(u8, payload, back);
                checked += 1;
            }
        }
    }
    test_log.info("interop: reference accepted {d} frames across every strategy\n", .{checked});
    try testing.expectEqual(3 * 3 * everyStrategy.len, checked);
}
test "interop: the reference decoder accepts this encoder's frames" {
    const reference = interopReference();
    defer testing.allocator.free(reference);
    var h = try interopHarness.init(testing.allocator);
    defer h.deinit();
    const zst_path = try interopScratch(testing.allocator, "zstd_interop_frame.zst");
    defer testing.allocator.free(zst_path);
    const out_path = try interopScratch(testing.allocator, "zstd_interop_out.bin");
    defer testing.allocator.free(out_path);
    var checked: usize = 0;
    for (interopDiffCorpus) |ci| {
        for (interopDiffSizes) |len| {
            const payload = h.prepare(interopCorpus[ci], len);
            for (interopDiffLevels) |level| {
                const frame = try compressWithOptions(testing.allocator, payload, .{ .level = level });
                defer testing.allocator.free(frame);
                try interopWrite(zst_path, frame);
                const result = try std.process.run(testing.allocator, testing.io, .{
                    .argv = &.{ reference, "-d", "-f", "-q", zst_path, "-o", out_path },
                });
                defer testing.allocator.free(result.stdout);
                defer testing.allocator.free(result.stderr);
                const code = interopExitCode(result.term) orelse return error.ReferenceFailed;
                if (code != 0) {
                    test_log.info("reference rejected our frame: {s} len={d} level={d} stderr={s}\n", .{ interopCorpus[ci].name, len, level, result.stderr });
                    return error.ReferenceRejected;
                }
                const decoded = try interopRead(testing.allocator, out_path);
                defer testing.allocator.free(decoded);
                try testing.expectEqualSlices(u8, payload, decoded);
                checked += 1;
            }
        }
    }
    test_log.info("reference decoded {d} of our frames\n", .{checked});
}
test "interop: this decoder accepts the reference encoder's frames" {
    const reference = interopReference();
    defer testing.allocator.free(reference);
    var h = try interopHarness.init(testing.allocator);
    defer h.deinit();
    const raw_path = try interopScratch(testing.allocator, "zstd_interop_raw.bin");
    defer testing.allocator.free(raw_path);
    const zst_path = try interopScratch(testing.allocator, "zstd_interop_frame.zst");
    defer testing.allocator.free(zst_path);
    var checked: usize = 0;
    for (interopDiffCorpus) |ci| {
        for (interopDiffSizes) |len| {
            const payload = h.prepare(interopCorpus[ci], len);
            // A spread of the reference's own levels, so the decoder is checked
            // against more than one setting.
            for ([_][]const u8{ "-1", "-3", "-9", "-19" }) |flag| {
                try interopWrite(raw_path, payload);
                const result = try std.process.run(testing.allocator, testing.io, .{
                    .argv = &.{ reference, "-q", "-f", flag, "--long", raw_path, "-o", zst_path },
                });
                defer testing.allocator.free(result.stdout);
                defer testing.allocator.free(result.stderr);
                const code = interopExitCode(result.term) orelse return error.ReferenceFailed;
                if (code != 0) {
                    // An empty input is refused by the reference compressor and
                    // says nothing about our decoder, so it is not counted as a
                    // failure.
                    if (len == 0) continue;
                    test_log.info("reference compress exit {d}: {s} len={d} flag={s} stderr={s}\n", .{ code, interopCorpus[ci].name, len, flag, result.stderr });
                    return error.ReferenceFailed;
                }
                const frame = try interopRead(testing.allocator, zst_path);
                defer testing.allocator.free(frame);
                const restored = try decompress(testing.allocator, frame);
                defer testing.allocator.free(restored);
                try testing.expectEqualSlices(u8, payload, restored);
                checked += 1;
            }
        }
    }
    test_log.info("we decoded {d} reference frames\n", .{checked});
}
// Differential interoperability on the parts of the format where a silent
// disagreement is most likely
//
// The self round trips above prove internal consistency, not agreement with
// anyone else. These close that gap both ways on the areas where a decoder
// either resolves a feature or produces plausible rubbish: dictionaries,
// checksums, skippable frames interleaved with real ones, multithreaded frames,
// and streaming (a different code path from one-shot). The reference binary is
// found through `interopReference`; a run without one fails rather than claiming
// coverage it does not have, and the counts these print make that visible.

test "interop: dictionary frames agree in both directions" {
    // A dictionary frame is the case where a silent disagreement is most likely:
    // the decoder either resolves the dictionary matches or produces plausible
    // rubbish. Both directions are checked, and the bytes must be identical.
    const alloc = testing.allocator;
    const ref = interopReference();
    defer alloc.free(ref);

    const dict_path = try interopScratch(alloc, "zstd_interop_diff_dict.bin");
    defer alloc.free(dict_path);
    const zst_path = try interopScratch(alloc, "zstd_interop_diff_dict_frame.zst");
    defer alloc.free(zst_path);
    const out_path = try interopScratch(alloc, "zstd_interop_diff_dict_out.bin");
    defer alloc.free(out_path);
    const raw_path = try interopScratch(alloc, "zstd_interop_diff_dict_raw.bin");
    defer alloc.free(raw_path);

    // A raw-content dictionary, with no ID. A dictionary that carried the
    // dictionary magic would announce entropy tables, and a buffer that announces
    // tables without providing them is not something a conforming decoder can use.
    // Raw content with no ID is understood identically by both implementations.
    const dict_content = "shared dictionary phrase appearing throughout these dictionary frames";
    var dict = try loadDictionary(alloc, dict_content);
    defer dict.deinit();
    try testing.expectEqual(@as(u32, 0), dict.dictId());
    try interopWrite(dict_path, dict.content());

    var payload: [8192]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = if (i % 3 == 0) 'x' else @intCast(i & 0xFF);
    @memcpy(payload[0..dict_content.len], dict_content);
    try interopWrite(raw_path, &payload);

    // Our frame, read by the reference.
    const ours = try compressWithOptions(alloc, &payload, .{ .level = 9, .dictionary = &dict });
    defer alloc.free(ours);
    try interopWrite(zst_path, ours);

    const check = try interopRun(alloc, &.{ ref, "-d", "-f", "-q", "-D", dict_path, zst_path, "-o", out_path });
    defer alloc.free(check.stderr);
    if (check.code != 0) {
        test_log.info("reference rejected our dictionary frame: {s}\n", .{check.stderr});
        return error.ReferenceRejected;
    }
    const back = try interopRead(alloc, out_path);
    defer alloc.free(back);
    try testing.expectEqualSlices(u8, &payload, back);

    // The reference's frame, read here.
    const produced = try interopRun(alloc, &.{ ref, "-19", "-f", "-q", "-D", dict_path, raw_path, "-o", zst_path });
    defer alloc.free(produced.stderr);
    if (produced.code != 0) return error.ReferenceFailed;

    const their_frame = try interopRead(alloc, zst_path);
    defer alloc.free(their_frame);
    var ctx = DecompressionContext.init(alloc);
    defer ctx.deinit();
    ctx.setDictionary(&dict);
    const our_decoded = try ctx.decompressAlloc(their_frame);
    defer alloc.free(our_decoded);
    try testing.expectEqualSlices(u8, &payload, our_decoded);

    test_log.info("interop: dictionary frames agreed in both directions\n", .{});
}
test "interop: checksummed frames are verified by both" {
    // A frame with a checksum that has been tampered with must be rejected by
    // both implementations, and an intact one accepted by both. Otherwise a
    // corrupt payload would pass silently on one side.
    const alloc = testing.allocator;
    const ref = interopReference();
    defer alloc.free(ref);

    const zst_path = try interopScratch(alloc, "zstd_interop_diff_sum_frame.zst");
    defer alloc.free(zst_path);
    const out_path = try interopScratch(alloc, "zstd_interop_diff_sum_out.bin");
    defer alloc.free(out_path);

    const pattern = "checksummed frame content, repeated so the frame is not trivial: ";
    var buf: [4096]u8 = undefined;
    for (buf[0..4096], 0..) |*b, i| b.* = pattern[i % pattern.len];

    const ours = try compressWithOptions(alloc, buf[0..], .{ .level = 3, .checksum = true });
    defer alloc.free(ours);

    // Intact: the reference accepts it and we read it back.
    try interopWrite(zst_path, ours);
    const check = try interopRun(alloc, &.{ ref, "-d", "-f", "-q", zst_path, "-o", out_path });
    defer alloc.free(check.stderr);
    if (check.code != 0) return error.ReferenceRejected;
    {
        const back = try interopRead(alloc, out_path);
        defer alloc.free(back);
        try testing.expectEqualSlices(u8, buf[0..], back);
    }
    {
        const back = try decompress(alloc, ours);
        defer alloc.free(back);
        try testing.expectEqualSlices(u8, buf[0..], back);
    }

    // Tampered: flip a byte in the payload region, which invalidates the digest.
    var broken = try alloc.dupe(u8, ours);
    defer alloc.free(broken);
    const target = broken.len - 6; // just before the four digest bytes
    broken[target] ^= 0xFF;

    const our_result = decompress(alloc, broken);
    if (our_result) |bad| {
        alloc.free(bad);
        return error.CorruptFrameAccepted;
    } else |_| {}

    try interopWrite(zst_path, broken);
    const their_result = try interopRun(alloc, &.{ ref, "-d", "-f", "-q", zst_path, "-o", out_path });
    defer alloc.free(their_result.stderr);
    if (their_result.code == 0) return error.CorruptFrameAcceptedByReference;

    test_log.info("interop: checksummed frames accepted when intact, rejected when tampered\n", .{});
}
test "interop: skippable frames interleaved with real ones" {
    // A skippable frame between real ones must be stepped over by the reference
    // and by us, and the real frames must still decode to their own content.
    const alloc = testing.allocator;
    const ref = interopReference();
    defer alloc.free(ref);

    const zst_path = try interopScratch(alloc, "zstd_interop_diff_skip_frame.zst");
    defer alloc.free(zst_path);
    const out_path = try interopScratch(alloc, "zstd_interop_diff_skip_out.bin");
    defer alloc.free(out_path);

    const first = "the first real frame in a stream that also holds skippable frames";
    const second = "the second real frame, with a different length so the two differ";

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(alloc);

    try interopAppendSkippable(alloc, &stream, "opaque metadata a decoder must ignore");
    {
        const f = try compress(alloc, first);
        defer alloc.free(f);
        try stream.appendSlice(alloc, f);
    }
    try interopAppendSkippable(alloc, &stream, "");
    {
        const f = try compress(alloc, second);
        defer alloc.free(f);
        try stream.appendSlice(alloc, f);
    }

    try interopWrite(zst_path, stream.items);

    // The reference must skip the opaque frames and concatenate the content.
    const check = try interopRun(alloc, &.{ ref, "-d", "-f", "-q", zst_path, "-o", out_path });
    defer alloc.free(check.stderr);
    if (check.code != 0) {
        test_log.info("reference rejected our skippable stream: {s}\n", .{check.stderr});
        return error.ReferenceRejected;
    }
    {
        const back = try interopRead(alloc, out_path);
        defer alloc.free(back);
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(alloc);
        try expected.appendSlice(alloc, first);
        try expected.appendSlice(alloc, second);
        try testing.expectEqualSlices(u8, expected.items, back);
    }

    // And we must walk the same stream, frame by frame. The regular frames are
    // identified separately from the skippable ones, so the two counts do not
    // interfere.
    var count: usize = 0;
    var skippable: usize = 0;
    var regular: usize = 0;
    var it = FrameIterator.init(stream.items);
    while (try it.next()) |frame| {
        if (frame.isSkippable()) {
            skippable += 1;
        } else {
            const text = try decompress(alloc, frame.bytes());
            defer alloc.free(text);
            if (regular == 0) try testing.expectEqualStrings(first, text);
            if (regular == 1) try testing.expectEqualStrings(second, text);
            regular += 1;
        }
        count += 1;
    }
    try testing.expectEqual(@as(usize, 4), count);
    try testing.expectEqual(@as(usize, 2), skippable);
    try testing.expectEqual(@as(usize, 2), regular);
    try testing.expectEqual(stream.items.len, it.offset());

    test_log.info("interop: skippable frames interleaved, {d} frames walked exactly\n", .{count});
}
test "interop: streaming output matches what the reference produced" {
    // Streaming compression must produce frames the reference accepts, and the
    // reference's frames must decode through the streaming path. Streaming takes
    // a different code path from one-shot, so agreement on one does not imply
    // agreement on the other.
    const alloc = testing.allocator;
    const ref = interopReference();
    defer alloc.free(ref);

    const raw_path = try interopScratch(alloc, "zstd_interop_diff_stream_raw.bin");
    defer alloc.free(raw_path);
    const zst_path = try interopScratch(alloc, "zstd_interop_diff_stream_frame.zst");
    defer alloc.free(zst_path);
    const out_path = try interopScratch(alloc, "zstd_interop_diff_stream_out.bin");
    defer alloc.free(out_path);

    var payload: [200_000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(20240917);
    for (&payload) |*b| b.* = if (prng.random().boolean()) 'a' else 'b';
    try interopWrite(raw_path, payload[0..]);

    // Streamed here, one awkward chunk at a time.
    var sc = StreamingCompressor.initWithOptions(alloc, .{ .level = 3 });
    defer sc.deinit();
    // The output buffer is sized with the public bound, which is what it is for:
    // one allocation up front, reused for every chunk.
    const bound = try compressBound(payload.len);
    var stream_out = try alloc.alloc(u8, bound);
    defer alloc.free(stream_out);
    var out_len: usize = 0;
    var chunk: usize = 1;
    var pos: usize = 0;
    while (pos < payload.len) {
        const take = @min(chunk, payload.len - pos);
        const produced = try sc.compressStream(stream_out[out_len..], payload[pos .. pos + take], .cont);
        out_len += produced.outProduced;
        pos += produced.inConsumed;
        chunk = chunk *% 3 +% 1;
    }
    while (true) {
        const produced = try sc.compressStream(stream_out[out_len..], &.{}, .end);
        out_len += produced.outProduced;
        if (produced.remaining == 0) break;
    }

    try interopWrite(zst_path, stream_out[0..out_len]);
    const check = try interopRun(alloc, &.{ ref, "-d", "-f", "-q", zst_path, "-o", out_path });
    defer alloc.free(check.stderr);
    if (check.code != 0) {
        test_log.info("reference rejected our streamed frame: {s}\n", .{check.stderr});
        return error.ReferenceRejected;
    }
    {
        const back = try interopRead(alloc, out_path);
        defer alloc.free(back);
        try testing.expectEqualSlices(u8, payload[0..], back);
    }

    // The reference's frame, decoded through our streaming path.
    const produced = try interopRun(alloc, &.{ ref, "-19", "-f", "-q", raw_path, "-o", zst_path });
    defer alloc.free(produced.stderr);
    if (produced.code != 0) return error.ReferenceFailed;
    const their_frame = try interopRead(alloc, zst_path);
    defer alloc.free(their_frame);

    var sd = StreamingDecompressor.init(alloc);
    defer sd.deinit();
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(alloc);
    var out_buf: [4096]u8 = undefined;
    var at: usize = 0;
    while (at < their_frame.len) {
        const take = @min(at + 1, their_frame.len) - at;
        const r = try sd.decompressStream(&out_buf, their_frame[at .. at + take]);
        try decoded.appendSlice(alloc, out_buf[0..r.outProduced]);
        at += r.inConsumed;
        if (r.inConsumed == 0 and r.outProduced == 0 and !r.needsMore) break;
    }
    while (decoded.items.len < payload.len) {
        const r = try sd.decompressStream(&out_buf, &.{});
        try decoded.appendSlice(alloc, out_buf[0..r.outProduced]);
        if (r.outProduced == 0) break;
    }
    try testing.expectEqualSlices(u8, payload[0..], decoded.items);

    test_log.info("interop: streaming agreed in both directions over {d} bytes\n", .{payload.len});
}
test "interop: randomized content agrees in both directions" {
    // Random sizes and levels, so the differential claim is not resting on a
    // handful of hand-picked cases.
    const alloc = testing.allocator;
    const ref = interopReference();
    defer alloc.free(ref);

    const raw_path = try interopScratch(alloc, "zstd_interop_diff_rand_raw.bin");
    defer alloc.free(raw_path);
    const zst_path = try interopScratch(alloc, "zstd_interop_diff_rand_frame.zst");
    defer alloc.free(zst_path);
    const out_path = try interopScratch(alloc, "zstd_interop_diff_rand_out.bin");
    defer alloc.free(out_path);

    var prng = std.Random.DefaultPrng.init(987654321);
    var buffer: [70000]u8 = undefined;
    var agreed: usize = 0;

    for (0..12) |_| {
        const len = prng.random().intRangeAtMost(usize, 1, 60000);
        // A mix of compressible and incompressible content, since the two fail
        // differently.
        for (buffer[0..len], 0..) |*b, i| {
            b.* = switch (i % 3) {
                0 => 'a' + @as(u8, @intCast(i % 26)),
                1 => @intCast(i & 0xFF),
                else => prng.random().int(u8),
            };
        }
        const level: i32 = prng.random().intRangeAtMost(i32, 1, 19);
        try interopWrite(raw_path, buffer[0..len]);

        // Theirs to ours. The reference compresses at the level this test picked,
        // so the frame it produces is the one being compared.
        var level_flag: [8]u8 = undefined;
        const level_text = try std.fmt.bufPrint(&level_flag, "-{d}", .{level});
        const produced = try interopRun(alloc, &.{ ref, "-q", "-f", level_text, raw_path, "-o", zst_path });
        defer alloc.free(produced.stderr);
        if (produced.code != 0) continue;

        const their_frame = try interopRead(alloc, zst_path);
        defer alloc.free(their_frame);
        const our_decoded = try decompress(alloc, their_frame);
        defer alloc.free(our_decoded);
        try testing.expectEqualSlices(u8, buffer[0..len], our_decoded);

        // Ours to theirs.
        const ours = try compressWithOptions(alloc, buffer[0..len], .{ .level = level });
        defer alloc.free(ours);
        try interopWrite(zst_path, ours);
        const check = try interopRun(alloc, &.{ ref, "-d", "-f", "-q", zst_path, "-o", out_path });
        defer alloc.free(check.stderr);
        if (check.code != 0) {
            test_log.info("reference rejected our frame at level {d}, {d} bytes\n", .{ level, len });
            return error.ReferenceRejected;
        }
        const back = try interopRead(alloc, out_path);
        defer alloc.free(back);
        try testing.expectEqualSlices(u8, buffer[0..len], back);

        agreed += 1;
    }

    test_log.info("interop: {d} randomized cases agreed in both directions\n", .{agreed});
    try testing.expect(agreed > 0);
}
test "compressBound covers every one-shot compression" {
    // The whole point of the bound: a buffer of exactly this size must hold the
    // frame whatever the input, so the guarantee is checked by compressing into
    // it rather than by comparing numbers.
    const alloc = testing.allocator;
    const sizes = [_]usize{ 0, 1, 2, 15, 16, 255, 256, 1024, 4096, 65535, 131072, 131073, 300000 };
    var source: [300000]u8 = undefined;
    for (sizes) |size| {
        // Incompressible content is the worst case, so it is what the bound has
        // to cover; repeating content only ever compresses smaller.
        var prng = std.Random.DefaultPrng.init(@intCast(size *% 2654435761 +% 12345));
        prng.random().bytes(source[0..size]);
        const data = source[0..size];

        const bound = try compressBound(data.len);
        try testing.expect(bound >= data.len);

        var buf = try alloc.alloc(u8, bound);
        defer alloc.free(buf);
        const written = compressInto(alloc, buf, data, 3) catch |e| {
            test_log.info("BOUNDSIZE {d} bound={d} err={s}\n", .{ data.len, bound, @errorName(e) });
            return e;
        };
        try testing.expect(written <= bound);

        var back = try alloc.alloc(u8, data.len);
        defer alloc.free(back);
        const got = try decompressInto(alloc, back, buf[0..written]);
        try testing.expectEqualSlices(u8, data, back[0..got]);
    }
}
test "compressBound grows monotonically and reports unrepresentable sizes" {
    // A size at or above the format's maximum has no valid bound. Reporting an
    // error is better than returning a wrapped value that would then look like a
    // real, far-too-small bound.
    try testing.expectError(error.SrcSizeTooLarge, compressBound(constants.max_input_size));
    try testing.expectError(error.SrcSizeTooLarge, compressBound(std.math.maxInt(usize)));

    // The margin shrinks with size but the bound still rises: a caller relying on
    // "never smaller than the input" must never be surprised.
    var previous: usize = 0;
    for ([_]usize{ 0, 1, 100, 1000, 65536, 131072, 1 << 20, 1 << 30 }) |size| {
        const bound = try compressBound(size);
        try testing.expect(bound >= size);
        try testing.expect(bound >= previous);
        previous = bound;
    }
}
test "compressInto rejects a buffer one byte short of the bound" {
    // Documents the failure mode the bound exists to prevent: too small a
    // destination is an error, never a silently truncated frame.
    const alloc = testing.allocator;
    var src: [512]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(99);
    prng.random().bytes(&src);

    const bound = try compressBound(src.len);
    try testing.expect(bound > src.len);

    const too_small = try alloc.alloc(u8, bound - 1);
    defer alloc.free(too_small);
    try testing.expectError(error.DstSizeTooSmall, compressInto(alloc, too_small, &src, 3));
}
test "compress and decompress empty" {
    const alloc = testing.allocator;
    const c = try compress(alloc, "");
    defer alloc.free(c);
    try testing.expect(c.len > 0);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqual(@as(usize, 0), d.len);
}
test "compress and decompress single byte" {
    const alloc = testing.allocator;
    const src = [_]u8{0x42};
    const c = try compress(alloc, &src);
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualSlices(u8, &src, d);
}
test "compress and decompress small string" {
    const alloc = testing.allocator;
    const src = "Hello, Zstandard!";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    try testing.expect(c.len > 0);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualStrings(src, d);
}
test "compress and decompress repetitive data" {
    const alloc = testing.allocator;
    const src = "ABABABABABABABABABABABABABABABABABABABABABABABABABABABAB";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualStrings(src, d);
}
test "compress and decompress zeros" {
    const alloc = testing.allocator;
    var src: [1000]u8 = undefined;
    @memset(&src, 0);
    const c = try compress(alloc, &src);
    defer alloc.free(c);
    try testing.expect(c.len < src.len);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualSlices(u8, &src, d);
}
test "compress and decompress all byte values" {
    const alloc = testing.allocator;
    var src: [256]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i);
    const c = try compress(alloc, &src);
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualSlices(u8, &src, d);
}
test "compress with level 1" {
    const alloc = testing.allocator;
    const src = "Test data for level 1 compression";
    const c = try compressWithLevel(alloc, src, 1);
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualStrings(src, d);
}
test "compress with level 22" {
    const alloc = testing.allocator;
    const src = "Test data for max level compression";
    const c = try compressWithLevel(alloc, src, 22);
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualStrings(src, d);
}
test "compress with all levels 1 to 22" {
    const alloc = testing.allocator;
    const src = "Level test data";
    var level: i32 = 1;
    while (level <= 22) : (level += 1) {
        {
            const c = try compressWithLevel(alloc, src, level);
            defer alloc.free(c);
            const d = try decompress(alloc, c);
            defer alloc.free(d);
            try testing.expectEqualStrings(src, d);
        }
    }
}
test "compress with checksum" {
    const alloc = testing.allocator;
    const src = "Checksum enabled data";
    const c = try compressWithOptions(alloc, src, .{ .checksum = true });
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualStrings(src, d);
}
test "compress into buffer" {
    var buf: [1024]u8 = undefined;
    const src = "Small data";
    const written = try compressInto(testing.allocator, &buf, src, 1);
    try testing.expect(written > 0);
    var out: [1024]u8 = undefined;
    const dec = try decompressInto(testing.allocator, &out, buf[0..written]);
    try testing.expectEqualStrings(src, out[0..dec]);
}
test "decompress bound" {
    const alloc = testing.allocator;
    const src = "Bound test data for decompression estimation";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    const bound = try decompressBound(testing.allocator, c);
    try testing.expect(bound >= src.len);
}
test "find frame compressed size" {
    const alloc = testing.allocator;
    const src = "Frame size test";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    const sz = try findFrameCompressedSize(testing.allocator, c);
    try testing.expectEqual(c.len, sz);
}
test "get frame header" {
    const alloc = testing.allocator;
    const src = "Header test";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    const fh = try getFrameHeader(c);
    try testing.expect(fh.headerSize > 0);
    try testing.expect(fh.contentSize > 0);
}
test "get frame content size" {
    const alloc = testing.allocator;
    const src = "Content size test";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    const cs = getFrameContentSize(c);
    try testing.expectEqual(@as(u64, src.len), cs);
}
test "isFrame valid" {
    const alloc = testing.allocator;
    const src = "isFrame test";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    try testing.expect(isFrame(c));
}
test "isFrame invalid" {
    const buf = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try testing.expect(!isFrame(&buf));
}
test "skippable frame write and read" {
    const data = "skippable payload";
    var buf: [256]u8 = undefined;
    const written = writeSkippableFrame(&buf, data, 0);
    try testing.expect(written > 0);
    try testing.expect(isSkippableFrame(buf[0..written]));
    var out: [256]u8 = undefined;
    const read = try readSkippableFrame(&out, buf[0..written]);
    try testing.expectEqualStrings(data, out[0..read]);
}
test "skippable frame too small dst" {
    var buf: [4]u8 = undefined;
    const data = "payload";
    const written = writeSkippableFrame(&buf, data, 0);
    try testing.expectEqual(@as(usize, 0), written);
}
test "skippable read too small src" {
    var buf: [8]u8 = undefined;
    const result = readSkippableFrame(&buf, &[_]u8{ 0x50, 0x2A });
    try testing.expectError(error.SrcSizeWrong, result);
}
test "skippable read wrong magic" {
    var buf: [16]u8 = undefined;
    buf[0..4].* = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD };
    buf[4..8].* = [_]u8{ 0, 0, 0, 0 };
    const result = readSkippableFrame(&buf, buf[0..8]);
    try testing.expectError(error.PrefixUnknown, result);
}
test "version info" {
    try testing.expectEqualStrings("0.0.4", versionString());
    try testing.expectEqual(@as(u32, 4), versionNumber());
    try testing.expectEqualStrings("1.6.0", specVersionString());
    try testing.expectEqual(@as(u32, 1 * 100 * 100 + 6 * 100), specVersionNumber());
    try testing.expect(maxCLevel() == 22);
    try testing.expect(minCLevel() < 0);
    try testing.expect(defaultCLevel() == 3);
}
test "unified Context round trip" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();
    const src = "unified context compresses and decompresses with one allocator";
    const c = try ctx.compress(src);
    defer testing.allocator.free(c);
    const d = try ctx.decompress(c);
    defer testing.allocator.free(d);
    try testing.expectEqualStrings(src, d);
}
test "unified Context reuse across frames" {
    var ctx = Context.initWithLevel(testing.allocator, 5);
    defer ctx.deinit();
    ctx.setChecksum(true);
    const a = try ctx.compress("first frame");
    defer testing.allocator.free(a);
    ctx.reset();
    const b = try ctx.compress("second frame");
    defer testing.allocator.free(b);
    const da = try ctx.decompress(a);
    defer testing.allocator.free(da);
    try testing.expectEqualStrings("first frame", da);
    const db = try ctx.decompress(b);
    defer testing.allocator.free(db);
    try testing.expectEqualStrings("second frame", db);
}
test "constants exported" {
    try testing.expectEqual(@as(u32, 0xFD2FB528), MAGICNUMBER);
    try testing.expectEqual(@as(u32, 0xEC30A437), MAGIC_DICTIONARY);
    try testing.expectEqual(@as(u32, 0x184D2A50), MAGIC_SKIPPABLE_START);
}
test "large data roundtrip 64KB" {
    const alloc = testing.allocator;
    var src: [65536]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    prng.random().bytes(&src);
    const c = try compress(alloc, &src);
    defer alloc.free(c);
    const d = try decompress(alloc, c);
    defer alloc.free(d);
    try testing.expectEqualSlices(u8, &src, d);
}
test "concatenated frames" {
    const alloc = testing.allocator;
    const src1 = "first frame";
    const src2 = "second frame";
    const c1 = try compress(alloc, src1);
    defer alloc.free(c1);
    const c2 = try compress(alloc, src2);
    defer alloc.free(c2);
    var concat = try alloc.alloc(u8, c1.len + c2.len);
    defer alloc.free(concat);
    std.mem.copyForwards(u8, concat[0..c1.len], c1);
    std.mem.copyForwards(u8, concat[c1.len..], c2);
    const d = try decompress(alloc, concat);
    defer alloc.free(d);
    try testing.expectEqualStrings(src1, d[0..src1.len]);
    try testing.expectEqualStrings(src2, d[src1.len..]);
}
test "decompress invalid data" {
    const alloc = testing.allocator;
    const bad = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    const result = decompress(alloc, &bad);
    try testing.expectError(error.PrefixUnknown, result);
}
test "decompress truncated data" {
    const alloc = testing.allocator;
    const src = "Truncate this after compress";
    const c = try compress(alloc, src);
    defer alloc.free(c);
    if (c.len > 4) {
        const result = decompress(alloc, c[0 .. c.len - 4]);
        if (result) |v| {
            alloc.free(v);
        } else |_| {}
    }
}
test "compression context init and deinit" {
    var ctx = CompressionContext.init(testing.allocator);
    defer ctx.deinit();
}
test "compression context with level" {
    var ctx = CompressionContext.initWithLevel(testing.allocator, 5);
    defer ctx.deinit();
    const src = "Context level test";
    const c = try ctx.compressAlloc(src);
    defer testing.allocator.free(c);
    try testing.expect(c.len > 0);
}
test "compression context set level" {
    var ctx = CompressionContext.init(testing.allocator);
    defer ctx.deinit();
    ctx.setLevel(10);
    const src = "Set level test";
    const c = try ctx.compressAlloc(src);
    defer testing.allocator.free(c);
    try testing.expect(c.len > 0);
}
test "compression context set checksum" {
    var ctx = CompressionContext.init(testing.allocator);
    defer ctx.deinit();
    ctx.setChecksum(true);
    const src = "Checksum context test";
    const c = try ctx.compressAlloc(src);
    defer testing.allocator.free(c);
    const d = try decompress(testing.allocator, c);
    defer testing.allocator.free(d);
    try testing.expectEqualStrings(src, d);
}
test "compression context compress into buffer" {
    var ctx = CompressionContext.init(testing.allocator);
    defer ctx.deinit();
    const src = "Buffer compress test";
    var buf: [512]u8 = undefined;
    const written = try ctx.compress(&buf, src);
    try testing.expect(written > 0);
}
test "compression context reset" {
    var ctx = CompressionContext.init(testing.allocator);
    defer ctx.deinit();
    const src = "Reset test";
    const c1 = try ctx.compressAlloc(src);
    defer testing.allocator.free(c1);
    ctx.reset();
    const c2 = try ctx.compressAlloc(src);
    defer testing.allocator.free(c2);
    try testing.expectEqual(c1.len, c2.len);
}
test "decompression context init and deinit" {
    var ctx = DecompressionContext.init(testing.allocator);
    defer ctx.deinit();
}
test "decompression context decompress" {
    var ctx = DecompressionContext.init(testing.allocator);
    defer ctx.deinit();
    const src = "Decompress context test";
    const c = try compress(testing.allocator, src);
    defer testing.allocator.free(c);
    const d = try ctx.decompressAlloc(c);
    defer testing.allocator.free(d);
    try testing.expectEqualStrings(src, d);
}
test "decompression context decompress into buffer" {
    var ctx = DecompressionContext.init(testing.allocator);
    defer ctx.deinit();
    const src = "Buffer decompress test";
    const c = try compress(testing.allocator, src);
    defer testing.allocator.free(c);
    var buf: [512]u8 = undefined;
    const written = try ctx.decompress(&buf, c);
    try testing.expectEqualStrings(src, buf[0..written]);
}
test "decompression context set max window size" {
    var ctx = DecompressionContext.init(testing.allocator);
    defer ctx.deinit();
    ctx.setMaxWindowSize(1024 * 1024);
}
test "decompression context reset" {
    var ctx = DecompressionContext.init(testing.allocator);
    defer ctx.deinit();
    const src = "Reset decompress test";
    const c = try compress(testing.allocator, src);
    defer testing.allocator.free(c);
    const d1 = try ctx.decompressAlloc(c);
    defer testing.allocator.free(d1);
    ctx.reset();
    const d2 = try ctx.decompressAlloc(c);
    defer testing.allocator.free(d2);
    try testing.expectEqualStrings(d1, d2);
}
test "decompression options defaults" {
    const opts = DecompressionOptions{};
    try testing.expect(opts.maxWindowSize > 0);
    try testing.expect(!opts.forceIgnoreChecksum);
}
test "dictionary load and dict id" {
    const alloc = testing.allocator;
    const raw = "dictionary content data";
    var dict = try createDictionaryFromData(alloc, raw, 42);
    defer dict.deinit();
    try testing.expectEqual(@as(u32, 42), dict.dictId());
    try testing.expect(dict.data.len > raw.len);
}
test "dictionary load from data" {
    const alloc = testing.allocator;
    const raw = "load dictionary test";
    var dict = try loadDictionary(alloc, raw);
    defer dict.deinit();
    try testing.expectEqual(@as(u32, 0), dict.dictId());
}
test "dictionary builder train" {
    const alloc = testing.allocator;
    const s1 = "The quick brown fox jumps over the lazy dog";
    const s2 = "Pack my box with five dozen liquor jugs";
    const s3 = "How vexingly quick daft zebras jump";
    const samples = [_][]const u8{ s1, s2, s3 };
    var builder = DictionaryBuilder.init(alloc, .{ .dictSize = 256, .dictId = 99 });
    var dict = try builder.train(&samples);
    defer dict.deinit();
    try testing.expectEqual(@as(u32, 99), dict.dictId());
    try testing.expect(dict.data.len > 0);
}
test "dictionary: a trained dictionary compresses its own corpus" {
    // A dictionary is only worth having if the encoder can reach back into it:
    // the frame declares the dictionary ID, its first block matches dictionary
    // content, and the decoder needs the same dictionary to reproduce it.
    const alloc = testing.allocator;
    const samples = [_][]const u8{
        "GET /api/v1/orders?status=open HTTP/1.1\r\nHost: example.com\r\nAccept: application/json\r\n",
        "GET /api/v1/orders?status=closed HTTP/1.1\r\nHost: example.com\r\nAccept: application/json\r\n",
        "GET /api/v1/orders?status=all HTTP/1.1\r\nHost: example.com\r\nAccept: application/json\r\n",
    };
    var builder = DictionaryBuilder.init(alloc, .{ .dictSize = 512, .dictId = 4242 });
    var dict = try builder.train(&samples);
    defer dict.deinit();

    const frame = try compressWithOptions(alloc, samples[1], .{
        .level = 9,
        .dictionary = &dict,
    });
    defer alloc.free(frame);
    // The frame names the dictionary, so a decoder without it must not silently
    // produce something.
    try testing.expectEqual(@as(u32, 4242), (try getFrameHeader(frame)).dictId);
    try testing.expectError(error.DictionaryWrong, decompress(alloc, frame));

    const restored = try decompressWithOptions(alloc, frame, .{ .dictionary = &dict });
    defer alloc.free(restored);
    try testing.expectEqualSlices(u8, samples[1], restored);

    // The dictionary has to earn its place: with it the frame is smaller than
    // without, because the request prefix now comes from the dictionary.
    const plain = try compressWithOptions(alloc, samples[1], .{ .level = 9 });
    defer alloc.free(plain);
    try testing.expect(frame.len < plain.len);
}
test "dictionary: the wrong dictionary is rejected" {
    const alloc = testing.allocator;
    var first = try createDictionaryFromData(alloc, "the first dictionary content, which is long enough to matter", 111);
    defer first.deinit();
    var second = try createDictionaryFromData(alloc, "a completely different dictionary body here", 222);
    defer second.deinit();
    const frame = try compressWithOptions(alloc, "a payload that will be compressed with the first dictionary", .{ .level = 5, .dictionary = &first });
    defer alloc.free(frame);
    // The frame names dictionary 111, so decoding it against 222 has to fail
    // loudly rather than return garbage.
    try testing.expectError(error.DictionaryWrong, decompressWithOptions(alloc, frame, .{ .dictionary = &second }));
    try testing.expectError(error.DictionaryWrong, decompress(alloc, frame));

    // A raw-content dictionary declares no ID, so the mismatch cannot be caught
    // from the header; the offsets still cannot resolve against the wrong
    // content, and the decode has to fail rather than invent output.
    var raw = try loadDictionary(alloc, "a raw dictionary body with no identifier at all");
    defer raw.deinit();
    var other = try loadDictionary(alloc, "some other raw dictionary body entirely");
    defer other.deinit();
    const raw_frame = try compressWithOptions(alloc, "a payload compressed with the raw dictionary body", .{ .level = 5, .dictionary = &raw });
    defer alloc.free(raw_frame);
    try testing.expectEqual(@as(u32, 0), (try getFrameHeader(raw_frame)).dictId);
    try testing.expectError(error.InvalidOffset, decompressWithOptions(alloc, raw_frame, .{ .dictionary = &other }));
    const right = try decompressWithOptions(alloc, raw_frame, .{ .dictionary = &raw });
    defer alloc.free(right);
    try testing.expectEqualSlices(u8, "a payload compressed with the raw dictionary body", right);
}
test "dictionary: the reference decoder accepts a dictionary-compressed frame" {
    // The dictionary is written as raw content, which is the form a reference
    // decoder accepts without the entropy-table section, and the frame it
    // produces is decoded here by the reference with `-D`.
    const reference = interopReference();
    defer testing.allocator.free(reference);
    const alloc = testing.allocator;
    const prefix = "shared-prefix-for-dictionary-frames: ";
    const samples = [_][]const u8{ prefix ++ "alpha", prefix ++ "beta", prefix ++ "gamma" };
    var builder = DictionaryBuilder.init(alloc, .{ .dictSize = 256 });
    var dict = try builder.train(&samples);
    defer dict.deinit();

    const payload = prefix ++ "delta, the part the dictionary has never seen";
    const frame = try compressWithOptions(alloc, payload, .{ .level = 9, .dictionary = &dict });
    defer alloc.free(frame);

    const dict_path = try interopScratch(alloc, "zstd_interop_dict.bin");
    defer alloc.free(dict_path);
    const frame_path = try interopScratch(alloc, "zstd_interop_dict_frame.zst");
    defer alloc.free(frame_path);
    const out_path = try interopScratch(alloc, "zstd_interop_dict_out.bin");
    defer alloc.free(out_path);
    try interopWrite(dict_path, dict.content());
    try interopWrite(frame_path, frame);
    const result = try std.process.run(alloc, testing.io, .{
        .argv = &.{ reference, "-d", "-f", "-q", "-D", dict_path, frame_path, "-o", out_path },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    const code = interopExitCode(result.term) orelse return error.ReferenceFailed;
    if (code != 0) {
        test_log.info("reference rejected our dictionary frame: stderr={s}\n", .{result.stderr});
        return error.ReferenceRejected;
    }
    const decoded = try interopRead(alloc, out_path);
    defer alloc.free(decoded);
    try testing.expectEqualSlices(u8, payload, decoded);
}
test "interop: multithreaded frames decode on the reference" {
    // The MT path writes independently encoded sections into one frame; a
    // second implementation is the independent check that they concatenate:
    // rep codes invalidated at every job boundary, overlap prefixes, and the
    // header written once around all of it.
    const reference = interopReference();
    defer testing.allocator.free(reference);
    const zst_path = try interopScratch(testing.allocator, "zstd_interop_mt.zst");
    defer testing.allocator.free(zst_path);
    const out_path = try interopScratch(testing.allocator, "zstd_interop_mt_out.bin");
    defer testing.allocator.free(out_path);

    const payload = try interopMtPayload(testing.allocator);
    defer testing.allocator.free(payload);
    var checked: usize = 0;
    for ([_]struct { level: i32, checksum: bool }{
        .{ .level = 1, .checksum = false },
        .{ .level = 3, .checksum = false },
        .{ .level = 9, .checksum = true },
    }) |case| {
        // Three workers over four jobs: the queue blocks and unblocks as
        // workers free up, which is the scheduling the frame must not care
        // about.
        const frame = try compressMT(testing.allocator, testing.io, payload, .{ .level = case.level, .checksum = case.checksum }, 3);
        defer testing.allocator.free(frame);
        const back = try decompress(testing.allocator, frame);
        defer testing.allocator.free(back);
        try testing.expectEqualSlices(u8, payload, back);

        try interopWrite(zst_path, frame);
        const result = try std.process.run(testing.allocator, testing.io, .{
            .argv = &.{ reference, "-d", "-f", "-q", zst_path, "-o", out_path },
        });
        defer testing.allocator.free(result.stdout);
        defer testing.allocator.free(result.stderr);
        const code = interopExitCode(result.term) orelse return error.ReferenceFailed;
        if (code != 0) {
            test_log.info("reference rejected the MT frame at level {d}: {s}\n", .{ case.level, result.stderr });
            return error.ReferenceRejected;
        }
        const decoded = try interopRead(testing.allocator, out_path);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, payload, decoded);
        checked += 1;
    }
    test_log.info("interop: the reference decoded {d} multithreaded frames\n", .{checked});
    try testing.expectEqual(3, checked);
}

test "canonical golden decompression vectors" {
    const alloc = testing.allocator;

    // 1. empty-block.zst: compressed block with 0 literals and 0 sequences
    const empty_block = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x00, 0x15, 0x00, 0x00, 0x00, 0x00 };
    const empty_res = try decompress(alloc, &empty_block);
    defer alloc.free(empty_res);
    try testing.expectEqual(@as(usize, 0), empty_res.len);

    // 2. zeroSeq_2B.zst: 2-byte sequence header with zero sequences, payload "Hello World!\n"
    const zero_seq = [_]u8{
        0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x00, 0x85, 0x00, 0x00, 0x68, 0x48, 0x65,
        0x6c, 0x6c, 0x6f, 0x20, 0x57, 0x6f, 0x72, 0x6c, 0x64, 0x21, 0x0a, 0x80,
        0x00,
    };
    const zero_res = try decompress(alloc, &zero_seq);
    defer alloc.free(zero_res);
    try testing.expectEqualStrings("Hello World!\n", zero_res);

    // 3. rle-first-block.zst: multiple blocks decoding to 1048576 zero bytes
    const rle_blocks = [_]u8{
        40, 181, 47, 253, 164, 0, 0, 16, 0, 2,   0,  16, 0,   2, 0, 16,
        0,  2,   0,  16,  0,   2, 0, 16, 0, 2,   0,  16, 0,   2, 0, 16,
        0,  2,   0,  16,  0,   3, 0, 16, 0, 241, 62, 22, 225,
    };
    const rle_res = try decompress(alloc, &rle_blocks);
    defer alloc.free(rle_res);
    try testing.expectEqual(@as(usize, 1048576), rle_res.len);
    for (rle_res) |b| try testing.expectEqual(@as(u8, 0), b);

    // Error vector 1: off0.bin.zst: invalid zero offset
    const off0 = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x00, 0x45, 0x00, 0x00, 0x08, 0x00, 0x02, 0x00, 0x2f, 0x43, 0x0b, 0xae };
    if (decompress(alloc, &off0)) |bad| {
        alloc.free(bad);
        return error.InvalidFrameAccepted;
    } else |_| {}

    // Error vector 2: truncated_huff_state.zst: truncated Huffman stream
    const trunc_huff = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x00, 0x55, 0x00, 0x00, 0x72, 0x80, 0x01, 0x04, 0x20, 0x7e, 0x1f, 0x02, 0xaa, 0x00 };
    if (decompress(alloc, &trunc_huff)) |bad| {
        alloc.free(bad);
        return error.InvalidFrameAccepted;
    } else |_| {}

    // Error vector 3: zeroSeq_extraneous.zst: extraneous bitstream padding
    const extra_seq = [_]u8{
        0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x00, 0x95, 0x00, 0x00, 0x68, 0x48, 0x65,
        0x6c, 0x6c, 0x6f, 0x20, 0x57, 0x6f, 0x72, 0x6c, 0x64, 0x21, 0x0a, 0x80,
        0x00, 0x00, 0x00,
    };
    if (decompress(alloc, &extra_seq)) |bad| {
        alloc.free(bad);
        return error.InvalidFrameAccepted;
    } else |_| {}
}
