const std = @import("std");
const errors = @import("../common/errors.zig");
const bitstream_mod = @import("../common/bitstream.zig");
const common_mod = @import("common.zig");

pub const max_table_log: u8 = common_mod.maxTableLog;
pub const min_table_log: u8 = common_mod.minTableLog;

pub fn countFrequencies(counts: []u32, src: []const u8, max_symbol: usize) usize {
    @memset(counts[0 .. max_symbol + 1], 0);
    var max: usize = 0;
    for (src) |b| {
        const v: usize = b;
        if (v <= max_symbol) {
            counts[v] += 1;
            if (v > max) max = v;
        }
    }
    return max;
}

pub fn minTableLog(src_size: usize, max_symbol_value: usize) u8 {
    if (src_size <= 1) return min_table_log;
    const min_bits_src: u32 = (31 - @clz(@as(u32, @intCast(src_size)))) + 1;
    const min_bits_symbols: u32 = (31 - @clz(@as(u32, @intCast(max_symbol_value)))) + 2;
    const min_bits = @min(min_bits_src, min_bits_symbols);
    return @intCast(min_bits);
}

pub fn optimalTableLog(max_table_log_in: u8, src_size: usize, max_symbol_value: usize) u8 {
    if (src_size <= 1) return min_table_log;
    const max_bits_src: u32 = if (src_size > 1) (31 - @clz(@as(u32, @intCast(src_size - 1)))) -% 2 else 0;
    var table_log: u32 = if (max_table_log_in == 0) max_table_log else max_table_log_in;
    if (max_bits_src < table_log) table_log = max_bits_src;
    const min_bits = minTableLog(src_size, max_symbol_value);
    if (min_bits > table_log) table_log = min_bits;
    if (table_log < min_table_log) table_log = min_table_log;
    if (table_log > max_table_log) table_log = max_table_log;
    return @intCast(table_log);
}

const rtb_table = [8]u32{ 0, 473195, 504333, 520860, 550000, 700000, 750000, 830000 };

pub fn normalizeCounts(normalized: []i16, counts: []const u32, table_log_in: u8, total: usize) errors.ZstdError!void {
    _ = try normalizeCountsExt(normalized, counts, table_log_in, total, false);
}

pub fn normalizeCountsExt(normalized: []i16, counts: []const u32, table_log_in: u8, total: usize, use_low_prob_count: bool) errors.ZstdError!u8 {
    const table_log: u32 = if (table_log_in == 0) max_table_log else table_log_in;
    if (table_log < min_table_log or table_log > max_table_log) return error.TableLogTooLarge;
    if (total == 0) return error.Corruption;

    const max_symbol_value = counts.len - 1;
    if (table_log < minTableLog(total, max_symbol_value)) return error.TableLogTooLarge;

    const low_prob_count: i16 = if (use_low_prob_count) -1 else 1;
    const scale: u6 = @intCast(62 - table_log);
    const step: u64 = (@as(u64, 1) << 62) / @as(u64, total);
    const v_step: u64 = @as(u64, 1) << (scale - 20);
    var still_to_distribute: i32 = @as(i32, 1) << @as(std.math.Log2Int(i32), @intCast(table_log));
    var largest: usize = 0;
    var largest_p: i16 = 0;
    const low_threshold: u32 = @intCast(total >> @as(std.math.Log2Int(usize), @intCast(table_log)));

    for (0..max_symbol_value + 1) |s| {
        if (counts[s] == total) {
            normalized[s] = @intCast(@as(i32, 1) << @as(std.math.Log2Int(i32), @intCast(table_log)));
            return @intCast(table_log);
        }
        if (counts[s] == 0) {
            normalized[s] = 0;
            continue;
        }
        if (counts[s] <= low_threshold) {
            normalized[s] = low_prob_count;
            still_to_distribute -= 1;
        } else {
            var proba: i16 = @intCast((@as(u64, counts[s]) *% step) >> scale);
            if (proba < 8) {
                const rest_to_beat = v_step * rtb_table[@intCast(proba)];
                if ((@as(u64, counts[s]) *% step) -% (@as(u64, @intCast(proba)) << scale) > rest_to_beat) {
                    proba += 1;
                }
            }
            if (proba > largest_p) {
                largest_p = proba;
                largest = s;
            }
            normalized[s] = proba;
            still_to_distribute -= proba;
        }
    }

    if (-still_to_distribute >= @as(i32, normalized[largest] >> 1)) {
        try normalizeM2(normalized, @intCast(table_log), counts, total, max_symbol_value, low_prob_count);
    } else {
        normalized[largest] += @intCast(still_to_distribute);
    }

    return @intCast(table_log);
}

