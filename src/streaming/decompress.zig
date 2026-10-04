const std = @import("std");
const bits = @import("../common/bits.zig");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const decompress_mod = @import("../decompress/decompress.zig");
const header_mod = @import("../frame/header.zig");
const types = @import("../common/types.zig");
const block_mod = @import("../frame/block.zig");
const checksum_mod = @import("../frame/checksum.zig");
const block_decompress = @import("../decompress/block.zig");
const entropy_mod = @import("../decompress/entropy.zig");
const legacy_mod = @import("../legacy/decoder.zig");

pub const StreamingDecompressor = struct {
    allocator: std.mem.Allocator,
    inBuffer: std.ArrayList(u8),
    outBuffer: std.ArrayList(u8),
    /// The current block's decoded bytes, reused across blocks.
    blockBuf: std.ArrayList(u8),
    /// Index in `blockBuf` of the first byte the caller has not received.
    delivered: usize = 0,
    stage: Stage,
    frameHeader: ?types.FrameHeader,
    checksumState: checksum_mod.ChecksumState,
    entropy: entropy_mod.State,
    finished: bool,
    /// Largest window a frame may declare. Set through
    /// `setMaxWindowSize`; a frame header asking for more is rejected as soon
    /// as the header is parsed.
    maxWindowSize: usize = @as(usize, 1) << @intCast(constants.window_log_limit_default),

    const Stage = enum { header, blocks, checksum, done };

    pub fn init(allocator: std.mem.Allocator) StreamingDecompressor {
        return .{
            .allocator = allocator,
            .inBuffer = .empty,
            .outBuffer = .empty,
            .blockBuf = .empty,
            .stage = .header,
            .frameHeader = null,
            .checksumState = checksum_mod.ChecksumState.init(),
            .entropy = entropy_mod.State.init(allocator),
            .finished = false,
        };
    }

    /// Rejects frames whose declared window exceeds `size`.
    pub fn setMaxWindowSize(self: *StreamingDecompressor, size: usize) void {
        self.maxWindowSize = size;
    }

    pub fn deinit(self: *StreamingDecompressor) void {
        self.inBuffer.deinit(self.allocator);
        self.outBuffer.deinit(self.allocator);
        self.blockBuf.deinit(self.allocator);
        self.entropy.deinit();
    }

    /// Decoded bytes from the current block that the caller's output has not had
    /// room for yet.
    fn undelivered(self: *const StreamingDecompressor) []const u8 {
        return self.blockBuf.items[self.delivered..];
    }

    /// Hands as much of the current block to `out` as fits and returns how many
    /// bytes that was.
    fn deliver(self: *StreamingDecompressor, out: []u8, outProduced: usize) usize {
        const avail = self.undelivered().len;
        if (avail == 0) return 0;
        const n = @min(avail, out.len - outProduced);
        std.mem.copyForwards(u8, out[outProduced..][0..n], self.undelivered()[0..n]);
        self.delivered += n;
        if (self.delivered == self.blockBuf.items.len) {
            self.blockBuf.clearRetainingCapacity();
            self.delivered = 0;
        }
        return n;
    }

    /// Feeds `inData` to the frame being decoded and writes what is ready into
    /// `out`. Mirrors `ZSTD_decompressStream`: every input byte is accepted and
    /// buffered, so `inConsumed` is always `inData.len`; `outProduced` counts the
    /// bytes delivered this call, and the caller keeps calling (with no input)
    /// while it is non-zero, since a block decodes into an internal buffer and is
    /// handed over in whatever pieces the output allows. `out` may be one byte.
    pub fn decompressStream(self: *StreamingDecompressor, out: []u8, inData: []const u8) errors.ZstdError!struct { inConsumed: usize, outProduced: usize, needsMore: bool } {
        try self.inBuffer.appendSlice(self.allocator, inData);
        var inConsumed: usize = 0;
        var outProduced: usize = 0;
        while (true) {
            // Whatever is left over from the last block goes out first, so a
            // caller with a small output buffer still makes progress.
            outProduced += self.deliver(out, outProduced);
            if (self.undelivered().len > 0) break;
            if (inConsumed >= self.inBuffer.items.len) break;
            if (self.stage == .header) {
                if (self.inBuffer.items.len - inConsumed < 5) break;
                const slice = self.inBuffer.items[inConsumed..];
                const magic = bits.readLe32(slice[0..4]);
                if ((magic & constants.magic_skippable_mask) == constants.magic_skippable_start) {
                    // A partial skippable frame is a "need more input" state, not
                    // an error, so the guarded reader is asked for the total and
                    // any short read is retried when more arrives.
                    const total = header_mod.readSkippableFrameSize(slice) catch |e| switch (e) {
                        error.SrcSizeWrong => break,
                        else => return e,
                    };
                    inConsumed += total;
                    continue;
                }
                if (magic != constants.magic_number) {
                    // Legacy frames (v01-v07) are decoded whole once all
                    // their bytes have arrived; they are small enough that
                    // buffering one frame is safe.
                    if (legacy_mod.isLegacy(slice)) {
                        const frame_size = legacy_mod.findFrameSize(self.allocator, slice) catch |e| {
                            // Not enough bytes buffered yet to size the frame.
                            if (e == error.SrcSizeWrong) break;
                            return e;
                        };
                        if (slice.len < frame_size) break; // wait for the rest
                        const res = try legacy_mod.decompressLegacy(
                            self.allocator,
                            out[outProduced..],
                            slice[0..frame_size],
                        );
                        outProduced += res.decoded;
                        inConsumed += res.consumed;
                        continue;
                    }
                    return error.PrefixUnknown;
                }

                // Compute the exact frame-header length so partial headers
                // wait for more input instead of failing mid-parse.
                const fhd: u8 = slice[4];
                const ss = (fhd >> 5) & 1;
                var need: usize = 5;
                if (ss == 0) need += 1; // window descriptor
                need += constants.did_field_size[fhd & 3];
                const fcs_code: u2 = @truncate(fhd >> 6);
                if (fcs_code == 0 and ss == 1) {
                    need += 1; // single-segment 1-byte FCS
                } else {
                    need += constants.fcs_field_size[fcs_code];
                }
                if (slice.len < need) break;

                const fh = try header_mod.getFrameHeader(slice);
                if (fh.windowSize > self.maxWindowSize) return error.WindowTooLarge;
                self.frameHeader = fh;
                inConsumed += fh.headerSize;
                self.entropy.resetFrame(); // frames are independent
                if (fh.checksumFlag) self.checksumState = checksum_mod.ChecksumState.init();
                self.stage = .blocks;
            }
            if (self.stage == .blocks) {
                if (self.inBuffer.items.len - inConsumed < 3) break;
                const prop = try block_mod.getBlockHeader(self.inBuffer.items[inConsumed..]);
                const cSize = prop.origSize;
                const needed: usize = 3 + (if (prop.blockType == .rle) @as(usize, 1) else @as(usize, cSize));
                if (self.inBuffer.items.len - inConsumed < needed) break;
                const block_slice = self.inBuffer.items[inConsumed .. inConsumed + needed];
                // A block decodes into a reusable buffer and is then handed to the
                // caller in whatever pieces the output allows, so the caller never
                // has to provide room for a whole block.
                try self.blockBuf.resize(self.allocator, constants.block_size_max);
                // A match may reach back at most the frame's declared window;
                // reaching past the output produced so far is a separate rule,
                // enforced per copy. The header carries the window as a 64-bit
                // field but everything below works in the target's own integer
                // type, so it is narrowed and clamped to maxInt(usize) once here.
                const window: usize = if (self.frameHeader) |fh|
                    @intCast(@min(fh.windowSize, @as(u64, std.math.maxInt(usize))))
                else
                    std.math.maxInt(usize);
                const decoded = try block_decompress.decompressBlockLimits(
                    &self.entropy,
                    self.blockBuf.items,
                    block_slice,
                    self.outBuffer.items,
                    .{ .max_offset = window },
                );
                self.blockBuf.shrinkRetainingCapacity(decoded);
                if (self.frameHeader != null and self.frameHeader.?.checksumFlag) {
                    self.checksumState.update(self.blockBuf.items[0..decoded]);
                }
                // The window is the decoder's copy of what it produced, kept
                // separately from what it has already handed over.
                try self.outBuffer.appendSlice(self.allocator, self.blockBuf.items);
                self.trimHistory();
                self.delivered = 0;
                inConsumed += needed;
                if (prop.lastBlock) {
                    if (self.frameHeader != null and self.frameHeader.?.checksumFlag) {
                        self.stage = .checksum;
                    } else {
                        self.stage = .header;
                        self.frameHeader = null;
                    }
                }
                // The block that was just decoded is delivered at the top of the
                // loop, in as many pieces as the caller's output allows.
                continue;
            }
            if (self.stage == .checksum) {
                if (self.inBuffer.items.len - inConsumed < 4) break;
                const expected = checksum_mod.readChecksum(self.inBuffer.items[inConsumed..]);
                const got = self.checksumState.final();
                if (expected != got) return error.ChecksumWrong;
                inConsumed += 4;
                self.stage = .header;
                self.frameHeader = null;
            }
        }
        if (inConsumed > 0) {
            const remaining = self.inBuffer.items.len - inConsumed;
            if (remaining > 0) std.mem.copyForwards(u8, self.inBuffer.items[0..remaining], self.inBuffer.items[inConsumed..]);
            self.inBuffer.shrinkRetainingCapacity(remaining);
        }
        const needsMore = self.stage != .header or self.inBuffer.items.len > 0;
        return .{ .inConsumed = inData.len, .outProduced = outProduced, .needsMore = needsMore };
    }

    /// Keeps at most one window of decoded output as history. Anything older than
    /// the window is unreachable, so dropping it keeps streaming memory
    /// proportional to the window rather than to the frame.
    fn trimHistory(self: *StreamingDecompressor) void {
        const fh = self.frameHeader orelse return;
        if (fh.windowSize == 0) return; // a single-segment frame declares no window
        const keep = @min(self.outBuffer.items.len, fh.windowSize);
        const drop = self.outBuffer.items.len - keep;
        if (drop == 0) return;
        std.mem.copyForwards(u8, self.outBuffer.items[0..keep], self.outBuffer.items[drop..]);
        self.outBuffer.shrinkRetainingCapacity(keep);
    }

    pub fn reset(self: *StreamingDecompressor) void {
        self.inBuffer.clearRetainingCapacity();
        self.outBuffer.clearRetainingCapacity();
        self.blockBuf.clearRetainingCapacity();
        self.delivered = 0;
        self.stage = .header;
        self.frameHeader = null;
        self.checksumState = checksum_mod.ChecksumState.init();
        self.entropy.resetFrame();
        self.finished = false;
    }
};

