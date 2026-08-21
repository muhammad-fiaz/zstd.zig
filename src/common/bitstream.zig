const std = @import("std");

pub const BitReader = struct {
    ptr: [*]const u8,
    len: usize,
    pos: usize,
    bit_container: u64,
    bits_consumed: u32,
    next_word: usize,

    pub fn init(src: []const u8) BitReader {
        var r = BitReader{
            .ptr = src.ptr,
            .len = src.len,
            .pos = src.len,
            .bit_container = 0,
            .bits_consumed = 0,
            .next_word = src.len,
        };
        r.reload();
        return r;
    }

    fn reload(r: *BitReader) void {
        if (r.next_word >= 8) {
            r.next_word -= 8;
            r.bit_container = readLE64(r.ptr + r.next_word);
            r.bits_consumed = 0;
        } else if (r.next_word > 0) {
            var tmp: u64 = 0;
            var i: usize = 0;
            while (i < r.next_word) : (i += 1) {
                tmp |= @as(u64, r.ptr[i]) << @as(std.math.Log2Int(u64), @intCast(i * 8));
            }
            r.bit_container = tmp;
            r.bits_consumed = @intCast((8 - r.next_word) * 8);
            r.next_word = 0;
        }
    }

    pub fn getBits(r: *BitReader, nb_bits: u32) u64 {
        if (nb_bits == 0) return 0;
        const mask: u64 = if (nb_bits == 64) 0xFFFFFFFFFFFFFFFF else (@as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(nb_bits))) - 1;
        const val = (r.bit_container >> @intCast(r.bits_consumed)) & mask;
        r.bits_consumed += nb_bits;
        if (r.bits_consumed >= 56 and r.next_word > 0) {
            const overflow = r.bits_consumed - 56;
            r.reload();
            if (overflow > 0) {
                r.bits_consumed = overflow;
            }
        }
        return val;
    }

    pub fn peekBits(r: *const BitReader, nb_bits: u32) u64 {
        if (nb_bits == 0) return 0;
        const mask: u64 = if (nb_bits == 64) 0xFFFFFFFFFFFFFFFF else (@as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(nb_bits))) - 1;
        return (r.bit_container >> @intCast(r.bits_consumed)) & mask;
    }

    pub fn skipBits(r: *BitReader, nb_bits: u32) void {
        r.bits_consumed += nb_bits;
        if (r.bits_consumed >= 56 and r.next_word > 0) {
            const overflow = r.bits_consumed - 56;
            r.reload();
            if (overflow > 0) r.bits_consumed = overflow;
        }
    }

    pub fn endOfStream(r: *const BitReader) bool {
        return r.next_word == 0 and r.bits_consumed >= 64;
    }
};

pub const BitWriter = struct {
    buffer: []u8,
    pos: usize,
    bit_container: u64,
    bit_pos: u32,

    pub fn init(buffer: []u8) BitWriter {
        return .{ .buffer = buffer, .pos = 0, .bit_container = 0, .bit_pos = 0 };
    }

    pub fn addBits(self: *BitWriter, value: u64, nb_bits: u32) void {
        self.bit_container |= (value << @as(std.math.Log2Int(u64), @intCast(self.bit_pos)));
        self.bit_pos += nb_bits;
        while (self.bit_pos >= 8) {
            if (self.pos < self.buffer.len) {
                self.buffer[self.pos] = @truncate(self.bit_container & 0xFF);
                self.pos += 1;
            }
            self.bit_container >>= 8;
            self.bit_pos -= 8;
        }
    }

    pub fn flush(self: *BitWriter) usize {
        if (self.bit_pos > 0) {
            if (self.pos < self.buffer.len) {
                self.buffer[self.pos] = @truncate(self.bit_container & 0xFF);
                self.pos += 1;
            }
            self.bit_pos = 0;
            self.bit_container = 0;
        }
        return self.pos;
    }
};

fn readLE64(ptr: [*]const u8) u64 {
    return @as(u64, ptr[0]) |
        (@as(u64, ptr[1]) << 8) |
        (@as(u64, ptr[2]) << 16) |
        (@as(u64, ptr[3]) << 24) |
        (@as(u64, ptr[4]) << 32) |
        (@as(u64, ptr[5]) << 40) |
        (@as(u64, ptr[6]) << 48) |
        (@as(u64, ptr[7]) << 56);
}

fn writeLE64(ptr: [*]u8, v: u64) void {
    ptr[0] = @truncate(v);
    ptr[1] = @truncate(v >> 8);
    ptr[2] = @truncate(v >> 16);
    ptr[3] = @truncate(v >> 24);
    ptr[4] = @truncate(v >> 32);
    ptr[5] = @truncate(v >> 40);
    ptr[6] = @truncate(v >> 48);
    ptr[7] = @truncate(v >> 56);
}