fn normalizeM2(norm: []i16, table_log: u8, count: []const u32, total_in: usize, max_symbol_value: usize, low_prob_count: i16) errors.ZstdError!void {
    const not_yet_assigned: i16 = -2;
    var total = total_in;
    var distributed: u32 = 0;

    const low_threshold = @as(u32, @intCast(total >> @as(std.math.Log2Int(usize), @intCast(table_log))));
    var low_one = @as(u32, @intCast((total * 3) >> @as(std.math.Log2Int(usize), @intCast(table_log + 1))));

    for (0..max_symbol_value + 1) |s| {
        if (count[s] == 0) {
            norm[s] = 0;
            continue;
        }
        if (count[s] <= low_threshold) {
            norm[s] = low_prob_count;
            distributed += 1;
            total -= count[s];
            continue;
        }
        if (count[s] <= low_one) {
            norm[s] = 1;
            distributed += 1;
            total -= count[s];
            continue;
        }
        norm[s] = not_yet_assigned;
    }

    var to_distribute = (@as(u32, 1) << @as(std.math.Log2Int(u32), @intCast(table_log))) - distributed;
    if (to_distribute == 0) return;

    if ((total / to_distribute) > low_one) {
        low_one = @intCast((total * 3) / (to_distribute * 2));
        for (0..max_symbol_value + 1) |s| {
            if (norm[s] == not_yet_assigned and count[s] <= low_one) {
                norm[s] = 1;
                distributed += 1;
                total -= count[s];
            }
        }
        to_distribute = (@as(u32, 1) << @as(std.math.Log2Int(u32), @intCast(table_log))) - distributed;
    }

    if (distributed == max_symbol_value + 1) {
        var max_v: usize = 0;
        var max_c: u32 = 0;
        for (0..max_symbol_value + 1) |s| {
            if (count[s] > max_c) {
                max_v = s;
                max_c = count[s];
            }
        }
        norm[max_v] += @intCast(to_distribute);
        return;
    }

    if (total == 0) {
        var s: usize = 0;
        while (to_distribute > 0) : (s = (s + 1) % (max_symbol_value + 1)) {
            if (norm[s] > 0) {
                to_distribute -= 1;
                norm[s] += 1;
            }
        }
        return;
    }

    const v_step_log: u6 = @intCast(62 - table_log);
    const mid = (@as(u64, 1) << (v_step_log - 1)) - 1;
    const r_step = (((@as(u64, 1) << v_step_log) * @as(u64, to_distribute)) + mid) / @as(u64, total);
    var tmp_total = mid;
    for (0..max_symbol_value + 1) |s| {
        if (norm[s] == not_yet_assigned) {
            const end = tmp_total + (@as(u64, count[s]) * r_step);
            const s_start = @as(u32, @intCast(tmp_total >> v_step_log));
            const s_end = @as(u32, @intCast(end >> v_step_log));
            const weight = s_end - s_start;
            if (weight < 1) return error.Corruption;
            norm[s] = @intCast(weight);
            tmp_total = end;
        }
    }
}