pub const DStream = StreamingDecompressor;

const testing = std.testing;

test "StreamingDecompressor init and deinit" {
    var sd = StreamingDecompressor.init(testing.allocator);
    defer sd.deinit();
}

test "StreamingDecompressor keeps at most one window of history" {
    // A frame several times its own window must decode in a stream without the
    // decoder holding the whole output: matches can only reach back one window,
    // so that is all the history worth keeping.
    const alloc = testing.allocator;
    const window_log = 17;
    const window = @as(usize, 1) << window_log;
    const payload_len = window * 4;
    const payload = try alloc.alloc(u8, payload_len);
    defer alloc.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i / 977));

    const frame = try @import("../compress/compress.zig").compress(alloc, payload, .{ .level = 3, .windowLog = window_log });
    defer alloc.free(frame);

    var sd = StreamingDecompressor.init(alloc);
    defer sd.deinit();
    const out = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(out);
    var produced: usize = 0;
    var pos: usize = 0;
    while (pos < frame.len) {
        const chunk = @min(frame.len - pos, 4096);
        const r = try sd.decompressStream(out, frame[pos .. pos + chunk]);
        try testing.expectEqualSlices(u8, payload[produced .. produced + r.outProduced], out[0..r.outProduced]);
        produced += r.outProduced;
        pos += r.inConsumed;
        try testing.expect(sd.outBuffer.items.len <= window);
    }
    // Anything still held back is delivered by asking again with no input, which
    // is what makes an output buffer smaller than a block work.
    while (true) {
        const r = try sd.decompressStream(out, "");
        try testing.expectEqualSlices(u8, payload[produced .. produced + r.outProduced], out[0..r.outProduced]);
        produced += r.outProduced;
        if (r.outProduced == 0) break;
    }
    try testing.expectEqual(payload_len, produced);
}

