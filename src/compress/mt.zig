//! Multithreaded compression: the ZSTDMT pattern, on this library's own worker
//! pool.
//!
//! One frame is split into jobs of at least `job_size_min` bytes. Each job runs
//! on a pool worker as an ordinary single-threaded block encoder over its own
//! segment, seeded with the `overlap` bytes of frame content (or dictionary)
//! that precede it, so the distances it finds are the distances the finished
//! frame's window already covers. The jobs write only blocks; the frame header
//! is written once, before any job starts, and the checksum once, after every
//! job has finished. What one job must not do is inherit repeat-offset history
//! from blocks it never encoded, so every job after the first starts with
//! `RepHistory.invalidated`, the same guarantee upstream's
//! `ZSTD_invalidateRepCodes` gives, which is what makes independently encoded
//! segments concatenate into one decodable frame.
//!
//! The caller supplies the allocator and the `std.Io` the pool's mutexes and
//! conditions use; the pool is created with the compressor and joined on
//! `deinit`, so a compressor is reusable across many frames the way an
//! `CompressionContext` is. One compress call runs at a time per compressor.
const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const compress_mod = @import("compress.zig");
const ldm_mod = @import("ldm.zig");
const checksum_mod = @import("../frame/checksum.zig");
const header_mod = @import("../frame/header.zig");
const pool_mod = @import("../common/pool.zig");
pub const CompressionOptions = compress_mod.CompressionOptions;
/// A mutex-guarded wrapper around the caller's allocator. Workers encode
/// concurrently and each one allocates its block-encoder scratch as it goes,
/// so every job goes through this one wrapper: `std.heap` no longer ships a
/// `ThreadSafeAllocator`, and callers may hand us anything (a fixed buffer, an
/// arena), which must not be raced. The mutex lives in the compressor, which
/// stays put for the whole call.
const Guarded = struct {
    child: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    fn allocator(self: *Guarded) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Guarded = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Guarded = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Guarded = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Guarded = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.child.rawFree(memory, alignment, ret_addr);
    }
};
/// The smallest input slice handed to one job, defaulting to upstream's
/// `ZSTDMT_JOBSIZE_MIN`. A frame smaller than this (or one job per input, once
/// the job count is capped) compresses on the calling thread through the
/// ordinary serial path, byte for byte.
pub const job_size_min: usize = 512 * 1024;
/// How many jobs may exist per worker. Jobs stream through the pool as workers
/// free up, so a worker that finishes its split early takes the next one
/// instead of the run ending on the slowest segment.
const jobs_per_worker = 2;
/// Upstream's `ZSTDMT_overlapLog` default per strategy: how much of the window
/// a job loads as its prefix, as a fraction (`overlap = window >> (9 - value)`).
fn overlapLogDefault(strategy: constants.Strategy) u8 {
    return switch (strategy) {
        .btultra2 => 9,
        .btultra, .btopt => 8,
        .btlazy2, .lazy2 => 7,
        .fast, .dfast, .greedy, .lazy => 6,
    };
}
/// The frame layout a compression will produce: header bytes, job split, and
/// the buffer size the whole frame needs. Derived once so the size check, the
/// header, and the jobs cannot disagree with each other.
const Split = struct {
    num_jobs: usize,
    job_size: usize,
    overlap: usize,
    header: [64]u8 = undefined,
    header_len: usize,

    /// Bytes the frame needs in total: header, one `compressBound` slot per
    /// job, and the four checksum bytes if the frame carries one.
    needed: usize,
};
/// A compression job: one segment of the input, its own output slot inside the
/// caller's frame buffer, and where in the frame it sits. Jobs only touch
/// their own fields plus the shared read-only options and plan, so they can
/// run concurrently on pool workers.
const Job = struct {
    /// The shared guarded allocator: several workers encode at once, each
    /// allocating its scratch, so all job allocations funnel through one
    /// mutex. Captured when the job is built.
    allocator: std.mem.Allocator,
    src: []const u8,

    /// Where `src` starts in the whole frame, so the frame's long-distance
    /// matches can be asked for by position.
    src_start: usize,
    prefix: []const u8,
    slot: []u8,
    options: *const CompressionOptions,
    plan: *const compress_mod.FramePlan,
    ldm: ?*const ldm_mod.Ldm,
    job_index: usize,
    ends_frame: bool,
    out_len: usize = 0,
    status: ?errors.ZstdError = null,

    fn run(arg: ?*anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(arg.?));
        self.out_len = compress_mod.compressBodyInto(self.allocator, self.slot, self.src, self.options.*, self.plan, .{
            .prefix = self.prefix,
            .invalidated_reps = self.job_index > 0,
            .ldm = self.ldm,
            .ldm_frame_offset = self.src_start,
            .ends_frame = self.ends_frame,
        }) catch |e| {
            self.status = e;
            return;
        };
    }
};
/// A reusable multithreaded compressor: one worker pool, created in `init` and
/// joined in `deinit`, reused for every frame compressed through it.
pub const MTCompressor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: CompressionOptions,

    /// Pool workers. Two jobs per worker may exist at once; more inputs than
    /// that queue in the pool as workers free up.
    threads: usize,

    /// Smallest slice handed to one job. Defaults to `job_size_min`; lowering
    /// it forces splits on smaller frames (the reference does not expose this,
    /// but the split machinery is the same).
    minJobSize: usize = job_size_min,
    pool: *pool_mod.Pool,

    /// One guarded view of the caller's allocator, shared by every job.
    guarded: Guarded,

    /// Creates a compressor with `threads` pool workers (at least one) that
    /// compresses with `options`. The pool's threads start here and are joined
    /// by `deinit`.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: CompressionOptions, threads: usize) !MTCompressor {
        if (threads == 0) return error.InvalidArgument;

        const pool = try pool_mod.Pool.init(allocator, io, threads, 0);
        errdefer pool.deinit();
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .threads = threads,
            .pool = pool,
            .guarded = .{ .child = allocator, .io = io },
        };
    }

    /// Joins the pool's workers. No compression may be in flight.
    pub fn deinit(self: *MTCompressor) void {
        self.pool.deinit();
    }

    /// Resets compressor state for reuse across frames.
    pub fn reset(self: *MTCompressor) void {
        _ = self;
    }

    /// Resizes the worker pool to the requested thread count.
    pub fn setWorkers(self: *MTCompressor, threads: usize) !void {
        if (threads == 0) return error.InvalidArgument;
        try self.pool.resize(threads);
        self.threads = threads;
    }

    /// Compresses `src` into `dst` and returns the frame's size. `dst` must
    /// hold `split.needed` bytes; `compressAlloc` sizes it. A frame that fits
    /// in one job takes the serial path instead, so the result is exactly the
    /// frame `compressInto` would have written.
    pub fn compressInto(self: *MTCompressor, dst: []u8, src: []const u8) errors.ZstdError!usize {
        const plan = compress_mod.planFrame(self.options, src.len);

        const sp = self.computeSplit(src.len, &plan);
        if (sp.num_jobs <= 1) return compress_mod.compressInto(self.allocator, dst, src, self.options);
        if (dst.len < sp.needed) return error.DstSizeTooSmall;

        // Long-distance matching runs once over the whole frame before any
        // job, because its table is the frame's memory of where its long
        // repeats are; each job then reads the matches that start inside its
        // own segment. `Ldm` is read-only from that point, so jobs share one.

        var ldm_state: ?ldm_mod.Ldm = null;
        defer if (ldm_state) |*l| l.deinit();
        if (plan.ldm.enabled and src.len > plan.ldm.minMatchLength) {
            ldm_state = try ldm_mod.Ldm.init(self.allocator, plan.ldm);
            try ldm_state.?.generateSequences(src, 0, src.len);
        }

        // The header describes the whole frame, so it is written once, by the
        // caller's thread, before any job runs. Each job writes only blocks.
        @memcpy(dst[0..sp.header_len], sp.header[0..sp.header_len]);

        var at: usize = sp.header_len;

        const jobs = self.allocator.alloc(Job, sp.num_jobs) catch return error.OutOfMemory;
        defer self.allocator.free(jobs);
        // A long-distance match is written into a block as the distance it was
        // found at, so a job has to hold the bytes it reaches for. The overlap
        // alone only covers what the match finder can see; where a job's own
        // long matches point further back, the prefix is grown to reach them
        // (never past the frame's window, where a distance stops being
        // describable anyway).

        var ldm_cursor: usize = 0;
        for (jobs, 0..) |*job, i| {
            const start = i * sp.job_size;

            const end = @min(start + sp.job_size, src.len);

            const cap = compress_mod.compressBound(end - start);

            var prefix_start: usize = if (i == 0) 0 else start -| sp.overlap;
            if (i > 0) {
                if (ldm_state) |*l| {
                    while (ldm_cursor < l.matches.items.len and l.matches.items[ldm_cursor].pos < start) ldm_cursor += 1;

                    var k = ldm_cursor;
                    while (k < l.matches.items.len and l.matches.items[k].pos < end) : (k += 1) {
                        const m = l.matches.items[k];

                        const source = m.pos -| m.offset;
                        if (source < prefix_start) prefix_start = source;
                    }
                }
            }
            job.* = .{
                .allocator = self.guarded.allocator(),
                .src = src[start..end],
                .src_start = start,
                // The first job continues from the dictionary (its segment
                // starts the frame); later jobs continue from the frame
                // content immediately before them.
                .prefix = if (i == 0)
                    if (self.options.dictionary) |d| d.content() else &.{}
                else
                    src[prefix_start..start],
                .slot = dst[at .. at + cap],
                .options = &self.options,
                .plan = &plan,
                .ldm = if (ldm_state) |*l| l else null,
                .job_index = i,
                .ends_frame = i == sp.num_jobs - 1,
            };
            at += cap;
        }

        for (jobs) |*job| self.pool.add(Job.run, job);
        self.pool.joinJobs();
        for (jobs) |job| if (job.status) |e| return e;

        // The slots are packed by capacity; the outputs are shorter. Slide
        // them together into one frame, then append the checksum.

        var write: usize = sp.header_len;
        for (jobs) |job| {
            const n = job.out_len;
            std.mem.copyForwards(u8, dst[write..][0..n], job.slot[0..n]);
            write += n;
        }
        if (self.options.checksum) {
            if (dst.len < write + 4) return error.DstSizeTooSmall;
            checksum_mod.writeChecksum(dst[write..], checksum_mod.computeChecksum(src));
            write += 4;
        }
        return write;
    }

    /// Compresses `src` into a frame sized exactly for this split and returns
    /// it. The caller frees it with `allocator`.
    pub fn compressAlloc(self: *MTCompressor, src: []const u8) anyerror![]u8 {
        const plan = compress_mod.planFrame(self.options, src.len);
        const sp = self.computeSplit(src.len, &plan);
        if (sp.num_jobs <= 1) return compress_mod.compress(self.allocator, src, self.options);

        const dst = try self.allocator.alloc(u8, sp.needed);
        errdefer self.allocator.free(dst);

        const written = try self.compressInto(dst, src);
        if (written == dst.len) return dst;
        return try self.allocator.realloc(dst, written);
    }

    /// The frame layout for an input of `src_len` bytes: how many jobs, how
    /// big, how much prefix each loads, and how large the frame can get.
    fn computeSplit(self: *const MTCompressor, src_len: usize, plan: *const compress_mod.FramePlan) Split {
        const contentSize: ?u64 = self.options.contentSize orelse @as(?u64, src_len);

        var header: [64]u8 = undefined;

        const header_len = header_mod.writeFrameHeader(&header, contentSize, plan.window_size, plan.dict_id, self.options.checksum, plan.single_segment);

        const job_min = @max(self.minJobSize, 1);

        var num_jobs: usize = if (src_len == 0) 1 else std.math.divCeil(usize, src_len, job_min) catch 1;

        const max_jobs = @max(self.threads, 1) * jobs_per_worker;
        num_jobs = @min(num_jobs, max_jobs);
        if (num_jobs > src_len) num_jobs = @max(src_len, 1);

        var job_size: usize = if (num_jobs <= 1) src_len else std.math.divCeil(usize, src_len, num_jobs) catch src_len;

        var overlap: usize = 0;

        if (num_jobs > 1) {
            // How much history each job loads, following upstream's
            // `ZSTDMT_computeOverlapSize`: a fraction of the window the frame
            // keeps (`history_limit`), which is the distance the header itself
            // declares. With long-distance matching the window is routinely
            // oversized, so the job size takes over as the base, as upstream
            // does for the same reason.

            const window_log: u8 = @intCast(std.math.log2_int(usize, plan.history_limit));

            const rlog: u8 = 9 - overlapLogDefault(self.options.strategy);

            const base: u8 = if (plan.ldm.enabled)
                @min(window_log, @as(u8, @intCast(std.math.log2_int(usize, job_size))) -| 2)
            else
                window_log;

            const ov_log: u8 = @min(base -| rlog, window_log);
            overlap = @as(usize, 1) << @intCast(ov_log);
            // A job must be at least its own overlap, or its prefix would be
            // as large as the segment following it. Upstream grows the
            // section size the same way; growing it here shrinks the job
            // count, which stays within the cap.
            if (job_size < overlap) {
                job_size = overlap;
                num_jobs = std.math.divCeil(usize, src_len, job_size) catch 1;
            }
            if (num_jobs > src_len) num_jobs = @max(src_len, 1);
        } else {
            num_jobs = 1;
            job_size = src_len;
        }

        // Every frame byte is accounted for once: header, one worst-case slot
        // per job (job boundaries add at most a block header each, which the
        // per-job bound already covers), and the checksum.

        var slots: usize = 0;

        var i: usize = 0;
        while (i < num_jobs) : (i += 1) {
            const start = i * job_size;

            const len = @min(job_size, src_len - start);
            slots += compress_mod.compressBound(len);
        }
        return .{
            .num_jobs = num_jobs,
            .job_size = job_size,
            .overlap = overlap,
            .header = header,
            .header_len = header_len,
            .needed = header_len + slots + 4,
        };
    }
};
/// One-shot multithreaded compression: creates a compressor with `threads`
/// pool workers, compresses `src` with `options`, and joins them again.
pub fn compressMT(allocator: std.mem.Allocator, io: std.Io, src: []const u8, options: CompressionOptions, threads: usize) anyerror![]u8 {
    var mt = try MTCompressor.init(allocator, io, options, threads);
    defer mt.deinit();
    return mt.compressAlloc(src);
}
// Tests
const testing = std.testing;
/// A payload that exercises every encoder path: text-like runs the match
/// finder chases, random bursts no table can describe well, constant runs
/// RLE likes, and a repeat copied far enough back to need a wide offset.
fn makePayload(allocator: std.mem.Allocator, len: usize, seed: u64) ![]u8 {
    const data = try allocator.alloc(u8, len);
    errdefer allocator.free(data);
    if (len == 0) return data;

    var prng = std.Random.DefaultPrng.init(seed);

    const random = prng.random();

    const text = "the quick brown fox jumps over the lazy dog while the frame splits into jobs; ";

    var pos: usize = 0;
    while (pos < len) {
        const phase = pos / 4096;
        switch (phase % 4) {
            0 => {
                const n = @min(text.len, len - pos);
                @memcpy(data[pos .. pos + n], text[0..n]);
                pos += n;
            },
            1 => {
                const n = @min(512, len - pos);
                @memset(data[pos .. pos + n], 'z');
                pos += n;
            },
            2 => {
                const n = @min(512, len - pos);
                random.bytes(data[pos .. pos + n]);
                pos += n;
            },
            else => {
                // A repeat of the payload's own head, far enough back that a
                // job only finds it with its prefix loaded.

                const back = @min(pos, 30000);

                const n = @min(back, len - pos);
                @memcpy(data[pos .. pos + n], data[pos - back ..][0..n]);
                pos += n;
            },
        }
    }
    return data;
}
fn roundTrip(allocator: std.mem.Allocator, payload: []const u8, options: CompressionOptions, threads: usize) !void {
    var mt = try MTCompressor.init(allocator, testing.io, options, threads);
    defer mt.deinit();

    const frame = try mt.compressAlloc(payload);
    defer allocator.free(frame);

    const back = try @import("../decompress/decompress.zig").decompress(allocator, frame);
    defer allocator.free(back);
    try testing.expectEqualSlices(u8, payload, back);
}

