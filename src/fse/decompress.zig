const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");

pub const FseDecoder = struct {
    table_log: u8,
    table_size: usize,
    symbols: []u16,
    nb_bits: []u8,
    new_state: []u16,

    pub fn deinit(self: *FseDecoder, allocator: std.mem.Allocator) void {
        allocator.free(self.symbols);
        allocator.free(self.nb_bits);
        allocator.free(self.new_state);
    }
};

pub fn buildDecoder(allocator: std.mem.Allocator, normalized: []const i16, table_log: u8, max_symbol: usize) errors.ZstdError!FseDecoder {
    const table_size: usize = @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(table_log));
    if (table_size > 1 << constants.max_fse_log) return error.TableLogTooLarge;
    var symbols = try allocator.alloc(u16, table_size);
    errdefer allocator.free(symbols);
    var nb_bits = try allocator.alloc(u8, table_size);
    errdefer allocator.free(nb_bits);
    var new_state = try allocator.alloc(u16, table_size);
    errdefer allocator.free(new_state);

    var high_threshold: usize = table_size - 1;
    for (0..table_size) |i| symbols[i] = 0;

    var s: usize = 0;
    while (s <= max_symbol) : (s += 1) {
        if (s < normalized.len and normalized[s] == -1) {
            symbols[high_threshold] = @intCast(s);
            if (high_threshold > 0) high_threshold -= 1 else break;
        }
    }

    const step: usize = (table_size >> 1) + (table_size >> 3) + 3;
    const mask = table_size - 1;
    var pos: usize = 0;
    s = 0;
    while (s <= max_symbol) : (s += 1) {
        if (s >= normalized.len) continue;
        const count = normalized[s];
        if (count <= 0) continue;
        var i: i32 = 0;
        while (i < count) : (i += 1) {
            symbols[pos] = @intCast(s);
            pos = (pos + step) & mask;
            while (pos > high_threshold) pos = (pos + step) & mask;
        }
    }

    for (0..table_size) |i| {
        const sym = symbols[i];
        const nc: i32 = if (sym < normalized.len) normalized[sym] else 0;
        if (nc == -1) {
            nb_bits[i] = table_log;
        } else if (nc == 1) {
            nb_bits[i] = table_log;
        } else {
            const n: u32 = @intCast(nc);
            const bits: u8 = @intCast(table_log - (31 - @clz(n)));
            nb_bits[i] = bits;
        }
    }

    var next = try allocator.alloc(u16, max_symbol + 1);
    defer allocator.free(next);
    @memset(next, 0);
    for (0..table_size) |i| {
        const sym = symbols[i];
        if (sym <= max_symbol) {
            const base = next[sym];
            new_state[i] = base;
            const add: u16 = @as(u16, 1) << @as(std.math.Log2Int(u16), @intCast(nb_bits[i]));
            next[sym] = base +% add;
        } else {
            new_state[i] = 0;
        }
    }

    return FseDecoder{
        .table_log = table_log,
        .table_size = table_size,
        .symbols = symbols,
        .nb_bits = nb_bits,
        .new_state = new_state,
    };
}

pub fn readFseTableHeader(src: []const u8, max_log: u8, max_symbol: usize) errors.ZstdError!struct { decoder: FseDecoder, bytes_read: usize } {
    _ = max_symbol;
    _ = max_log;
    _ = src;
    return error.UnsupportedFeature;
}

pub const BitStream = struct {
    src: []const u8,
    container: u64,
    bits_in_container: u32,
    ptr: usize,

    pub fn init(src: []const u8) BitStream {
        var bs = BitStream{ .src = src, .container = 0, .bits_in_container = 0, .ptr = 0 };
        bs.refill();
        return bs;
    }

    fn refill(bs: *BitStream) void {
        while (bs.bits_in_container <= 56 and bs.ptr < bs.src.len) {
            bs.container |= @as(u64, bs.src[bs.ptr]) << @as(std.math.Log2Int(u64), @intCast(bs.bits_in_container));
            bs.bits_in_container += 8;
            bs.ptr += 1;
        }
    }

    pub fn getBits(bs: *BitStream, n: u32) u32 {
        if (n == 0) return 0;
        if (bs.bits_in_container < n) bs.refill();
        const mask: u64 = if (n == 32) 0xFFFFFFFF else (@as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(n))) - 1;
        const val: u32 = @truncate(bs.container & mask);
        bs.container >>= @as(std.math.Log2Int(u64), @intCast(n));
        bs.bits_in_container -= n;
        if (bs.bits_in_container <= 24 and bs.ptr < bs.src.len) bs.refill();
        return val;
    }

    pub fn peekBits(bs: *const BitStream, n: u32) u32 {
        if (n == 0) return 0;
        const mask: u64 = if (n == 32) 0xFFFFFFFF else (@as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(n))) - 1;
        return @truncate(bs.container & mask);
    }

    pub fn consumeBits(bs: *BitStream, n: u32) void {
        if (n == 0) return;
        if (bs.bits_in_container < n) bs.refill();
        bs.container >>= @as(std.math.Log2Int(u64), @intCast(n));
        bs.bits_in_container -= n;
        if (bs.bits_in_container <= 24 and bs.ptr < bs.src.len) bs.refill();
    }
};

pub fn decodeFseTable(allocator: std.mem.Allocator, src: []const u8, max_log: u32, max_symbol: usize) errors.ZstdError!struct { decoder: FseDecoder, bytes_read: usize, table_log: u8 } {
    if (src.len == 0) return error.InvalidFseTable;
    var pos: usize = 0;
    const first = src[pos];
    pos += 1;
    if (first == 0) return error.InvalidFseTable;
    var table_log: u8 = 0;
    if ((first & 0x80) == 0) {
        table_log = (first & 0x7F) + 1;
        if (table_log > max_log) return error.TableLogTooLarge;
    } else {
        return error.UnsupportedFeature;
    }
    const decoder = try decodeNormalized(allocator, src[pos..], table_log, max_symbol);
    pos += decoder.bytes_read;
    return .{ .decoder = decoder.decoder, .bytes_read = pos, .table_log = table_log };
}

fn decodeNormalized(allocator: std.mem.Allocator, src: []const u8, table_log: u8, max_symbol: usize) errors.ZstdError!struct { decoder: FseDecoder, bytes_read: usize } {
    _ = src;
    _ = table_log;
    _ = max_symbol;
    _ = allocator;
    return error.UnsupportedFeature;
}
