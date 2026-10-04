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
    var tableLog: u32 = if (max_table_log_in == 0) max_table_log else max_table_log_in;
    if (max_bits_src < tableLog) tableLog = max_bits_src;
    const min_bits = minTableLog(src_size, max_symbol_value);
    if (min_bits > tableLog) tableLog = min_bits;
    if (tableLog < min_table_log) tableLog = min_table_log;
    if (tableLog > max_table_log) tableLog = max_table_log;
    return @intCast(tableLog);
}

const rtb_table = [8]u32{ 0, 473195, 504333, 520860, 550000, 700000, 750000, 830000 };

pub fn normalizeCounts(normalized: []i16, counts: []const u32, table_log_in: u8, total: usize) errors.ZstdError!void {
    _ = try normalizeCountsExt(normalized, counts, table_log_in, total, false);
}

pub fn normalizeCountsExt(normalized: []i16, counts: []const u32, table_log_in: u8, total: usize, use_low_prob_count: bool) errors.ZstdError!u8 {
    const tableLog: u32 = if (table_log_in == 0) max_table_log else table_log_in;
    if (tableLog < min_table_log or tableLog > max_table_log) return error.TableLogTooLarge;
    if (total == 0) return error.Corruption;

    const max_symbol_value = counts.len - 1;
    if (tableLog < minTableLog(total, max_symbol_value)) return error.TableLogTooLarge;

    const low_prob_count: i16 = if (use_low_prob_count) -1 else 1;
    const scale: u6 = @intCast(62 - tableLog);
    const step: u64 = (@as(u64, 1) << 62) / @as(u64, total);
    const v_step: u64 = @as(u64, 1) << (scale - 20);
    var still_to_distribute: i32 = @as(i32, 1) << @as(std.math.Log2Int(i32), @intCast(tableLog));
    var largest: usize = 0;
    var largest_p: i16 = 0;
    const low_threshold: u32 = @intCast(total >> @as(std.math.Log2Int(usize), @intCast(tableLog)));

    for (0..max_symbol_value + 1) |s| {
        if (counts[s] == total) {
            normalized[s] = @intCast(@as(i32, 1) << @as(std.math.Log2Int(i32), @intCast(tableLog)));
            return @intCast(tableLog);
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
        try normalizeM2(normalized, @intCast(tableLog), counts, total, max_symbol_value, low_prob_count);
    } else {
        normalized[largest] += @intCast(still_to_distribute);
    }

    return @intCast(tableLog);
}

fn normalizeM2(norm: []i16, tableLog: u8, count: []const u32, total_in: usize, max_symbol_value: usize, low_prob_count: i16) errors.ZstdError!void {
    const not_yet_assigned: i16 = -2;
    var total = total_in;
    var distributed: u32 = 0;

    const low_threshold = @as(u32, @intCast(total >> @as(std.math.Log2Int(usize), @intCast(tableLog))));
    var low_one = @as(u32, @intCast((total * 3) >> @as(std.math.Log2Int(usize), @intCast(tableLog + 1))));

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

    var to_distribute = (@as(u32, 1) << @as(std.math.Log2Int(u32), @intCast(tableLog))) - distributed;
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
        to_distribute = (@as(u32, 1) << @as(std.math.Log2Int(u32), @intCast(tableLog))) - distributed;
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

    const v_step_log: u6 = @intCast(62 - tableLog);
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

/// Writes a normalized-count header in the compact format.
///
/// This is the current format's writer, which is the reference FSE_writeNCount
/// unchanged: the header encoding was never revised between v0.1 and the present,
/// so one writer serves every version, and the legacy encoders use it too.
pub fn writeNCount(dst: []u8, normalized: []const i16, max_symbol_value: usize, tableLog: u8) errors.ZstdError!usize {
    if (tableLog > max_table_log or tableLog < min_table_log) return error.TableLogTooLarge;
    if (dst.len == 0) return error.DstSizeTooSmall;

    var outPos: usize = 0;
    var bitStream: u32 = (@as(u32, tableLog) - min_table_log);
    var bitCount: u32 = 4;
    const table_size: i32 = @as(i32, 1) << @as(std.math.Log2Int(i32), @intCast(tableLog));
    var remaining: i32 = table_size + 1;
    var threshold: i32 = table_size;
    var nbBits: u32 = @as(u32, tableLog) + 1;
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
                bitStream += @as(u32, 0xFFFF) << @as(std.math.Log2Int(u32), @intCast(bitCount));
                if (outPos + 2 > dst.len) return error.DstSizeTooSmall;
                dst[outPos] = @truncate(bitStream);
                dst[outPos + 1] = @truncate(bitStream >> 8);
                outPos += 2;
                bitStream >>= 16;
            }
            while (symbol >= start + 3) {
                start += 3;
                bitStream += @as(u32, 3) << @as(std.math.Log2Int(u32), @intCast(bitCount));
                bitCount += 2;
            }
            bitStream += @as(u32, @intCast(symbol - start)) << @as(std.math.Log2Int(u32), @intCast(bitCount));
            bitCount += 2;
            if (bitCount > 16) {
                if (outPos + 2 > dst.len) return error.DstSizeTooSmall;
                dst[outPos] = @truncate(bitStream);
                dst[outPos + 1] = @truncate(bitStream >> 8);
                outPos += 2;
                bitStream >>= 16;
                bitCount -= 16;
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
        bitStream += @as(u32, @intCast(count)) << @as(std.math.Log2Int(u32), @intCast(bitCount));
        bitCount += nbBits;
        if (count < max_val) {
            bitCount -= 1;
        }
        previous_is_0 = (count == 1);
        if (remaining < 1) return error.Corruption;
        while (remaining < threshold) {
            nbBits -= 1;
            threshold >>= 1;
        }
        if (bitCount > 16) {
            if (outPos + 2 > dst.len) return error.DstSizeTooSmall;
            dst[outPos] = @truncate(bitStream);
            dst[outPos + 1] = @truncate(bitStream >> 8);
            outPos += 2;
            bitStream >>= 16;
            bitCount -= 16;
        }
    }

    if (remaining != 1) return error.Corruption;

    if (bitCount > 0) {
        if (outPos + 2 <= dst.len) {
            dst[outPos] = @truncate(bitStream);
            dst[outPos + 1] = @truncate(bitStream >> 8);
            outPos += (bitCount + 7) / 8;
        } else {
            const bytes = (bitCount + 7) / 8;
            if (outPos + bytes > dst.len) return error.DstSizeTooSmall;
            for (0..bytes) |b| {
                dst[outPos + b] = @truncate(bitStream >> @as(std.math.Log2Int(u32), @intCast(b * 8)));
            }
            outPos += bytes;
        }
    }

    return outPos;
}

pub const FseSymbolTransform = struct {
    deltaFindState: i16 = 0,
    deltaNbBits: u32 = 0,
};

pub const FseCTable = struct {
    tableLog: u8 = 0,
    max_symbol_value: u8 = 0,
    nextState: []u16,
    symbolTt: []FseSymbolTransform,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FseCTable) void {
        self.allocator.free(self.nextState);
        self.allocator.free(self.symbolTt);
    }
};

