const std = @import("std");
const errors = @import("errors.zig");

pub const ZstdError = errors.ZstdError;

// Forward LSB bit reader. C reference (lib/common/bitstream.h:BIT_DStream_t) uses reverse
// LIFO with bitContainer and bitsConsumed, reading via BIT_lookBits/BIT_readBits. This Zig version
// reads forward LSB to match our custom BitWriter. For spec FSE/HUF reverse streams, a reverse
// reader would be required (TODO). Filling logic mirrors BIT_reloadDStream.
pub const BitReader = struct {
    ptr: [*]const u8,
    end: [*]const u8,
    bits: u64,
    bits_left: i32,

    pub fn init(src: []const u8) BitReader {
        const end_ptr = src.ptr + src.len;
        return .{
            .ptr = src.ptr,
            .end = end_ptr,
            .bits = 0,
            .bits_left = 0,
        };
    }

    pub fn fillBits(self: *BitReader) ZstdError!void {
        if (self.bits_left >= 24) return;
        while (self.bits_left <= 56 and @intFromPtr(self.ptr) < @intFromPtr(self.end)) {
            self.bits |= @as(u64, self.ptr[0]) << @intCast(@as(u32, @intCast(self.bits_left)));
            self.ptr += 1;
            self.bits_left += 8;
        }
    }

    pub fn readBits(self: *BitReader, comptime n: u6) ZstdError!u32 {
        if (self.bits_left < n) return error.InvalidBitStream;
        const val: u32 = @truncate(self.bits);
        self.bits >>= n;
        self.bits_left -= n;
        return val;
    }

    pub fn readBitsRuntime(self: *BitReader, n: u32) ZstdError!u32 {
        if (n > 32) return error.InvalidBitStream;
        if (self.bits_left < @as(i32, @intCast(n))) return error.InvalidBitStream;
        const val: u32 = @truncate(self.bits);
        self.bits >>= @intCast(n);
        self.bits_left -= @as(i32, @intCast(n));
        return val;
    }

    pub fn peekBits(self: *BitReader, comptime n: u6) ZstdError!u32 {
        if (self.bits_left < n) return error.InvalidBitStream;
        return @truncate(self.bits);
    }

    pub fn peekBitsRuntime(self: *BitReader, n: u32) ZstdError!u32 {
        if (n > 32) return error.InvalidBitStream;
        if (self.bits_left < @as(i32, @intCast(n))) return error.InvalidBitStream;
        return @truncate(self.bits);
    }

    pub fn skipBits(self: *BitReader, n: u32) void {
        const skip = @min(n, @as(u32, @intCast(self.bits_left)));
        self.bits >>= @intCast(skip);
        self.bits_left -= @as(i32, @intCast(skip));
    }

    pub fn alignToByte(self: *BitReader) void {
        const discard: u3 = @intCast(@as(u3, @intCast(self.bits_left)) & 7);
        self.bits >>= discard;
        self.bits_left -= discard;
    }

    pub fn bytesRemaining(self: *BitReader) usize {
        return @intFromPtr(self.end) - @intFromPtr(self.ptr);
    }

    pub fn hasBits(self: *BitReader) bool {
        return self.bits_left > 0 or @intFromPtr(self.ptr) < @intFromPtr(self.end);
    }
};
