const std = @import("std");
const errors = @import("errors.zig");

pub const ZstdError = errors.ZstdError;

// Minimal forward bit writer (LSB first). The C reference (lib/common/bitstream.h:BIT_CStream_t)
// uses a LIFO reverse direction where first bits written are last read. This Zig version uses
// forward LSB for simplicity to match our custom BitReader. For spec-compliant FSE/HUF streams,
// a reverse writer would be needed (TODO). Refer to lib/common/bitstream.h:BIT_addBits, BIT_flushBits.
pub const BitWriter = struct {
    buf: []u8,
    pos: usize,
    acc: u64,
    bits: u32,

    pub fn init(buf: []u8) BitWriter {
        return .{ .buf = buf, .pos = 0, .acc = 0, .bits = 0 };
    }

    pub fn writeBits(self: *BitWriter, value: u32, nbBits: u5) ZstdError!void {
        if (nbBits == 0) return;
        if (nbBits > 31) return error.InvalidBitStream;
        self.acc |= @as(u64, value & ((@as(u32, 1) << nbBits) - 1)) << @intCast(self.bits);
        self.bits += nbBits;
        while (self.bits >= 8) {
            if (self.pos >= self.buf.len) return error.DstSizeTooSmall;
            self.buf[self.pos] = @truncate(self.acc);
            self.pos += 1;
            self.acc >>= 8;
            self.bits -= 8;
        }
    }

    pub fn writeBitsRuntime(self: *BitWriter, value: u32, nbBits: u32) ZstdError!void {
        if (nbBits == 0) return;
        if (nbBits > 32) return error.InvalidBitStream;
        self.acc |= @as(u64, value) << @intCast(self.bits);
        self.bits += @intCast(nbBits);
        while (self.bits >= 8) {
            if (self.pos >= self.buf.len) return error.DstSizeTooSmall;
            self.buf[self.pos] = @truncate(self.acc);
            self.pos += 1;
            self.acc >>= 8;
            self.bits -= 8;
        }
    }

    pub fn flush(self: *BitWriter) ZstdError!void {
        while (self.bits > 0) {
            if (self.pos >= self.buf.len) return error.DstSizeTooSmall;
            self.buf[self.pos] = @truncate(self.acc);
            self.pos += 1;
            self.acc >>= 8;
            if (self.bits >= 8) self.bits -= 8 else self.bits = 0;
        }
        self.acc = 0;
        self.bits = 0;
    }

    pub fn alignToByte(self: *BitWriter) ZstdError!void {
        try self.flush();
    }

    pub fn bytesWritten(self: *const BitWriter) usize {
        return self.pos;
    }

    pub fn close(self: *BitWriter) ZstdError!usize {
        // lib/common/bitstream.h:BIT_closeCStream adds endMark (1 bit) and flushes
        try self.writeBits(1, 1);
        try self.flush();
        return self.pos;
    }
};