test "StreamingDecompressor delivers into a one-byte output" {
    // The output buffer does not have to be large: each call makes what progress
    // it can and the next call continues.
    const alloc = testing.allocator;
    const payload = "a stream that arrives in pieces and leaves in pieces, byte by byte, is still a stream";
    const frame = try @import("../compress/compress.zig").compress(alloc, payload, .{});
    defer alloc.free(frame);
    var sd = StreamingDecompressor.init(alloc);
    defer sd.deinit();
    var scratch: [64]u8 = undefined;
    var got: usize = 0;
    var pos: usize = 0;
    while (true) {
        const r = try sd.decompressStream(scratch[0..1], frame[pos..]);
        pos += r.inConsumed;
        if (r.outProduced > 0) {
            try testing.expectEqual(payload[got], scratch[0]);
            got += 1;
        } else if (pos >= frame.len) {
            break;
        }
    }
    try testing.expectEqual(payload.len, got);
}

test "StreamingDecompressor reset" {
    var sd = StreamingDecompressor.init(testing.allocator);
    defer sd.deinit();
    sd.reset();
}

test "StreamingDecompressor streaming" {
    var sd = StreamingDecompressor.init(testing.allocator);
    defer sd.deinit();
    const alloc = testing.allocator;
    const src = "streaming decomp test";
    const comp_mod = @import("../compress/compress.zig");
    const c = try comp_mod.compress(alloc, src, .{});
    defer alloc.free(c);
    var out: [256]u8 = undefined;
    var total: usize = 0;
    var pos: usize = 0;
    while (pos < c.len) {
        const chunk_size = @min(c.len - pos, 4);
        const r = try sd.decompressStream(out[total..], c[pos .. pos + chunk_size]);
        total += r.outProduced;
        pos += chunk_size;
        if (r.outProduced == 0 and !r.needsMore) break;
    }
    try testing.expectEqualStrings(src, out[0..total]);
}
