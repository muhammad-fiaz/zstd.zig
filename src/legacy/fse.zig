//! Finite State Entropy (FSE) decoding for historic Zstandard formats.

const std = @import("std");
const bits = @import("../common/bits.zig");
const errors = @import("../common/errors.zig");
const dtable = @import("../fse/dtable.zig");
const fse_compress = @import("../fse/compress.zig");
const format = @import("format.zig");
/// The absolute table-log ceiling the historic header reader enforces before the
/// per-version limits apply.
pub const table_log_absolute_max: u8 = 15;
/// The compact header cannot express a table log below this.
pub const table_log_min: u8 = 5;
/// The narrowest table the historic sequence encoders build, which is also the
/// narrowest a "raw" table can be for the lengths: six bits for literal lengths
/// and seven for match lengths.
pub const raw_table_log_max: u8 = 7;
pub const DTable = dtable.DTable;
pub const NCountHeader = struct {
    /// Normalized counts for symbols `0..max_symbol`. Entries above `max_symbol`
    /// are left zero, matching the reference, which only ever reads back to the
    /// symbol count it reported.
    norm: [format.max_ml + 1]i16 = @splat(0),
    max_symbol: usize = 0,
    table_log: u8 = 0,
    /// Header bytes consumed.
    read: usize = 0,
};
/// Reads a 32-bit little-endian word at `ip`, zero-padding when fewer than four
/// bytes remain. The reference reads a whole word at a position its own pointer
/// comparisons have just bounded; in a slice-based reader the same word is read
/// past the end often enough (short headers near the end of a block) that
/// padding is safe and robust, matching the reference behavior on every
/// position the reference's guards allow.
fn wordAt(src: []const u8, ip: usize) u32 {
    if (ip + 4 <= src.len) return bits.readLe32(src[ip..]);
    var buf: [4]u8 = @splat(0);
    const n = src.len -| ip;
    @memcpy(buf[0..n], src[@min(ip, src.len)..]);
    return bits.readLe32(&buf);
}
/// True when the reference's `ip <= iend - 7`, i.e. when there is room to step
/// the cursor by whole bytes and still read a full word afterwards.
fn wideAhead(src: []const u8, ip: usize) bool {
    return src.len >= 7 and ip <= src.len - 7;
}
/// True when the reference's `ip + (bitCount >> 3) <= iend - 4`.
fn fitsAfterAdvance(src: []const u8, ip: usize, bit_count: u32) bool {
    const advance: usize = bit_count >> 3;
    return src.len >= 4 and (ip + advance <= src.len - 4 or advance > src.len);
}
/// Reads a normalized-count header into `out`, for symbols `0..max_symbol_init`.
///
/// `max_symbol_init` bounds what the caller can express; the header may report a
/// smaller symbol count, which is written back into `out.max_symbol`. A header
/// needing more symbols than the caller allows is `error.MaxSymbolValueTooSmall`,
/// which is the distinction the reference draws and which callers turn into
/// corruption rather than a table read.
pub fn readNCount(out: *NCountHeader, max_symbol_init: usize, src: []const u8) errors.ZstdError!void {
    if (src.len < 4) return error.SrcSizeWrong;
    @memset(&out.norm, 0);

    var ip: usize = 0;
    var bit_stream: u32 = wordAt(src, ip);
    const table_log: u8 = @intCast((bit_stream & 0xF) + table_log_min);
    if (table_log > table_log_absolute_max) return error.TableLogTooLarge;
    bit_stream >>= 4;
    var bit_count: u32 = 4;

    var remaining: i32 = (@as(i32, 1) << @intCast(table_log)) + 1;
    var threshold: i32 = @as(i32, 1) << @intCast(table_log);
    var nb_bits: u32 = @as(u32, table_log) + 1;

    var char_num: usize = 0;
    var previous0 = false;

    while (remaining > 1 and char_num <= max_symbol_init) {
        if (previous0) {
            // Runs of zero counts: a 16-bit window of all ones means 24 more
            // zeros, then a pair of set bits at a time means 3 more each, then
            // the remaining one or two bits give the final partial run.
            var n0: usize = char_num;
            while ((bit_stream & 0xFFFF) == 0xFFFF) {
                n0 += 24;
                if (src.len >= 5 and ip < src.len - 5) {
                    ip += 2;
                    bit_stream = wordAt(src, ip) >> @intCast(bit_count & 31);
                } else {
                    bit_stream >>= 16;
                    bit_count += 16;
                }
            }
            while ((bit_stream & 3) == 3) {
                n0 += 3;
                bit_stream >>= 2;
                bit_count += 2;
            }
            n0 += bit_stream & 3;
            bit_count += 2;
            if (n0 > max_symbol_init) return error.MaxSymbolValueTooSmall;
            // Zero counts stay implicit: the buffer was zeroed above.
            char_num = n0;
            if (wideAhead(src, ip) or fitsAfterAdvance(src, ip, bit_count)) {
                ip += bit_count >> 3;
                bit_count &= 7;
                bit_stream = wordAt(src, ip) >> @intCast(bit_count & 31);
            } else {
                bit_stream >>= 2;
            }
        }

        const max_val: i32 = (2 * threshold - 1) - remaining;
        var count: i32 = undefined;
        const max_val_bits: u32 = @bitCast(max_val);
        if ((bit_stream & @as(u32, @intCast(threshold - 1))) < max_val_bits) {
            count = @intCast(bit_stream & @as(u32, @intCast(threshold - 1)));
            bit_count += nb_bits - 1;
        } else {
            count = @intCast(bit_stream & @as(u32, @intCast(2 * threshold - 1)));
            if (count >= threshold) count -= max_val;
            bit_count += nb_bits;
        }
        // The encoded value is one more than the count, with zero meaning
        // "less than one" after the decrement.
        count -= 1;
        remaining -= if (count < 0) -count else count;
        out.norm[char_num] = @intCast(count);
        char_num += 1;
        previous0 = count == 0;

        while (remaining < threshold) {
            nb_bits -= 1;
            threshold >>= 1;
        }

        if (wideAhead(src, ip) or fitsAfterAdvance(src, ip, bit_count)) {
            ip += bit_count >> 3;
            bit_count &= 7;
        } else {
            // The reference slides to the last four bytes and keeps the bit
            // offset; the saturating subtraction is the same guard the current
            // format's reader uses.
            const diff = src.len - 4 -| ip;
            bit_count -%= @as(u32, @intCast(diff * 8));
            bit_count &= 31;
            ip = src.len - 4;
        }
        bit_stream = wordAt(src, ip) >> @intCast(bit_count & 31);
    }

    // The loop also ends when the caller's symbol ceiling is reached, so this
    // distinguishes "the table is complete" from "the caller ran out of room".
    if (remaining != 1) return error.Corruption;
    out.max_symbol = char_num - 1;
    out.table_log = table_log;
    ip += (bit_count + 7) >> 3;
    if (ip > src.len) return error.SrcSizeWrong;
    out.read = ip;
}
/// Builds a decoding table from a header just read by `readNCount`.
pub fn buildFromHeader(
    allocator: std.mem.Allocator,
    header: *const NCountHeader,
    max_table_log: u8,
) errors.ZstdError!DTable {
    if (header.table_log > max_table_log) return error.TableLogTooLarge;
    return dtable.build(
        allocator,
        header.norm[0 .. header.max_symbol + 1],
        header.max_symbol,
        header.table_log,
    );
}
/// The four ways a sequence section can describe one of its FSE tables. The
/// numbering is the same in every version: RLE, uniform, repeat, dynamic.
pub const Encoding = enum(u2) {
    rle = 0,
    raw = 1,
    static_reuse = 2,
    dynamic = 3,
};
/// Which of the three sequence tables a descriptor is for. Only used to pick the
/// per-table symbol and log ceilings.
pub const Table = enum {
    literal_length,
    offset,
    match_length,
};
/// The symbol ceiling a version's sequence tables use, per table.
pub fn symbolCeiling(version: format.Version, which: Table) usize {
    if (version.hasModernSequences()) {
        return switch (which) {
            .literal_length => 35,
            .offset => 28,
            .match_length => 52,
        };
    }
    return switch (which) {
        .literal_length => format.max_ll,
        .offset => format.max_off,
        .match_length => format.max_ml,
    };
}
/// The table-log ceiling a version's sequence tables use, per table.
pub fn tableLogCeiling(version: format.Version, which: Table) u8 {
    if (version.hasModernSequences()) {
        return switch (which) {
            .literal_length => 9,
            .offset => 8,
            .match_length => 9,
        };
    }
    return switch (which) {
        .literal_length => format.ll_fse_log,
        .offset => format.off_fse_log,
        .match_length => format.ml_fse_log,
    };
}
/// The table log a uniform ("raw") table uses, which is the width of its code.
pub fn rawTableLog(version: format.Version, which: Table) u8 {
    if (version.hasModernSequences()) {
        // v0.6 and v0.7 build their uniform tables from the predefined normalized
        // counts at a fixed log rather than one cell per symbol.
        return switch (which) {
            .literal_length => 6,
            .offset => 5,
            .match_length => 6,
        };
    }
    return switch (which) {
        .literal_length => format.ll_bits,
        .offset => format.off_bits,
        .match_length => format.ml_bits,
    };
}
/// A decoding table plus the width of the state initialiser that loads it.
pub const TableAndLog = struct {
    table: DTable,
};
// Tests
const testing = std.testing;
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub const writeNCount = fse_compress.writeNCount;