pub fn writeNCount(dst: []u8, normalized: []const i16, max_symbol_value: usize, table_log: u8) errors.ZstdError!usize {
    if (table_log > max_table_log or table_log < min_table_log) return error.TableLogTooLarge;
    if (dst.len == 0) return error.DstSizeTooSmall;

    var out_pos: usize = 0;
    var bit_stream: u32 = (@as(u32, table_log) - min_table_log);
    var bit_count: u32 = 4;
    const table_size: i32 = @as(i32, 1) << @as(std.math.Log2Int(i32), @intCast(table_log));
    var remaining: i32 = table_size + 1;
    var threshold: i32 = table_size;
    var nb_bits: u32 = @as(u32, table_log) + 1;
    var symbol: usize = 0;
    const alphabet_size = max_symbol_value + 1;
    var previous_is_0 = false;

    while (symbol < alphabet_size and remaining > 1) {
        if (previous_is_0) {
            var start = symbol;
            while (symbol < alphabet_size and normalized[symbol] == 0) : (symbol += 1) {}
            if (symbol == alphabet_size) break;
            while (symbol >= start + 24) {
                start += 24;
                bit_stream += @as(u32, 0xFFFF) << @as(std.math.Log2Int(u32), @intCast(bit_count));
                if (out_pos + 2 > dst.len) return error.DstSizeTooSmall;
                dst[out_pos] = @truncate(bit_stream);
                dst[out_pos + 1] = @truncate(bit_stream >> 8);
                out_pos += 2;
                bit_stream >>= 16;
            }
            while (symbol >= start + 3) {
                start += 3;
                bit_stream += @as(u32, 3) << @as(std.math.Log2Int(u32), @intCast(bit_count));
                bit_count += 2;
            }
            bit_stream += @as(u32, @intCast(symbol - start)) << @as(std.math.Log2Int(u32), @intCast(bit_count));
            bit_count += 2;
            if (bit_count > 16) {
                if (out_pos + 2 > dst.len) return error.DstSizeTooSmall;
                dst[out_pos] = @truncate(bit_stream);
                dst[out_pos + 1] = @truncate(bit_stream >> 8);
                out_pos += 2;
                bit_stream >>= 16;
                bit_count -= 16;
            }
        }
        var count: i32 = normalized[symbol];
        symbol += 1;
        const max_val: i32 = (2 * threshold - 1) - remaining;
        remaining -= if (count < 0) -count else count;
        count += 1;
        if (count >= threshold) {
            count += max_val;
        }
        bit_stream += @as(u32, @intCast(count)) << @as(std.math.Log2Int(u32), @intCast(bit_count));
        bit_count += nb_bits;
        if (count < max_val) {
            bit_count -= 1;
        }
        previous_is_0 = (count == 1);
        if (remaining < 1) return error.Corruption;
        while (remaining < threshold) {
            nb_bits -= 1;
            threshold >>= 1;
        }
        if (bit_count > 16) {
            if (out_pos + 2 > dst.len) return error.DstSizeTooSmall;
            dst[out_pos] = @truncate(bit_stream);
            dst[out_pos + 1] = @truncate(bit_stream >> 8);
            out_pos += 2;
            bit_stream >>= 16;
            bit_count -= 16;
        }
    }

    if (remaining != 1) return error.Corruption;

    if (bit_count > 0) {
        if (out_pos + 2 <= dst.len) {
            dst[out_pos] = @truncate(bit_stream);
            dst[out_pos + 1] = @truncate(bit_stream >> 8);
            out_pos += (bit_count + 7) / 8;
        } else {
            const bytes = (bit_count + 7) / 8;
            if (out_pos + bytes > dst.len) return error.DstSizeTooSmall;
            for (0..bytes) |b| {
                dst[out_pos + b] = @truncate(bit_stream >> @as(std.math.Log2Int(u32), @intCast(b * 8)));
            }
            out_pos += bytes;
        }
    }

    return out_pos;
}

pub const FseSymbolTransform = struct {
    delta_find_state: i16 = 0,
    delta_nb_bits: u32 = 0,
};

pub const FseCTable = struct {
    table_log: u8 = 0,
    max_symbol_value: u8 = 0,
    next_state: []u16,
    symbol_tt: []FseSymbolTransform,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FseCTable) void {
        self.allocator.free(self.next_state);
        self.allocator.free(self.symbol_tt);
    }
};

