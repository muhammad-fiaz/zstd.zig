//! XXH64 hash implementation reusing the Zig 0.17.0 standard library (std.hash.XxHash64).

const std = @import("std");

/// Computes the XXH64 hash of `data` with `seed`.
pub fn xxhash64(data: []const u8, seed: u64) u64 {
    return std.hash.XxHash64.hash(seed, data);
}

/// Streaming XXH64 state machine wrapping `std.hash.XxHash64`.
pub const XxHash64State = struct {
    hasher: std.hash.XxHash64,

    pub fn init(seed: u64) XxHash64State {
        return .{
            .hasher = std.hash.XxHash64.init(seed),
        };
    }

    pub fn update(self: *XxHash64State, data: []const u8) void {
        self.hasher.update(data);
    }

    pub fn digest(self: *const XxHash64State) u64 {
        var copy = self.hasher;
        return copy.final();
    }
};

const testing = std.testing;

test "xxhash64 empty" {
    try testing.expectEqual(@as(u64, 0xEF46DB3751D8E999), xxhash64("", 0));
}

test "xxhash64 matches the published vectors" {
    try testing.expectEqual(@as(u64, 0xD24EC4F1A98C6E5B), xxhash64("a", 0));
    try testing.expectEqual(@as(u64, 0x44BC2CF5AD770999), xxhash64("abc", 0));
}

test "xxhash64 streamed in pieces matches the one-shot digest" {
    var split_at_two = XxHash64State.init(0);
    split_at_two.update("ab");
    split_at_two.update("c");
    try testing.expectEqual(@as(u64, 0x44BC2CF5AD770999), split_at_two.digest());

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
