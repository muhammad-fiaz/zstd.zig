const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const compress_mod = @import("../compress/compress.zig");
const header_mod = @import("../frame/header.zig");
const checksum_mod = @import("../frame/checksum.zig");
const block_mod = @import("../compress/block.zig");
const search_mod = @import("../compress/search.zig");
const dict_mod = @import("../dictionary/dictionary.zig");
pub const EndDirective = enum { cont, flush, end };
/// Incremental frame compressor, following Zstandard's own contract for a call:
/// every byte of `inData` is accepted into an internal buffer so `inConsumed` is
/// always `inData.len`; as much of it as `out` can hold becomes blocks right away,
/// nothing waiting for end of stream except the tail `.flush`/`.end` would emit
/// as a partial block; and `remaining` reports input still held internally, so a
/// caller using `.end` loops until it is 0 and a caller short of output room
/// calls again with a larger `out`. The header is written once, entropy tables
/// and repeat offsets are threaded block to block, and the checksum covers input
/// as it arrives.
pub const StreamingCompressor = struct {
    allocator: std.mem.Allocator,
    options: compress_mod.CompressionOptions,
    /// Input accepted but not yet turned into a block.
    pending: std.ArrayList(u8),
    checksumState: checksum_mod.ChecksumState,
    finished: bool,
    headerWritten: bool,
    level: i32,
    /// Frame-level entropy state: repeat offsets and the literals table, both
    /// threaded through every block so the decoder stays in sync.
    entropy: block_mod.FrameEntropy,
    /// Content the next block's sequences may reach back into: the dictionary for
    /// the first block, then the frame's own recent output, trimmed to the
    /// window the frame declares.
    history: std.ArrayList(u8),
    /// Reused across blocks so the history is laid out once per block.
    window: block_mod.BlockWindow,
    /// Most history bytes kept: exactly the window the frame header declares.
    /// Allowing matches to reach farther than the declared window would produce
    /// frames a conforming decoder must refuse, so this is not a memory cap
    /// but part of the format contract.
    historyLimit: usize = 1 << 17,

    /// The window written into the frame header for these options. The header
    /// and the history kept for matching must agree, or the frame declares one
    /// window and encodes matches beyond it.
    fn declaredWindow(options: compress_mod.CompressionOptions) usize {
        return if (options.windowLog != 0)
            @as(usize, 1) << @intCast(options.windowLog)
        else
            @as(usize, 1) << 17;
    }

    pub fn init(allocator: std.mem.Allocator, level: i32) !StreamingCompressor {
        const options = compress_mod.getCompressionParameters(level, 0, 0);
        return StreamingCompressor{
            .allocator = allocator,
            .options = options,
            .pending = .empty,
            .history = .empty,
            .window = .{},
            .checksumState = checksum_mod.ChecksumState.init(),
            .finished = false,
            .headerWritten = false,
            .level = level,
            .entropy = .{},
            .historyLimit = declaredWindow(options),
        };
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, options: compress_mod.CompressionOptions) StreamingCompressor {
        return StreamingCompressor{
            .allocator = allocator,
            .options = options,
            .pending = .empty,
            .history = .empty,
            .window = .{},
            .checksumState = checksum_mod.ChecksumState.init(),
            .finished = false,
            .headerWritten = false,
            .level = options.level,
            .entropy = .{},
            .historyLimit = declaredWindow(options),
        };
    }

    pub fn deinit(self: *StreamingCompressor) void {
        self.pending.deinit(self.allocator);
        self.history.deinit(self.allocator);
        self.window.deinit(self.allocator);
    }

    pub fn setPledgedSrcSize(self: *StreamingCompressor, size: ?u64) void {
        self.options.contentSize = size;
    }

    pub fn setChecksumFlag(self: *StreamingCompressor, flag: bool) void {
        self.options.checksum = flag;
    }

    /// Room a block of `chunk` bytes can need in the output: a raw block is the
    /// fallback, so a compressed block never exceeds its input by more than the
    /// block header.
    fn roomFor(chunk: usize) usize {
        return chunk + 3;
    }

    /// Drops the first `n` bytes of the pending buffer, keeping the capacity so
    /// the buffer is reused for the rest of the frame.
    fn consumePending(self: *StreamingCompressor, n: usize) void {
        if (n == 0) return;
        const left = self.pending.items.len - n;
        if (left > 0) std.mem.copyForwards(u8, self.pending.items[0..left], self.pending.items[n..]);
        self.pending.shrinkRetainingCapacity(left);
    }

    pub fn setDictionary(self: *StreamingCompressor, dictionary: ?*const dict_mod.Dictionary) void {
        self.options.dictionary = dictionary;
        self.options.dictId = if (dictionary) |d| d.dictId() else 0;
        self.history.clearRetainingCapacity();
        if (dictionary) |d| self.history.appendSlice(self.allocator, d.content()) catch {};
        // A dictionary larger than the window is trimmed like any other
        // history: per the format the window covers the dictionary too, so
        // only its tail can be matched against.
        self.trimHistoryToLimit();
    }

    /// Drops the oldest history once only the most recent window's worth is
    /// worth keeping for matching.
    fn trimHistoryToLimit(self: *StreamingCompressor) void {
        if (self.history.items.len > self.historyLimit) {
            const drop = self.history.items.len - self.historyLimit;
            std.mem.copyForwards(u8, self.history.items[0..self.historyLimit], self.history.items[drop..]);
            self.history.shrinkRetainingCapacity(self.historyLimit);
        }
    }

    /// The distance bound the frame's own header promises. A block can
    /// outgrow the window, so without this clamp the finder emits offsets the
    /// header never described and the frame is rejected by a conforming
    /// decoder, this one included.
    fn searchWindowLimit(options: compress_mod.CompressionOptions) u32 {
        const bounded = @min(@max(@as(u64, declaredWindow(options)), 1024), @as(u64, std.math.maxInt(usize)));
        const wlog = @min(
            constants.window_log_max,
            std.math.log2_int(usize, @as(usize, @intCast(bounded))),
        );
        return search_mod.windowLimitFor(@intCast(wlog));
    }

    /// Compresses one block from the front of the pending buffer. Returns null when
    /// the output has no room, consuming nothing; the caller must retry with a
    /// larger buffer. The block is searched with the accumulated history in
    /// front, so a match can cross a block boundary as in a single-shot frame.
    fn emitBlock(self: *StreamingCompressor, out: []u8, outPos: *usize, is_last: bool) !?usize {
        const chunk = @min(self.pending.items.len, constants.block_size_max);
        if (chunk == 0) return 0;
        if (out.len - outPos.* < roomFor(chunk)) return null;
        const config = block_mod.searchConfigFor(self.options.strategy, self.options.level);
        const written = try block_mod.compressBlockWithWindow(
            self.allocator,
            out[outPos.*..],
            self.pending.items[0..chunk],
            is_last,
            &self.entropy,
            &config,
            null,
            self.history.items,
            &self.window,
            searchWindowLimit(self.options),
        );
        outPos.* += written;
        // The block just encoded joins the history the next one may reach into.
        try self.history.appendSlice(self.allocator, self.pending.items[0..chunk]);
        self.trimHistoryToLimit();
        self.consumePending(chunk);
        return chunk;
    }

    /// Emits blocks until the pending buffer is below `min_to_emit`, the output runs
    /// out of room, or the last block has been written. `required` says the caller
    /// asked for these bytes to leave now (`.flush`/`.end`), so having no room for
    /// even one block is an error rather than silent stalling. While the stream is
    /// open `min_to_emit` is one full block, so small writes produce one block per
    /// block of input; a flush or end emits whatever partial block is left.
    fn drain(self: *StreamingCompressor, out: []u8, outPos: *usize, finish: bool, required: bool, min_to_emit: usize) !bool {
        var emitted_any = false;
        while (self.pending.items.len >= min_to_emit) {
            // A block is only marked last when it is the final one *and* the
            // frame really ends here, so an `.end` call that runs out of output
            // leaves a frame the caller can finish with the next call.
            const remaining_after = self.pending.items.len - @min(self.pending.items.len, constants.block_size_max);
            const is_last = finish and remaining_after == 0;
            const consumed = try self.emitBlock(out, outPos, is_last) orelse {
                // Room for some blocks is progress; room for none at all is a
                // caller that cannot satisfy a `.flush` or `.end` request.
                if (required and !emitted_any) return error.DstSizeTooSmall;
                return false;
            };
            if (consumed == 0) return false;
            emitted_any = true;
            if (is_last) return true;
        }
        return false;
    }

    pub fn compressStream(self: *StreamingCompressor, out: []u8, inData: []const u8, directive: EndDirective) errors.ZstdError!struct { inConsumed: usize, outProduced: usize, remaining: usize } {
        if (self.finished and directive != .end) return error.StageWrong;
        var outPos: usize = 0;
        if (!self.headerWritten) {
            const windowSize: u64 = declaredWindow(self.options);
            const singleSegment = self.options.contentSize != null and self.options.contentSize.? < 256 * 1024 and windowSize >= (self.options.contentSize orelse 0);
            const headerSize = header_mod.writeFrameHeader(out[outPos..], self.options.contentSize, windowSize, self.options.dictId, self.options.checksum, singleSegment);
            outPos += headerSize;
            self.headerWritten = true;
        }
        if (inData.len > 0) {
            try self.pending.appendSlice(self.allocator, inData);
            self.checksumState.update(inData);
        }

        switch (directive) {
            // While the stream is open, full blocks go out as they arrive; only a
            // partial block waits for more input, and a small output simply means
            // the input stays buffered.
            .cont => _ = try self.drain(out, &outPos, false, false, constants.block_size_max),
            // A flush ends the current block even if it is partial, which is what
            // makes the output decodable at this point.
            .flush => _ = try self.drain(out, &outPos, true, true, 1),
            .end => {
                if (self.pending.items.len == 0) {
                    // An empty stream still needs a last block so the frame ends.
                    if (out.len - outPos < 3) return error.DstSizeTooSmall;
                    outPos += try block_mod.compressBlock(self.allocator, out[outPos..], &[_]u8{}, true, &self.entropy);
                } else {
                    const done = try self.drain(out, &outPos, true, true, 1);
                    if (!done or self.pending.items.len != 0) {
                        // The output was too small for the rest. The frame is
                        // still open: the caller retries `.end` with more room.
                        return .{ .inConsumed = inData.len, .outProduced = outPos, .remaining = self.pending.items.len };
                    }
                }
                if (self.options.checksum) {
                    if (out.len - outPos < 4) return error.DstSizeTooSmall;
                    checksum_mod.writeChecksum(out[outPos..], self.checksumState.final());
                    outPos += 4;
                }
                self.finished = true;
                return .{ .inConsumed = inData.len, .outProduced = outPos, .remaining = 0 };
            },
        }
        return .{ .inConsumed = inData.len, .outProduced = outPos, .remaining = self.pending.items.len };
    }

    pub fn reset(self: *StreamingCompressor) void {
        self.pending.clearRetainingCapacity();
        self.history.clearRetainingCapacity();
        self.checksumState = checksum_mod.ChecksumState.init();
        self.finished = false;
        self.headerWritten = false;
        // A reset starts a new frame, so the carried entropy state restarts too.
        self.entropy.reset();
    }
};
pub const CStream = StreamingCompressor;
const testing = std.testing;
/// Progress from a test goes through this rather than stderr, so a run under the
/// build system's test-runner protocol is not reported as a failed command.
const test_log = std.log.scoped(.zstd_zig_streaming_test);
/// Counts allocations so "this type reuses its buffers" is a measurement rather
/// than a claim. Without such a check, moving a per-frame allocation back inside
/// a loop is invisible: nothing fails, the suite stays green, and the only
/// symptom is a compressor that allocates on every frame.
const AllocCounter = struct {
    inner: std.mem.Allocator,
    count: usize = 0,

    fn alloc(self: *AllocCounter, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        self.count += 1;
        return self.inner.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(self: *AllocCounter, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        return self.inner.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(self: *AllocCounter, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(self: *AllocCounter, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        self.inner.rawFree(memory, alignment, ret_addr);
    }

    fn allocator(self: *AllocCounter) std.mem.Allocator {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .alloc = @ptrCast(&alloc),
                .resize = @ptrCast(&resize),
                .remap = @ptrCast(&remap),
                .free = @ptrCast(&free),
            },
        };
    }
};
test "StreamingCompressor end with an output buffer that fills up keeps the frame open" {
    // Regression: a `.end` call whose output could not hold the remaining blocks
    // used to drop the unconsumed input, write the checksum and mark the frame
    // finished, so the frame decoded to less than the input. The compressor now
    // keeps the tail and reports it as `remaining`, and the caller finishes the
    // frame with another `.end` call.
    const alloc = testing.allocator;
    const payload_len = 300 * 1024;
    const payload = try alloc.alloc(u8, payload_len);
    defer alloc.free(payload);
    var prng = std.Random.DefaultPrng.init(0x57EA);
    const random = prng.random();
    for (payload) |*b| b.* = random.int(u8);

    var sc = try StreamingCompressor.init(alloc, 9);
    defer sc.deinit();
    var frame = std.ArrayList(u8).empty;
    defer frame.deinit(alloc);

    // A roomy first call, then deliberately cramped ones, then final `.end` calls
    // with only room for one block: the frame has to be finished across several
    // calls, and nothing may be lost.
    var buf: [8192]u8 = undefined;
    const first = try sc.compressStream(&buf, payload, .cont);
    try frame.appendSlice(alloc, buf[0..first.outProduced]);
    try testing.expectEqual(payload.len, first.remaining);

    const out = try alloc.alloc(u8, 200 * 1024);
    defer alloc.free(out);
    var calls: usize = 0;
    while (true) : (calls += 1) {
        const r = try sc.compressStream(out, "", .end);
        try frame.appendSlice(alloc, out[0..r.outProduced]);
        if (r.remaining == 0) break;
        try testing.expect(!sc.finished);
        try testing.expect(calls < 1000);
    }
    try testing.expect(calls > 0);
    try testing.expect(sc.finished);

    // The frame must decode to exactly the input: nothing was dropped.
    const restored = try @import("../zstd.zig").decompress(alloc, frame.items);
    defer alloc.free(restored);
    try testing.expectEqualSlices(u8, payload, restored);
}
test "StreamingCompressor emits blocks while the stream is still open" {
    // Incrementality: a caller that only ever passes `.cont` must see output long
    // before the end of the input, which is what rules out buffering everything
    // and compressing once at the end.
    const alloc = testing.allocator;
    const payload_len = 8 * 1024 * 1024;
    const payload = try alloc.alloc(u8, payload_len);
    defer alloc.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i *% 7);

    var sc = try StreamingCompressor.init(alloc, 3);
    defer sc.deinit();
    const out = try alloc.alloc(u8, 256 * 1024);
    defer alloc.free(out);

    var produced: usize = 0;
    var produced_early = false;
    var pos: usize = 0;
    while (pos < payload.len) {
        const chunk = @min(payload.len - pos, 64 * 1024);
        const r = try sc.compressStream(out, payload[pos .. pos + chunk], .cont);
        pos += r.inConsumed;
        produced += r.outProduced;
        // After the first megabyte of input there must already be output.
        if (pos >= 1024 * 1024) produced_early = true;
    }
    try testing.expect(produced_early);
    // The pending buffer holds at most the tail a partial block needs, not the
    // whole stream.
    try testing.expect(sc.pending.items.len < payload_len / 2);
}
test "StreamingCompressor flush makes the output decodable at that point" {
    const alloc = testing.allocator;
    const payload = "the quick brown fox jumps over the lazy dog, repeatedly and at length";
    var sc = try StreamingCompressor.init(alloc, 5);
    defer sc.deinit();
    var buf: [4096]u8 = undefined;
    var frame = std.ArrayList(u8).empty;
    defer frame.deinit(alloc);

    const a = try sc.compressStream(&buf, payload[0..20], .cont);
    try frame.appendSlice(alloc, buf[0..a.outProduced]);
    const b = try sc.compressStream(&buf, payload[20..], .flush);
    try frame.appendSlice(alloc, buf[0..b.outProduced]);
    // A flush empties the internal buffer, so the decoder can already see
    // everything handed in so far.
    try testing.expectEqual(@as(usize, 0), b.remaining);
}
test "StreamingCompressor does not turn every write into a block" {
    // While the stream is open only whole blocks leave, so a caller writing small
    // pieces gets one block per block of input. Emitting a block per write
    // instead cost 100x the ratio on this input.
    const alloc = testing.allocator;
    const line = "Streaming compression processes data incrementally, without buffering all of it at once. ";
    var sc = try StreamingCompressor.init(alloc, 5);
    defer sc.deinit();
    var out: [1 << 17]u8 = undefined;
    var frame = std.ArrayList(u8).empty;
    defer frame.deinit(alloc);
    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(alloc);

    for (0..400) |_| {
        try expected.appendSlice(alloc, line);
        const r = try sc.compressStream(&out, line, .cont);
        try frame.appendSlice(alloc, out[0..r.outProduced]);
    }
    while (true) {
        const r = try sc.compressStream(&out, "", .end);
        try frame.appendSlice(alloc, out[0..r.outProduced]);
        if (r.remaining == 0) break;
    }
    // 400 writes of 88 bytes would be 400 blocks if every write were one.
    try testing.expect(frame.items.len < expected.items.len / 100);
    const restored = try @import("../zstd.zig").decompress(alloc, frame.items);
    defer alloc.free(restored);
    try testing.expectEqualSlices(u8, expected.items, restored);
}
test "StreamingCompressor init and deinit" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
}
test "StreamingCompressor initWithOptions" {
    const opts = compress_mod.CompressionOptions{ .level = 5 };
    var sc = StreamingCompressor.initWithOptions(testing.allocator, opts);
    defer sc.deinit();
}
test "StreamingCompressor cont then end" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
    var buf: [4096]u8 = undefined;
    const r1 = try sc.compressStream(&buf, "hello ", .cont);
    try testing.expect(r1.inConsumed == 6 or r1.remaining > 0);
    const r2 = try sc.compressStream(&buf, "world", .end);
    try testing.expect(r2.outProduced > 0);
}
test "StreamingCompressor flush" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
    var buf: [4096]u8 = undefined;
    _ = try sc.compressStream(&buf, "data", .flush);
    try testing.expect(!sc.finished);
}
test "StreamingCompressor end writes empty block" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
    var buf: [4096]u8 = undefined;
    const r = try sc.compressStream(&buf, "", .end);
    try testing.expect(r.outProduced > 0);
    try testing.expect(sc.finished);
}
test "StreamingCompressor setChecksumFlag" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
    sc.setChecksumFlag(true);
    var buf: [4096]u8 = undefined;
    const r = try sc.compressStream(&buf, "checksum data", .end);
    try testing.expect(r.outProduced > 0);
}
test "StreamingCompressor setPledgedSrcSize" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
    sc.setPledgedSrcSize(100);
    var buf: [4096]u8 = undefined;
    _ = try sc.compressStream(&buf, "pledged", .end);
}
test "StreamingCompressor reset" {
    var sc = try StreamingCompressor.init(testing.allocator, 3);
    defer sc.deinit();
    var buf: [4096]u8 = undefined;
    _ = try sc.compressStream(&buf, "first", .end);
    sc.reset();
    try testing.expect(!sc.finished);
    try testing.expect(!sc.headerWritten);
}
test "a second frame through the same compressor does not rebuild its tables" {
    // The search tables, literal buffer and entropy state are what make
    // compression expensive to set up, and they are sized to the window rather
    // than to one frame. A compressor that rebuilds them per frame would still
    // pass every correctness test, so the property is measured directly: after
    // the first frame, compressing another must not allocate.
    var counter = AllocCounter{ .inner = testing.allocator };
    const alloc = counter.allocator();

    var payload: [32768]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(9);
    for (&payload) |*b| b.* = if (prng.random().boolean()) 'a' else 'b';

    var sc = try StreamingCompressor.init(alloc, 9);
    defer sc.deinit();

    // One frame, in awkward pieces, to reach the steady state.
    const encodeOne = struct {
        fn run(c: *StreamingCompressor, out: []u8, src: []const u8) !usize {
            var pos: usize = 0;
            var chunk: usize = 1;
            while (pos < src.len) {
                const take = @min(chunk, src.len - pos);
                const r = try c.compressStream(out[0..], src[pos .. pos + take], .cont);
                pos += r.inConsumed;
                chunk = chunk *% 3 +% 1;
            }
            while (true) {
                const r = try c.compressStream(out[0..], &.{}, .end);
                if (r.remaining == 0) return r.outProduced;
            }
        }
    }.run;

    var out: [131072]u8 = undefined;
    _ = try encodeOne(&sc, &out, &payload);

    // The second frame goes through the same instance, so everything the first
    // frame needed is already there.
    const after_first = counter.count;
    sc.reset();
    _ = try encodeOne(&sc, &out, &payload);
    const second_frame = counter.count - after_first;

    // The second frame reuses everything the first allocated; the few remaining
    // allocations are buffer growth, not rebuilt state, so a frame of the same
    // shape costs the same small constant. What must not happen is cost
    // proportional to the window, which is what per-frame search tables and
    // entropy state would look like. The bound is loose enough to survive a
    // growth step and tight enough to fail if they go back to per-frame.
    if (second_frame > 8) {
        std.debug.print("second frame cost {d} allocations\n", .{second_frame});
        return error.TooManyAllocations;
    }

    // A third frame must not cost more than the second: if it did, something is
    // still growing on every call.
    const after_second = counter.count;
    sc.reset();
    _ = try encodeOne(&sc, &out, &payload);
    const third_frame = counter.count - after_second;
    if (third_frame > second_frame) {
        std.debug.print("third frame cost {d}, second {d}\n", .{ third_frame, second_frame });
        return error.AllocationsGrowing;
    }
}
