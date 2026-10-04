//! Huffman literal decoding for historic Zstandard formats.

const std = @import("std");
const bits = @import("../common/bits.zig");
const errors = @import("../common/errors.zig");
const bitstream = @import("../common/bitstream.zig");
const legacy_fse = @import("fse.zig");
const format = @import("format.zig");
/// The deepest code length the historic literal tables can express.
pub const max_table_log: u8 = 16;
/// The shallowest table a static allocation is sized for, which is what every
/// historic reader uses.
pub const default_table_log: u8 = 12;
pub const max_symbol: usize = 255;
/// A single-symbol decoding cell: which byte, and how many bits its code is.
pub const CellX2 = struct {
    byte: u8,
    nbBits: u8,
};
/// A double-symbol decoding cell: two packed bytes, how many bits the pair costs,
/// and how many bytes it emits (1 or 2).
pub const CellX4 = struct {
    sequence: u16,
    nbBits: u8,
    length: u8,
};
/// The largest table a decode can address.
pub const max_table_size: usize = 1 << max_table_log;
pub const TableX2 = struct {
    log: u8,
    cells: [max_table_size]CellX2,
};
pub const TableX4 = struct {
    log: u8,
    cells: [max_table_size]CellX4,
};
/// The weights and derived shape of a literal Huffman table.
pub const Stats = struct {
    /// `weights[0..count]` are the code lengths' complements: a weight of `w`
    /// means a code of `max_bits + 1 - w` bits. `count` symbols are described;
    /// the implied last one follows at index `count`.
    weights: [max_symbol + 2]u8 = @splat(0),
    count: usize = 0,
    max_bits: u8 = 0,
    /// Header bytes consumed.
    read: usize = 0,
};
/// Reads a literal Huffman table description. `hw_size` is how many weights the
/// caller can hold, which the FSE-compressed form needs in order to bound its
/// own output.
///
/// Returns the number of header bytes consumed. `stats.weights` holds `count`
/// explicit weights plus the implied last one at index `count`.
pub fn readStats(
    allocator: std.mem.Allocator,
    stats: *Stats,
    hw_size: usize,
    src: []const u8,
) errors.ZstdError!usize {
    if (src.len == 0) return error.SrcSizeWrong;
    @memset(&stats.weights, 0);
    stats.count = 0;
    stats.max_bits = 0;

    const first = src[0];
    var i_size: usize = undefined;
    var o_size: usize = undefined;

    if (first >= 128) {
        if (first >= 242) {
            // "Every symbol has weight one": a table with a flat code. The run
            // lengths are implicit, chosen so the table is a valid Huffman code.
            const lengths = [14]usize{ 1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 63, 64, 127, 128 };
            o_size = lengths[first - 242];
            @memset(stats.weights[0..hw_size], 1);
            i_size = 0;
        } else {
            // Weights stored directly, one nibble each, high nibble first.
            o_size = first - 127;
            i_size = (o_size + 1) / 2;
            if (i_size + 1 > src.len) return error.SrcSizeWrong;
            if (o_size >= hw_size) return error.Corruption;
            var n: usize = 0;
            while (n < o_size) : (n += 2) {
                stats.weights[n] = src[1 + n / 2] >> 4;
                stats.weights[n + 1] = src[1 + n / 2] & 15;
            }
            // An odd count leaves the final nibble as the high one.
            if (o_size & 1 != 0) stats.weights[o_size - 1] = src[1 + (o_size - 1) / 2] >> 4;
        }
    } else {
        // The normal case: the weights are themselves FSE-compressed.
        i_size = first;
        if (i_size + 1 > src.len) return error.SrcSizeWrong;
        // The reference passes `hwSize - 1` because the last weight is implied
        // and is derived from the total rather than decoded.
        o_size = try fseDecompressWeights(allocator, stats.weights[0 .. hw_size - 1], src[1 .. 1 + i_size]);
    }

    return finishStats(stats, hw_size, o_size, i_size);
}
/// Shared tail of `readStats`: derive the table log, the implied final weight and
/// the rank histogram, and reject a weight list that cannot describe a code.
fn finishStats(stats: *Stats, hw_size: usize, o_size: usize, i_size: usize) errors.ZstdError!usize {
    var rank_stats: [max_table_log + 1]u32 = @splat(0);
    var weight_total: u32 = 0;
    for (stats.weights[0..o_size]) |w| {
        if (w >= max_table_log) return error.Corruption;
        rank_stats[w] += 1;
        weight_total += (@as(u32, 1) << @intCast(w)) >> 1;
    }
    if (weight_total == 0) return error.Corruption;

    // The total must be short of the next power of two by exactly a power of
    // two: the difference is the implied last symbol's share.
    const max_bits: u8 = @intCast(bits.highbit32(weight_total) + 1);
    if (max_bits > max_table_log) return error.Corruption;
    const total: u32 = @as(u32, 1) << @intCast(max_bits);
    const rest: u32 = total - weight_total;
    const verif: u32 = @as(u32, 1) << @intCast(bits.highbit32(rest));
    const last_weight: u8 = @intCast(bits.highbit32(rest) + 1);
    if (verif != rest) return error.Corruption;
    stats.weights[o_size] = last_weight;
    rank_stats[last_weight] += 1;

    // A valid code has an even number of leaves at the deepest rank, at least
    // two of them.
    if (rank_stats[1] < 2 or (rank_stats[1] & 1) != 0) return error.Corruption;

    stats.count = o_size + 1;
    stats.max_bits = max_bits;
    if (stats.count > hw_size) return error.Corruption;
    return i_size + 1;
}
/// Decodes the FSE-compressed weight list. This is the reference `FSE_decompress`
/// over byte symbols: read a normalized-count header, build the table, then run
/// two interleaved states until the stream ends.
///
/// Two states alternate, four symbols to a group, and the loop ends on the *states*
/// reaching zero rather than on the stream alone. That matters: a stream whose last
/// container is not exactly exhausted still terminates correctly as long as both
/// states land on zero, which is the only condition the reference accepts.
fn fseDecompressWeights(allocator: std.mem.Allocator, dst: []u8, src: []const u8) errors.ZstdError!usize {
    if (src.len < 2) return error.SrcSizeWrong;
    var header = legacy_fse.NCountHeader{};
    try legacy_fse.readNCount(&header, max_symbol, src);
    if (header.read >= src.len) return error.SrcSizeWrong;

    var table = try legacy_fse.buildFromHeader(allocator, &header, legacy_fse.table_log_absolute_max);
    defer table.deinit();

    var stream = bitstream.BIT_DStream.init(src[header.read..]) catch |e| switch (e) {
        error.SrcSizeWrong, error.Corruption => return error.Corruption,
        else => return e,
    };
    var s1: u16 = @intCast(stream.readBits(table.log));
    _ = stream.reload();
    var s2: u16 = @intCast(stream.readBits(table.log));
    _ = stream.reload();

    const symbolOf = struct {
        fn f(t: *const @import("../fse/dtable.zig").DTable, state: u16) u8 {
            return @truncate(t.entries[state].symbol);
        }
    }.f;
    const advance = struct {
        fn f(
            ds: *bitstream.BIT_DStream,
            t: *const @import("../fse/dtable.zig").DTable,
            state: u16,
        ) u16 {
            const entry = t.entries[state];
            if (entry.nbBits == 0) return entry.newState;
            return @intCast(@as(u64, entry.newState) + ds.readBits(entry.nbBits));
        }
    }.f;

    var written: usize = 0;
    while (stream.reload() == .unfinished and written + 3 < dst.len) {
        dst[written] = symbolOf(&table, s1);
        s1 = advance(&stream, &table, s1);
        dst[written + 1] = symbolOf(&table, s2);
        s2 = advance(&stream, &table, s2);
        dst[written + 2] = symbolOf(&table, s1);
        s1 = advance(&stream, &table, s1);
        dst[written + 3] = symbolOf(&table, s2);
        s2 = advance(&stream, &table, s2);
        written += 4;
    }
    while (written < dst.len) {
        if (stream.reload() == .overflow or (stream.endOfStream() and s1 == 0)) break;
        dst[written] = symbolOf(&table, s1);
        s1 = advance(&stream, &table, s1);
        written += 1;
        if (written >= dst.len) break;
        if (stream.reload() == .overflow or (stream.endOfStream() and s2 == 0)) break;
        dst[written] = symbolOf(&table, s2);
        s2 = advance(&stream, &table, s2);
        written += 1;
    }
    // Both states back at zero and the stream exactly consumed: anything else means
    // the header described a different number of weights than the table does.
    if (stream.endOfStream() and s1 == 0 and s2 == 0) return written;
    return error.Corruption;
}
/// Fills a single-symbol table from a weight list.
pub fn buildX2(table: *TableX2, stats: *const Stats) errors.ZstdError!void {
    if (stats.max_bits > max_table_log) return error.TableLogTooLarge;
    if (stats.max_bits == 0) return error.Corruption;
    table.log = stats.max_bits;

    // How many symbols share each weight, and therefore how many table slots that
    // weight's codes occupy: a weight-`n` code is `max_bits + 1 - n` bits wide and
    // so takes `2^(n-1)` slots.
    var per_weight: [max_table_log + 1]u32 = @splat(0);
    for (stats.weights[0..stats.count]) |w| {
        if (w == 0) continue;
        if (w > stats.max_bits) return error.Corruption;
        per_weight[w] += 1;
    }

    // The first slot of each weight's run. Weights run in increasing order, which
    // puts the longest codes first - exactly the order the decoder's table index
    // expects.
    var rank_start: [max_table_log + 1]u32 = @splat(0);
    var next: u32 = 0;
    var n: usize = 1;
    while (n <= stats.max_bits) : (n += 1) {
        rank_start[n] = next;
        next += per_weight[n] << @intCast(n - 1);
    }
    // The slots have to add up to the table exactly, or the codes would overlap or
    // leave a gap the decoder could land in.
    if (next != (@as(u32, 1) << @intCast(stats.max_bits))) return error.Corruption;

    for (stats.weights[0..stats.count], 0..) |w, sym| {
        if (w == 0) continue;
        const length: usize = (@as(usize, 1) << @intCast(w)) >> 1;
        const cell = CellX2{ .byte = @intCast(sym), .nbBits = @intCast(stats.max_bits + 1 - w) };
        const end = rank_start[w] + @as(u32, @intCast(length));
        var i: usize = rank_start[w];
        rank_start[w] = end;
        while (i < end) : (i += 1) table.cells[i] = cell;
    }
}
/// Fills a double-symbol table from a weight list.
/// One entry of the weight-sorted symbol list the `X4` builder walks.
const SortedSymbol = struct {
    symbol: u8,
    weight: u8,
};
/// Fills a double-symbol table from a weight list.
///
/// The tree is walked in two levels. The first assigns each symbol a slot range
/// proportional to its code length. Within a range wide enough for the code, a
/// second symbol is packed next to it, which is what lets an `X4` cell emit two
/// bytes for one table lookup. A range too narrow for a second symbol keeps a
/// single-byte cell instead, and both cases coexist in one table.
///
/// `mem_log` is the depth the table is indexed at: the deepest code the weights
/// can express. It may not be shallower than the weights need or deeper than the
/// format's table-log ceiling. Every reference reader uses the maximum, and so
/// does this one, because a shallower table silently loses accuracy.
pub fn buildX4(table: *TableX4, mem_log: u8, stats: *const Stats) errors.ZstdError!void {
    if (mem_log > max_table_log) return error.TableLogTooLarge;
    if (stats.max_bits > mem_log) return error.TableLogTooLarge;
    if (mem_log < default_table_log) return error.TableLogTooLarge;
    const target_log = mem_log;
    const nb_bits_baseline: u32 = stats.max_bits + 1;
    table.log = mem_log;

    // The heaviest rank actually present; the table is built to that depth.
    var max_w: u8 = stats.max_bits;
    while (max_w > 0 and rankCount(stats, max_w) == 0) max_w -= 1;
    if (max_w == 0) return error.Corruption;

    // Bucket the symbols by weight. That both sorts them and gives each weight
    // class its first slot.
    var rank_start: [max_table_log + 2]u32 = @splat(0);
    var next: u32 = 0;
    var w: usize = 1;
    while (w <= max_w) : (w += 1) {
        rank_start[w] = next;
        next += rankCount(stats, @intCast(w));
    }
    const size_of_sort = next;

    var sorted: [max_symbol + 1]SortedSymbol = undefined;
    for (stats.weights[0..stats.count], 0..) |weight, sym| {
        if (weight == 0) continue;
        const slot = rank_start[weight];
        rank_start[weight] = slot + 1;
        if (slot >= sorted.len) return error.Corruption;
        sorted[slot] = .{ .symbol = @intCast(sym), .weight = weight };
    }
    // After bucketing, `rank_start[w]` points at where weight `w + 1` begins,
    // which is the index the second level scans from.
    rank_start[0] = 0;

    // `rank_val[consumed][weight]` is the slot the next symbol of that weight
    // takes once `consumed` bits have already been spent. Row 0 is the unshifted
    // one; the rest are that row shifted right by the consumed count.
    var rank_val: [max_table_log + 1][max_table_log + 1]u32 = @splat(@splat(0));
    const min_bits: u32 = nb_bits_baseline - max_w;
    const rescale: i32 = @as(i32, mem_log) - @as(i32, stats.max_bits) - 1;
    var next_rank_val: u32 = 0;
    w = 1;
    while (w <= max_w) : (w += 1) {
        const cur = next_rank_val;
        next_rank_val += rankCount(stats, @intCast(w)) << @intCast(w + @as(u32, @intCast(rescale)));
        rank_val[0][w] = cur;
    }
    var consumed: u32 = min_bits;
    while (consumed <= @as(u32, mem_log) -| min_bits) : (consumed += 1) {
        w = 1;
        while (w <= max_w) : (w += 1) {
            rank_val[consumed][w] = rank_val[0][w] >> @intCast(consumed);
        }
    }

    fillX4(
        &table.cells,
        target_log,
        sorted[0..size_of_sort],
        &rank_start,
        &rank_val,
        max_w,
        nb_bits_baseline,
    );
}
fn rankCount(stats: *const Stats, weight: u8) u32 {
    var n: u32 = 0;
    for (stats.weights[0..stats.count]) |w| {
        if (w == weight) n += 1;
    }
    return n;
}
fn fillX4(
    cells: []CellX4,
    target_log: u8,
    sorted: []const SortedSymbol,
    rank_start: *const [max_table_log + 2]u32,
    rank_val: *const [max_table_log + 1][max_table_log + 1]u32,
    max_weight: u8,
    nb_bits_baseline: u32,
) void {
    const min_bits: u32 = nb_bits_baseline - max_weight;
    // How far the table is stretched relative to the code's own depth. Always
    // <= 1, because the weights cannot express a code deeper than `target_log`.
    const scale_log: i32 = @as(i32, @intCast(nb_bits_baseline)) - @as(i32, @intCast(target_log));
    var rank_val_row: [max_table_log + 1]u32 = rank_val[0][0 .. max_table_log + 1].*;

    for (sorted) |entry| {
        const nb_bits: u32 = nb_bits_baseline - entry.weight;
        const start: usize = rank_val_row[entry.weight];
        const length: usize = @as(usize, 1) << @intCast(target_log - @as(u8, @intCast(nb_bits)));
        if (@as(usize, target_log) -| @as(usize, nb_bits) >= min_bits) {
            // Wide enough to carry a second symbol alongside this one.
            var min_weight: i32 = @as(i32, @intCast(nb_bits)) + scale_log;
            if (min_weight < 1) min_weight = 1;
            if (@as(usize, @intCast(min_weight)) > max_table_log) return;
            // `rank_start[w]` is the first slot of weight `w + 1`, so weight
            // `min_weight`'s own bucket starts one index earlier. Slot 0 was pinned
            // to zero, which is what makes weight 1's bucket start there.
            const sorted_rank: usize = rank_start[@as(usize, @intCast(min_weight)) - 1];
            if (sorted_rank > sorted.len) return;
            fillX4Level2(
                cells[start..],
                target_log - @as(u8, @intCast(nb_bits)),
                nb_bits,
                rank_val[nb_bits][0 .. max_table_log + 1],
                @intCast(min_weight),
                sorted[sorted_rank..],
                nb_bits_baseline,
                entry.symbol,
            );
        } else {
            // Narrow: one symbol at this depth.
            const cell = CellX4{
                .sequence = entry.symbol,
                .nbBits = @intCast(nb_bits),
                .length = 1,
            };
            const end = @min(start + length, cells.len);
            for (cells[start..end]) |*c| c.* = cell;
        }
        rank_val_row[entry.weight] += @intCast(length);
    }
}
fn fillX4Level2(
    cells: []CellX4,
    size_log: u8,
    consumed: u32,
    rank_val_origin: []const u32,
    min_weight: u8,
    sorted: []const SortedSymbol,
    nb_bits_baseline: u32,
    base_seq: u8,
) void {
    var rank_val: [max_table_log + 1]u32 = @splat(0);
    @memcpy(rank_val[0..rank_val_origin.len], rank_val_origin);

    // Symbols lighter than `min_weight` cannot pair here, so the slots before the
    // first eligible one hold only the symbol already decoded.
    if (min_weight > 1) {
        const skip = rank_val[min_weight];
        const cell = CellX4{
            .sequence = base_seq,
            .nbBits = @intCast(consumed),
            .length = 1,
        };
        for (cells[0..@min(skip, cells.len)]) |*c| c.* = cell;
    }

    for (sorted) |entry| {
        const nb_bits: u32 = nb_bits_baseline - entry.weight;
        const start: usize = rank_val[entry.weight];
        if (nb_bits > size_log) return;
        const length: usize = @as(usize, 1) << @intCast(size_log - @as(u8, @intCast(nb_bits)));
        const cell = CellX4{
            .sequence = @as(u16, base_seq) | (@as(u16, entry.symbol) << 8),
            .nbBits = @intCast(nb_bits + consumed),
            .length = 2,
        };
        const end = @min(start + length, cells.len);
        for (cells[start..end]) |*c| c.* = cell;
        rank_val[entry.weight] += @intCast(length);
    }
}
// Stream decoding
/// Decodes one `X2` stream into `dst`.
///
/// The stream is driven the way the reference drives it: reload while there is
/// room ahead, then keep going without reloading once the container is
/// exhausted, and finally require the stream to have ended exactly. That last
/// requirement is what separates "this stream held exactly its share" from "the
/// table and the jump table disagree".
pub fn decodeStreamX2(
    dst: []u8,
    stream: *bitstream.BIT_DStream,
    table: *const TableX2,
) errors.ZstdError!void {
    var out: usize = 0;
    while (stream.reload() == .unfinished and out < dst.len) {
        const val: usize = @intCast(stream.lookBits(table.log));
        dst[out] = table.cells[val].byte;
        stream.skipBits(table.cells[val].nbBits);
        out += 1;
    }
    while (out < dst.len) {
        const val: usize = @intCast(stream.lookBits(table.log));
        dst[out] = table.cells[val].byte;
        stream.skipBits(table.cells[val].nbBits);
        out += 1;
    }
    if (!stream.endOfStream()) return error.Corruption;
}
/// Decodes one `X4` stream into `dst`, returning how many bytes it wrote.
///
/// An `X4` cell carries up to two symbols, so the loop stops two bytes short
/// before running out of room, and the very last symbol uses the reference's
/// narrower rule: a two-symbol cell at the end of the stream consumes only the
/// first symbol's bits.
pub fn decodeStreamX4(
    dst: []u8,
    stream: *bitstream.BIT_DStream,
    table: *const TableX4,
) errors.ZstdError!usize {
    var out: usize = 0;
    while (stream.reload() == .unfinished and out + 8 <= dst.len) {
        out += decodeSymbolX4(dst[out..], stream, table);
        out += decodeSymbolX4(dst[out..], stream, table);
        out += decodeSymbolX4(dst[out..], stream, table);
        out += decodeSymbolX4(dst[out..], stream, table);
    }
    // The remaining loops hold two bytes of room so that a two-symbol cell always
    // has somewhere to put both of its bytes. Stopping one byte early would emit
    // the first symbol of such a cell and silently drop the second.
    while (stream.reload() == .unfinished and out + 2 <= dst.len) {
        out += decodeSymbolX4(dst[out..], stream, table);
    }
    while (out + 2 <= dst.len) {
        out += decodeSymbolX4(dst[out..], stream, table);
    }
    if (out < dst.len) out += decodeLastSymbolX4(dst[out..], stream, table);
    return out;
}
fn decodeSymbolX4(dst: []u8, stream: *bitstream.BIT_DStream, table: *const TableX4) usize {
    if (dst.len == 0) return 0;
    const val: usize = @intCast(stream.lookBits(table.log));
    const cell = table.cells[val];
    dst[0] = @truncate(cell.sequence);
    if (cell.length == 2 and dst.len >= 2) {
        dst[1] = @truncate(cell.sequence >> 8);
        stream.skipBits(cell.nbBits);
        return 2;
    }
    // One byte of room for a two-symbol cell: the first symbol is emitted, and the
    // cell's bits are still consumed because the code that selected it covered both
    // symbols. The second is simply not returned, which is the reference's
    // end-of-stream rule.
    stream.skipBits(cell.nbBits);
    return 1;
}
fn decodeLastSymbolX4(dst: []u8, stream: *bitstream.BIT_DStream, table: *const TableX4) usize {
    if (dst.len == 0) return 0;
    const val: usize = @intCast(stream.lookBits(table.log));
    const cell = table.cells[val];
    dst[0] = @truncate(cell.sequence);
    if (cell.length == 1) {
        stream.skipBits(cell.nbBits);
    } else if (stream.bitsConsumed < bitstream.container_bits) {
        stream.skipBits(cell.nbBits);
        // Clamped rather than wrapped: past the end of the container there are
        // no bits left to consume, and the stream is finished either way.
        if (stream.bitsConsumed > bitstream.container_bits) {
            stream.bitsConsumed = bitstream.container_bits;
        }
    }
    return 1;
}
/// Decodes the four-stream literal layout, choosing the single- or double-symbol
/// table.
///
/// The choice is the decoder's, not the format's: both tables read the same
/// bitstream and produce the same bytes, they just look up one or two symbols at a
/// time. The double-symbol table is preferred when the weights fit the table depth
/// the reference sizes its buffers at, because it does half the lookups.
pub fn decompress4X(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
) errors.ZstdError!usize {
    if (src.len < 6) return error.Corruption;
    var stats = Stats{};
    const header_read = try readStats(allocator, &stats, max_symbol + 1, src);
    if (header_read >= src.len) return error.SrcSizeWrong;
    const body = src[header_read..];

    if (stats.max_bits <= default_table_log) {
        var table: TableX4 = undefined;
        buildX4(&table, default_table_log, &stats) catch |e| switch (e) {
            error.Corruption => return error.Corruption,
            else => return e,
        };
        try decompress4X4(dst, body, &table);
    } else {
        var table: TableX2 = undefined;
        try buildX2(&table, &stats);
        try decompress4X2(dst, body, &table);
    }
    return dst.len;
}
/// Decodes a single-stream Huffman section: one flat table, one bitstream, and
/// no jump table or four-way split.
///
/// This is the reference's `HUF_decompress1X1` shape, which v0.5 is the first
/// historic version able to select: its literals header carries a flag saying
/// the section is one stream rather than four. The table description is read
/// from the front of the section exactly as in the four-stream case, and what
/// follows is the whole bitstream.
pub fn decompress1X(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
) errors.ZstdError!usize {
    if (src.len < 6) return error.Corruption;
    var stats = Stats{};
    const header_read = try readStats(allocator, &stats, max_symbol + 1, src);
    if (header_read >= src.len) return error.SrcSizeWrong;
    const body = src[header_read..];

    var table: TableX2 = undefined;
    try buildX2(&table, &stats);
    var stream = bitstream.BIT_DStream.init(body) catch |e| switch (e) {
        error.SrcSizeWrong => return error.Corruption,
        else => return e,
    };
    try decodeStreamX2(dst, &stream, &table);
    return dst.len;
}