pub const BIT_CStream = struct {
    bit_container: u64 = 0,
    bit_pos: u32 = 0,
    buf: []u8,
    ptr: usize = 0,
    end_ptr: usize = 0,

    pub fn init(dst: []u8) !BIT_CStream {
        if (dst.len <= 8) return error.DstSizeTooSmall;
        return BIT_CStream{
            .bit_container = 0,
            .bit_pos = 0,
            .buf = dst,
            .ptr = 0,
            .end_ptr = dst.len - 8,
        };
    }

    pub fn addBits(self: *BIT_CStream, value: u64, nb_bits: u32) void {
        if (nb_bits == 0) return;
        const mask: u64 = if (nb_bits >= 64) 0xFFFFFFFFFFFFFFFF else (@as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(nb_bits))) - 1;
        self.bit_container |= (value & mask) << @as(std.math.Log2Int(u64), @intCast(self.bit_pos));
        self.bit_pos += nb_bits;
    }

    pub fn addBitsFast(self: *BIT_CStream, value: u64, nb_bits: u32) void {
        if (nb_bits == 0) return;
        self.bit_container |= value << @as(std.math.Log2Int(u64), @intCast(self.bit_pos));
        self.bit_pos += nb_bits;
    }

    pub fn flushBits(self: *BIT_CStream) void {
        const nb_bytes = self.bit_pos >> 3;
        std.debug.assert(self.bit_pos < 64);
        std.debug.assert(self.ptr <= self.end_ptr);
        if (self.ptr + 8 <= self.buf.len) {
            writeLE64(self.buf.ptr + self.ptr, self.bit_container);
        } else {
            for (0..@min(self.buf.len - self.ptr, 8)) |i| {
                self.buf[self.ptr + i] = @truncate((self.bit_container >> @as(std.math.Log2Int(u64), @intCast(i * 8))) & 0xFF);
            }
        }
        self.ptr += nb_bytes;
        if (self.ptr > self.end_ptr) self.ptr = self.end_ptr;
        self.bit_pos &= 7;
        self.bit_container >>= @as(std.math.Log2Int(u64), @intCast(nb_bytes * 8));
    }

    pub fn close(self: *BIT_CStream) !usize {
        self.addBitsFast(1, 1); // end mark
        self.flushBits();
        if (self.bit_pos > 0) {
            if (self.ptr < self.buf.len) {
                self.buf[self.ptr] = @truncate(self.bit_container & 0xFF);
            }
        }
        if (self.ptr >= self.end_ptr) return error.DstSizeTooSmall;
        return self.ptr + (if (self.bit_pos > 0) @as(usize, 1) else @as(usize, 0));
    }
};

pub const DStreamStatus = enum {
    unfinished,
    end_of_buffer,
    completed,
    overflow,
};

