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
    totalLen: usize,
    buffer: [32]u8,
    buffered: usize,
    v1: u64,
    v2: u64,
    v3: u64,
    v4: u64,
    largeLen: bool,

    pub fn init(seed: u64) XxHash64State {
        return .{
            .seed = seed,
            .totalLen = 0,
            .buffer = @splat(0),
            .buffered = 0,
            .v1 = seed +% PRIME64_1 +% PRIME64_2,
            .v2 = seed +% PRIME64_2,
            .v3 = seed,
            .v4 = seed -% PRIME64_1,
            .largeLen = false,
        };
    }

    pub fn update(self: *XxHash64State, data: []const u8) void {
        self.totalLen += data.len;
        if (self.totalLen >= 32) self.largeLen = true;
        var p: usize = 0;
        if (self.buffered > 0) {
            const need = 32 - self.buffered;
            if (data.len < need) {
                std.mem.copyForwards(u8, self.buffer[self.buffered..][0..data.len], data);
                self.buffered += data.len;
                return;
            } else {
                std.mem.copyForwards(u8, self.buffer[self.buffered..][0..need], data[0..need]);
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
            std.mem.copyForwards(u8, self.buffer[0..rem], data[p..]);
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
        if (self.largeLen) {
            h64 = rotl64(self.v1, 1) +% rotl64(self.v2, 7) +% rotl64(self.v3, 12) +% rotl64(self.v4, 18);
            h64 = mergeAcc(h64, self.v1);
            h64 = mergeAcc(h64, self.v2);
            h64 = mergeAcc(h64, self.v3);
            h64 = mergeAcc(h64, self.v4);
        } else {
            h64 = self.seed +% PRIME64_5;
        }
        h64 +%= @as(u64, self.totalLen);
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

const testing = @import("std").testing;

test "xxhash64 empty" {
    try testing.expectEqual(@as(u64, 0xEF46DB3751D8E999), xxhash64("", 0));
}

test "xxhash64 matches the published vectors" {
    // A wrong checksum constant is invisible: a decoder agreeing with the encoder on
    // the wrong one would accept every tampered frame. These are the format's
    // reference values for seed 0, so agreement is with the format.
    try testing.expectEqual(@as(u64, 0xD24EC4F1A98C6E5B), xxhash64("a", 0));
    try testing.expectEqual(@as(u64, 0x44BC2CF5AD770999), xxhash64("abc", 0));
}

test "xxhash64 streamed in pieces matches the one-shot digest" {
    // The streaming form has its own tail handling for the leftover bytes, so
    // splitting the input exercises a different path from the single-shot
    // length branch.
    var split_at_two = XxHash64State.init(0);
    split_at_two.update("ab");
    split_at_two.update("c");
    try testing.expectEqual(@as(u64, 0x44BC2CF5AD770999), split_at_two.digest());

    // Splitting inside the 8-byte stripe and inside the 4-byte remainder both
    // have to converge on the same answer.
    var many = XxHash64State.init(0);
    const stripe = "0123456789abcdefghijklmnop";
    for (stripe) |c| many.update(&[_]u8{c});
    try testing.expectEqual(xxhash64(stripe, 0), many.digest());
}

test "xxhash64 deterministic" {
    const a = xxhash64("hello", 0);
    const b = xxhash64("hello", 0);
    try testing.expectEqual(a, b);
}

test "xxhash64 different inputs" {
    const a = xxhash64("hello", 0);
    const b = xxhash64("world", 0);
    try testing.expect(a != b);
}

test "XxHash64State" {
    var st = XxHash64State.init(0);
    st.update("hello");
    try testing.expectEqual(xxhash64("hello", 0), st.digest());
}

test "XxHash64State multi update" {
    var st1 = XxHash64State.init(0);
    st1.update("hel");
    st1.update("lo");
    var st2 = XxHash64State.init(0);
    st2.update("hello");
    try testing.expectEqual(st1.digest(), st2.digest());
}
