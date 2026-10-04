//! One-shot compression entry points.
//!
//! `allocator` is the caller's: it backs the returned slice and all transient
//! scratch. Each call builds and frees its own working state, so a loop over
//! frames is better served by a context, which reuses that state.

const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const header_mod = @import("../frame/header.zig");
const checksum_mod = @import("../frame/checksum.zig");
const block_mod = @import("block.zig");
const ldm_mod = @import("ldm.zig");
const testing = std.testing;
const search_mod = @import("search.zig");
const dict_mod = @import("../dictionary/dictionary.zig");
const prepared_mod = @import("../dictionary/prepared.zig");

pub const CompressionOptions = struct {
    level: i32 = 3,
    windowLog: u8 = 0,
    hashLog: u8 = 0,
    chainLog: u8 = 0,
    searchLog: u8 = 0,
    minMatch: u8 = 0,
    targetLength: u32 = 0,
    strategy: constants.Strategy = .fast,
    checksum: bool = false,
    dictId: u32 = 0,
    /// Dictionary whose content the first block may match back into.
    dictionary: ?*const dict_mod.Dictionary = null,
    /// Prepared dictionary with pre-built entropy tables and content.
    preparedDictionary: ?*const prepared_mod.PreparedDictionary = null,
    contentSize: ?u64 = null,
    /// Long-distance matching enable flag.
    longDistanceMatching: bool = false,
    /// Log2 of long-distance table entries. 0 uses default based on level.
    ldmHashLog: u8 = 0,
    /// Log2 of entries per bucket. 0 uses default based on level.
    ldmBucketSizeLog: u8 = 0,
    /// Shortest match reported by long-distance matcher. 0 uses default.
    ldmMinMatch: u32 = 0,
    /// Log2 of rate for long-distance matching split points. 0 uses default.
    ldmHashRateLog: u8 = 0,
    /// Worker thread count for multithreaded compression. Default 0 is single-threaded.
    workers: usize = 0,
    /// Explicit target size per compression job in bytes. 0 uses default.
    jobSize: usize = 0,
    /// Overlap log controlling window fraction loaded into job prefix. 0 uses default.
    overlapLog: u8 = 0,
    /// Optional IO interface for worker pool synchronization.
    io: ?std.Io = null,

    /// The long-distance parameters these options ask for, with the zeros
    /// filled in from the level's parameters.
    pub fn ldmParams(self: CompressionOptions, window_log: u8) ldm_mod.Params {
        var params = ldm_mod.Params{
            .enabled = self.longDistanceMatching,
            .hashLog = self.ldmHashLog,
            .bucketSizeLog = self.ldmBucketSizeLog,
            .minMatchLength = self.ldmMinMatch,
            .hashRateLog = self.ldmHashRateLog,
        };
        if (params.enabled) params.adjust(window_log, self.strategy, self.hashLog);
        return params;
    }
};

/// Buffer size a one-shot compression of `src_size` bytes needs: the format's own
/// worst-case bound (input, per-block headers of incompressible data, frame header,
/// optional checksum). The same value the public `zstd.compressBound` reports, so
/// a buffer sized with that can be passed straight to `compressInto`. Used
/// internally to fail fast on a short buffer rather than mid-frame.
pub fn compressBound(src_size: usize) usize {
    return constants.compressBound(src_size);
}

/// Compresses `src` and returns an owned slice. The caller frees it with the
/// same `allocator`.
pub fn compress(allocator: std.mem.Allocator, src: []const u8, options: CompressionOptions) anyerror![]u8 {
    const bound = compressBound(src.len);
    const dst = try allocator.alloc(u8, bound);
    errdefer allocator.free(dst);
    const written = try compressInto(allocator, dst, src, options);
    if (written == dst.len) return dst;
    return try allocator.realloc(dst, written);
}

/// Compresses `src` into `dst`, which must hold at least
/// `compressBound(src.len)` bytes. `allocator` backs transient encoding
/// scratch only; nothing allocated from it escapes.
pub fn compressInto(allocator: std.mem.Allocator, dst: []u8, src: []const u8, options: CompressionOptions) errors.ZstdError!usize {
    if (dst.len < compressBound(src.len)) return error.DstSizeTooSmall;
    const plan = planFrame(options, src.len);
    const contentSize: ?u64 = options.contentSize orelse @as(?u64, src.len);
    // A dictionary identifies the frame, so its ID goes in the header unless the
    // caller asked for a specific one.
    const headerSize = header_mod.writeFrameHeader(dst[0..], contentSize, plan.window_size, plan.dict_id, options.checksum, plan.single_segment);
    var pos: usize = headerSize;

    // Long-distance matching runs once over the whole frame before any block is
    // encoded, because its table is the frame's memory of where its long
    // repeats are. The block parsers then treat the matches it found as
    // candidates, which is the only way a distance larger than one block can be
    // used.
    var ldm_state: ?ldm_mod.Ldm = null;
    defer if (ldm_state) |*l| l.deinit();
    if (plan.ldm.enabled and src.len > plan.ldm.minMatchLength) {
        ldm_state = try ldm_mod.Ldm.init(allocator, plan.ldm);
        // One pass over the input both records the split points and finds the
        // matches; a split point can only match something already passed, which
        // is exactly what a back-reference needs.
        try ldm_state.?.generateSequences(src, 0, src.len);
    }

    pos += try compressBodyInto(allocator, dst[pos..], src, options, &plan, .{
        .prefix = if (options.dictionary) |d| d.content() else &.{},
        .ldm = if (ldm_state) |*l| l else null,
    });

    if (options.checksum) {
        if (dst.len < pos + 4) return error.DstSizeTooSmall;
        const chk = checksum_mod.computeChecksum(src);
        checksum_mod.writeChecksum(dst[pos..], chk);
        pos += 4;
    }
    return pos;
}