/// Decodes four single-symbol streams into four contiguous output segments.
///
/// The segments are `(size + 3) / 4` bytes each, clamped to the output. The
/// reference does not clamp, which writes past the buffer for a literal section
/// shorter than four bytes.
pub fn decompress4X2(dst: []u8, src: []const u8, table: *const TableX2) errors.ZstdError!void {
    if (src.len < 10) return error.Corruption;
    const jt = try JumpTable.parse(src);
    const bounds = jt.segmentBounds(dst.len);

    var streams: [4]bitstream.BIT_DStream = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const start = jt.offset(i);
        const length = jt.lengths[i];
        streams[i] = bitstream.BIT_DStream.init(src[start..][0..length]) catch |e| switch (e) {
            error.SrcSizeWrong => return error.Corruption,
            error.Corruption => return error.Corruption,
            else => return e,
        };
    }

    const ends = [4]usize{ bounds[0], bounds[1], bounds[2], bounds[3] };
    const starts = [4]usize{ 0, bounds[0], bounds[1], bounds[2] };
    i = 0;
    while (i < 4) : (i += 1) {
        try decodeStreamX2(dst[starts[i]..ends[i]], &streams[i], table);
    }
}
/// Decodes four double-symbol streams into four contiguous output segments.
pub fn decompress4X4(dst: []u8, src: []const u8, table: *const TableX4) errors.ZstdError!void {
    if (src.len < 10) return error.Corruption;
    const jt = try JumpTable.parse(src);
    const bounds = jt.segmentBounds(dst.len);

    var streams: [4]bitstream.BIT_DStream = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const start = jt.offset(i);
        const length = jt.lengths[i];
        streams[i] = bitstream.BIT_DStream.init(src[start..][0..length]) catch |e| switch (e) {
            error.SrcSizeWrong => return error.Corruption,
            error.Corruption => return error.Corruption,
            else => return e,
        };
    }

    const ends = [4]usize{ bounds[0], bounds[1], bounds[2], bounds[3] };
    const starts = [4]usize{ 0, bounds[0], bounds[1], bounds[2] };
    i = 0;
    while (i < 4) : (i += 1) {
        const written = try decodeStreamX4(dst[starts[i]..ends[i]], &streams[i], table);
        if (written != ends[i] - starts[i]) return error.Corruption;
    }
}
// Stream layouts
/// Where the four streams of a literal section write their output.
pub const Layout = enum {
    /// v0.1: one byte per stream in rotation, so stream 1 owns every fourth
    /// byte of the output rather than a contiguous quarter.
    interleaved,
    /// v0.2 onward: stream 1 owns the first `(dstSize + 3) / 4` bytes, stream 2
    /// the next quarter, and so on.
    segmented,
    /// v0.5 onward: one stream for the whole output.
    single,
};
/// The v0.2 - v0.4 jump table: three explicit 16-bit lengths and a fourth that
/// is whatever the section has left over.
pub const JumpTable = struct {
    lengths: [4]usize,

    pub fn parse(src: []const u8) errors.ZstdError!JumpTable {
        if (src.len < 6) return error.Corruption;
        const l1: usize = bits.readLe16(src[0..2]);
        const l2: usize = bits.readLe16(src[2..4]);
        const l3: usize = bits.readLe16(src[4..6]);
        // Checked with saturating arithmetic: three hostile 16-bit lengths would
        // otherwise wrap and hand back a fourth length larger than the section.
        const taken = l1 +| l2 +| l3 +| 6;
        if (taken > src.len) return error.Corruption;
        return .{ .lengths = .{ l1, l2, l3, src.len - taken } };
    }

    pub fn offset(self: JumpTable, index: usize) usize {
        var at: usize = 6;
        for (self.lengths[0..index]) |l| at += l;
        return at;
    }

    pub fn total(self: JumpTable) usize {
        return 6 + self.lengths[0] + self.lengths[1] + self.lengths[2] + self.lengths[3];
    }

    /// The four segment boundaries in the output for a segmented layout.
    pub fn segmentBounds(self: JumpTable, dst_size: usize) [4]usize {
        _ = self;
        const seg = (dst_size + 3) / 4;
        const b1 = @min(seg, dst_size);
        const b2 = @min(2 * seg, dst_size);
        const b3 = @min(3 * seg, dst_size);
        return .{ b1, b2, b3, dst_size };
    }
};
/// The reference's `HUF_decompress` front end: three shapes short of any table
/// work at all. Getting these wrong costs the literals of every block whose
/// compressed size happens to equal its expanded size.
pub const ShortShape = enum { copy, rle };
pub fn decompressFrontEndChecks(dst_size: usize, c_src_size: usize) errors.ZstdError!?ShortShape {
    if (dst_size == 0) return error.DstSizeTooSmall;
    if (c_src_size > dst_size) return error.Corruption;
    if (c_src_size == dst_size) return .copy;
    if (c_src_size == 1) return .rle;
    return null;
}
// Tests
const testing = std.testing;
// ---------------------------------------------------------------------------
// Stream decoding
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Stream layouts
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A weight list read from a real captured literal body, so the X4 builder is
/// exercised on the weight spread a genuine encoder produces rather than a
/// hand-made one. Returns the stats and the streams that follow the description.
fn sampleStats() !struct { Stats, []const u8 } {
    const body = sampleLiteralSection();
    var s = Stats{};
    const header_read = try readStats(testing.allocator, &s, max_symbol + 1, body);
    return .{ s, body[header_read..] };
}
/// The captured v0.2 frame's Huffman literal body: the 153 bytes that follow the
/// literal section's five-byte header. Its first 32 bytes describe the weights and
/// the rest are the four streams.
///
/// Taken from the golden frame rather than copied, so it cannot drift from the
/// vector the decoder is checked against.
fn sampleLiteralSection() []const u8 {
    const golden = @import("golden_frames.zig");
    // A four-byte frame header plus a three-byte block header; the block then starts
    // with the literal section's five-byte header, so the Huffman body follows.
    return golden.frame_v02[4 + 3 + 5 ..][0..153];
}

