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

/// Scan `src` and emit all matches of at least 4 bytes whose positions hash
/// to the same bucket as an earlier position (single-pass hash scan).
pub fn findMatches(allocator: std.mem.Allocator, src: []const u8, hash_log: u8) ![]Match {
    if (src.len < 8) return &[_]Match{};
    const size: usize = @as(usize, 1) << @intCast(hash_log);
    const head = try allocator.alloc(u32, size);
    defer allocator.free(head);
    @memset(head, 0);

    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(allocator);

    var anchor: usize = 0;
    var pos: usize = 0;
    while (pos + 4 <= src.len) : (pos += 1) {
        var hf = HashTable{ .table = head, .hash_log = hash_log, .window_log = 0 };
        const h = hf.hashValue(src, pos);
        const cand = head[h];
        head[h] = @intCast(pos + 1);
        if (cand == 0) continue;
        const cpos: usize = cand - 1;
        const max_len = @min(src.len - pos, 131072);
        var len: usize = 0;
        while (len < max_len and src[cpos + len] == src[pos + len]) : (len += 1) {}
        if (len >= 4) {
            out.append(allocator, .{
                .offset = @intCast(pos - cpos),
                .length = @intCast(len),
                .lit_length = @intCast(pos - anchor),
            }) catch return error.OutOfMemory;
            pos += len - 1;
            anchor = pos + 1;
        }
    }
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
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

const testing = @import("std").testing;

test "HashTable init and deinit" {
    var ht = try HashTable.init(testing.allocator, 12);
    defer ht.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1 << 12), ht.table.len);
}

test "HashTable hashValue" {
    var ht = try HashTable.init(testing.allocator, 12);
    defer ht.deinit(testing.allocator);
    const data = [_]u8{ 1, 2, 3, 4, 5 };
    const h = ht.hashValue(&data, 0);
    try testing.expect(h < ht.table.len);
}

test "HashTable hashValue out of bounds" {
    var ht = try HashTable.init(testing.allocator, 12);
    defer ht.deinit(testing.allocator);
    const data = [_]u8{ 1, 2 };
    try testing.expectEqual(@as(u32, 0), ht.hashValue(&data, 0));
}

test "countMatchLength identical" {
    const a = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const b = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try testing.expectEqual(@as(usize, 10), countMatchLength(&a, &b));
}

test "countMatchLength partial" {
    const a = [_]u8{ 1, 2, 3, 4, 5 };
    const b = [_]u8{ 1, 2, 3, 99, 100 };
    try testing.expectEqual(@as(usize, 3), countMatchLength(&a, &b));
}

test "countMatchLength none" {
    const a = [_]u8{ 1, 2, 3 };
    const b = [_]u8{ 9, 8, 7 };
    try testing.expectEqual(@as(usize, 0), countMatchLength(&a, &b));
}

test "countMatchLength empty" {
    const a = [_]u8{};
    const b = [_]u8{ 1, 2, 3 };
    try testing.expectEqual(@as(usize, 0), countMatchLength(&a, &b));
}

test "findMatches finds repeats" {
    const alloc = testing.allocator;
    const src = "abcdef" ** 20;
    const matches = try findMatches(alloc, src, 12);
    defer alloc.free(matches);
    try testing.expect(matches.len > 0);
    for (matches) |m| {
        try testing.expect(m.length >= 4);
        try testing.expect(m.offset >= 1);
    }
}