/// Everything the frame's header and body agree on, derived once from the
/// options and the input length so the one-shot path and every multithreaded
/// job build the same frame: the declared window, single-segment flag, window
/// id, effective long-distance parameters, and the history bounds the block
/// finders respect.
pub const FramePlan = struct {
    single_segment: bool,
    window_size: u64,
    dict_id: u32,
    ldm: ldm_mod.Params,
    history_limit: usize,
    search_window: u32,
};

/// Derives the frame plan for a one-shot compression of `src_len` bytes.
pub fn planFrame(options: CompressionOptions, src_len: usize) FramePlan {
    // The window the frame will actually declare. A frame with a single segment
    // carries no window descriptor: its window is the whole content, which
    // always covers every distance an LDM match can use.
    const declared_window_size: u64 = if (options.windowLog != 0)
        @as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(options.windowLog))
    else if (src_len == 0)
        1024
    else
        @max(@as(u64, src_len), 1024);
    const single_segment = declared_window_size >= @as(u64, src_len) and src_len < 256 * 1024;
    const effective_window_size = if (single_segment)
        @max(declared_window_size, @as(u64, 1024))
    else
        declared_window_size;
    // Long-distance matching needs a window wide enough for a "long" distance,
    // so enabling it raises the window floor, and the LDM table is sized from
    // that same window: a distance the frame cannot hold is never written.
    const ldm_window_log: u8 = @intCast(@min(constants.window_log_max, 64 - @clz(@max(effective_window_size, @as(u64, 1) << @intCast(ldm_mod.min_window_log)))));
    const ldm_params = options.ldmParams(@max(if (options.windowLog != 0) options.windowLog else 0, if (options.longDistanceMatching) ldm_mod.min_window_log else 0));
    var ldm_effective = ldm_params;
    if (ldm_effective.enabled) ldm_effective.windowLog = ldm_window_log;
    const window_size: u64 = if (single_segment)
        @max(declared_window_size, @as(u64, 1024))
    else
        @max(declared_window_size, if (ldm_effective.enabled) @as(u64, 1) << @intCast(ldm_mod.min_window_log) else 0);
    const dict_id: u32 = if (options.dictId != 0) options.dictId else if (options.dictionary) |d| d.dictId() else 0;
    // The window this frame can reach, capped at 64 MiB. Everything here stays in
    // the target's own integer type: `window_size` is a `u64` because the frame
    // header carries a 64-bit value, and `log2_int` reports a `u64` too. Neither
    // fits the 32-bit `usize` these results are used as, so the narrowing happens
    // before the shift rather than after it.
    const window_log: u5 = @intCast(@min(
        @as(u64, constants.window_log_max),
        std.math.log2_int(usize, @as(usize, @intCast(@min(window_size, @as(u64, std.math.maxInt(usize)))))),
    ));
    const history_limit: usize = @min(@as(usize, 1) << window_log, 64 * 1024 * 1024);
    // A block can be larger than the window the frame declares, so the finder's
    // reach is bounded separately from the history buffer. Without this, a
    // small window plus a large block produces matches the frame header never
    // promised to describe, and the frame is then rejected by a conforming
    // decoder, this one included.
    const search_window: u32 = search_mod.windowLimitFor(@intCast(@min(
        @as(u64, constants.window_log_max),
        std.math.log2_int(usize, @as(usize, @intCast(@min(@max(window_size, 1024), @as(u64, std.math.maxInt(usize)))))),
    )));
    return .{
        .single_segment = single_segment,
        .window_size = window_size,
        .dict_id = dict_id,
        .ldm = ldm_effective,
        .history_limit = history_limit,
        .search_window = search_window,
    };
}

