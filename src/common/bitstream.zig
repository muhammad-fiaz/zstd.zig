//! Forward and reverse bit streams for the entropy layers. Bits go in at the low
//! end of a 64-bit container and are read back from the high end, which is why the
//! two directions are separate types.
//!
//! `addBits` never loses bits: the writer flushes whole bytes once more than 32
//! bits are pending, so one call may append at most 32 (the widest single field is
//! a 28-bit offset extra). `close` appends the mandatory end-of-stream `1` bit, so
//! the final byte is never zero, which is how a decoder finds the stream end.
//! `BIT_DStream` reports over-reads as `.overflow` rather than trapping.

const std = @import("std");
const errors = @import("errors.zig");
const bits = @import("bits.zig");

/// Container width. Everything in the bitstream layer is expressed in terms
/// of this, so switching to a wider container would be a single-line change.
pub const container_bits: u32 = 64;
const Container = u64;
const shift_t = std.math.Log2Int(Container);

/// Pending bits above which the writer drains whole bytes. Keeping the
/// invariant "at most 32 bits pending on entry to addBits" is what makes
/// `value << bitPos` provably lossless for any 32-bit `value`.
const flush_threshold: u32 = 32;

// Forward writer

/// Forward bit writer used by the FSE and Huffman encoders.
pub const BIT_CStream = struct {
    /// Destination buffer, owned by the caller.
    buf: []u8,
    /// Next byte index to receive flushed data.
    ptr: usize,
    /// Bit container holding the not-yet-flushed tail.
    bitContainer: Container = 0,
    /// Number of pending bits in `bitContainer`, always <= 64.
    bitPos: u32 = 0,
    /// Set once the buffer has been exhausted; further writes are no-ops so
    /// that callers can finish an encoding pass and check `ok` at the end.
    overflowed: bool = false,

    pub const InitError = errors.ZstdError;

    /// `dst` must have room for at least 9 bytes so that the 8-byte flush can
    /// always address a full container plus the trailing partial byte.
    pub fn init(dst: []u8) InitError!BIT_CStream {
        if (dst.len <= 8) return error.DstSizeTooSmall;
        return .{ .buf = dst, .ptr = 0 };
    }

    /// Appends the low `nbBits` of `value`. `nbBits` must not exceed 32 (the format's
    /// widest single field is a 28-bit offset extra). Once the buffer is exhausted
    /// further writes are ignored, so a caller can finish a pass and check once.
    pub fn addBits(self: *BIT_CStream, value: u64, nbBits: u32) void {
        if (nbBits == 0 or self.overflowed) return;
        std.debug.assert(nbBits <= flush_threshold);
        // Invariant: at most `flush_threshold` bits are pending on entry, so
        // the shift below cannot discard any of the `nbBits` payload bits.
        std.debug.assert(self.bitPos <= flush_threshold);
        const mask: Container = (@as(Container, 1) << @as(shift_t, @intCast(nbBits))) - 1;
        self.bitContainer |= (value & mask) << @as(shift_t, @intCast(self.bitPos));
        self.bitPos += nbBits;
        if (self.bitPos > flush_threshold) self.flushBits();
    }

    /// Appends `value` without masking. Only valid when the caller already
    /// guaranteed that `value` fits in `nbBits` bits.
    pub fn addBitsFast(self: *BIT_CStream, value: u64, nbBits: u32) void {
        if (nbBits == 0 or self.overflowed) return;
        std.debug.assert(self.bitPos <= flush_threshold);
        self.bitContainer |= value << @as(shift_t, @intCast(self.bitPos));
        self.bitPos += nbBits;
        if (self.bitPos > flush_threshold) self.flushBits();
    }

    /// Moves every whole pending byte into `buf`, keeping the remainder.
    ///
    /// Total by construction for every reachable state (`bitPos <= 64`):
    /// a full container drains all 8 bytes, anything smaller drains the
    /// whole-byte prefix.
    pub fn flushBits(self: *BIT_CStream) void {
        if (self.overflowed) return;
        const nbBytes = self.bitPos >> 3;
        if (nbBytes == 0) return;
        if (self.ptr + nbBytes > self.buf.len) {
            self.overflowed = true;
            return;
        }
        if (nbBytes >= 8) {
            bits.writeLe64(self.buf[self.ptr..][0..8], self.bitContainer);
            self.ptr += 8;
            self.bitContainer = 0;
            self.bitPos = 0;
            return;
        }
        // `nbBytes` is in 1..8 and `ptr + nbBytes <= buf.len`, so the wide
        // store below always stays in bounds.
        if (self.ptr + 8 <= self.buf.len) {
            bits.writeLe64(self.buf[self.ptr..][0..8], self.bitContainer);
        } else {
            for (0..nbBytes) |i| {
                self.buf[self.ptr + i] = @truncate(self.bitContainer >> @as(shift_t, @intCast(i * 8)));
            }
        }
        self.ptr += nbBytes;
        self.bitContainer >>= @as(shift_t, @intCast(nbBytes * 8));
        self.bitPos &= 7;
    }

    /// Bytes fully written so far, excluding the pending partial byte.
    pub fn written(self: *const BIT_CStream) usize {
        return self.ptr;
    }

    /// True when every write so far fitted inside `buf`.
    pub fn ok(self: *const BIT_CStream) bool {
        return !self.overflowed;
    }

    /// Appends the mandatory end-of-stream marker and returns the total
    /// number of significant bytes, or `error.DstSizeTooSmall` when the buffer
    /// cannot hold the result.
    pub fn close(self: *BIT_CStream) InitError!usize {
        if (self.overflowed) return error.DstSizeTooSmall;
        self.addBitsFast(1, 1); // end mark
        self.flushBits();
        const total = self.ptr + (self.bitPos + 7) / 8;
        if (total > self.buf.len) return error.DstSizeTooSmall;
        if (self.bitPos > 0) {
            self.buf[self.ptr] = @truncate(self.bitContainer & 0xFF);
        }
        if (total == 0) return error.DstSizeTooSmall;
        return total;
    }
};

