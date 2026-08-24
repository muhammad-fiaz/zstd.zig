const xxhash = @import("../common/xxhash.zig");

pub fn computeChecksum(data: []const u8) u32 {
    const h = xxhash.xxhash64(data, 0);
    return @truncate(h & 0xFFFFFFFF);
}

pub const ChecksumState = struct {
    state: xxhash.XxHash64State,

    pub fn init() ChecksumState {
        return .{ .state = xxhash.XxHash64State.init(0) };
    }

    pub fn update(self: *ChecksumState, data: []const u8) void {
        self.state.update(data);
    }

    pub fn final(self: *const ChecksumState) u32 {
        return @truncate(self.state.digest() & 0xFFFFFFFF);
    }
};

pub fn writeChecksum(buf: []u8, checksum: u32) void {
    buf[0] = @truncate(checksum);
    buf[1] = @truncate(checksum >> 8);
    buf[2] = @truncate(checksum >> 16);
    buf[3] = @truncate(checksum >> 24);
}

pub fn readChecksum(src: []const u8) u32 {
    return @as(u32, src[0]) | (@as(u32, src[1]) << 8) | (@as(u32, src[2]) << 16) | (@as(u32, src[3]) << 24);
}

const testing = @import("std").testing;

test "checksum deterministic" {
    const a = computeChecksum("hello world");
    const b = computeChecksum("hello world");
    try testing.expectEqual(a, b);
}

test "checksum different inputs" {
    const a = computeChecksum("hello");
    const b = computeChecksum("world");
    try testing.expect(a != b);
}

test "checksum read" {
    const buf = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
    try testing.expectEqual(@as(u32, 0x12345678), readChecksum(&buf));
}
