//! Sequence FSE decoding tables (symbols + bit counts + state transitions).
//! Backed by the canonical builder in `dtable.zig`.

const std = @import("std");
const errors = @import("../common/errors.zig");
const dtable_mod = @import("dtable.zig");

pub const FseTable = struct {
    tableLog: u8,
    table_size: usize,
    symbols: []u16,
    nbBits: []u8,
    new_state_base: []u16,

    pub fn deinit(self: *FseTable, allocator: std.mem.Allocator) void {
        allocator.free(self.symbols);
        allocator.free(self.nbBits);
        allocator.free(self.new_state_base);
    }
};

/// Build an FseTable view from the canonical decoding-table builder.
pub fn buildFseTable(allocator: std.mem.Allocator, normalized_counter: []const i16, max_symbol: usize, tableLog: u8) errors.ZstdError!FseTable {
    var dt = try dtable_mod.build(allocator, normalized_counter, max_symbol, tableLog);
    defer dt.deinit();

    const size = dt.entries.len;
    const symbols = try allocator.alloc(u16, size);
    errdefer allocator.free(symbols);
    const nbBits = try allocator.alloc(u8, size);
    errdefer allocator.free(nbBits);
    const new_state_base = try allocator.alloc(u16, size);
    errdefer allocator.free(new_state_base);

    for (dt.entries, 0..) |e, i| {
        symbols[i] = e.symbol;
        nbBits[i] = e.nbBits;
        // Invert entry.newState = (next << nbBits) - table_size
        // to recover the transition base `next`.
        const next: u16 = @intCast((@as(usize, e.newState) + size) >> @intCast(e.nbBits));
        new_state_base[i] = next;
    }

    return .{
        .tableLog = tableLog,
        .table_size = size,
        .symbols = symbols,
        .nbBits = nbBits,
        .new_state_base = new_state_base,
    };
}

// Tests

const testing = std.testing;

test "buildFseTable mirrors the canonical decoding table" {
    // Normalized counts 12 + 10 + 6 + 4 fill a 32-entry table exactly, so the
    // view must be a faithful mirror of what `dtable.zig` built: the same
    // symbols in the same cells, and a transition base that re-encodes to the
    // same state.
    const norm = [_]i16{ 12, 10, 6, 4 };
    var t = try buildFseTable(testing.allocator, &norm, norm.len - 1, 5);
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 32), t.table_size);

    var histogram: [4]u32 = @splat(0);
    for (t.symbols) |s| histogram[s] += 1;
    for (norm, 0..) |c, s| try testing.expectEqual(@as(u32, @intCast(c)), histogram[s]);

    var canonical = try dtable_mod.build(testing.allocator, &norm, norm.len - 1, 5);
    defer canonical.deinit();
    for (canonical.entries, 0..) |e, i| {
        try testing.expectEqual(e.symbol, t.symbols[i]);
        try testing.expectEqual(e.nbBits, t.nbBits[i]);
        const reencoded: u32 = (@as(u32, t.new_state_base[i]) << @intCast(e.nbBits)) - @as(u32, @intCast(t.table_size));
        try testing.expectEqual(@as(u32, e.newState), reencoded);
    }
}