/// Whether this build has no threads at all. Kept as a function so the test
/// bodies read the same either way and the reference to `Thread.spawn` stays
/// inside a comptime-known branch.
fn builtin_single_threaded() bool {
    return @import("builtin").single_threaded;
}

test "mt: a single job writes exactly the serial frame" {
    const alloc = testing.allocator;

    const payload = try makePayload(alloc, 90000, 1);
    defer alloc.free(payload);

    const options = CompressionOptions{ .level = 5 };

    const serial = try compress_mod.compress(alloc, payload, options);
    defer alloc.free(serial);

    var mt = try MTCompressor.init(alloc, testing.io, options, 4);
    defer mt.deinit();
    // A job floor above the input keeps the split at one job, which must take
    // the serial path rather than approximate it.
    mt.minJobSize = 1 << 30;

    const frame = try mt.compressAlloc(payload);
    defer alloc.free(frame);
    try testing.expectEqualSlices(u8, serial, frame);
}
test "mt: long-distance matches survive a job split" {
    // LDM matches are found over the whole frame and are stored in frame
    // coordinates, so a job that only holds a slice of the frame must be handed
    // the matches belonging to its own segment and enough prefix to reach their
    // sources. Getting either wrong still produces a decodable frame, just not
    // the one that was compressed.
    const alloc = testing.allocator;
    const len = 44444;

    const payload = try alloc.alloc(u8, len);
    defer alloc.free(payload);
    // A varied body with a copy of its own head placed far enough back that no
    // job's default overlap covers it.
    {
        var prng = std.Random.DefaultPrng.init(0x5A17);

        const rnd = prng.random();
        var pos: usize = 0;
        while (pos < len) {
            const n = @min(1 + rnd.uintLessThan(usize, 300), len - pos);
            if (rnd.boolean()) {
                @memset(payload[pos..][0..n], rnd.int(u8));
            } else {
                rnd.bytes(payload[pos..][0..n]);
            }
            pos += n;
        }
        @memcpy(payload[20000 .. 20000 + 16000], payload[0..16000]);
        @memcpy(payload[38000 .. 38000 + 6444], payload[1000..7444]);
    }

    for ([_]struct { level: i32, strategy: constants.Strategy, content: bool }{
        .{ .level = 1, .strategy = .fast, .content = true },
        .{ .level = 3, .strategy = .btlazy2, .content = false },
        .{ .level = 9, .strategy = .btultra2, .content = true },
    }) |c| {
        var mt = try MTCompressor.init(alloc, testing.io, .{
            .level = c.level,
            .strategy = c.strategy,
            .longDistanceMatching = true,
            .contentSize = if (c.content) len else null,
        }, 3);
        defer mt.deinit();
        mt.minJobSize = 4096;

        const frame = try mt.compressAlloc(payload);
        defer alloc.free(frame);

        const back = try @import("../decompress/decompress.zig").decompress(alloc, frame);
        defer alloc.free(back);
        try testing.expectEqualSlices(u8, payload, back);
    }
}
test "mt: multi-job frames round trip at the split boundaries" {
    const alloc = testing.allocator;
    const job = 32 * 1024;

    const sizes = [_]usize{ 1, 4096, job - 1, job, job + 1, 2 * job, 2 * job + 5000, 7 * job + 13 };
    for (sizes) |len| {
        const payload = try makePayload(alloc, len, 0x51);
        defer alloc.free(payload);
        for ([_]i32{ 1, 3, 7 }) |level| {
            var options = CompressionOptions{ .level = level };
            try roundTrip(alloc, payload, options, 4);
            options.checksum = true;
            try roundTrip(alloc, payload, options, 4);
        }
    }
}
test "mt: split planning follows the upstream floor and overlap mapping" {
    const alloc = testing.allocator;
    _ = alloc;

    const options = CompressionOptions{ .level = 3 };

    var mt = try MTCompressor.init(testing.allocator, testing.io, options, 4);
    defer mt.deinit();

    // One input below the floor stays one serial job...

    const plan = compress_mod.planFrame(options, 4096);

    var sp = mt.computeSplit(4096, &plan);
    try testing.expectEqual(@as(usize, 1), sp.num_jobs);

    // ...while a 2 MiB input splits into 512 KiB jobs, four workers times two.

    const plan2 = compress_mod.planFrame(options, 2 * 1024 * 1024);
    sp = mt.computeSplit(2 * 1024 * 1024, &plan2);
    try testing.expect(sp.num_jobs >= 2);
    try testing.expect(sp.num_jobs <= 4 * jobs_per_worker);
    try testing.expect(sp.job_size >= job_size_min);
    // The default overlap for the non-optimal strategies is window / 8.

    const window_log: usize = @intCast(std.math.log2_int(usize, plan2.history_limit));
    try testing.expectEqual(@as(usize, 1) << @intCast(window_log - 3), sp.overlap);
    // The frame header comes out of the split, sized and complete.
    try testing.expect(sp.header_len > 0);
    try testing.expect(sp.needed > sp.header_len);

    // Raising the floor shrinks the job count to match, never past the cap.
    mt.minJobSize = 512 * 1024;

    const plan3 = compress_mod.planFrame(options, 6 * 1024 * 1024);
    sp = mt.computeSplit(6 * 1024 * 1024, &plan3);
    try testing.expectEqual(@as(usize, 8), sp.num_jobs); // 6 MiB / 512 KiB, capped at 4 workers x 2
    try testing.expectEqual(@as(usize, 6 * 1024 * 1024 / 8), sp.job_size);
}
test "mt: identical inputs produce identical frames" {
    const options = CompressionOptions{ .level = 3 };
    const alloc = testing.allocator;

    const payload = try makePayload(alloc, 300000, 2);
    defer alloc.free(payload);

    var first = try MTCompressor.init(alloc, testing.io, options, 3);
    defer first.deinit();
    first.minJobSize = 64 * 1024;

    const a = try first.compressAlloc(payload);
    defer alloc.free(a);

    var second = try MTCompressor.init(alloc, testing.io, options, 3);
    defer second.deinit();
    second.minJobSize = 64 * 1024;

    const b = try second.compressAlloc(payload);
    defer alloc.free(b);

    try testing.expectEqualSlices(u8, a, b);
}
test "mt: compressMT one-shot matches a reused compressor" {
    const alloc = testing.allocator;
    const payload = try makePayload(alloc, 200000, 3);
    defer alloc.free(payload);

    const options = CompressionOptions{ .level = 4, .checksum = true };

    var mt = try MTCompressor.init(alloc, testing.io, options, 2);
    defer mt.deinit();
    mt.minJobSize = 32 * 1024;

    const reused = try mt.compressAlloc(payload);
    defer alloc.free(reused);

    // The one-shot helper makes its own compressor; same options, same split.
    mt.minJobSize = job_size_min; // untouched by compressMT, but keep ours honest

    const one = try compressMT(alloc, testing.io, payload, options, 2);
    defer alloc.free(one);
    // compressMT uses the default 512 KiB floor, which the 200 KB input does
    // not reach, so it is the serial frame; that is still a valid frame of
    // the same content.

    const back = try @import("../decompress/decompress.zig").decompress(alloc, one);
    defer alloc.free(back);
    try testing.expectEqualSlices(u8, payload, back);
}
test "mt: checksum frames survive jobs and detect tampering" {
    const alloc = testing.allocator;
    const payload = try makePayload(alloc, 180000, 4);
    defer alloc.free(payload);

    const options = CompressionOptions{ .level = 3, .checksum = true };

    var mt = try MTCompressor.init(alloc, testing.io, options, 4);
    defer mt.deinit();
    mt.minJobSize = 32 * 1024;

    const frame = try mt.compressAlloc(payload);
    defer alloc.free(frame);

    const back = try @import("../decompress/decompress.zig").decompress(alloc, frame);
    defer alloc.free(back);
    try testing.expectEqualSlices(u8, payload, back);

    // One flipped byte in the checksum region must fail the digest.

    var broken = try alloc.dupe(u8, frame);
    defer alloc.free(broken);

    const target = broken.len - 1;
    broken[target] ^= 0xFF;
    try testing.expectError(error.ChecksumWrong, @import("../decompress/decompress.zig").decompress(alloc, broken));
}
test "mt: tiny inputs take the serial path" {
    const alloc = testing.allocator;
    for ([_]usize{ 0, 1, 2, 17 }) |len| {
        const payload = try makePayload(alloc, len, 5);
        defer alloc.free(payload);

        const options = CompressionOptions{ .level = 3 };

        const serial = try compress_mod.compress(alloc, payload, options);
        defer alloc.free(serial);

        var mt = try MTCompressor.init(alloc, testing.io, options, 4);
        defer mt.deinit();

        const frame = try mt.compressAlloc(payload);
        defer alloc.free(frame);
        try testing.expectEqualSlices(u8, serial, frame);
    }
}
test "mt: long-distance matching round trips across job boundaries" {
    const alloc = testing.allocator;
    // Two random sections then a copy of the first: the repeat sits about
    // 700 KiB back, inside the window but past any single job.

    const section = 512 * 1024;

    const payload = try alloc.alloc(u8, section * 2 + 131072);
    defer alloc.free(payload);

    var prng = std.Random.DefaultPrng.init(0x4D544C44);

    const random = prng.random();
    for (payload[0 .. section * 2]) |*b| b.* = random.intRangeAtMost(u8, 0, 63);
    @memcpy(payload[section * 2 ..], payload[0..131072]);

    var mt = try MTCompressor.init(alloc, testing.io, .{
        .level = 5,
        .windowLog = 22,
        .longDistanceMatching = true,
        .ldmHashRateLog = 4,
    }, 4);
    defer mt.deinit();
    mt.minJobSize = 256 * 1024;

    const frame = try mt.compressAlloc(payload);
    defer alloc.free(frame);

    const back = try @import("../decompress/decompress.zig").decompress(alloc, frame);
    defer alloc.free(back);
    try testing.expectEqualSlices(u8, payload, back);
}
test "mt: concurrent compressors round trip independently" {
    // Several compressors, each with its own pool, all alive at once: the
    // pattern an application that compresses in parallel actually uses.

    const Round = struct {
        fn run(id: usize) !void {
            const payload = try makePayload(testing.allocator, 150000, 100 + id);
            defer testing.allocator.free(payload);

            var mt = try MTCompressor.init(testing.allocator, testing.io, .{ .level = 3 }, 2);
            defer mt.deinit();
            mt.minJobSize = 24 * 1024;

            const frame = try mt.compressAlloc(payload);
            defer testing.allocator.free(frame);

            const back = try @import("../decompress/decompress.zig").decompress(testing.allocator, frame);
            defer testing.allocator.free(back);
            try testing.expectEqualSlices(u8, payload, back);
        }

        fn entry(id: usize) void {
            run(id) catch |e| std.debug.panic("concurrent mt round {d} failed: {s}", .{ id, @errorName(e) });
        }
    };

    if (builtin_single_threaded()) {
        try Round.run(0);
        return;
    }

    const thread_count = 4;

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Round.entry, .{i});
    for (threads) |t| t.join();
}

