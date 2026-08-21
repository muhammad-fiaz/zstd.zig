const std = @import("std");
const errors = @import("../common/errors.zig");

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

pub const FseState = struct {
    table: *const FseTable,
    state: u16,

    pub fn init(table: *const FseTable, bit_reader: *BitReader) FseState {
        const s = bit_reader.getBits(table.table_log);
        return .{ .table = table, .state = @truncate(s) };
    }

    pub fn getSymbol(self: *const FseState) u16 {
        return self.table.symbols[self.state];
    }

    pub fn update(self: *FseState, bit_reader: *BitReader) void {
        const nb_bits = self.table.nb_bits[self.state];
        const delta = bit_reader.getBits(nb_bits);
        self.state = @truncate(@as(usize, self.table.new_state_base[self.state]) + delta);
    }
};

const BitReader = struct {
    src: []const u8,
    bit_container: u64,
    bits_consumed: u32,
    ptr: usize,

    pub fn init(src: []const u8) BitReader {
        var r = BitReader{ .src = src, .bit_container = 0, .bits_consumed = 64, .ptr = src.len };
        r.reload();
        return r;
    }

    fn reload(r: *BitReader) void {
        while (r.bits_consumed >= 32 and r.ptr >= 4) {
            r.ptr -= 4;
            const v: u64 = @as(u64, r.src[r.ptr]) | (@as(u64, r.src[r.ptr + 1]) << 8) | (@as(u64, r.src[r.ptr + 2]) << 16) | (@as(u64, r.src[r.ptr + 3]) << 24);
            r.bit_container = (r.bit_container << 32) | v;
            r.bits_consumed -= 32;
        }
        if (r.bits_consumed >= 8 and r.ptr > 0) {
            const remain = @min(@as(usize, 4), r.ptr);
            if (remain > 0 and r.bits_consumed >= @as(u32, @intCast(remain * 8))) {
                var v: u64 = 0;
                var i: usize = 0;
                while (i < remain) : (i += 1) {
                    v |= @as(u64, r.src[r.ptr - remain + i]) << @as(std.math.Log2Int(u64), @intCast(i * 8));
                }
                r.ptr -= remain;
                r.bit_container = (r.bit_container << @as(std.math.Log2Int(u64), @intCast(remain * 8))) | v;
                r.bits_consumed -= @intCast(remain * 8);
            }
        }
    }

    pub fn getBits(r: *BitReader, nb_bits: u32) u64 {
        if (nb_bits == 0) return 0;
        if (r.bits_consumed + nb_bits > 64) r.reload();
        const mask: u64 = if (nb_bits == 64) ~@as(u64, 0) else (@as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(nb_bits))) - 1;
        const val = (r.bit_container >> @intCast(r.bits_consumed)) & mask;
        r.bits_consumed += nb_bits;
        return val;
    }
};

pub fn buildFseTable(allocator: std.mem.Allocator, normalized_counter: []const i16, table_log: u8, max_symbol: usize) errors.ZstdError!FseTable {
    const table_size: usize = @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(table_log));
    var symbols = try allocator.alloc(u16, table_size);
    errdefer allocator.free(symbols);
    var nb_bits = try allocator.alloc(u8, table_size);
    errdefer allocator.free(nb_bits);
    var new_state_base = try allocator.alloc(u16, table_size);
    errdefer allocator.free(new_state_base);

    var high_threshold: usize = table_size - 1;
    for (0..table_size) |i| symbols[i] = 0;

    var s: usize = 0;
    while (s <= max_symbol) : (s += 1) {
        const count = normalized_counter[s];
        if (count == -1) {
            symbols[high_threshold] = @intCast(s);
            if (high_threshold > 0) high_threshold -= 1;
        }
    }

    const step: usize = (table_size >> 1) + (table_size >> 3) + 3;
    const mask = table_size - 1;
    var pos: usize = 0;
    s = 0;
    while (s <= max_symbol) : (s += 1) {
        const count = normalized_counter[s];
        if (count <= 0) continue;
        var i: i32 = 0;
        while (i < count) : (i += 1) {
            symbols[pos] = @intCast(s);
            pos = (pos + step) & mask;
            while (pos > high_threshold) pos = (pos + step) & mask;
        }
    }
    if (pos != 0) return error.Corruption;

    for (0..table_size) |i| {
        const sym = symbols[i];
        const nc = normalized_counter[sym];
        var bits: u8 = 0;
        if (nc == -1) {
            bits = table_log;
        } else if (nc == 1) {
            bits = table_log;
        } else {
            const c: u32 = @intCast(nc);
            var l: u8 = 0;
            var v: u32 = c;
            while (v > 1) : (v >>= 1) {
                l += 1;
            }
            bits = table_log - l;
        }
        nb_bits[i] = bits;
    }

    var next_state = try allocator.alloc(u16, max_symbol + 1);
    defer allocator.free(next_state);
    @memset(next_state, 0);
    for (0..table_size) |i| {
        const sym = symbols[i];
        const base = next_state[sym];
        const add = @as(u16, 1) << @as(std.math.Log2Int(u16), @intCast(nb_bits[i]));
        new_state_base[i] = base;
        next_state[sym] = base + add;
    }

    return FseTable{
        .table_log = table_log,
        .table_size = table_size,
        .symbols = symbols,
        .nb_bits = nb_bits,
        .new_state_base = new_state_base,
    };
}
