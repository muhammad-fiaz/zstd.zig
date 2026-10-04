//! FSE encoding: CTable construction, encoder state management, and
//! symbol-to-bitstream encoding per the FSE algorithm used by Zstandard.

const std = @import("std");
const errors = @import("../common/errors.zig");
const bitstream_mod = @import("../common/bitstream.zig");
const bits = @import("../common/bits.zig");

const testing = std.testing;

pub const SymbolTT = struct {
    deltaFindState: i32,
    deltaNbBits: u32,
};

pub const CTable = struct {
    log: u8,
    maxSymbol: usize,
    /// Next-state lookup grouped by symbol order; each cell stores size+u.
    /// (the low bits are the next-state, cell index is implicit).
    nextState: []u16,
    symbolTt: []SymbolTT,

    pub fn deinit(self: *CTable, allocator: std.mem.Allocator) void {
        allocator.free(self.nextState);
        allocator.free(self.symbolTt);
    }
};

/// Builds an encoding table from normalized counts.
pub fn buildCTable(
    allocator: std.mem.Allocator,
    norm: []const i16,
    max_symbol: usize,
    tableLog: u8,
) errors.ZstdError!CTable {
    if (tableLog < 5 or tableLog > 9) return error.TableLogTooLarge;
    const size: usize = @as(usize, 1) << @intCast(tableLog);
    const next_state = try allocator.alloc(u16, size);
    errdefer allocator.free(next_state);
    const symbol_tt = try allocator.alloc(SymbolTT, max_symbol + 1);
    errdefer allocator.free(symbol_tt);
    const cell_symbol = try allocator.alloc(u16, size + 8); // +8 slack mirrors spread fast path
    defer allocator.free(cell_symbol);
    try fillCTable(next_state, symbol_tt, cell_symbol, norm, max_symbol, tableLog);
    return .{ .log = tableLog, .maxSymbol = max_symbol, .nextState = next_state, .symbolTt = symbol_tt };
}

/// Number of table cells a spread step may touch; the algorithm writes a cell
/// before discovering the step landed past the high-probability watermark, so
/// the buffer needs a few cells of slack.
pub const spread_slack: usize = 8;

/// Fills caller-provided buffers with an encoding table derived from `norm`. The
/// allocation-free core of `buildCTable`; the slices must be at least
/// `1 << tableLog`, `max_symbol + 1` and `(1 << tableLog) + spread_slack` long.
pub fn fillCTable(
    next_state: []u16,
    symbol_tt: []SymbolTT,
    cell_symbol: []u16,
    norm: []const i16,
    max_symbol: usize,
    tableLog: u8,
) errors.ZstdError!void {
    if (tableLog < 5 or tableLog > 9) return error.TableLogTooLarge;
    const size: usize = @as(usize, 1) << @intCast(tableLog);
    const maxSv1 = max_symbol + 1;
    if (next_state.len < size or symbol_tt.len < maxSv1 or cell_symbol.len < size + spread_slack) {
        return error.WorkspaceTooSmall;
    }
    const mask: usize = size - 1;
    const step: usize = (size >> 1) + (size >> 3) + 3;

    var cumul: [258]u32 = @splat(0);
    var high_threshold: usize = size - 1;

    // Normalized counts must exactly cover the table.
    var total_count: i32 = 0;
    for (norm[0..maxSv1]) |c| {
        if (c == -1) total_count += 1 else if (c > 0) total_count += c;
    }
    if (total_count != @as(i32, @intCast(size))) return error.Corruption;

    // Symbol start positions; lay down low-probability symbols at top cells.
    cumul[0] = 0;
    for (1..maxSv1 + 1) |u| {
        const c = norm[u - 1];
        if (c == -1) {
            cumul[u] = cumul[u - 1] + 1;
            cell_symbol[high_threshold] = @intCast(u - 1);
            high_threshold -= 1;
        } else {
            if (c < 0) return error.Corruption;
            cumul[u] = cumul[u - 1] + @as(u32, @intCast(c));
        }
    }
    cumul[maxSv1] = @intCast(size + 1);

    // Spread symbols (simple path; equivalent to the unrolled fast path).
    var position: usize = 0;
    for (0..maxSv1) |s| {
        const c = norm[s];
        if (c <= 0) continue;
        var i: i32 = 0;
        while (i < c) : (i += 1) {
            cell_symbol[position] = @intCast(s);
            position = (position + step) & mask;
            while (position > high_threshold) position = (position + step) & mask;
        }
    }

    // Build next_state: for each cell u with symbol s, next_state[cumul[s]++] = size+u.
    var running: [256]u32 = @splat(0);
    for (0..maxSv1) |s| running[s] = cumul[s];
    for (0..size) |u| {
        const s = cell_symbol[u];
        next_state[running[s]] = @intCast(size + u);
        running[s] += 1;
    }

    // Symbol transformation table.
    var total: u32 = 0;
    for (0..maxSv1) |s| {
        switch (norm[s]) {
            0 => {
                const delta: u64 = (@as(u64, tableLog + 1) << 16) - (@as(u64, 1) << @intCast(tableLog));
                symbol_tt[s] = .{ .deltaNbBits = @truncate(delta), .deltaFindState = 0 };
            },
            -1, 1 => {
                const delta: u64 = (@as(u64, tableLog) << 16) - (@as(u64, 1) << @intCast(tableLog));
                symbol_tt[s] = .{ .deltaNbBits = @truncate(delta), .deltaFindState = @bitCast(total -% 1) };
                total += 1;
            },
            else => {
                const c: u32 = @intCast(norm[s]);
                const max_bits_out: u32 = @as(u32, tableLog) - bits.highbit32(c - 1);
                const min_state_plus: u32 = c << @intCast(max_bits_out);
                symbol_tt[s] = .{
                    .deltaNbBits = (max_bits_out << 16) - min_state_plus,
                    .deltaFindState = @bitCast(total -% c),
                };
                total += c;
            },
        }
    }
}