pub fn buildCTable(allocator: std.mem.Allocator, normalized: []const i16, max_symbol_value: usize, table_log: u8) errors.ZstdError!FseCTable {
    const table_size = @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(table_log));
    const table_mask = table_size - 1;
    const max_sv1 = max_symbol_value + 1;

    var next_state = try allocator.alloc(u16, table_size);
    errdefer allocator.free(next_state);
    var symbol_tt = try allocator.alloc(FseSymbolTransform, max_sv1);
    errdefer allocator.free(symbol_tt);

    var cumul = try allocator.alloc(u16, max_sv1 + 2);
    defer allocator.free(cumul);
    var table_symbol = try allocator.alloc(u8, table_size);
    defer allocator.free(table_symbol);

    var high_threshold: usize = table_size - 1;

    cumul[0] = 0;
    for (1..max_sv1 + 1) |u| {
        const norm = normalized[u - 1];
        if (norm == -1) {
            cumul[u] = cumul[u - 1] + 1;
            table_symbol[high_threshold] = @truncate(u - 1);
            if (high_threshold > 0) high_threshold -= 1;
        } else {
            cumul[u] = cumul[u - 1] + @as(u16, @intCast(norm));
        }
    }
    cumul[max_sv1] = @intCast(table_size + 1);

    const step = common_mod.getTableStep(table_size);
    var position: usize = 0;
    for (0..max_sv1) |s| {
        const norm = normalized[s];
        if (norm > 0) {
            for (0..@intCast(norm)) |_| {
                table_symbol[position] = @truncate(s);
                position = (position + step) & table_mask;
                while (position > high_threshold) {
                    position = (position + step) & table_mask;
                }
            }
        }
    }

    for (0..table_size) |u| {
        const symbol = table_symbol[u];
        const next = cumul[symbol];
        cumul[symbol] += 1;
        next_state[next] = @intCast(table_size + u);
    }

    var total: usize = 0;
    for (0..max_sv1) |s| {
        const norm = normalized[s];
        switch (norm) {
            0 => {
                symbol_tt[s] = .{ .delta_find_state = 0, .delta_nb_bits = 0 };
            },
            -1, 1 => {
                symbol_tt[s] = .{
                    .delta_find_state = @intCast(@as(i32, @intCast(total)) - 1),
                    .delta_nb_bits = (@as(u32, table_log) << 16) -% (@as(u32, 1) << @as(std.math.Log2Int(u32), @intCast(table_log))),
                };
                total += 1;
            },
            else => {
                const max_bits_out = table_log - (31 - @as(u8, @intCast(@clz(@as(u32, @intCast(norm - 1))))));
                const min_state_plus = @as(u32, @intCast(norm)) << @as(std.math.Log2Int(u32), @intCast(max_bits_out));
                symbol_tt[s] = .{
                    .delta_find_state = @intCast(@as(i32, @intCast(total)) - norm),
                    .delta_nb_bits = (@as(u32, max_bits_out) << 16) -% min_state_plus,
                };
                total += @intCast(norm);
            },
        }
    }

    return FseCTable{
        .table_log = table_log,
        .max_symbol_value = @truncate(max_symbol_value),
        .next_state = next_state,
        .symbol_tt = symbol_tt,
        .allocator = allocator,
    };
}

pub const FseCState = struct {
    value: usize = 0,
    state_log: u8 = 0,

    pub fn init(ctable: *const FseCTable, symbol: u8) FseCState {
        const idx = @as(usize, @intCast(@as(i32, ctable.symbol_tt[symbol].delta_find_state) + 1));
        return .{
            .value = ctable.next_state[idx],
            .state_log = ctable.table_log,
        };
    }

    pub fn encodeSymbol(self: *FseCState, bit_stream: *bitstream_mod.BIT_CStream, ctable: *const FseCTable, symbol: u8) void {
        const tt = ctable.symbol_tt[symbol];
        const nb_bits = (self.value +% tt.delta_nb_bits) >> 16;
        bit_stream.addBits(self.value, @intCast(nb_bits));
        const find_state_idx = (self.value >> @as(std.math.Log2Int(usize), @intCast(nb_bits))) +% @as(usize, @bitCast(@as(isize, tt.delta_find_state)));
        self.value = ctable.next_state[find_state_idx];
    }

    pub fn flush(self: *const FseCState, bit_stream: *bitstream_mod.BIT_CStream) void {
        bit_stream.addBits(self.value & ((@as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(self.state_log))) - 1), self.state_log);
    }
};

const testing = std.testing;

test "countFrequencies basic" {
    var counts: [256]u32 = undefined;
    const src = [_]u8{ 0, 0, 1, 2, 2, 2, 3 };
    const max_sym = countFrequencies(&counts, &src, 3);
    try testing.expectEqual(@as(usize, 3), max_sym);
    try testing.expectEqual(@as(u32, 2), counts[0]);
    try testing.expectEqual(@as(u32, 1), counts[1]);
    try testing.expectEqual(@as(u32, 3), counts[2]);
    try testing.expectEqual(@as(u32, 1), counts[3]);
}

test "countFrequencies empty" {
    var counts: [256]u32 = undefined;
    const src = [_]u8{};
    const max_sym = countFrequencies(&counts, &src, 5);
    try testing.expectEqual(@as(usize, 0), max_sym);
}

test "countFrequencies single symbol" {
    var counts: [256]u32 = undefined;
    const src = [_]u8{ 42, 42, 42 };
    const max_sym = countFrequencies(&counts, &src, 42);
    try testing.expectEqual(@as(usize, 42), max_sym);
    try testing.expectEqual(@as(u32, 3), counts[42]);
}

test "normalizeCounts basic" {
    var normalized: [32]i16 = undefined;
    const counts = [_]u32{ 10, 5, 3 };
    try normalizeCounts(&normalized, &counts, 5, 18);
    try testing.expect(normalized[0] > 0);
    try testing.expect(normalized[1] > 0);
    try testing.expect(normalized[2] > 0);
}