pub const BIT_DStream = struct {
    bit_container: u64 = 0,
    bits_consumed: u32 = 0,
    src: []const u8,
    ptr: usize = 0, // offset in src where ptr points

    pub fn init(src: []const u8) !BIT_DStream {
        if (src.len < 1) return error.SrcSizeWrong;
        var stream = BIT_DStream{
            .src = src,
            .bit_container = 0,
            .bits_consumed = 0,
            .ptr = 0,
        };

        if (src.len >= 8) {
            stream.ptr = src.len - 8;
            stream.bit_container = readLE64(src.ptr + stream.ptr);
            const last_byte = src[src.len - 1];
            if (last_byte == 0) return error.Corruption;
            stream.bits_consumed = 8 - @as(u32, 31 - @clz(@as(u32, last_byte)));
        } else {
            stream.ptr = 0;
            var container: u64 = src[0];
            switch (src.len) {
                7 => {
                    container += @as(u64, src[6]) << (64 - 16);
                    container += @as(u64, src[5]) << (64 - 24);
                    container += @as(u64, src[4]) << (64 - 32);
                    container += @as(u64, src[3]) << 24;
                    container += @as(u64, src[2]) << 16;
                    container += @as(u64, src[1]) << 8;
                },
                6 => {
                    container += @as(u64, src[5]) << (64 - 24);
                    container += @as(u64, src[4]) << (64 - 32);
                    container += @as(u64, src[3]) << 24;
                    container += @as(u64, src[2]) << 16;
                    container += @as(u64, src[1]) << 8;
                },
                5 => {
                    container += @as(u64, src[4]) << (64 - 32);
                    container += @as(u64, src[3]) << 24;
                    container += @as(u64, src[2]) << 16;
                    container += @as(u64, src[1]) << 8;
                },
                4 => {
                    container += @as(u64, src[3]) << 24;
                    container += @as(u64, src[2]) << 16;
                    container += @as(u64, src[1]) << 8;
                },
                3 => {
                    container += @as(u64, src[2]) << 16;
                    container += @as(u64, src[1]) << 8;
                },
                2 => {
                    container += @as(u64, src[1]) << 8;
                },
                else => {},
            }
            stream.bit_container = container;
            const last_byte = src[src.len - 1];
            if (last_byte == 0) return error.Corruption;
            const high_bit = 31 - @clz(@as(u32, last_byte));
            stream.bits_consumed = (8 - @as(u32, high_bit)) + @as(u32, @intCast((8 - src.len) * 8));
        }
        return stream;
    }

    pub fn lookBits(self: *const BIT_DStream, nb_bits: u32) u64 {
        if (nb_bits == 0) return 0;
        const reg_mask: u32 = 63;
        const shifted_left = self.bit_container << @as(std.math.Log2Int(u64), @intCast(self.bits_consumed & reg_mask));
        const shift_right = ((reg_mask + 1) - nb_bits) & reg_mask;
        return shifted_left >> @as(std.math.Log2Int(u64), @intCast(shift_right));
    }

    pub fn skipBits(self: *BIT_DStream, nb_bits: u32) void {
        self.bits_consumed += nb_bits;
    }

    pub fn readBits(self: *BIT_DStream, nb_bits: u32) u64 {
        const val = self.lookBits(nb_bits);
        self.skipBits(nb_bits);
        return val;
    }

    pub fn readBitsFast(self: *BIT_DStream, nb_bits: u32) u64 {
        return self.readBits(nb_bits);
    }

    pub fn reload(self: *BIT_DStream) DStreamStatus {
        if (self.bits_consumed > 64) {
            return .overflow;
        }
        // In C: limitPtr = start + 8 (i.e. offset 8 in srcBuffer)
        // If ptr >= 8, normal internal reload
        if (self.ptr >= 8) {
            const nb_bytes = self.bits_consumed >> 3;
            self.ptr -= nb_bytes;
            self.bits_consumed &= 7;
            self.bit_container = readLE64(self.src.ptr + self.ptr);
            return .unfinished;
        }
        // If ptr == 0 (reached start of buffer, no more bytes left to shift in)
        if (self.ptr == 0) {
            if (self.bits_consumed < 64) return .end_of_buffer;
            return .completed;
        }
        // 0 < ptr < 8: cautious update (only happens when srcSize > 8 and ptr is nearing 0)
        var nb_bytes = self.bits_consumed >> 3;
        var result: DStreamStatus = .unfinished;
        if (self.ptr < nb_bytes) {
            nb_bytes = @intCast(self.ptr);
            result = .end_of_buffer;
        }
        self.ptr -= nb_bytes;
        self.bits_consumed -= nb_bytes * 8;
        self.bit_container = readLE64(self.src.ptr + self.ptr);
        return result;
    }

    pub fn endOfStream(self: *const BIT_DStream) bool {
        return self.ptr == 0 and self.bits_consumed >= 64;
    }
};

pub const InverseBitReader = struct {
    src: []const u8,
    bit_container: u64,
    bits_consumed: u32,
    ptr: usize,

    pub fn init(src: []const u8) InverseBitReader {
        var r = InverseBitReader{
            .src = src,
            .bit_container = 0,
            .bits_consumed = 32,
            .ptr = src.len,
        };
        r.reload();
        return r;
    }

    fn reload(r: *InverseBitReader) void {
        if (r.ptr >= 4) {
            r.ptr -= 4;
            const v = @as(u32, r.src[r.ptr]) |
                (@as(u32, r.src[r.ptr + 1]) << 8) |
                (@as(u32, r.src[r.ptr + 2]) << 16) |
                (@as(u32, r.src[r.ptr + 3]) << 24);
            r.bit_container = (r.bit_container << 32) | v;
            r.bits_consumed -= 32;
        } else if (r.ptr > 0) {
            var v: u64 = 0;
            var i: usize = 0;
            while (i < r.ptr) : (i += 1) {
                v |= @as(u64, r.src[i]) << @as(std.math.Log2Int(u64), @intCast(i * 8));
            }
            const bits = r.ptr * 8;
            r.bit_container = (r.bit_container << @as(std.math.Log2Int(u64), @intCast(bits))) | v;
            r.bits_consumed -= @intCast(bits);
            r.ptr = 0;
        }
    }

    pub fn getBitsFast(r: *InverseBitReader, nb_bits: u32) u32 {
        if (nb_bits == 0) return 0;
        if (r.bits_consumed + nb_bits > 64) r.reload();
        const mask: u64 = if (nb_bits >= 32) 0xFFFFFFFF else (@as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(nb_bits))) - 1;
        const val: u32 = @truncate((r.bit_container >> @intCast(r.bits_consumed)) & mask);
        r.bits_consumed += nb_bits;
        return val;
    }
};