test "the weight-description special forms are recognised" {
    var stats = Stats{};
    // 242 + 3 selects the flat-code form with four symbols of weight one: a code
    // where every literal is three bits wide.
    const header = [_]u8{245};
    try testing.expectEqual(@as(usize, 1), try readStats(testing.allocator, &stats, max_symbol + 1, &header));
    // Four explicit weights plus the implied fifth, and the table they describe is
    // three bits deep.
    try testing.expectEqual(@as(usize, 5), stats.count);
    try testing.expectEqual(@as(u8, 3), stats.max_bits);
    for (stats.weights[0..4]) |w| try testing.expectEqual(@as(u8, 1), w);
    try testing.expectEqual(@as(u8, 3), stats.weights[4]);
}
test "the weight-description nibble form is high nibble first" {
    var stats = Stats{};
    // 127 + 4 selects four explicitly stored weights packed two per byte, high
    // nibble first. Four weight-1 symbols total 4, which leaves 4 for the implied
    // fifth symbol, so its weight is 3 and the table is three bits deep.
    const header = [_]u8{ 127 + 4, 0x11, 0x11 };
    try testing.expectEqual(@as(usize, 3), try readStats(testing.allocator, &stats, max_symbol + 1, &header));
    try testing.expectEqual(@as(usize, 5), stats.count);
    try testing.expectEqual(@as(u8, 3), stats.max_bits);
    for (stats.weights[0..4]) |w| try testing.expectEqual(@as(u8, 1), w);
    try testing.expectEqual(@as(u8, 3), stats.weights[4]);
}
test "a weight list that cannot describe a code is rejected" {
    var stats = Stats{};
    // One symbol of weight 2 and no rank-1 symbol at all. A Huffman code always
    // has at least two leaves at its deepest level, and here that level would be
    // empty, so the implied last symbol cannot complete the total.
    const header = [_]u8{ 127 + 1, 0x20 };
    try testing.expectError(error.Corruption, readStats(testing.allocator, &stats, max_symbol + 1, &header));
    // The same rejection happens whatever the weights were: the total is a power
    // of two minus a power of two, but the implied symbol's share is not the
    // difference, so the implied weight cannot complete it.
    const impossible = [_]u8{ 127 + 2, 0x50, 0x10 };
    try testing.expectError(error.Corruption, readStats(testing.allocator, &stats, max_symbol + 1, &impossible));
}
test "an empty weight description is rejected" {
    var stats = Stats{};
    try testing.expectError(error.SrcSizeWrong, readStats(testing.allocator, &stats, max_symbol + 1, &[_]u8{}));
}
test "the jump table's fourth length is what remains" {
    // Six bytes of lengths, then four streams.
    const body = [_]u8{
        2, 0, // 2
        3, 0, // 3
        1, 0, // 1
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, // stream 4: the last byte, 1 byte
    };
    const jt = try JumpTable.parse(&body);
    try testing.expectEqual([_]usize{ 2, 3, 1, 1 }, jt.lengths);
    try testing.expectEqual(@as(usize, 6), jt.offset(0));
    try testing.expectEqual(@as(usize, 8), jt.offset(1));
    try testing.expectEqual(@as(usize, 11), jt.offset(2));
    try testing.expectEqual(@as(usize, 12), jt.offset(3));
    try testing.expectEqual(body.len, jt.total());
}
test "a jump table whose lengths overrun the section is rejected" {
    // Three 0xFFFF lengths against an eleven-byte section. Unsigned subtraction
    // would wrap and produce a fourth length of a huge number.
    const body = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 1, 2, 3, 4, 5 };
    try testing.expectError(error.Corruption, JumpTable.parse(&body));
    const too_short = [_]u8{ 1, 0, 0, 0, 0 };
    try testing.expectError(error.Corruption, JumpTable.parse(&too_short));
}
test "segment boundaries divide the output into four near-equal parts" {
    const jt = JumpTable{ .lengths = .{ 1, 1, 1, 1 } };
    // 10 bytes split 3/3/3/1, so the last segment can be shorter than the rest.
    try testing.expectEqual([_]usize{ 3, 6, 9, 10 }, jt.segmentBounds(10));
    // 8 bytes divide evenly.
    try testing.expectEqual([_]usize{ 2, 4, 6, 8 }, jt.segmentBounds(8));
    // Fewer bytes than streams. The reference computes the last segment's end as
    // a fixed quarter of the output past the third, which runs past the buffer
    // and writes out of bounds here. Clamping is the whole difference between
    // that and a safe reader, so the trailing segments come out empty rather than
    // overlapping.
    try testing.expectEqual([_]usize{ 1, 2, 2, 2 }, jt.segmentBounds(2));
}
test "the decompress front end's size-only shapes" {
    try testing.expectEqual(@as(?ShortShape, null), try decompressFrontEndChecks(100, 50));
    // Equal sizes mean the section is stored verbatim.
    try testing.expectEqual(@as(?ShortShape, .copy), try decompressFrontEndChecks(100, 100));
    // One byte means every literal is that byte.
    try testing.expectEqual(@as(?ShortShape, .rle), try decompressFrontEndChecks(100, 1));
    // Nothing to regenerate is an error, not an empty success.
    try testing.expectError(error.DstSizeTooSmall, decompressFrontEndChecks(0, 0));
    // A compressed section larger than its output cannot be compressed.
    try testing.expectError(error.Corruption, decompressFrontEndChecks(10, 11));
}
test "the block size cap every historic literal buffer assumes" {
    // Every reference reader sizes its literal buffer at 128 KB and rejects more,
    // so a literal count above that is corruption in all seven versions.
    try testing.expectEqual(@as(usize, 131072), format.block_size_max);
}
test "the X4 table fills every cell it indexes" {
    // A cell the X4 builder never writes is a cell the decoder reads as
    // uninitialised, and a partial fill produces plausible bytes rather than an
    // error. Every slot within the table's indexed width must therefore carry a
    // cell with a legal width.
    const stats = (try sampleStats())[0];
    var t4: TableX4 = undefined;
    try buildX4(&t4, default_table_log, &stats);
    try testing.expectEqual(default_table_log, t4.log);

    const used = @as(usize, 1) << @intCast(t4.log);
    for (t4.cells[0..used], 0..) |c, slot| {
        // A two-symbol cell's width is at least 1 and at most the table depth; a
        // one-symbol cell is a symbol with no partner, also at least 1 bit.
        try testing.expect(c.length == 1 or c.length == 2);
        try testing.expect(c.nbBits >= 1 and c.nbBits <= t4.log);
        // Both symbols of a two-symbol cell are real literals.
        if (c.length == 2) {
            try testing.expect(@as(u8, @truncate(c.sequence)) < stats.count);
            try testing.expect(@as(u8, @truncate(c.sequence >> 8)) < stats.count);
        }
        _ = slot;
    }
}
test "the X4 and X2 tables decode a real section identically" {
    // A real captured literal section, decoded both ways. The two paths are
    // independent implementations of the same format, so agreeing on real data is
    // the check that neither has drifted.
    const body = sampleLiteralSection();
    const sampled = try sampleStats();
    const stats = sampled[0];
    const streams = sampled[1];
    const size: usize = 216;

    const out2 = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(out2);
    var t2: TableX2 = undefined;
    try buildX2(&t2, &stats);
    try decompress4X2(out2, streams, &t2);

    const out4 = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(out4);
    var t4: TableX4 = undefined;
    try buildX4(&t4, default_table_log, &stats);
    try decompress4X4(out4, streams, &t4);

    try testing.expectEqualSlices(u8, out2, out4);
    // And the entry point chooses one of them, so it must produce the same bytes.
    const out = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(out);
    _ = try decompress4X(testing.allocator, out, body);
    try testing.expectEqualSlices(u8, out2, out);
}
