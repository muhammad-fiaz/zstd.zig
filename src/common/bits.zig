//! Bit-twiddling primitives. Zstandard bitstreams are little-endian, written from
//! the low end of a 64-bit container. Every helper here is total (defined for
//! every input) and endianness-explicit, so results match on little- and
//! big-endian targets.

const std = @import("std");
const builtin = @import("builtin");

/// Index of the most significant set bit. `0` maps to `0`, matching the
/// behaviour the format relies on when scanning symbol codes.
pub fn highbit32(val: u32) u32 {
    return 31 - @clz(val);
}

pub fn countTrailingZeros32(val: u32) u32 {
    return @ctz(val);
}

pub fn countLeadingZeros32(val: u32) u32 {
    return @clz(val);
}

/// Number of leading bytes shared by two pointers, used to turn a word-wise
/// comparison into a byte match length. The scan is expressed in terms of
/// byte order explicitly so big-endian targets do not silently invert it.
pub fn nbCommonBytes(val: usize) u32 {
    if (val == 0) return @sizeOf(usize);
    if (builtin.cpu.arch.endian() == .little) {
        if (@sizeOf(usize) == 8) {
            return @as(u32, @ctz(@as(u64, val))) >> 3;
        } else {
            return @as(u32, @ctz(@as(u32, @truncate(val)))) >> 3;
        }
    } else {
        if (@sizeOf(usize) == 8) {
            return @as(u32, @clz(@as(u64, val))) >> 3;
        } else {
            return @as(u32, @clz(@as(u32, @truncate(val)))) >> 3;
        }
    }
}

pub fn rotateRightU32(val: u32, count: u32) u32 {
    return std.math.rotr(u32, val, count);
}

pub fn rotateRightU64(val: u64, count: u32) u64 {
    return std.math.rotr(u64, val, count);
}

pub fn rotateLeftU32(val: u32, count: u32) u32 {
    return std.math.rotl(u32, val, count);
}

pub fn rotateLeftU64(val: u64, count: u32) u64 {
    return std.math.rotl(u64, val, count);
}

/// Read a little-endian `u64` from `src[0..8]` without requiring alignment.
/// The byte-at-a-time form is what the format's back-referencing loaders rely
/// on, and it compiles to a single load on little-endian targets.
pub inline fn readLe64(src: []const u8) u64 {
    return std.mem.readInt(u64, src[0..8], .little);
}

/// Read a little-endian `u32` from `src[0..4]` without requiring alignment.
pub inline fn readLe32(src: []const u8) u32 {
    return std.mem.readInt(u32, src[0..4], .little);
}

/// Read a little-endian `u16` from `src[0..2]` without requiring alignment.
pub inline fn readLe16(src: []const u8) u16 {
    return std.mem.readInt(u16, src[0..2], .little);
}

/// Read a little-endian `u24` (3 bytes) as `u32`.
pub inline fn readLe24(src: []const u8) u32 {
    return @as(u32, src[0]) |
        (@as(u32, src[1]) << 8) |
        (@as(u32, src[2]) << 16);
}

pub inline fn writeLe64(dst: []u8, val: u64) void {
    std.mem.writeInt(u64, dst[0..8], val, .little);
}

pub inline fn writeLe32(dst: []u8, val: u32) void {
    std.mem.writeInt(u32, dst[0..4], val, .little);
}

pub inline fn writeLe16(dst: []u8, val: u16) void {
    std.mem.writeInt(u16, dst[0..2], val, .little);
}

const testing = std.testing;

test "highbit32 power of two" {
    try testing.expectEqual(@as(u32, 0), highbit32(1));
    try testing.expectEqual(@as(u32, 1), highbit32(2));
    try testing.expectEqual(@as(u32, 2), highbit32(4));
    try testing.expectEqual(@as(u32, 31), highbit32(0x80000000));
}

test "highbit32 non power of two" {
    try testing.expectEqual(@as(u32, 2), highbit32(7));
    try testing.expectEqual(@as(u32, 3), highbit32(15));
}