// Reverse reader

pub const DStreamStatus = enum {
    /// More bytes remain inside the current container.
    unfinished,
    /// The container reached the start of the buffer; the tail is valid.
    end_of_buffer,
    /// The stream is fully consumed.
    completed,
    /// More bits were requested than the stream contains.
    overflow,
};

/// Reverse bit reader for FSE and Huffman bitstreams.
pub const BIT_DStream = struct {
    /// The whole bitstream, including the trailing padding byte.
    src: []const u8,
    /// Index of the first byte of the current 8-byte container.
    ptr: usize = 0,
    bitContainer: Container = 0,
    bitsConsumed: u32 = 0,

    pub const InitError = errors.ZstdError;

    /// Locates the final non-zero padding bit and prepares the first
    /// container. `error.Corruption` is returned when the stream is empty or
    /// the last byte is zero, both of which violate the format.
    pub fn init(src: []const u8) InitError!BIT_DStream {
        if (src.len < 1) return error.SrcSizeWrong;
        const lastByte = src[src.len - 1];
        if (lastByte == 0) return error.Corruption;
        // 8 - index_of_highest_set_bit, i.e. skip the zero padding and the
        // single set marker bit.
        const padding: u32 = 8 - @as(u32, @intCast(bits.highbit32(lastByte)));

        var stream = BIT_DStream{ .src = src, .ptr = 0 };
        if (src.len >= 8) {
            stream.ptr = src.len - 8;
            stream.bitContainer = bits.readLe64(src[stream.ptr..]);
            stream.bitsConsumed = padding;
            return stream;
        }
        // Short stream: build a container whose low bytes are the whole input,
        // zero-padded on the right, and account for the missing high bytes.
        var container: Container = 0;
        for (src, 0..) |b, i| {
            container |= @as(Container, b) << @as(shift_t, @intCast(i * 8));
        }
        stream.bitContainer = container;
        stream.bitsConsumed = padding + @as(u32, @intCast((8 - src.len) * 8));
        return stream;
    }

    /// Peeks `nbBits` without consuming them. `nbBits` must be <= 32.
    pub fn lookBits(self: *const BIT_DStream, nbBits: u32) Container {
        if (nbBits == 0) return 0;
        const shifted: Container = self.bitContainer << @as(shift_t, @intCast(self.bitsConsumed & 63));
        return shifted >> @as(shift_t, @intCast(container_bits - nbBits));
    }

    pub fn skipBits(self: *BIT_DStream, nbBits: u32) void {
        self.bitsConsumed += nbBits;
    }

    pub fn readBits(self: *BIT_DStream, nbBits: u32) Container {
        const val = self.lookBits(nbBits);
        self.bitsConsumed += nbBits;
        return val;
    }

    pub fn readBitsFast(self: *BIT_DStream, nbBits: u32) Container {
        return self.readBits(nbBits);
    }

    /// Refills the container until `nbBits` more bits can be read without
    /// reloading; false means the stream cannot provide them. A reload keeps the
    /// bit offset while stepping back whole bytes, so a caller needing more bits
    /// than a container holds must refill first: the sequence decoder reads a
    /// code's extra bits plus three FSE state updates between reloads, which
    /// exceeds 64 bits for wide offset, match and literal lengths.
    pub fn ensure(self: *BIT_DStream, nbBits: u32) bool {
        while (self.bitsConsumed + nbBits > container_bits) {
            switch (self.reload()) {
                .unfinished => continue,
                .end_of_buffer, .completed => return false,
                .overflow => {
                    std.debug.print("DBG ensure fail n={d} consumed={d} ptr={d} len={d}\n", .{ nbBits, self.bitsConsumed, self.ptr, self.src.len });
                    return false;
                },
            }
        }
        return true;
    }

    pub fn reload(self: *BIT_DStream) DStreamStatus {
        if (self.bitsConsumed > container_bits) return .overflow;
        if (self.ptr == 0) {
            if (self.bitsConsumed < container_bits) return .end_of_buffer;
            return .completed;
        }
        var nbBytes: usize = self.bitsConsumed >> 3;
        var result: DStreamStatus = .unfinished;
        if (nbBytes > self.ptr) {
            nbBytes = self.ptr;
            result = .end_of_buffer;
        }
        self.ptr -= nbBytes;
        self.bitsConsumed -= @as(u32, @intCast(nbBytes * 8));
        self.bitContainer = bits.readLe64(self.src[self.ptr..]);
        return result;
    }

    /// True once the whole stream (padding included) has been consumed.
    pub fn endOfStream(self: *const BIT_DStream) bool {
        return self.ptr == 0 and self.bitsConsumed >= container_bits;
    }

    /// Bytes of `src` the reader has not yet taken. A stream that has been
    /// driven to its end reports 0.
    pub fn remaining(self: *const BIT_DStream) usize {
        if (self.ptr > self.src.len) return 0;
        return self.src.len - self.ptr;
    }

    /// Drains the stream and reports whether every byte was consumed without
    /// over-reading. A well-formed bitstream ends exactly exhausted; leftover
    /// bytes or an over-read both indicate corruption.
    pub fn requireCompleted(self: *BIT_DStream) errors.ZstdError!void {
        while (true) {
            switch (self.reload()) {
                .unfinished => continue,
                .completed => return,
                .end_of_buffer => return error.Corruption,
                .overflow => return error.Corruption,
            }
        }
    }
};

