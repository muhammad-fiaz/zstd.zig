//! FSE encoding: CTable construction, encoder state management, and
//! symbol-to-bitstream encoding per the FSE algorithm used by the
//! Zstandard format.

const std = @import("std");
const errors = @import("../common/errors.zig");
const bitstream_mod = @import("../common/bitstream.zig");

fn highbit32(v: u32) u5 {
    std.debug.assert(v != 0);
    return @intCast(31 - @clz(v));
}

pub const SymbolTT = struct {
    delta_find_state: i32,
    delta_nb_bits: u32,
};

pub const CTable = struct {
    log: u8,
    max_symbol: usize,
    /// Next-state lookup grouped by symbol order; each cell stores size+u.
    /// (the low bits are the next-state, cell index is implicit).
    next_state: []u16,
    symbol_tt: []SymbolTT,

    pub fn deinit(self: *CTable, allocator: std.mem.Allocator) void {
        allocator.free(self.next_state);
        allocator.free(self.symbol_tt);
    }
};

/// Builds an encoding table from normalized counts.
pub fn buildCTable(
    allocator: std.mem.Allocator,
    norm: []const i16,
    max_symbol: usize,
    table_log: u8,
) errors.ZstdError!CTable {
    if (table_log < 5 or table_log > 9) return error.TableLogTooLarge;
    const size: usize = @as(usize, 1) << @intCast(table_log);
    const mask: usize = size - 1;
    const step: usize = (size >> 1) + (size >> 3) + 3;
    const max_sv1 = max_symbol + 1;

    var cumul: [258]u32 = undefined;
    const cell_symbol = try allocator.alloc(u16, size + 8); // +8 slack mirrors spread fast path
    defer allocator.free(cell_symbol);

    var high_threshold: usize = size - 1;

    // Normalized counts must exactly cover the table.
    var total_count: i32 = 0;
    for (norm[0..max_sv1]) |c| {
        if (c == -1) total_count += 1 else if (c > 0) total_count += c;
    }
    if (total_count != @as(i32, @intCast(size))) return error.Corruption;

    // Symbol start positions; lay down low-probability symbols at top cells.
    cumul[0] = 0;
    for (1..max_sv1 + 1) |u| {
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
    cumul[max_sv1] = @intCast(size + 1);

    // Spread symbols (simple path; equivalent to the unrolled fast path).
    var position: usize = 0;
    for (0..max_sv1) |s| {
        const c = norm[s];
        if (c <= 0) continue;
        var i: i32 = 0;
        while (i < c) : (i += 1) {
            cell_symbol[position] = @intCast(s);
            position = (position + step) & mask;
            while (position > high_threshold) position = (position + step) & mask;
        }
    }

    // Build next_state: for each cell u with symbol s, tableU16[cumul[s]++] = size+u.
    const next_state = try allocator.alloc(u16, size);
    errdefer allocator.free(next_state);
    var running: [256]u32 = undefined;
    for (0..max_sv1) |s| running[s] = cumul[s];
    for (0..size) |u| {
        const s = cell_symbol[u];
        next_state[running[s]] = @intCast(size + u);
        running[s] += 1;
    }

    // Symbol transformation table.
    const symbol_tt = try allocator.alloc(SymbolTT, max_sv1);
    errdefer allocator.free(symbol_tt);
    var total: u32 = 0;
    for (0..max_sv1) |s| {
        switch (norm[s]) {
            0 => {
                const delta: u64 = (@as(u64, table_log + 1) << 16) - (@as(u64, 1) << @intCast(table_log));
                symbol_tt[s] = .{ .delta_nb_bits = @truncate(delta), .delta_find_state = 0 };
            },
            -1, 1 => {
                const delta: u64 = (@as(u64, table_log) << 16) - (@as(u64, 1) << @intCast(table_log));
                symbol_tt[s] = .{ .delta_nb_bits = @truncate(delta), .delta_find_state = @bitCast(total -% 1) };
                total += 1;
            },
            else => {
                const c: u32 = @intCast(norm[s]);
                const max_bits_out: u32 = @as(u32, table_log) - highbit32(c - 1);
                const min_state_plus: u32 = c << @intCast(max_bits_out);
                symbol_tt[s] = .{
                    .delta_nb_bits = (max_bits_out << 16) - min_state_plus,
                    .delta_find_state = @bitCast(total -% c),
                };
                total += c;
            },
        }
    }

    return .{ .log = table_log, .max_symbol = max_symbol, .next_state = next_state, .symbol_tt = symbol_tt };
}

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
        const tt = ct.symbol_tt[symbol];
        const nb_bits_out: u32 = (tt.delta_nb_bits +% (1 << 15)) >> 16;
        self.value = (@as(usize, nb_bits_out) << 16) -% @as(usize, tt.delta_nb_bits);
        const idx: isize = @as(isize, @intCast(self.value >> @intCast(nb_bits_out))) + tt.delta_find_state;
        std.debug.assert(idx >= 0 and idx < ct.next_state.len);
        self.value = ct.next_state[@intCast(idx)];
    }

    /// FSE_encodeSymbol: write current-state low bits, then transition.
    pub fn encodeSymbol(self: *CState, ct: *const CTable, bc: *bitstream_mod.BIT_CStream, symbol: u8) void {
        const tt = ct.symbol_tt[symbol];
        const nb_bits_out: u32 = @truncate((self.value +% @as(usize, tt.delta_nb_bits)) >> 16);
        if (nb_bits_out > 0) {
            bc.addBits(@intCast(self.value & ((@as(usize, 1) << @intCast(nb_bits_out)) - 1)), nb_bits_out);
        }
        const idx: isize = @as(isize, @intCast(self.value >> @intCast(nb_bits_out))) + tt.delta_find_state;
        std.debug.assert(idx >= 0 and idx < ct.next_state.len);
        self.value = ct.next_state[@intCast(idx)];
    }

    /// FSE_flushCState.
    pub fn flushState(self: *const CState, bc: *bitstream_mod.BIT_CStream) void {
        bc.addBits(@intCast(self.value & ((@as(usize, 1) << @intCast(self.log)) - 1)), self.log);
        bc.flushBits();
    }
};