test "highbit32 is total over u32" {
    // Property: the reported bit index must actually be set. A bounded
    // pseudo-random sweep plus all powers of two covers the space without
    // looping over the full 2^32 domain.
    var v: u32 = 1;
    var i: usize = 0;
    while (i < 4096) : ({
        i += 1;
        v *%= 0x9E3779B1;
    }) {
        const idx = highbit32(v);
        try testing.expect(idx < 32);
        try testing.expect(v & (@as(u32, 1) << @intCast(idx)) != 0);
    }
    for (0..32) |j| {
        const shift: u5 = @intCast(j);
        try testing.expectEqual(@as(u32, @intCast(j)), highbit32(@as(u32, 1) << shift));
    }
}

test "countTrailingZeros32" {
    try testing.expectEqual(@as(u32, 0), countTrailingZeros32(1));
    try testing.expectEqual(@as(u32, 3), countTrailingZeros32(8));
    // Total: ctz(0) is defined as the bit width.
    try testing.expectEqual(@as(u32, 32), countTrailingZeros32(0));
}

test "countLeadingZeros32" {
    try testing.expectEqual(@as(u32, 31), countLeadingZeros32(1));
    try testing.expectEqual(@as(u32, 0), countLeadingZeros32(0x80000000));
    try testing.expectEqual(@as(u32, 32), countLeadingZeros32(0));
}

test "nbCommonBytes" {
    if (@sizeOf(usize) == 8) {
        try testing.expectEqual(@as(u32, 0), nbCommonBytes(0x00FF00FF00FF00FF));
        try testing.expectEqual(@as(u32, 7), nbCommonBytes(0xFF00000000000000));
    } else {
        try testing.expectEqual(@as(u32, 0), nbCommonBytes(0x00FF00FF));
        try testing.expectEqual(@as(u32, 3), nbCommonBytes(0xFF000000));
    }
    try testing.expectEqual(@as(u32, @intCast(@sizeOf(usize))), nbCommonBytes(0));
}

test "rotateRightU32" {
    try testing.expectEqual(@as(u32, 0xC0000000), rotateRightU32(0x80000001, 1));
    try testing.expectEqual(@as(u32, 1), rotateRightU32(1, 0));
    // Rotating by the full width is defined, not a panic.
    try testing.expectEqual(@as(u32, 1), rotateRightU32(1, 32));
    try testing.expectEqual(@as(u32, 0x00000002), rotateRightU32(1, 31));
}

test "rotateRightU64" {
    try testing.expectEqual(@as(u64, 2), rotateRightU64(1, 63));
    try testing.expectEqual(@as(u64, 0x8000000000000000), rotateRightU64(1, 1));
    try testing.expectEqual(@as(u64, 1), rotateRightU64(1, 64));
}

test "rotate helpers are inverses" {
    const a: u32 = 0xDEADBEEF;
    try testing.expectEqual(a, rotateLeftU32(rotateRightU32(a, 13), 13));
    const b: u64 = 0x0123456789ABCDEF;
    try testing.expectEqual(b, rotateLeftU64(rotateRightU64(b, 29), 29));
}

test "little endian read and write roundtrip" {
    var buf: [8]u8 = undefined;
    writeLe64(buf[0..], 0x0102030405060708);
    try testing.expectEqualSlices(u8, &[_]u8{ 8, 7, 6, 5, 4, 3, 2, 1 }, &buf);
    try testing.expectEqual(@as(u64, 0x0102030405060708), readLe64(&buf));

    writeLe32(buf[0..4], 0x11223344);
    try testing.expectEqual(@as(u32, 0x11223344), readLe32(buf[0..4]));

    writeLe16(buf[0..2], 0xABCD);
    try testing.expectEqual(@as(u16, 0xABCD), readLe16(buf[0..2]));

    try testing.expectEqual(@as(u32, 0x0000C3), readLe24(&[_]u8{ 0xC3, 0x00, 0x00 }));
}