pub fn buildCTable(allocator: std.mem.Allocator, normalized: []const i16, max_symbol_value: usize, tableLog: u8) errors.ZstdError!FseCTable {
    const table_size = @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(tableLog));
    const table_mask = table_size - 1;
    const maxSv1 = max_symbol_value + 1;

    var next_state = try allocator.alloc(u16, table_size);
    errdefer allocator.free(next_state);
    var symbol_tt = try allocator.alloc(FseSymbolTransform, maxSv1);
    errdefer allocator.free(symbol_tt);

    var cumul = try allocator.alloc(u16, maxSv1 + 2);
    defer allocator.free(cumul);
    var table_symbol = try allocator.alloc(u8, table_size);
    defer allocator.free(table_symbol);

    var high_threshold: usize = table_size - 1;

    cumul[0] = 0;
    for (1..maxSv1 + 1) |u| {
        const norm = normalized[u - 1];
        if (norm == -1) {
            cumul[u] = cumul[u - 1] + 1;
            table_symbol[high_threshold] = @truncate(u - 1);
            if (high_threshold > 0) high_threshold -= 1;
        } else {
            cumul[u] = cumul[u - 1] + @as(u16, @intCast(norm));
        }
    }
    cumul[maxSv1] = @intCast(table_size + 1);

    const step = common_mod.getTableStep(table_size);
    var position: usize = 0;
    for (0..maxSv1) |s| {
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
    for (0..maxSv1) |s| {
        const norm = normalized[s];
        switch (norm) {
            0 => {
                symbol_tt[s] = .{ .deltaFindState = 0, .deltaNbBits = 0 };
            },
            -1, 1 => {
                symbol_tt[s] = .{
                    .deltaFindState = @intCast(@as(i32, @intCast(total)) - 1),
                    .deltaNbBits = (@as(u32, tableLog) << 16) -% (@as(u32, 1) << @as(std.math.Log2Int(u32), @intCast(tableLog))),
                };
                total += 1;
            },
            else => {
                const max_bits_out = tableLog - (31 - @as(u8, @intCast(@clz(@as(u32, @intCast(norm - 1))))));
                const min_state_plus = @as(u32, @intCast(norm)) << @as(std.math.Log2Int(u32), @intCast(max_bits_out));
                symbol_tt[s] = .{
                    .deltaFindState = @intCast(@as(i32, @intCast(total)) - norm),
                    .deltaNbBits = (@as(u32, max_bits_out) << 16) -% min_state_plus,
                };
                total += @intCast(norm);
            },
        }
    }

    return FseCTable{
        .tableLog = tableLog,
        .max_symbol_value = @truncate(max_symbol_value),
        .nextState = next_state,
        .symbolTt = symbol_tt,
        .allocator = allocator,
    };
}

pub const FseCState = struct {
    value: usize = 0,
    state_log: u8 = 0,

    pub fn init(ctable: *const FseCTable, symbol: u8) FseCState {
        const idx = @as(usize, @intCast(@as(i32, ctable.symbolTt[symbol].deltaFindState) + 1));
        return .{
            .value = ctable.nextState[idx],
            .state_log = ctable.tableLog,
        };
    }

    pub fn encodeSymbol(self: *FseCState, bitStream: *bitstream_mod.BIT_CStream, ctable: *const FseCTable, symbol: u8) void {
        const tt = ctable.symbolTt[symbol];
        const nbBits = (self.value +% tt.deltaNbBits) >> 16;
        bitStream.addBits(self.value, @intCast(nbBits));
        const find_state_idx = (self.value >> @as(std.math.Log2Int(usize), @intCast(nbBits))) +% @as(usize, @bitCast(@as(isize, tt.deltaFindState)));
        self.value = ctable.nextState[find_state_idx];
    }

    pub fn flush(self: *const FseCState, bitStream: *bitstream_mod.BIT_CStream) void {
        bitStream.addBits(self.value & ((@as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(self.state_log))) - 1), self.state_log);
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