/// Inline storage for the small tables a Huffman tree description needs: the
/// format caps its FSE table log at 6, so 64 cells always suffice. The table
/// returned by `build` borrows this storage and must not outlive it.
pub const SmallCTable = struct {
    next_state: [1 << 6]u16 = @splat(0),
    symbol_tt: [1 << 6]SymbolTT = @splat(.{ .deltaFindState = 0, .deltaNbBits = 0 }),
    cell_symbol: [(1 << 6) + spread_slack]u16 = @splat(0),

    pub fn build(
        self: *SmallCTable,
        norm: []const i16,
        max_symbol: usize,
        tableLog: u8,
    ) errors.ZstdError!CTable {
        if (tableLog > 6) return error.TableLogTooLarge;
        const size: usize = @as(usize, 1) << @intCast(tableLog);
        if (max_symbol + 1 > self.symbol_tt.len) return error.MaxSymbolValueTooLarge;
        try fillCTable(
            self.next_state[0..size],
            self.symbol_tt[0 .. max_symbol + 1],
            self.cell_symbol[0..],
            norm,
            max_symbol,
            tableLog,
        );
        return .{
            .log = tableLog,
            .maxSymbol = max_symbol,
            .nextState = self.next_state[0..size],
            .symbolTt = self.symbol_tt[0 .. max_symbol + 1],
        };
    }
};

