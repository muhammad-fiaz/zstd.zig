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
