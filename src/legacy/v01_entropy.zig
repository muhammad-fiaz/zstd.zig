//! The entropy layers of the v0.1 format. v0.1 predates the current layouts: its
//! literals are a Huffman-coded section whose regenerated size is carried partly
//! in the block header, and its sequences are driven by three FSE tables
//! described by a separate byte region rather than by extra bits in the bitstream.
const std = @import("std");
const errors = @import("../common/errors.zig");
const bits = @import("../common/bits.zig");
const bitstream = @import("../common/bitstream.zig");
const dtable = @import("../fse/dtable.zig");
const ncount = @import("../fse/ncount.zig");
/// v0.1 fixed parameters.
pub const min_match: u32 = 4;
pub const ll_bits: u8 = 6;
pub const ml_bits: u8 = 7;
pub const off_bits: u8 = 5;
pub const max_ll: usize = (@as(usize, 1) << ll_bits) - 1;
pub const max_ml: usize = (@as(usize, 1) << ml_bits) - 1;
pub const max_off: usize = (@as(usize, 1) << off_bits) - 1;
pub const ll_fse_log: u8 = 10;
pub const ml_fse_log: u8 = 10;
pub const off_fse_log: u8 = 9;
/// Largest symbol a Huffman weight can name, and the largest table the format
/// can describe.
pub const max_huff_symbol: usize = 255;
pub const max_huff_table_log: u8 = 12;
// Huffman literals
const HuffEntry = struct {
    symbol: u8,
    nb_bits: u8,
};
const HuffTable = struct {
    entries: []HuffEntry,
    table_log: u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *HuffTable) void {
        self.allocator.free(self.entries);
    }
};
/// Reads a v0.1 Huffman table description, returning the table and how many
/// description bytes it used.
///
/// Three description forms exist: a single-symbol table, direct four-bit
/// weights, and weights compressed with FSE. The last symbol's weight is never
/// written; it is implied by the others having to leave a clean power of two.
fn readHuffTable(allocator: std.mem.Allocator, src: []const u8) !struct { table: HuffTable, read: usize } {
    if (src.len < 1) return error.Corruption;
    const desc_size = src[0];
    var weights: [max_huff_symbol + 2]u8 = undefined;
    var weight_count: usize = undefined;
    var read: usize = 1;

    if (desc_size >= 242) {
        // One symbol, described by its table log.
        @memset(weights[0 .. max_huff_symbol + 1], 1);
        weight_count = 0;
    } else if (desc_size >= 128) {
        // Direct weights, two per byte, high nibble first.
        weight_count = desc_size - 127;
        const packed_len = (weight_count + 1) / 2;
        if (1 + packed_len > src.len) return error.Corruption;
        var n: usize = 0;
        while (n + 1 < weight_count) : (n += 2) {
            const byte = src[1 + n / 2];
            weights[n] = byte >> 4;
            weights[n + 1] = byte & 15;
        }
        read = 1 + packed_len;
    } else {
        // FSE-compressed weights: the same normalized-count header the current
        // format uses, then a stream that drives two interleaved states.
        if (1 + desc_size > src.len) return error.Corruption;
        var norm: [max_huff_symbol + 1]i16 = undefined;
        var max_symbol: usize = max_huff_symbol;
        var table_log: u8 = 0;
        const header_read = try ncount.readNCount(norm[0..], &max_symbol, &table_log, src[1 .. 1 + desc_size]);
        if (max_symbol > max_huff_symbol) return error.Corruption;
        var table = try dtable.build(allocator, norm[0 .. max_symbol + 1], max_symbol, table_log);
        defer table.deinit();
        weight_count = try decodeFseWeights(&table, src[1 + header_read .. 1 + desc_size], &weights);
        read = 1 + desc_size;
    }
    if (weight_count > max_huff_symbol) return error.Corruption;

    // A weight w owns (1 << w) >> 1 cells, so the weights have to add up to
    // (almost) a power of two; whatever is missing is the implied last symbol.
    var rank_counts: [max_huff_table_log + 2]u32 = @splat(0);
    var weight_total: u32 = 0;
    for (weights[0..weight_count]) |w| {
        if (w > max_huff_table_log) return error.Corruption;
        rank_counts[w] += 1;
        weight_total += (@as(u32, 1) << @intCast(w)) >> 1;
    }
    if (weight_total == 0) return error.Corruption;
    const max_bits: u8 = @intCast(bits.highbit32(weight_total) + 1);
    if (max_bits > max_huff_table_log) return error.TableLogTooLarge;
    const total: u32 = @as(u32, 1) << @intCast(max_bits);
    const rest = total - weight_total;
    if (rest == 0 or (rest & (rest - 1)) != 0) {
        return error.Corruption;
    }
    const last_weight: u8 = @intCast(bits.highbit32(rest) + 1);
    if (last_weight > max_huff_table_log) return error.Corruption;
    weights[weight_count] = last_weight;
    rank_counts[last_weight] += 1;

    // A valid tree has at least two symbols at the shortest weight, and an even
    // number of them.
    if (rank_counts[1] < 2 or (rank_counts[1] & 1) != 0) return error.Corruption;

    // Ranks run from the shortest weight up: the first symbol of weight 1 owns
    // cell 0, the first of weight 2 owns what those left, and so on.
    var rank_start: [max_huff_table_log + 2]u32 = @splat(0);
    var next_rank: u32 = 0;
    var n: u8 = 1;
    while (n <= max_bits) : (n += 1) {
        rank_start[n] = next_rank;
        next_rank += rank_counts[n] << @intCast(n - 1);
    }
    const entries = try allocator.alloc(HuffEntry, total);
    errdefer allocator.free(entries);
    var s: usize = 0;
    while (s <= weight_count) : (s += 1) {
        const w: u8 = weights[s];
        const length: u32 = (@as(u32, 1) << @intCast(w)) >> 1;
        var i: u32 = 0;
        while (i < length) : (i += 1) {
            entries[rank_start[w] + i] = .{ .symbol = @intCast(s), .nb_bits = max_bits + 1 - w };
        }
        rank_start[w] += length;
    }
    return .{ .table = .{ .entries = entries, .table_log = max_bits, .allocator = allocator }, .read = read };
}
/// Decodes FSE-compressed Huffman weights into `out`, returning how many were
/// produced. The stream drives *two* interleaved states alternating a symbol
/// from each, as this version's FSE encoder wrote it: a single-state decoder
/// reads the same bits in a different order and yields different weights.
fn decodeFseWeights(
    table: *const dtable.DTable,
    src: []const u8,
    out: *[max_huff_symbol + 2]u8,
) !usize {
    var ds = try bitstream.BIT_DStream.init(src);
    var s1 = try initState(&ds, table);
    var s2 = try initState(&ds, table);
    const omax = max_huff_symbol + 1;
    var op: usize = 0;

    // Four symbols per pass, in the order the writer produced them. No reload
    // happens inside a group: the 64-bit container is wide enough for the group's
    // bits, and reloading there would move the read position.
    while (ds.reload() == .unfinished and op + 3 < omax) {
        out[op] = symbolOf(table, s1);
        s1 = advanceState(&ds, table, s1);
        out[op + 1] = symbolOf(table, s2);
        s2 = advanceState(&ds, table, s2);
        out[op + 2] = symbolOf(table, s1);
        s1 = advanceState(&ds, table, s1);
        out[op + 3] = symbolOf(table, s2);
        s2 = advanceState(&ds, table, s2);
        op += 4;
    }

    // Tail: one symbol from each state in turn, stopping when the stream is
    // spent and that state is back at zero. This build of the format reads
    // tables in the slow mode, so the states are what ends the loop, not the
    // stream alone.
    while (op < omax) {
        if (ds.reload() == .overflow or (ds.endOfStream() and s1 == 0)) break;
        out[op] = symbolOf(table, s1);
        s1 = advanceState(&ds, table, s1);
        op += 1;
        if (op >= omax) break;
        if (ds.reload() == .overflow or (ds.endOfStream() and s2 == 0)) break;
        out[op] = symbolOf(table, s2);
        s2 = advanceState(&ds, table, s2);
        op += 1;
    }

    if (ds.endOfStream() and s1 == 0 and s2 == 0) return op;
    return error.Corruption;
}
fn symbolOf(table: *const dtable.DTable, state: u16) u8 {
    return @intCast(table.entries[state].symbol);
}
fn advanceState(ds: *bitstream.BIT_DStream, table: *const dtable.DTable, state: u16) u16 {
    const entry = table.entries[state];
    if (entry.nbBits == 0) return entry.newState;
    return entry.newState +% @as(u16, @truncate(ds.readBits(entry.nbBits)));
}
/// Decodes a v0.1 Huffman-coded literals section into `dst`, which must be
/// exactly the regenerated size: this format has no end marker. The literals are
/// *not* one bitstream: this version split them into four independent streams
/// behind a table of three 16-bit lengths, with regenerated bytes interleaved one
/// per stream round-robin, which is why a single-stream reader produces
/// text-shaped nonsense here.
pub fn decompressLiterals(allocator: std.mem.Allocator, dst: []u8, src: []const u8) !struct { written: usize, read: usize } {
    var table = try readHuffTable(allocator, src);
    defer table.table.deinit();
    const body = src[table.read..];
    if (body.len == 0) return error.Corruption;

    // Three stored lengths plus a fourth implied by what remains.
    if (body.len < 8) return error.Corruption;
    const length1: usize = bits.readLe16(body[0..]);
    const length2: usize = bits.readLe16(body[2..]);
    const length3: usize = bits.readLe16(body[4..]);
    if (length1 + length2 + length3 + 8 > body.len) return error.Corruption;
    const length4: usize = body.len - 6 - length1 - length2 - length3;
    const start1: usize = 6;
    const start2 = start1 + length1;
    const start3 = start2 + length2;
    const start4 = start3 + length3;
    if (length1 + length2 + length3 + 6 >= body.len) return error.Corruption;

    var d1 = try bitstream.BIT_DStream.init(body[start1..][0..length1]);
    var d2 = try bitstream.BIT_DStream.init(body[start2..][0..length2]);
    var d3 = try bitstream.BIT_DStream.init(body[start3..][0..length3]);
    var d4 = try bitstream.BIT_DStream.init(body[start4..][0..length4]);

    const log = table.table.table_log;
    // The format decodes 16 bytes per round, one from each stream in turn, while the
    // output still has room for a full round plus the tail. The tail finishes from
    // the first stream alone, which is why that stream is the longest.
    const olimit = if (dst.len < 15) dst.len else dst.len - 15;
    var op: usize = 0;
    var status = d2.reload();
    while (status != .completed and status != .overflow and op < olimit) {
        for (0..16) |k| {
            const ds = switch (k & 3) {
                0 => &d1,
                1 => &d2,
                2 => &d3,
                else => &d4,
            };
            if (op + k >= dst.len) break;
            // No pre-check here: a group that runs past the end is normal and
            // `reload` is what reports a real over-read.
            const index: usize = @intCast(ds.lookBits(log));
            const entry = table.table.entries[index];
            dst[op + k] = entry.symbol;
            ds.skipBits(entry.nb_bits);
        }
        op += 16;
        // The four streams are written to run out together, so the round ends when
        // any of them is exhausted. Streams 2 to 4 decide it; stream 1 is refilled
        // regardless, because the tail is decoded from it.
        const s2 = d2.reload();
        const s3 = d3.reload();
        const s4 = d4.reload();
        _ = d1.reload();
        status = if (s2 == .completed or s2 == .overflow) s2 else if (s3 == .completed or s3 == .overflow) s3 else s4;
    }
    if (status == .overflow) return error.Corruption;

    // Tail: the format continues from *a copy of the first stream only*, not
    // round-robin. That asymmetry is why stream 1 is the longest of the four -
    // it carries the extra symbols the 16-byte groups could not cover. Reading
    // the tail from all four streams looks reasonable and silently drops bytes.
    var tail = d1;
    while (op < dst.len) {
        // Continue while the stream is merely at its end, not only while bits
        // remain buffered: the last symbols live in the container the reader is
        // already positioned on, so requiring a fresh refill here drops them.
        const st = tail.reload();
        if (st == .completed or st == .overflow) break;
        const index: usize = @intCast(tail.lookBits(log));
        const entry = table.table.entries[index];
        dst[op] = entry.symbol;
        op += 1;
        tail.skipBits(entry.nb_bits);
    }
    if (op != dst.len) return error.Corruption;
    return .{ .written = op, .read = table.read + body.len };
}
// Sequences
/// One decoded v0.1 sequence.
pub const Sequence = struct {
    lit_length: u32,
    match_length: u32,
    offset: u32,
};
const TableOrder = enum { ll, off, ml };
/// Builds one of the three sequence tables. v0.1 described a table in four ways:
/// one repeated symbol, a flat table with no description at all, an
/// FSE-normalized-count header, and the two-bit selector that picks between them.
fn buildSeqTable(allocator: std.mem.Allocator, which: TableOrder, mode: u2, src: []const u8) !struct { table: dtable.DTable, read: usize } {
    const max_symbol = switch (which) {
        .ll => max_ll,
        .off => max_off,
        .ml => max_ml,
    };
    const raw_log = switch (which) {
        .ll => ll_bits,
        .off => off_bits,
        .ml => ml_bits,
    };
    const max_log = switch (which) {
        .ll => ll_fse_log,
        .off => off_fse_log,
        .ml => ml_fse_log,
    };
    switch (mode) {
        2 => {
            if (src.len < 1) return error.Corruption;
            if (src[0] > max_symbol) return error.Corruption;
            return .{ .table = try dtable.buildRle(allocator, src[0]), .read = 1 };
        },
        1 => {
            // Raw table: cell `i` is symbol `i` and consumes no bits, so the
            // state is the symbol and reading it costs nothing beyond the
            // initial state. No description bytes are read.
            return .{ .table = try dtable.buildRaw(allocator, raw_log), .read = 0 };
        },
        else => {
            if (src.len < 1) return error.Corruption;
            const norm = try allocator.alloc(i16, max_symbol + 1);
            defer allocator.free(norm);
            var symbol_max = max_symbol;
            var table_log: u8 = 0;
            const header_read = try ncount.readNCount(norm, &symbol_max, &table_log, src);
            if (table_log > max_log) return error.Corruption;
            if (symbol_max > max_symbol) return error.Corruption;
            return .{
                .table = try dtable.build(allocator, norm[0 .. symbol_max + 1], symbol_max, table_log),
                .read = header_read,
            };
        },
    }
}
/// Reads the sequence-section header: the count, the three table selectors, and
/// the byte region that carries the long literal and match lengths.
pub const SeqHeader = struct {
    count: usize,
    dumps: []const u8,
    ll_mode: u2,
    off_mode: u2,
    ml_mode: u2,
};
pub fn readSeqHeader(src: []const u8) !struct { header: SeqHeader, read: usize } {
    if (src.len < 5) return error.Corruption;
    const count: usize = @as(usize, bits.readLe16(src[0..2]));
    const selectors = src[2];
    var pos: usize = 3;
    const dumps_length: usize = if (selectors & 2 != 0) blk: {
        if (pos + 2 > src.len) return error.Corruption;
        const value = @as(usize, src[pos]) | (@as(usize, src[pos + 1]) << 8);
        pos += 2;
        break :blk value;
    } else blk: {
        if (pos + 1 > src.len) return error.Corruption;
        const value = @as(usize, src[pos]) | (@as(usize, selectors & 1) << 8);
        pos += 1;
        break :blk value;
    };
    if (pos + dumps_length > src.len) return error.Corruption;
    return .{
        .header = .{
            .count = count,
            .dumps = src[pos .. pos + dumps_length],
            .ll_mode = @intCast(selectors >> 6),
            .off_mode = @intCast((selectors >> 4) & 3),
            .ml_mode = @intCast((selectors >> 2) & 3),
        },
        .read = pos + dumps_length,
    };
}
/// Decodes the v0.1 sequences of one block, returning them and the source bytes
/// they used.
pub fn decodeSequences(allocator: std.mem.Allocator, src: []const u8) !struct { sequences: []Sequence, read: usize } {
    const header_result = try readSeqHeader(src);
    const header = header_result.header;
    var pos = header_result.read;

    // One cleanup for the whole function: the tables are released in build order
    // and `built` says how many are live. Separate error and success hooks would
    // both fire on a later failure and free the same table twice.
    var tables: [3]dtable.DTable = undefined;
    var built: usize = 0;
    defer {
        if (built > 0) tables[0].deinit();
        if (built > 1) tables[1].deinit();
        if (built > 2) tables[2].deinit();
    }
    const orders = [3]TableOrder{ .ll, .off, .ml };
    const modes = [3]u2{ header.ll_mode, header.off_mode, header.ml_mode };
    for (orders, modes) |which, mode| {
        const r = try buildSeqTable(allocator, which, mode, src[pos..]);
        tables[built] = r.table;
        built += 1;
        pos += r.read;
    }
    if (pos > src.len) return error.Corruption;
    const body = src[pos..];
    if (body.len == 0) return error.Corruption;
    var ds = try bitstream.BIT_DStream.init(body);

    // The three states are seeded in this order and updated in the same order.
    var st_ll = try initState(&ds, &tables[0]);
    var st_off = try initState(&ds, &tables[1]);
    var st_ml = try initState(&ds, &tables[2]);

    const sequences = try allocator.alloc(Sequence, header.count);
    errdefer allocator.free(sequences);
    var dumps = header.dumps;
    var previous_offset: u32 = 1;

    for (sequences) |*sequence| {
        // The bitstream is refilled at the top of every sequence, before any code is
        // read. This is a correctness requirement, not an optimisation: a
        // container holds 64 bits and `lookBits` shifts within it, so past 64
        // consumed bits reads return shifted-in zeros instead of stream data.
        // Without the reload the first sequences decode fine and the rest is
        // garbage: a failure that looks like a plausible decode.
        _ = ds.reload();

        // Each state is read and advanced *immediately*, before the next value is
        // touched. The bit order is part of the format: a code's state update is
        // written directly after that code, and the offset's extra bits after the
        // offset state has advanced. Collecting all three symbols first consumes
        // the same bits in a different order, yielding plausible wrong lengths
        // from the second sequence on.
        var lit_length: u32 = @intCast(tables[0].entries[st_ll].symbol);
        st_ll = advanceEntry(&ds, tables[0].entries[st_ll]);
        if (lit_length == max_ll) {
            // Running out of dumps contributes zero rather than failing: the
            // format treats the dump area as best-effort, and a frame that
            // needs one must still decode.
            const add: u32 = if (dumps.len > 0) blk: {
                const v: u32 = dumps[0];
                dumps = dumps[1..];
                break :blk v;
            } else 0;
            if (add < 255) {
                lit_length += add;
            } else {
                if (dumps.len < 3) {
                    dumps = &.{};
                } else lit_length = bits.readLe24(dumps);
                dumps = dumps[3..];
            }
        }

        // Offset: the code gives the number of extra bits, and code 0 means the
        // previous offset stands.
        const off_code: u32 = @intCast(tables[1].entries[st_off].symbol);
        st_off = advanceEntry(&ds, tables[1].entries[st_off]);
        var offset: u32 = undefined;
        if (off_code == 0) {
            offset = previous_offset;
        } else {
            const extra_bits: u5 = @intCast(off_code - 1);
            offset = (@as(u32, 1) << @intCast(extra_bits)) + @as(u32, @truncate(ds.readBits(extra_bits)));
        }

        // Match length, again with dumps for the maximum code.
        var match_length: u32 = @intCast(tables[2].entries[st_ml].symbol);
        st_ml = advanceEntry(&ds, tables[2].entries[st_ml]);
        if (match_length == max_ml) {
            // Running out of dumps contributes zero rather than failing: the
            // format treats the dump area as best-effort, and a frame that
            // needs one must still decode.
            const add: u32 = if (dumps.len > 0) blk: {
                const v: u32 = dumps[0];
                dumps = dumps[1..];
                break :blk v;
            } else 0;
            if (add < 255) {
                match_length += add;
            } else {
                if (dumps.len < 3) {
                    dumps = &.{};
                } else match_length = bits.readLe24(dumps);
                dumps = dumps[3..];
            }
        }
        match_length += min_match;

        sequence.* = .{ .lit_length = lit_length, .match_length = match_length, .offset = offset };
        // The history only moves when there are literals, so only then does the
        // previous offset change.
        if (lit_length != 0) previous_offset = offset;
    }

    return .{ .sequences = sequences, .read = pos + (body.len - ds.remaining()) };
}
fn initState(ds: *bitstream.BIT_DStream, table: *const dtable.DTable) !u16 {
    if (table.log == 0) return 0;
    if (!ds.ensure(table.log)) return error.Corruption;
    const state: u16 = @intCast(ds.readBits(table.log));
    if (state >= table.entries.len) return error.Corruption;
    return state;
}
fn advanceEntry(ds: *bitstream.BIT_DStream, entry: dtable.Entry) u16 {
    if (entry.nbBits == 0) return entry.newState;
    return entry.newState +% @as(u16, @truncate(ds.readBits(entry.nbBits)));
}
const testing = std.testing;
// ---------------------------------------------------------------------------
// Sequences
// ---------------------------------------------------------------------------