/// FSE_CState.
pub const CState = struct {
    value: usize = 0,
    log: u8 = 0,

    /// FSE_initCState.
    pub fn initBase(self: *CState, ct: *const CTable) void {
        self.value = @as(usize, 1) << @intCast(ct.log);
        self.log = ct.log;
    }

    /// FSE_initCState2: first symbol uses the smallest possible state.
    pub fn initState(self: *CState, ct: *const CTable, symbol: u8) void {
        self.initBase(ct);
        const tt = ct.symbolTt[symbol];
        const nb_bits_out: u32 = (tt.deltaNbBits +% (1 << 15)) >> 16;
        self.value = (@as(usize, nb_bits_out) << 16) -% @as(usize, tt.deltaNbBits);
        const idx: isize = @as(isize, @intCast(self.value >> @intCast(nb_bits_out))) + tt.deltaFindState;
        std.debug.assert(idx >= 0 and idx < ct.nextState.len);
        self.value = ct.nextState[@intCast(idx)];
    }

    /// FSE_encodeSymbol: write current-state low bits, then transition.
    pub fn encodeSymbol(self: *CState, ct: *const CTable, bc: *bitstream_mod.BIT_CStream, symbol: u8) void {
        const tt = ct.symbolTt[symbol];
        const nb_bits_out: u32 = @truncate((self.value +% @as(usize, tt.deltaNbBits)) >> 16);
        if (nb_bits_out > 0) {
            bc.addBits(@intCast(self.value & ((@as(usize, 1) << @intCast(nb_bits_out)) - 1)), nb_bits_out);
        }
        const idx: isize = @as(isize, @intCast(self.value >> @intCast(nb_bits_out))) + tt.deltaFindState;
        std.debug.assert(idx >= 0 and idx < ct.nextState.len);
        self.value = ct.nextState[@intCast(idx)];
    }

    /// FSE_flushCState.
    pub fn flushState(self: *const CState, bc: *bitstream_mod.BIT_CStream) void {
        bc.addBits(@intCast(self.value & ((@as(usize, 1) << @intCast(self.log)) - 1)), self.log);
        bc.flushBits();
    }
};

test "buildCTable stores one next state per cell" {
    // Four symbols over thirty-two states. Every cell of an encoding table holds
    // the state the encoder moves to next, biased by the table size so that a
    // zero state cannot be confused with an unwritten cell.
    const alloc = testing.allocator;
    const norm = [_]i16{ 16, 8, 4, 4 };
    const size: usize = 32;
    var table = try buildCTable(alloc, &norm, norm.len - 1, 5);
    defer table.deinit(alloc);
    try testing.expectEqual(@as(u8, 5), table.log);
    try testing.expectEqual(norm.len - 1, table.maxSymbol);
    try testing.expectEqual(size, table.nextState.len);
    for (table.nextState) |cell| {
        try testing.expect(cell >= size and cell < 2 * size);
    }
}

test "buildCTable refuses a table log outside the format's range" {
    const alloc = testing.allocator;
    const norm = [_]i16{ 1, 1 };
    try testing.expectError(error.TableLogTooLarge, buildCTable(alloc, &norm, norm.len - 1, 4));
    try testing.expectError(error.TableLogTooLarge, buildCTable(alloc, &norm, norm.len - 1, 10));
}

test "buildCTable refuses counts that do not cover the table" {
    // The counts must sum to exactly the table size; anything else would leave
    // cells unwritten.
    const alloc = testing.allocator;
    const short = [_]i16{ 8, 4, 2, 2 };
    try testing.expectError(error.Corruption, buildCTable(alloc, &short, short.len - 1, 5));
    const over = [_]i16{ 20, 8, 4, 4 };
    try testing.expectError(error.Corruption, buildCTable(alloc, &over, over.len - 1, 5));
}

test "encoding a run stays inside the table for every symbol" {
    // Whatever a symbol's counts are, the state machine it drives has to remain
    // inside the table for as long as the caller keeps encoding. The reverse
    // direction, writing a stream here and reading it through the matching
    // decoding table, is covered end to end by the Huffman weight tests.
    const alloc = testing.allocator;
    const norm = [_]i16{ 16, 8, 4, 2, 1, 1 };
    var table = try buildCTable(alloc, &norm, norm.len - 1, 5);
    defer table.deinit(alloc);
    const size: usize = @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(table.log));

    for (0..norm.len) |symbol| {
        var buffer: [128]u8 = undefined;
        var stream = try bitstream_mod.BIT_CStream.init(&buffer);
        var state = CState{};
        state.initState(&table, @intCast(symbol));
        try testing.expect(state.value >= size and state.value < 2 * size);
        for (0..32) |_| {
            state.encodeSymbol(&table, &stream, @intCast(symbol));
            try testing.expect(state.value >= size and state.value < 2 * size);
        }
        state.flushState(&stream);
        try testing.expect(stream.ok());
    }
}
