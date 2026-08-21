const std = @import("std");

pub const XXH_PRIME1: u64 = 0x9E3779B185EBCA87;
pub const XXH_PRIME2: u64 = 0xC2B2AE3D27D4EB4F;
pub const XXH_PRIME3: u64 = 0x165667B19E3779F9;
pub const XXH_PRIME4: u64 = 0x85EBCA77C2B2AE63;
pub const XXH_PRIME5: u64 = 0x27D4EB2F165667C5;

inline fn round(acc: u64, input: u64) u64 {
    var a = acc;
    a +%= input *% XXH_PRIME2;
    a = std.math.rotl(u64, a, 31);
    a *%= XXH_PRIME1;
    return a;
}

inline fn mergeRound(acc: u64, val: u64) u64 {
    const r = round(0, val);
    var a = acc ^ r;
    a = a *% XXH_PRIME1 +% XXH_PRIME4;
    return a;
}

inline fn avalanche(h: u64) u64 {
    var v = h;
    v ^= v >> 33;
    v *%= XXH_PRIME2;
    v ^= v >> 29;
    v *%= XXH_PRIME3;
    v ^= v >> 32;
    return v;
}

pub fn hash(data: []const u8) u64 {
    const len = data.len;
    var h64: u64 = undefined;

    if (len >= 32) {
        const end_ptr = data.ptr + len;
        const limit = end_ptr - 32;

        var v1 = XXH_PRIME5 +% XXH_PRIME1 +% XXH_PRIME2;
        var v2 = XXH_PRIME5 +% XXH_PRIME2;
        var v3 = XXH_PRIME5 +% 0;
        var v4 = XXH_PRIME5 -% XXH_PRIME1;

        var ptr = data.ptr;
        while (@intFromPtr(ptr) <= @intFromPtr(limit)) : (ptr += 32) {
            v1 = round(v1, std.mem.readInt(u64, ptr[0..8], .little));
            v2 = round(v2, std.mem.readInt(u64, ptr[8..16], .little));
            v3 = round(v3, std.mem.readInt(u64, ptr[16..24], .little));
            v4 = round(v4, std.mem.readInt(u64, ptr[24..32], .little));
        }

        h64 = std.math.rotl(u64, v1, 1) +% std.math.rotl(u64, v2, 7) +% std.math.rotl(u64, v3, 12) +% std.math.rotl(u64, v4, 18);
        h64 = mergeRound(h64, v1);
        h64 = mergeRound(h64, v2);
        h64 = mergeRound(h64, v3);
        h64 = mergeRound(h64, v4);
    } else {
        h64 = XXH_PRIME5;
    }

    h64 +%= @as(u64, len);

    var ptr = data.ptr + len;

    while (@intFromPtr(ptr) >= @intFromPtr(data.ptr) + 8) {
        ptr -= 8;
        h64 ^= round(0, std.mem.readInt(u64, ptr[0..8], .little));
        h64 = std.math.rotl(u64, h64, 27) *% XXH_PRIME1 +% XXH_PRIME4;
    }

    if (@intFromPtr(ptr) >= @intFromPtr(data.ptr) + 4) {
        ptr -= 4;
        h64 ^= (@as(u64, std.mem.readInt(u32, ptr[0..4], .little)) *% XXH_PRIME1);
        h64 = std.math.rotl(u64, h64, 23) *% XXH_PRIME2 +% XXH_PRIME3;
    }

    while (@intFromPtr(ptr) > @intFromPtr(data.ptr)) {
        ptr -= 1;
        h64 ^= (@as(u64, ptr[0]) *% XXH_PRIME5);
        h64 = std.math.rotl(u64, h64, 11) *% XXH_PRIME1;
    }

    return avalanche(h64);
}

test "xxh64 empty" {
    const h = hash("");
    try std.testing.expect(h != 0);
}

test "xxh64 hash non-zero" {
    const data = "Hello, world!";
    const h = hash(data);
    try std.testing.expect(h != 0);
}

test "xxh64 deterministic" {
    const data = "deterministic test data for xxh64 verification";
    const h1 = hash(data);
    const h2 = hash(data);
    try std.testing.expectEqual(h1, h2);
}

test "xxh64 different inputs produce different hashes" {
    const h1 = hash("input1");
    const h2 = hash("input2");
    try std.testing.expect(h1 != h2);
}
