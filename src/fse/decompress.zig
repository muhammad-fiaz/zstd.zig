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
    var normalized = try allocator.alloc(i16, max_symbol + 1);
    defer allocator.free(normalized);
    @memset(normalized, 0);

    var max_sv = max_symbol;
    var table_log: u8 = 0;
    const bytes_read = try readNCount(normalized, &max_sv, &table_log, src);
    if (table_log > max_log) return error.TableLogTooLarge;

    const dec = try buildDecoder(allocator, normalized[0 .. max_sv + 1], table_log, max_sv);
    return .{
        .decoder = dec,
        .bytes_read = bytes_read,
        .table_log = table_log,
    };
}

pub fn readNCount(normalized_counter: []i16, max_sv_ptr: *usize, table_log_ptr: *u8, header_buffer: []const u8) errors.ZstdError!usize {
    if (header_buffer.len == 0) return error.InvalidFseTable;
    if (header_buffer.len < 8) {
        var buffer = [_]u8{0} ** 8;
        @memcpy(buffer[0..header_buffer.len], header_buffer);
        var max_sv = max_sv_ptr.*;
        var table_log: u8 = 0;
        const count_size = readNCountBody(normalized_counter, &max_sv, &table_log, &buffer) catch return error.InvalidFseTable;
        if (count_size > header_buffer.len) return error.InvalidFseTable;
        max_sv_ptr.* = max_sv;
        table_log_ptr.* = table_log;
        return count_size;
    }
    return readNCountBody(normalized_counter, max_sv_ptr, table_log_ptr, header_buffer);
}

fn readLE32At(buf: []const u8, idx: usize) u32 {
    return @as(u32, buf[idx]) |
        (@as(u32, buf[idx + 1]) << 8) |
        (@as(u32, buf[idx + 2]) << 16) |
        (@as(u32, buf[idx + 3]) << 24);
}

fn readNCountBody(normalized_counter: []i16, max_sv_ptr: *usize, table_log_ptr: *u8, src: []const u8) errors.ZstdError!usize {
    @memset(normalized_counter[0 .. max_sv_ptr.* + 1], 0);

    var ip: usize = 0;
    const iend = src.len;
    var bit_stream: u32 = readLE32At(src, 0);
    const nb_bits_initial: u8 = @truncate((bit_stream & 0xF) + constants.min_fse_log);
    if (nb_bits_initial > constants.max_fse_log) return error.TableLogTooLarge;
    bit_stream >>= 4;
    var bit_count: u32 = 4;
    table_log_ptr.* = nb_bits_initial;
    var nb_bits: u32 = @as(u32, nb_bits_initial);
    var remaining: i32 = (@as(i32, 1) << @as(std.math.Log2Int(i32), @intCast(nb_bits))) + 1;
    var threshold: i32 = @as(i32, 1) << @as(std.math.Log2Int(i32), @intCast(nb_bits));
    nb_bits += 1;

    var charnum: usize = 0;
    var previous0 = false;
    const max_sv1 = max_sv_ptr.* + 1;

    while (true) {
        if (previous0) {
            var repeats: u32 = @ctz(~bit_stream | 0x80000000) >> 1;
            while (repeats >= 12) {
                charnum += 3 * 12;
                if (ip <= iend - 7) {
                    ip += 3;
                } else {
                    const diff: usize = iend - 7 - ip;
                    bit_count -%= @as(u32, @truncate(diff * 8));
                    bit_count &= 31;
                    ip = iend - 4;
                }
                bit_stream = readLE32At(src, ip) >> @as(std.math.Log2Int(u32), @intCast(bit_count));
                repeats = @ctz(~bit_stream | 0x80000000) >> 1;
            }
            charnum += 3 * repeats;
            bit_stream >>= @as(std.math.Log2Int(u32), @intCast(2 * repeats));
            bit_count += 2 * repeats;

            charnum += bit_stream & 3;
            bit_count += 2;

            if (charnum >= max_sv1) break;

            if (ip <= iend - 7 or (ip + (bit_count >> 3) <= iend - 4)) {
                ip += bit_count >> 3;
                bit_count &= 7;
            } else {
                const diff: usize = iend - 4 - ip;
                bit_count -%= @as(u32, @truncate(diff * 8));
                bit_count &= 31;
                ip = iend - 4;
            }
            bit_stream = readLE32At(src, ip) >> @as(std.math.Log2Int(u32), @intCast(bit_count));
        }

        const max_val = (2 * threshold - 1) - remaining;
        var count: i32 = 0;

        if ((bit_stream & @as(u32, @intCast(threshold - 1))) < @as(u32, @intCast(max_val))) {
            count = @intCast(bit_stream & @as(u32, @intCast(threshold - 1)));
            bit_count += nb_bits - 1;
        } else {
            count = @intCast(bit_stream & @as(u32, @intCast(2 * threshold - 1)));
            if (count >= threshold) count -= max_val;
            bit_count += nb_bits;
        }

        count -= 1;
        if (count >= 0) {
            remaining -= count;
        } else {
            remaining += count;
        }
        normalized_counter[charnum] = @intCast(count);
        charnum += 1;
        previous0 = (count == 0);

        if (remaining < threshold) {
            if (remaining <= 1) break;
            nb_bits = @as(u32, 31 - @clz(@as(u32, @intCast(remaining)))) + 1;
            threshold = @as(i32, 1) << @as(std.math.Log2Int(i32), @intCast(nb_bits - 1));
        }
        if (charnum >= max_sv1) break;

        if (ip <= iend - 7 or (ip + (bit_count >> 3) <= iend - 4)) {
            ip += bit_count >> 3;
            bit_count &= 7;
        } else {
            const diff: usize = iend - 4 - ip;
            bit_count -%= @as(u32, @truncate(diff * 8));
            bit_count &= 31;
            ip = iend - 4;
        }
        bit_stream = readLE32At(src, ip) >> @as(std.math.Log2Int(u32), @intCast(bit_count));
    }

    if (remaining != 1) return error.Corruption;
    if (charnum > max_sv1) return error.Corruption;

    max_sv_ptr.* = charnum - 1;
    ip += (bit_count + 7) >> 3;
    if (ip > iend) return error.Corruption;
    return ip;
}

pub const FseDState = struct {
    state: usize = 0,
    table: *const FseDecoder,

    pub fn init(table: *const FseDecoder, bit_stream: *bitstream_mod.BIT_DStream) FseDState {
        const s = bit_stream.readBits(table.table_log);
        return .{
            .state = @intCast(s),
            .table = table,
        };
    }

    pub fn decodeSymbol(self: *FseDState, bit_stream: *bitstream_mod.BIT_DStream) u8 {
        const symbol = self.table.symbols[self.state];
        const nb_bits = self.table.nb_bits[self.state];
        const rest = bit_stream.readBits(nb_bits);
        self.state = self.table.new_state[self.state] +% @as(u16, @intCast(rest));
        return @truncate(symbol);
    }
};

const bitstream_mod = @import("../common/bitstream.zig");