/// Diagnostic view of the decoded Huffman weights, for locating whether a bad
/// literal decode comes from the weights or from the decode loop itself.
pub fn inspectWeights(allocator: std.mem.Allocator, src: []const u8) !struct { weights: [max_huff_symbol + 2]u8, count: usize, table_log: u8 } {
    const desc_size = src[0];
    if (desc_size >= 128 or 1 + desc_size > src.len) return error.Corruption;
    var weights: [max_huff_symbol + 2]u8 = undefined;
    @memset(&weights, 0);
    var norm: [max_huff_symbol + 1]i16 = undefined;
    var max_symbol: usize = max_huff_symbol;
    var table_log: u8 = 0;
    const header_read = try ncount.readNCount(norm[0..], &max_symbol, &table_log, src[1 .. 1 + desc_size]);
    var table = try dtable.build(allocator, norm[0 .. max_symbol + 1], max_symbol, table_log);
    defer table.deinit();
    const count = try decodeFseWeights(&table, src[1 + header_read .. 1 + desc_size], &weights);
    return .{ .weights = weights, .count = count, .table_log = table_log };
}

test "v01: a hand-built direct-weight table is validated before use" {
    // Isolates the table construction from the FSE weight decode. Four weights
    // that cannot sum to a power of two once the implied last symbol is added
    // must be rejected, which is the check that catches a mis-read table.
    var desc = [_]u8{ 127 + 4, (2 << 4) | 2, (1 << 4) | 3 };
    try testing.expectError(error.Corruption, readHuffTable(testing.allocator, &desc));

    // Weights {2,2,1,3} total 9; the implied symbol must make up the difference
    // to a power of two, and 16 - 9 = 7 is not one, so this is invalid too.
    // Weights {2,2,2,2} total 8, and 16 - 8 = 8 is, so this one is valid and
    // the implied symbol has weight 4.
    var good = [_]u8{ 127 + 4, (1 << 4) | 1, (2 << 4) | 2 };
    var table = try readHuffTable(testing.allocator, &good);
    defer table.table.deinit();
    try testing.expectEqual(@as(u8, 3), table.table.table_log);
    try testing.expectEqual(@as(usize, 8), table.table.entries.len);
    // Symbols 0..3 have weight 2 (two cells each), symbol 4 is the implied one
    // with weight 4 (eight cells), so the first eight cells alternate in pairs.
    // Two symbols of weight 1 take one cell each, then the weight-2 symbols take
    // two cells each, and the implied symbol is last.
    try testing.expectEqual(@as(u8, 0), table.table.entries[0].symbol);
    try testing.expectEqual(@as(u8, 1), table.table.entries[1].symbol);
    try testing.expectEqual(@as(u8, 2), table.table.entries[2].symbol);
    try testing.expectEqual(@as(u8, 3), table.table.entries[4].symbol);
    try testing.expectEqual(@as(u8, 4), table.table.entries[6].symbol);
    try testing.expectEqual(@as(u8, 3), table.table.entries[0].nb_bits);
    try testing.expectEqual(@as(u8, 2), table.table.entries[6].nb_bits);
}