// Tests

const testing = std.testing;

test "BIT_CStream writes whole bytes" {
    var buf: [16]u8 = undefined;
    var bc = try BIT_CStream.init(&buf);
    bc.addBits(0xFF, 8);
    // The payload fills the first byte exactly, so the end-of-stream marker
    // lands in a second byte.
    const n = try bc.close();
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u8, 0xFF), buf[0]);
    try testing.expectEqual(@as(u8, 0x01), buf[1]);
}

test "BIT_CStream packs two nibbles into one byte" {
    var buf: [16]u8 = undefined;
    var bc = try BIT_CStream.init(&buf);
    bc.addBits(0x0F, 4);
    bc.addBits(0x0A, 4);
    // 8 payload bits plus the end marker = 9 bits, so the marker lands in a
    // second byte.
    const n = try bc.close();
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u8, 0xAF), buf[0]);
    try testing.expectEqual(@as(u8, 0x01), buf[1]);
}

test "BIT_CStream appends a non-zero final byte" {
    // Every stream must end with a set bit, otherwise a decoder cannot find
    // the end. Exercise the case where the payload is an exact multiple of 8
    // bits so the marker lands in a fresh byte.
    var buf: [16]u8 = undefined;
    var bc = try BIT_CStream.init(&buf);
    bc.addBits(0xAB, 8);
    const n = try bc.close();
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u8, 0x01), buf[1]);
}

test "BIT_CStream does not lose bits past the container width" {
    // 40 x 16 bits: without the automatic flush inside addBits the upper
    // 16 bits of the container would be dropped.
    var buf: [128]u8 = undefined;
    var bc = try BIT_CStream.init(&buf);
    var i: u32 = 0;
    while (i < 40) : (i += 1) bc.addBits(i & 0xFFFF, 16);
    const n = try bc.close();
    try testing.expectEqual(@as(usize, 81), n);
    // Spot-check the decoded values through the reverse reader.
    var ds = try BIT_DStream.init(buf[0..n]);
    var j: u32 = 40;
    while (j > 0) {
        j -= 1;
        try testing.expectEqual(@as(Container, j & 0xFFFF), ds.readBits(16));
        _ = ds.reload();
    }
}