/// How one call to `compressBodyInto` continues from what came before it. The
/// serial one-shot path seeds the dictionary and marks its output as the whole
/// frame; a multithreaded job seeds the frame content its segment follows,
/// invalidates the repeat history it never encoded, and only the final job may
/// close the frame.
pub const BodyConfig = struct {
    /// Bytes immediately before `src` that sequences may reach into: the
    /// dictionary content for a frame's start, or the already-encoded frame
    /// content a multithreaded job continues from. The caller keeps it within
    /// the frame's window so every distance it enables is one the header
    /// declares.
    prefix: []const u8 = &.{},
    /// Begin with no usable repeat history, for a job that did not encode the
    /// blocks immediately before it (`RepHistory.invalidated`).
    invalidated_reps: bool = false,
    /// The frame's long-distance matches, generated once over the whole input;
    /// `null` disables long-distance matching for this call.
    ldm: ?*const ldm_mod.Ldm = null,
    /// Where `src[0]` sits in the whole frame. Long-distance matches are found
    /// and stored in frame coordinates, so a call that encodes only part of the
    /// frame (a multithreaded job) says where its slice starts; the one-shot
    /// path, whose `src` is the whole frame, leaves it at zero.
    ldm_frame_offset: usize = 0,
    /// Whether this call may mark its final block as the frame's last block.
    /// Only the call that ends the frame does; intermediate jobs leave every
    /// block open for the next one to continue.
    ends_frame: bool = true,
};

/// The block loop shared by the one-shot path and each multithreaded job:
/// writes the blocks covering `src` (no frame header, no checksum) and returns
/// how many bytes they took. `plan` and `options` must be the same values every
/// participating call was derived from, or the jobs would disagree about the
/// frame.
pub fn compressBodyInto(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
    options: CompressionOptions,
    plan: *const FramePlan,
    cfg: BodyConfig,
) errors.ZstdError!usize {
    // One entropy state for the call. The decoder carries repeat offsets and
    // the literals Huffman table across blocks, so the encoder must do the same
    // within what it encodes; a job starts its own because it never saw the
    // blocks before it.
    var entropy = block_mod.FrameEntropy{};
    if (cfg.invalidated_reps) entropy.reps = search_mod.RepHistory.invalidated();

    // Scratch for a block's long matches, so the parser never allocates for
    // them. LDM reports at most one match per split point, and a 128 KiB block
    // holds far fewer than that.
    const ldm_scratch_len: usize = 256;
    const ldm_scratch_storage = if (cfg.ldm != null)
        try allocator.alloc(search_mod.LongMatch, ldm_scratch_len)
    else
        &[_]search_mod.LongMatch{};
    defer if (ldm_scratch_storage.len > 0) allocator.free(ldm_scratch_storage);
    const ldm_scratch = ldm_scratch_storage;

    // What the next block's sequences may reach back into: the dictionary or
    // job prefix first, then this call's own recent output. The window the
    // frame declares bounds how much of it is kept, so a long frame does not
    // grow this without limit, and a distance that would exceed the window is
    // never written.
    var history: std.ArrayList(u8) = .empty;
    defer history.deinit(allocator);
    if (cfg.prefix.len > 0) try history.appendSlice(allocator, cfg.prefix);
    var window: block_mod.BlockWindow = .{};
    defer window.deinit(allocator);
    const block_config = block_mod.searchConfigFor(options.strategy, options.level);

    const blockMax = constants.block_size_max;
    var pos: usize = 0;
    var srcPos: usize = 0;
    while (srcPos < src.len) {
        const remaining = src.len - srcPos;
        const chunk = @min(remaining, blockMax);
        const is_last = cfg.ends_frame and (srcPos + chunk >= src.len);
        const written = try block_mod.compressBlockWithWindow(
            allocator,
            dst[pos..],
            src[srcPos .. srcPos + chunk],
            is_last,
            &entropy,
            &block_config,
            if (cfg.ldm) |l| l.ldmMatchesIn(cfg.ldm_frame_offset + srcPos, chunk, @constCast(ldm_scratch)) else null,
            history.items,
            &window,
            plan.search_window,
        );
        pos += written;
        srcPos += chunk;
        // The block just encoded joins the history the next one may reach into.
        if (history.items.len < plan.history_limit or history.items.len > 0) {
            try history.appendSlice(allocator, src[srcPos - chunk .. srcPos]);
            if (history.items.len > plan.history_limit) {
                const drop = history.items.len - plan.history_limit;
                std.mem.copyForwards(u8, history.items[0..plan.history_limit], history.items[drop..]);
                history.shrinkRetainingCapacity(plan.history_limit);
            }
        }
    }
    if (src.len == 0 and cfg.ends_frame) {
        const written = try block_mod.compressBlockWithStrategy(allocator, dst[0..], src, true, &entropy, options.strategy, options.level, null, history.items, &window);
        pos += written;
    }
    return pos;
}

/// Writes the frame tail (checksum) and returns the total size.
/// The parameters `level` implies, as a fully populated options struct.
pub fn getCompressionParameters(level: i32, src_size: usize, window_log: u8) CompressionOptions {
    const params = @import("parameters.zig").getParams(level, src_size, 0);
    var opts = CompressionOptions{
        .level = @max(constants.c_level_min, @min(constants.c_level_max, level)),
        .windowLog = params.windowLog,
        .hashLog = params.hashLog,
        .chainLog = params.chainLog,
        .searchLog = params.searchLog,
        .minMatch = params.minMatch,
        .targetLength = params.targetLength,
        .strategy = params.strategy,
    };
    if (window_log != 0) opts.windowLog = @max(constants.window_log_min, @min(constants.window_log_max, window_log));
    return opts;
}

test "compressBound returns value" {
    const b = compressBound(100);
    try testing.expect(b > 100);
}
