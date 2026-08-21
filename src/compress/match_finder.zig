const std = @import("std");

pub const Match = struct {
    offset: u32,
    length: u32,
    lit_length: u32,
};

pub const HashTable = struct {
    table: []u32,
    hash_log: u8,
    window_log: u8,

    pub fn init(allocator: std.mem.Allocator, hash_log: u8) !HashTable {
        const size: usize = @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(hash_log));
        const table = try allocator.alloc(u32, size);
        @memset(table, 0);
        return .{ .table = table, .hash_log = hash_log, .window_log = 0 };
    }

    pub fn deinit(self: *HashTable, allocator: std.mem.Allocator) void {
        allocator.free(self.table);
    }

    pub fn hashValue(self: *const HashTable, data: []const u8, pos: usize) u32 {
        if (pos + 4 > data.len) return 0;
        const v: u32 = @as(u32, data[pos]) | (@as(u32, data[pos + 1]) << 8) | (@as(u32, data[pos + 2]) << 16) | (@as(u32, data[pos + 3]) << 24);
        const h: u32 = (v *% 2654435761) >> @intCast(32 - self.hash_log);
        return h & (@as(u32, @intCast(self.table.len)) - 1);
    }
};

pub fn findMatches(allocator: std.mem.Allocator, src: []const u8, hash_log: u8) ![]Match {
    _ = allocator;
    _ = src;
    _ = hash_log;
    return &[_]Match{};
}

pub fn countMatchLength(a: []const u8, b: []const u8) usize {
    var i: usize = 0;
    const max = @min(a.len, b.len);
    while (i + 8 <= max) : (i += 8) {
        const va = read64(a[i..]);
        const vb = read64(b[i..]);
        if (va != vb) {
            return i + countBytes(va ^ vb);
        }
    }
    while (i < max and a[i] == b[i]) : (i += 1) {}
    return i;
}

fn read64(p: []const u8) u64 {
    return @as(u64, p[0]) | (@as(u64, p[1]) << 8) | (@as(u64, p[2]) << 16) | (@as(u64, p[3]) << 24) | (@as(u64, p[4]) << 32) | (@as(u64, p[5]) << 40) | (@as(u64, p[6]) << 48) | (@as(u64, p[7]) << 56);
}

fn countBytes(diff: u64) usize {
    if (diff == 0) return 8;
    return @ctz(diff) >> 3;
}