test "readNCount round trips the reference's own encoder output" {
    // A wide, uneven distribution exercising the -1 marker, zero runs and the
    // short-buffer path at once.
    var header: [64]u8 = @splat(0);
    const norm = [_]i16{ 1, 1, 1, 16, 8, 4, -1, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const used = try writeNCount(&header, &norm, norm.len - 1, 5);

    // The reader is handed the rest of the block, not just the header, because
    // the reference always reads a 32-bit word at the header's start. A table
    // this small encodes in fewer than four bytes, which is legal precisely
    // because the caller passes a larger buffer.
    var got = NCountHeader{};
    try readNCount(&got, norm.len - 1, header[0..]);
    try testing.expectEqual(used, got.read);
    try testing.expectEqual(@as(u8, 5), got.table_log);
    // The header stops at the last symbol with a non-zero count; the trailing
    // zeros are implied and never appear on the wire.
    try testing.expectEqual(@as(usize, 6), got.max_symbol);
    for (norm[0..7], 0..) |c, i| try testing.expectEqual(c, got.norm[i]);
    for (got.norm[7..norm.len]) |c| try testing.expectEqual(@as(i16, 0), c);
}
test "readNCount either rejects a header or returns a table that adds up" {
    // Property: whatever the reader accepts must describe a table the builder
    // can turn into a decoding table, so the counts must sum to exactly
    // `1 << table_log` with every count at least -1.
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const random = prng.random();
    var trial: usize = 0;
    while (trial < 1024) : (trial += 1) {
        var header: [32]u8 = undefined;
        random.bytes(&header);
        var got = NCountHeader{};
        if (readNCount(&got, format.max_ml, &header)) |_| {
            try testing.expect(got.read >= 1 and got.read <= header.len);
            try testing.expect(got.table_log >= table_log_min);
            try testing.expect(got.table_log <= table_log_absolute_max);
            try testing.expect(got.max_symbol <= format.max_ml);
            var total: i32 = 0;
            for (got.norm[0 .. got.max_symbol + 1]) |c| {
                try testing.expect(c >= -1);
                total += if (c < 0) 1 else c;
            }
            try testing.expectEqual(@as(i32, 1) << @intCast(got.table_log), total);
        } else |_| {}
    }
}
test "readNCount rejects a header that claims an impossible table log" {
    // The low nibble of the first byte carries tableLog - 5, so 0xF means log
    // 20, well past the historic ceiling of 15.
    const header = [_]u8{ 0x0F, 0x00, 0x00, 0x00 };
    var sink = NCountHeader{};
    try testing.expectError(error.TableLogTooLarge, readNCount(&sink, format.max_ml, &header));
}
test "readNCount rejects a short header" {
    var sink2 = NCountHeader{};
    try testing.expectError(error.SrcSizeWrong, readNCount(&sink2, format.max_ml, &[_]u8{ 1, 2, 3 }));
    var sink3 = NCountHeader{};
    try testing.expectError(error.SrcSizeWrong, readNCount(&sink3, format.max_ml, &[_]u8{}));
}
test "the historic table log ceiling is above the current format's" {
    // The reference header reader accepts up to 15 and the sequence tables cap at
    // 10; the current format caps both at 9. Reading a historic header with a
    // current-format reader would reject a valid table.
    try testing.expect(table_log_absolute_max > 9);
    try testing.expectEqual(@as(u8, 10), tableLogCeiling(.v02, .literal_length));
    try testing.expectEqual(@as(u8, 9), tableLogCeiling(.v06, .literal_length));
}
test "per-version ceilings are what the reference pins" {
    for ([_]format.Version{ .v01, .v02, .v03, .v04, .v05 }) |v| {
        try testing.expectEqual(@as(usize, 63), symbolCeiling(v, .literal_length));
        try testing.expectEqual(@as(usize, 31), symbolCeiling(v, .offset));
        try testing.expectEqual(@as(usize, 127), symbolCeiling(v, .match_length));
        try testing.expectEqual(@as(u8, 10), tableLogCeiling(v, .literal_length));
        try testing.expectEqual(@as(u8, 9), tableLogCeiling(v, .offset));
        try testing.expectEqual(@as(u8, 10), tableLogCeiling(v, .match_length));
        try testing.expectEqual(@as(u8, 6), rawTableLog(v, .literal_length));
        try testing.expectEqual(@as(u8, 5), rawTableLog(v, .offset));
        try testing.expectEqual(@as(u8, 7), rawTableLog(v, .match_length));
    }
    for ([_]format.Version{ .v06, .v07 }) |v| {
        try testing.expectEqual(@as(usize, 35), symbolCeiling(v, .literal_length));
        try testing.expectEqual(@as(usize, 28), symbolCeiling(v, .offset));
        try testing.expectEqual(@as(usize, 52), symbolCeiling(v, .match_length));
    }
}
test "buildFromHeader enforces the caller's log ceiling" {
    var header: [64]u8 = @splat(0);
    const norm = [_]i16{ 16, 8, 8 };
    _ = try writeNCount(&header, &norm, 2, 5);
    var got = NCountHeader{};
    try readNCount(&got, 2, &header);
    var t = try buildFromHeader(testing.allocator, &got, 9);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 5), t.log);
    try testing.expectError(error.TableLogTooLarge, buildFromHeader(testing.allocator, &got, 4));
}
