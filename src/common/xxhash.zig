const PRIME64_1: u64 = 0x9E3779B185EBCA87;
const PRIME64_2: u64 = 0xC2B2AE3D27D4EB4F;
const PRIME64_3: u64 = 0x165667B19E3779F9;
const PRIME64_4: u64 = 0x85EBCA77C2B2AE63;
const PRIME64_5: u64 = 0x27D4EB2F165667C5;

const std = @import("std");

fn rotl64(x: u64, r: u6) u64 {
    return std.math.rotl(u64, x, r);
}

pub fn xxhash64(data: []const u8, seed: u64) u64 {
    var h64: u64 = undefined;
    const len = data.len;
    var p: usize = 0;
    if (len >= 32) {
        var v1 = seed +% PRIME64_1 +% PRIME64_2;
        var v2 = seed +% PRIME64_2;
        var v3 = seed;
        var v4 = seed -% PRIME64_1;
        while (p + 32 <= len) : (p += 32) {
            v1 = rotl64(v1 +% read64(data[p..]) *% PRIME64_2, 31) *% PRIME64_1;
            v2 = rotl64(v2 +% read64(data[p + 8 ..]) *% PRIME64_2, 31) *% PRIME64_1;
            v3 = rotl64(v3 +% read64(data[p + 16 ..]) *% PRIME64_2, 31) *% PRIME64_1;
            v4 = rotl64(v4 +% read64(data[p + 24 ..]) *% PRIME64_2, 31) *% PRIME64_1;
        }
        h64 = rotl64(v1, 1) +% rotl64(v2, 7) +% rotl64(v3, 12) +% rotl64(v4, 18);
        h64 = mergeAcc(h64, v1);
        h64 = mergeAcc(h64, v2);
        h64 = mergeAcc(h64, v3);
        h64 = mergeAcc(h64, v4);
    } else {
        h64 = seed +% PRIME64_5;
    }
    h64 +%= @as(u64, len);
    while (p + 8 <= len) : (p += 8) {
        const k1 = rotl64(read64(data[p..]) *% PRIME64_2, 31) *% PRIME64_1;
        h64 ^= k1;
        h64 = rotl64(h64, 27) *% PRIME64_1 +% PRIME64_4;
    }
    if (p + 4 <= len) {
        h64 ^= @as(u64, read32(data[p..])) *% PRIME64_1;
        p += 4;
        h64 = rotl64(h64, 23) *% PRIME64_2 +% PRIME64_3;
    }
    while (p < len) : (p += 1) {
        h64 ^= @as(u64, data[p]) *% PRIME64_5;
        h64 = rotl64(h64, 11) *% PRIME64_1;
    }
    h64 ^= h64 >> 33;
    h64 *%= PRIME64_2;
    h64 ^= h64 >> 29;
    h64 *%= PRIME64_3;
    h64 ^= h64 >> 32;
    return h64;
}

fn mergeAcc(h: u64, v: u64) u64 {
    var hh = h;
    hh ^= rotl64(v *% PRIME64_2, 31) *% PRIME64_1;
    hh = hh *% PRIME64_1 +% PRIME64_4;
    return hh;
}

fn read64(d: []const u8) u64 {
    return @as(u64, d[0]) |
        (@as(u64, d[1]) << 8) |
        (@as(u64, d[2]) << 16) |
        (@as(u64, d[3]) << 24) |
        (@as(u64, d[4]) << 32) |
        (@as(u64, d[5]) << 40) |
        (@as(u64, d[6]) << 48) |
        (@as(u64, d[7]) << 56);
}

fn read32(d: []const u8) u32 {
    return @as(u32, d[0]) |
        (@as(u32, d[1]) << 8) |
        (@as(u32, d[2]) << 16) |
        (@as(u32, d[3]) << 24);
}

pub const XxHash64State = struct {
    seed: u64,
    total_len: usize,
    buffer: [32]u8,
    buffered: usize,
    v1: u64,
    v2: u64,
    v3: u64,
    v4: u64,
    large_len: bool,

    pub fn init(seed: u64) XxHash64State {
        return .{
            .seed = seed,
            .total_len = 0,
            .buffer = [_]u8{0} ** 32,
            .buffered = 0,
            .v1 = seed +% PRIME64_1 +% PRIME64_2,
            .v2 = seed +% PRIME64_2,
            .v3 = seed,
            .v4 = seed -% PRIME64_1,
            .large_len = false,
        };
    }

    pub fn update(self: *XxHash64State, data: []const u8) void {
        self.total_len += data.len;
        if (self.total_len >= 32) self.large_len = true;
        var p: usize = 0;
        if (self.buffered > 0) {
            const need = 32 - self.buffered;
            if (data.len < need) {
                @memcpy(self.buffer[self.buffered..][0..data.len], data);
                self.buffered += data.len;
                return;
            } else {
                @memcpy(self.buffer[self.buffered..][0..need], data[0..need]);
                self.consumeStripe(self.buffer[0..32]);
                self.buffered = 0;
                p = need;
            }
        }
        while (p + 32 <= data.len) : (p += 32) {
            self.consumeStripe(data[p .. p + 32]);
        }
        if (p < data.len) {
            const rem = data.len - p;
            @memcpy(self.buffer[0..rem], data[p..]);
            self.buffered = rem;
        }
    }

    fn consumeStripe(self: *XxHash64State, stripe: []const u8) void {
        self.v1 = rotl64(self.v1 +% read64(stripe[0..]) *% PRIME64_2, 31) *% PRIME64_1;
        self.v2 = rotl64(self.v2 +% read64(stripe[8..]) *% PRIME64_2, 31) *% PRIME64_1;
        self.v3 = rotl64(self.v3 +% read64(stripe[16..]) *% PRIME64_2, 31) *% PRIME64_1;
        self.v4 = rotl64(self.v4 +% read64(stripe[24..]) *% PRIME64_2, 31) *% PRIME64_1;
    }

    pub fn digest(self: *const XxHash64State) u64 {
        var h64: u64 = undefined;
        if (self.large_len) {
            h64 = rotl64(self.v1, 1) +% rotl64(self.v2, 7) +% rotl64(self.v3, 12) +% rotl64(self.v4, 18);
            h64 = mergeAcc(h64, self.v1);
            h64 = mergeAcc(h64, self.v2);
            h64 = mergeAcc(h64, self.v3);
            h64 = mergeAcc(h64, self.v4);
        } else {
            h64 = self.seed +% PRIME64_5;
        }
        h64 +%= @as(u64, self.total_len);
        var p: usize = 0;
        const buf = self.buffer[0..self.buffered];
        while (p + 8 <= buf.len) : (p += 8) {
            const k1 = rotl64(read64(buf[p..]) *% PRIME64_2, 31) *% PRIME64_1;
            h64 ^= k1;
            h64 = rotl64(h64, 27) *% PRIME64_1 +% PRIME64_4;
        }
        if (p + 4 <= buf.len) {
            h64 ^= @as(u64, read32(buf[p..])) *% PRIME64_1;
            p += 4;
            h64 = rotl64(h64, 23) *% PRIME64_2 +% PRIME64_3;
        }
        while (p < buf.len) : (p += 1) {
            h64 ^= @as(u64, buf[p]) *% PRIME64_5;
            h64 = rotl64(h64, 11) *% PRIME64_1;
        }
        h64 ^= h64 >> 33;
        h64 *%= PRIME64_2;
        h64 ^= h64 >> 29;
        h64 *%= PRIME64_3;
        h64 ^= h64 >> 32;
        return h64;
    }
};
