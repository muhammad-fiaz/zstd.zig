//! Sequence FSE decoding tables (symbols + bit counts + state transitions).
//! Backed by the canonical builder in `dtable.zig`.

const std = @import("std");
const errors = @import("../common/errors.zig");
const dtable_mod = @import("dtable.zig");

pub const FseTable = struct {
    table_log: u8,
    table_size: usize,
    symbols: []u16,
    nb_bits: []u8,
    new_state_base: []u16,

    pub fn deinit(self: *FseTable, allocator: std.mem.Allocator) void {
        allocator.free(self.symbols);
        allocator.free(self.nb_bits);
        allocator.free(self.new_state_base);
    }
};

/// Build an FseTable view from the canonical decoding-table builder.
pub fn buildFseTable(allocator: std.mem.Allocator, normalized_counter: []const i16, max_symbol: usize, table_log: u8) errors.ZstdError!FseTable {
    var dt = try dtable_mod.build(allocator, normalized_counter, max_symbol, table_log);
    defer dt.deinit();

    const size = dt.entries.len;
    const symbols = try allocator.alloc(u16, size);
    errdefer allocator.free(symbols);
    const nb_bits = try allocator.alloc(u8, size);
    errdefer allocator.free(nb_bits);
    const new_state_base = try allocator.alloc(u16, size);
    errdefer allocator.free(new_state_base);

    for (dt.entries, 0..) |e, i| {
        symbols[i] = e.symbol;
        nb_bits[i] = e.nb_bits;
        // Invert entry.new_state = (next << nb_bits) - table_size
        // to recover the transition base `next`.
        const next: u16 = @intCast((@as(usize, e.new_state) + size) >> @intCast(e.nb_bits));
        new_state_base[i] = next;
    }

    return .{
        .table_log = table_log,
        .table_size = size,
        .symbols = symbols,
        .nb_bits = nb_bits,
        .new_state_base = new_state_base,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "buildFseTable covers full distribution" {
    const norm = [_]i16{ 12, 10, 6, 4 };
    var t = try buildFseTable(testing.allocator, &norm, norm.len - 1, 5);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 32), t.table_size);
    var covered = [_]bool{false} ** 32;
    for (t.nb_bits, t.new_state_base) |bits, base| {
        const span = @as(usize, 1) << @intCast(bits);
        var k: usize = 0;
        while (k < span) : (k += 1) covered[base + k] = true;
    }
    for (covered) |c| try testing.expect(c);
}