test "BIT_CStream handles a full 32-bit field" {
    var buf: [64]u8 = undefined;
    var bc = try BIT_CStream.init(&buf);
    bc.addBits(0xDEADBEEF, 32);
    bc.addBits(0x0BADF00D, 32);
    const n = try bc.close();
    try testing.expectEqual(@as(usize, 9), n);
    var ds = try BIT_DStream.init(buf[0..n]);
    try testing.expectEqual(@as(Container, 0xBADF00D), ds.readBits(32));
    _ = ds.reload();
    try testing.expectEqual(@as(Container, 0xDEADBEEF), ds.readBits(32));
}

test "BIT_CStream rejects a buffer that is too small" {
    var buf: [8]u8 = undefined;
    try testing.expectError(error.DstSizeTooSmall, BIT_CStream.init(&buf));
}

test "BIT_CStream reports overflow instead of writing past the buffer" {
    var buf: [10]u8 = undefined;
    var bc = try BIT_CStream.init(&buf);
    var i: u32 = 0;
    while (i < 64) : (i += 1) bc.addBits(0xFF, 8);
    try testing.expect(!bc.ok());
    try testing.expectError(error.DstSizeTooSmall, bc.close());
}

test "BIT_DStream rejects empty and zero-padded streams" {
    try testing.expectError(error.SrcSizeWrong, BIT_DStream.init(&[_]u8{}));
    try testing.expectError(error.Corruption, BIT_DStream.init(&[_]u8{ 0xFF, 0x00 }));
    try testing.expectError(error.Corruption, BIT_DStream.init(&[_]u8{0x00}));
}

test "BIT_DStream round trips arbitrary bit patterns" {
    // Drive a forward writer and a reverse reader over pseudo-random fields.
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const random = prng.random();
    for (0..64) |trial| {
        var fields: [24]u64 = undefined;
        var widths: [24]u32 = undefined;
        var buf: [256]u8 = undefined;
        var bc = try BIT_CStream.init(&buf);
        for (0..24) |i| {
            const w: u32 = random.intRangeAtMost(u32, 1, 28);
            widths[i] = w;
            fields[i] = random.int(u64) & ((@as(u64, 1) << @intCast(w)) - 1);
            bc.addBits(fields[i], w);
        }
        const n = try bc.close();

        var ds = try BIT_DStream.init(buf[0..n]);
        var i: usize = 24;
        while (i > 0) {
            i -= 1;
            try testing.expectEqual(fields[i], ds.readBits(widths[i]));
            _ = ds.reload();
        }
        if (trial == 0) try testing.expect(n > 0);
    }
}

test "BIT_DStream short buffers" {
    // Streams shorter than 8 bytes must still decode: the container is assembled from
    // the available bytes and the missing high bytes are accounted for in the
    // consumed count. Write into a full-size buffer, hand the reader the prefix.
    var backing: [16]u8 = undefined;
    var bc = try BIT_CStream.init(&backing);
    bc.addBits(0x5A, 8);
    bc.addBits(0xC3, 8);
    const n = try bc.close();
    try testing.expect(n <= 4);
    var ds = try BIT_DStream.init(backing[0..n]);
    try testing.expectEqual(@as(Container, 0xC3), ds.readBits(8));
    _ = ds.reload();
    try testing.expectEqual(@as(Container, 0x5A), ds.readBits(8));
}

test "BIT_DStream signals overflow when over-read" {
    var buf: [16]u8 = @splat(0x11);
    var ds = try BIT_DStream.init(&buf);
    // Consume far more bits than the stream holds.
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        _ = ds.readBits(8);
    }
    try testing.expectEqual(DStreamStatus.overflow, ds.reload());
}

test "BIT_DStream lookBits does not consume" {
    var buf: [16]u8 = @splat(0);
    buf[0] = 0xAB;
    buf[1] = 0xCD;
    buf[2] = 0xEF;
    buf[3] = 0x01;
    // The stream must end with a non-zero marker byte.
    buf[buf.len - 1] = 0x01;
    const ds = try BIT_DStream.init(&buf);
    const a = ds.lookBits(8);
    const b = ds.lookBits(8);
    try testing.expectEqual(a, b);
    var mutable = ds;
    try testing.expectEqual(a, mutable.readBits(8));
    try testing.expectEqual(b, mutable.readBits(8));
}
