//! FSE decoding-table construction and state transitions.
//!
//! Produces decoding tables where each cell stores a symbol plus the number
//! of bits to consume and the next state, computed as
//! `new_state = (counter << nb_bits) - table_size`, which is the layout the
//! Zstandard format defines for FSE-encoded data.

const std = @import("std");
const errors = @import("../common/errors.zig");

pub const Entry = struct {
    symbol: u16,
    nb_bits: u8,
    new_state: u16,
};

pub const DTable = struct {
    log: u8,
    entries: []Entry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DTable) void {
        self.allocator.free(self.entries);
    }

    pub fn tableSize(self: *const DTable) usize {
        return self.entries.len;
    }
};

fn highbit32(v: u32) u5 {
    std.debug.assert(v != 0);
    return @intCast(31 - @clz(v));
}

/// Builds a decoding table from normalized counts for symbols 0..max_symbol
/// (counts may be -1, marking low-probability symbols placed at the top of
/// the table).
pub fn build(
    allocator: std.mem.Allocator,
    norm: []const i16,
    max_symbol: usize,
    table_log: u8,
) errors.ZstdError!DTable {
    if (table_log > 9) return error.TableLogTooLarge; // FDBG1
    // The compact header cannot express table logs below 5.
    if (table_log < 5) return error.TableLogTooLarge; // FDBG2
    const table_size: usize = @as(usize, 1) << @intCast(table_log);
    const max_sv1 = max_symbol + 1;

    const entries = try allocator.alloc(Entry, table_size);
    errdefer allocator.free(entries);

    var symbol_next_buf: [256]u16 = undefined;

    // Validate counts up-front so low-probability placement cannot underflow.
    var low_prob_count: usize = 0;
    for (0..max_sv1) |s| {
        const c = if (s < norm.len) norm[s] else 0;
        if (c == -1) {
            low_prob_count += 1;
            if (low_prob_count > table_size) return error.Corruption; // FDBG3
        } else if (c < 0 or c > table_size) {
            return error.Corruption; // FDBG4
        }
    }

    var high_threshold: usize = table_size - 1;

    // Init, lay down low-probability symbols (-1 counts) at the top of the table.
    for (entries) |*e| e.* = .{ .symbol = 0, .nb_bits = 0, .new_state = 0 };
    for (0..max_sv1) |s| {
        const c = if (s < norm.len) norm[s] else 0;
        if (c == -1) {
            entries[high_threshold].symbol = @intCast(s);
            symbol_next_buf[s] = 1;
            high_threshold -= 1;
        } else {
            symbol_next_buf[s] = @intCast(c);
        }
    }

    // Spread symbols.
    const mask: usize = table_size - 1;
    const step: usize = (table_size >> 1) + (table_size >> 3) + 3;
    var pos: usize = 0;
    for (0..max_sv1) |s| {
        const c = if (s < norm.len) norm[s] else 0;
        if (c <= 0) continue;
        var i: i32 = 0;
        while (i < c) : (i += 1) {
            entries[pos].symbol = @intCast(s);
            pos = (pos + step) & mask;
            while (pos > high_threshold) pos = (pos + step) & mask;
        }
    }
    if (pos != 0) return error.Corruption; // FDBG5 // normalized counter incorrect

    // Build the decoding table: nb_bits and new_state follow the format
    // definition new_state = (next << nb_bits) - table_size.
    for (0..table_size) |u| {
        const symbol = entries[u].symbol;
        const next_state = symbol_next_buf[symbol];
        symbol_next_buf[symbol] += 1;
        const nb_bits: u8 = @intCast(@as(u32, table_log) - highbit32(next_state));
        entries[u].nb_bits = nb_bits;
        entries[u].new_state = @truncate((@as(u32, next_state) << @intCast(nb_bits)) -% @as(u32, @intCast(table_size)));
    }

    return .{ .log = table_log, .entries = entries, .allocator = allocator };
}

/// Single-symbol RLE table (tableLog = 0): every decode consumes 0 bits.
pub fn buildRle(allocator: std.mem.Allocator, symbol: u16) errors.ZstdError!DTable {
    const entries = try allocator.alloc(Entry, 1);
    entries[0] = .{ .symbol = symbol, .nb_bits = 0, .new_state = 0 };
    return .{ .log = 0, .entries = entries, .allocator = allocator };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "dtable rle consumes no bits" {
    var t = try buildRle(testing.allocator, 42);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 0), t.log);
    try testing.expectEqual(@as(u16, 42), t.entries[0].symbol);
}

test "dtable simple distribution" {
    // norm {16,8,8} log 5 -> size 32; verify state coverage partitions [0,32).
    const norm = [_]i16{ 16, 8, 8 };
    var t = try build(testing.allocator, &norm, 2, 5);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 32), t.entries.len);
    var covered = [_]bool{false} ** 32;
    for (t.entries) |e| {
        const span = @as(usize, 1) << @intCast(e.nb_bits);
        var k: usize = 0;
        while (k < span) : (k += 1) {
            const idx = e.new_state + k;
            try testing.expect(idx < 32); // ranges must not exceed table
            covered[idx] = true;
        }
    }
    for (covered) |c| try testing.expect(c);
}

test "dtable rejects bad position" {
    // Sum of counts (4) != table size (32 for log 5) -> spread cannot return to 0.
    const norm = [_]i16{ 2, 1, 1 };
    const result = build(testing.allocator, &norm, 2, 5);
    try testing.expectError(error.Corruption, result);
}

test "dtable rejects small log" {
    const norm = [_]i16{ 2, 1, 1 };
    const result = build(testing.allocator, &norm, 2, 4);
    try testing.expectError(error.TableLogTooLarge, result);
}