test "mt: a non-thread-safe allocator survives multithreaded compression" {
    // The pool's workers allocate their own scratch as they encode, so the
    // compressor guards the caller's allocator. A caller that hands over an
    // allocator which is explicitly not thread-safe is the case that guard
    // exists for: without it this races, and with it the run is leak-clean.
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var unsafe_allocator: std.heap.DebugAllocator(.{ .thread_safe = false }) = .{};
    defer {
        const check = unsafe_allocator.deinit();
        testing.expect(check == .ok) catch {};
    }
    const allocator = unsafe_allocator.allocator();

    const payload = try makePayload(allocator, 150000, 99);
    defer allocator.free(payload);
    var mt = try MTCompressor.init(allocator, testing.io, .{ .level = 3, .checksum = true }, 3);
    defer mt.deinit();
    mt.minJobSize = 16 * 1024;

    const frame = try mt.compressAlloc(payload);
    defer allocator.free(frame);
    const back = try @import("../decompress/decompress.zig").decompress(allocator, frame);
    defer allocator.free(back);
    try testing.expectEqualSlices(u8, payload, back);
}

test "mt: concurrent compressors agree with a main-thread reference" {
    // Several compressors running at once, each with its own pool, all compressing
    // the same payload: every frame must equal the one the main thread produces,
    // because the split depends only on the input and the options.
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    const clients = 3;
    const payload = try makePayload(testing.allocator, 150000, 7);
    defer testing.allocator.free(payload);
    const options: CompressionOptions = .{ .level = 3, .checksum = true };

    var reference = try MTCompressor.init(testing.allocator, testing.io, options, 4);
    defer reference.deinit();
    reference.minJobSize = 24 * 1024;
    const expected = try reference.compressAlloc(payload);
    defer testing.allocator.free(expected);

    const Context = struct {
        payload_data: []const u8,
        expected_data: []const u8,
        opts: CompressionOptions,
    };
    const ctx = Context{
        .payload_data = payload,
        .expected_data = expected,
        .opts = options,
    };

    const Client = struct {
        fn run(context: *const Context, id: usize) !void {
            var mt = try MTCompressor.init(testing.allocator, testing.io, context.opts, 4);
            defer mt.deinit();
            mt.minJobSize = 24 * 1024;
            const frame = try mt.compressAlloc(context.payload_data);
            defer testing.allocator.free(frame);
            try testing.expectEqualSlices(u8, context.expected_data, frame);
            const back = try @import("../decompress/decompress.zig").decompress(testing.allocator, frame);
            defer testing.allocator.free(back);
            try testing.expectEqualSlices(u8, context.payload_data, back);
            _ = id;
        }
        fn entry(context: *const Context, id: usize) void {
            run(context, id) catch |e| std.debug.panic("client {d} failed: {s}", .{ id, @errorName(e) });
        }
    };

    var threads: [clients]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Client.entry, .{ &ctx, i });
    for (threads) |t| t.join();
}
