//! Huffman literal encoding: code construction, tree-description serialisation,
//! and 1-stream / 4-stream bitstream output.
//!
//! A literals payload is a `Huffman_Tree_Description` followed by one or four
//! bitstreams (RFC 8878 Section 4.2.1). The description is either a direct nibble
//! table (header byte >= 128; byte minus 127 is the weight count, high nibble
//! first) or an FSE-compressed weight stream whose size is the header byte, with
//! an FSE table log the format caps at 6. In both forms the last weight is
//! implied and the decoder recovers the table log from `sum(2^(weight-1))`, so
//! Kraft equality is a hard requirement: the encoder must emit a *complete* code.
//!
//! Code construction is two-stage: the optimal unconstrained Huffman code is used
//! whenever it fits the format's depth limit, and only otherwise does the
//! length-limited fallback run. Both stages emit a complete code, every present
//! symbol with a length in 1..=depth summing to exactly `1 << depth`.

const std = @import("std");
const errors = @import("../common/errors.zig");
const bitstream_mod = @import("../common/bitstream.zig");
const fse = @import("../fse/ctable.zig");
const fse_w = @import("../fse/compress.zig");

/// Format ceiling on the Huffman table log (RFC 8878 Section 4.2.1.1).
pub const max_table_log: u8 = 12;
/// Depth the literals encoder aims for. The reference encoder uses the same
/// value; the format itself allows up to `max_table_log`.
pub const default_table_log: u8 = 11;
/// The weight stream inside a tree description is FSE-coded with a table log
/// the format caps at 6.
pub const weight_table_log_max: u8 = 6;
pub const max_symbol: usize = 255;
/// Payloads regenerating fewer bytes than this use a single bitstream.
pub const min_literals_4_streams: usize = 256;
/// Below this many literals a tree description cannot pay for itself, unless a
/// previous table can be re-used.
pub const min_literals_to_compress: usize = 64;
/// Smallest regenerated size the format allows for a 4-stream section.
pub const min_literals_4_stream_size: usize = 6;

/// Literals block types, matching `Literals_Block_Type`.
pub const Mode = enum(u2) {
    raw = 0,
    rle = 1,
    compressed = 2,
    treeless = 3,
};

/// Histogram facts the encoder needs beyond the counts themselves.
pub const Stats = struct {
    /// Highest symbol present.
    max_symbol: u8 = 0,
    /// Number of distinct symbols present.
    cardinality: u16 = 0,
    /// Count of the most frequent symbol.
    largest: u32 = 0,
    /// Total number of bytes scanned.
    total: u32 = 0,
};

/// A complete Huffman code plus the derived weight list the tree description
/// needs.
pub const Table = struct {
    /// Deepest code in the table. The decoder derives exactly this value from
    /// the weights, so it is not a free parameter.
    table_log: u8 = 0,
    /// Highest symbol carrying a code.
    max_symbol: u8 = 0,
    /// Number of coded symbols.
    cardinality: u16 = 0,
    /// Code length per symbol; zero means the symbol is not in the table.
    lengths: [256]u8 = @splat(0),
    /// Canonical code per symbol, meaningful where `lengths` is non-zero.
    codes: [256]u32 = @splat(0),
    /// Tree-description weight per symbol: `table_log + 1 - lengths`.
    weights: [256]u8 = @splat(0),

    /// Exact number of payload bytes this table would produce, which is what
    /// decides whether re-using it beats describing a fresh one.
    pub fn payloadSize(self: *const Table, counts: *const [256]u32) u32 {
        var bits: u64 = 0;
        for (counts, 0..) |c, s| {
            if (c == 0) continue;
            bits += @as(u64, c) * self.lengths[s];
        }
        return @intCast((bits + 7) / 8);
    }
};

/// Reusable scratch for the literals encoder. Owned by the frame-level
/// literals state so consecutive blocks of a frame never re-allocate.
pub const Scratch = struct {
    counts: [256]u32 = @splat(0),
    /// Present symbols ordered by ascending count.
    ascending: [256]u8 = undefined,
    /// Present symbols ordered by descending count.
    descending: [256]u8 = undefined,
    weight_counts: [max_table_log + 2]u32 = @splat(0),
    norm: [max_table_log + 2]i16 = @splat(0),
    weight_table: fse.SmallCTable = .{},
};

/// Frame-level literals state: the table the decoder would still remember from
/// an earlier block, plus the scratch needed to build the next one.
pub const LiteralsState = struct {
    table: Table = .{},
    /// True when `table` was described in a literals section of the current
    /// frame, so the decoder still holds it. Raw and RLE sections do not clear
    /// it: the format only replaces the table on a new description.
    available: bool = false,
    scratch: Scratch = .{},

    /// Starts a new frame: the decoder drops its table along with everything
    /// else that is frame-local.
    pub fn reset(self: *LiteralsState) void {
        self.table = .{};
        self.available = false;
    }

    /// True when the remembered table can encode every symbol of the input.
    pub fn covers(self: *const LiteralsState, counts: *const [256]u32, stats: Stats) bool {
        if (!self.available) return false;
        for (counts[0 .. @as(usize, stats.max_symbol) + 1], 0..) |c, s| {
            if (c != 0 and self.table.lengths[s] == 0) return false;
        }
        return true;
    }
};

/// Counts `src` into `counts` and returns the derived histogram facts.
pub fn analyze(counts: *[256]u32, src: []const u8) Stats {
    @memset(counts, 0);
    var stats = Stats{};
    for (src) |b| {
        if (counts[b] == 0) stats.cardinality += 1;
        counts[b] += 1;
        if (b > stats.max_symbol) stats.max_symbol = b;
    }
    for (counts[0 .. @as(usize, stats.max_symbol) + 1]) |c| {
        stats.total += c;
        if (c > stats.largest) stats.largest = c;
    }
    return stats;
}

const CountOrder = struct {
    counts: *const [256]u32,

    /// Most frequent first, symbol value breaking ties so the result does not
    /// depend on the sort implementation.
    fn frequentFirst(self: CountOrder, a: u8, b: u8) bool {
        const ca = self.counts[a];
        const cb = self.counts[b];
        if (ca != cb) return ca > cb;
        return a < b;
    }

    /// Rarest first. The Huffman merge relies on the leaf queue being sorted by
    /// count, so this ordering is a correctness requirement rather than a
    /// preference.
    fn leastFrequentFirst(self: CountOrder, a: u8, b: u8) bool {
        const ca = self.counts[a];
        const cb = self.counts[b];
        if (ca != cb) return ca < cb;
        return a < b;
    }
};

/// Lists the present symbols in both count orders, which the two code-length
/// algorithms consume.
fn orderSymbols(counts: *const [256]u32, stats: Stats, scratch: *Scratch) void {
    var n: usize = 0;
    for (counts[0 .. @as(usize, stats.max_symbol) + 1], 0..) |c, s| {
        if (c != 0) {
            scratch.ascending[n] = @intCast(s);
            n += 1;
        }
    }
    const order = CountOrder{ .counts = counts };
    std.mem.sort(u8, scratch.ascending[0..n], order, CountOrder.leastFrequentFirst);
    std.mem.copyForwards(u8, scratch.descending[0..n], scratch.ascending[0..n]);
    std.mem.sort(u8, scratch.descending[0..n], order, CountOrder.frequentFirst);
}

/// Unconstrained Huffman code lengths, computed with the classic two-queue
/// construction: the leaf queue is sorted by count while internal nodes emerge
/// in non-decreasing order, so each merge only has to look at the two queue
/// heads. Returns the longest code.
fn huffmanLengths(counts: *const [256]u32, ascending: []const u8, lengths: *[256]u8) u8 {
    const m = ascending.len;
    const max_nodes = 2 * m;
    var weight: [2 * (max_symbol + 1)]u32 = @splat(0);
    var parent: [2 * (max_symbol + 1)]u16 = @splat(0);
    for (ascending, 0..) |s, i| weight[i] = counts[s];

    var leaf: usize = 0; // cursor into the leaf queue
    var internal: usize = m; // cursor into the internal-node queue
    var nodes: usize = m; // next free node id
    while (nodes < max_nodes - 1) {
        var pick: [2]usize = undefined;
        for (0..2) |k| {
            const prefer_leaf = leaf < m and (internal >= nodes or weight[leaf] <= weight[internal]);
            pick[k] = if (prefer_leaf) blk: {
                const idx = leaf;
                leaf += 1;
                break :blk idx;
            } else blk: {
                const idx = internal;
                internal += 1;
                break :blk idx;
            };
        }
        weight[nodes] = weight[pick[0]] + weight[pick[1]];
        parent[pick[0]] = @intCast(nodes);
        parent[pick[1]] = @intCast(nodes);
        nodes += 1;
    }

    // A parent always has a higher node id than its children, so one reverse
    // sweep assigns every depth.
    var depth: [2 * (max_symbol + 1)]u8 = @splat(0);
    depth[nodes - 1] = 0;
    var i: usize = nodes - 1;
    while (i > 0) {
        i -= 1;
        depth[i] = depth[parent[i]] + 1;
    }
    var deepest: u8 = 0;
    for (ascending, 0..) |s, li| {
        lengths[s] = depth[li];
        if (depth[li] > deepest) deepest = depth[li];
    }
    return deepest;
}

/// Fewest terms needed to express `value` as a sum of powers of two no larger
/// than `1 << (depth-1)`. `value` is measured in units of `2^-depth`, so the
/// capacity of a depth-`depth` code is `1 << depth`.
fn minTerms(value: u32, depth: u8) u32 {
    if (value == 0) return 0;
    if (value == (@as(u32, 1) << @intCast(depth))) return 2; // no term covers it alone
    return @popCount(value);
}

/// Length-limited assignment, used when the optimal code is too deep. Symbols
/// are served most-frequent first, each taking the largest power of two that
/// leaves the remaining symbols able to fill the remaining capacity exactly. The
/// `minTerms` test makes each step provably feasible, so the search cannot
/// dead-end and the result satisfies Kraft equality by construction.
fn lengthLimitedLengths(descending: []const u8, depth: u8, lengths: *[256]u8) u8 {
    const full: u32 = @as(u32, 1) << @intCast(depth);
    const longest: u32 = full >> 1;
    var capacity: u32 = full;
    var remaining: usize = descending.len;
    var deepest: u8 = 0;
    for (descending) |s| {
        const left: u32 = @intCast(remaining - 1);
        const ceiling: u32 = @min(longest, capacity - left);
        var term: u32 = @as(u32, 1) << @intCast(31 - @clz(ceiling));
        while (term != 0) : (term >>= 1) {
            const rest = capacity - term;
            if (left <= rest and minTerms(rest, depth) <= left) break;
        }
        // Unreachable for a fillable state; kept so a logic error degrades to a
        // still-valid code rather than a panic in the middle of a frame.
        if (term == 0) term = 1;
        const length: u8 = @intCast(depth - (31 - @clz(term)));
        lengths[s] = length;
        if (length > deepest) deepest = length;
        capacity -= term;
        remaining -= 1;
    }
    return deepest;
}

/// Fills in `table_log`, `weights`, `codes` and the symbol metadata from
/// `lengths`, and verifies the Kraft identity the format depends on.
fn finalizeTable(table: *Table, stats: Stats) errors.ZstdError!void {
    var per_rank: [max_table_log + 2]u16 = @splat(0);
    var deepest: u8 = 0;
    var coded: u16 = 0;
    var max_symbol_seen: u8 = 0;
    for (0..256) |s| {
        const l = table.lengths[s];
        if (l == 0) continue;
        if (l > max_table_log) return error.InvalidHuffmanTable;
        per_rank[l] += 1;
        coded += 1;
        if (l > deepest) deepest = l;
        if (s > max_symbol_seen) max_symbol_seen = @intCast(s);
    }
    if (deepest == 0 or coded != stats.cardinality) return error.InvalidHuffmanTable;

    // Canonical codes: cells are handed out longest code first, each symbol
    // taking `1 << (table_log - length)` of them. The decoder fills its flat
    // table in exactly this order, which is what makes the codes agree.
    var start: [max_table_log + 2]u32 = @splat(0);
    var next: u32 = 0;
    var rank = deepest;
    while (rank >= 1) : (rank -= 1) {
        start[rank] = next;
        next += @as(u32, per_rank[rank]) << @as(std.math.Log2Int(u32), @intCast(deepest - rank));
    }
    if (next != (@as(u32, 1) << @intCast(deepest))) return error.InvalidHuffmanTable;

    for (0..256) |s| {
        const l = table.lengths[s];
        if (l == 0) {
            table.codes[s] = 0;
            table.weights[s] = 0;
            continue;
        }
        const span: u32 = @as(u32, 1) << @as(std.math.Log2Int(u32), @intCast(deepest - l));
        table.codes[s] = start[l] >> @intCast(deepest - l);
        start[l] += span;
        table.weights[s] = deepest + 1 - l;
    }
    table.table_log = deepest;
    table.max_symbol = max_symbol_seen;
    table.cardinality = coded;
}

/// Smallest depth that can hold `cardinality` symbols in a complete code.
/// A complete code needs one cell per leaf, so `2^depth >= cardinality`.
pub fn minDepthFor(cardinality: u16) u8 {
    if (cardinality <= 2) return 1;
    return @intCast(32 - @clz(@as(u32, cardinality) - 1));
}

/// Builds a complete code for `counts` with no code longer than `max_depth`.
///
/// Returns `error.InvalidHuffmanTable` for alphabets of fewer than two
/// symbols, because a one-symbol alphabet has no complete code (Kraft equality
/// is unreachable) and must be written as an RLE literals section instead.
pub fn buildTable(
    table: *Table,
    counts: *const [256]u32,
    stats: Stats,
    max_depth: u8,
    scratch: *Scratch,
) errors.ZstdError!void {
    if (stats.cardinality < 2) return error.InvalidHuffmanTable;
    // The depth floor wins over the caller's cap: a code shallower than
    // ceil(log2(cardinality)) cannot be complete, so honouring a smaller cap
    // would produce an undecodable table.
    const depth: u8 = @max(minDepthFor(stats.cardinality), @min(max_depth, max_table_log));
    orderSymbols(counts, stats, scratch);
    @memset(table.lengths[0..], 0);
    const m: usize = stats.cardinality;
    var deepest = huffmanLengths(counts, scratch.ascending[0..m], &table.lengths);
    if (deepest > depth) {
        @memset(table.lengths[0..], 0);
        deepest = lengthLimitedLengths(scratch.descending[0..m], depth, &table.lengths);
    }
    try finalizeTable(table, stats);
}

/// Encodes the weight list with FSE, the second tree-description form.
///
/// Returns 0 when the weights are not worth compressing: too few to matter, all
/// distinct, or not enough room in `dst`. Returns 1 for the single-value (RLE)
/// case, which the caller writes verbatim.
fn writeFseWeights(dst: []u8, weights: []const u8, scratch: *Scratch) errors.ZstdError!usize {
    const wt_size = weights.len;
    if (wt_size < 3 or dst.len < 4) return 0;

    @memset(scratch.weight_counts[0..], 0);
    var max_weight: usize = 0;
    for (weights) |w| {
        scratch.weight_counts[w] += 1;
        if (w > max_weight) max_weight = w;
    }
    var largest: u32 = 0;
    for (scratch.weight_counts[0 .. max_weight + 1]) |c| {
        if (c > largest) largest = c;
    }
    if (largest == wt_size) return 1; // one distinct weight: RLE description
    if (largest == 1) return 0; // all weights distinct: nothing to gain

    const table_log = fse_w.optimalTableLog(weight_table_log_max, wt_size, max_weight);
    @memset(scratch.norm[0..], 0);
    _ = try fse_w.normalizeCountsExt(
        &scratch.norm,
        scratch.weight_counts[0 .. max_weight + 1],
        table_log,
        wt_size,
        false,
    );
    var op: usize = 0;
    op += try fse_w.writeNCount(dst[op..], scratch.norm[0 .. max_weight + 1], max_weight, table_log);
    const ctable = try scratch.weight_table.build(scratch.norm[0 .. max_weight + 1], max_weight, table_log);
    var bc = try bitstream_mod.BIT_CStream.init(dst[op..]);
    encodeFseSymbols(&bc, &ctable, weights);
    op += try bc.close();
    return op;
}

/// Writes the two interleaved FSE state machines a weight stream is built from.
/// The decoder emits even-indexed symbols from its first state and odd-indexed
/// ones from its second, so state one carries the even positions. Symbols are
/// written back to front (the reverse bitstream reads the last-written bits first)
/// and the states are flushed second-first, so state one's final value lands in
/// the last bytes of the stream.
fn encodeFseSymbols(bc: *bitstream_mod.BIT_CStream, ctable: *const fse.CTable, symbols: []const u8) void {
    const n = symbols.len;
    var state1: fse.CState = undefined;
    var state2: fse.CState = undefined;
    const top = n - 1;
    const hi_even: usize = if (top % 2 == 0) top else top - 1;
    const hi_odd: usize = if (top % 2 == 1) top else top - 1;
    state1.initState(ctable, symbols[hi_even]);
    state2.initState(ctable, symbols[hi_odd]);
    var i: isize = @as(isize, @intCast(n)) - 3;
    while (i >= 0) : (i -= 1) {
        const idx: usize = @intCast(i);
        if (idx % 2 == 0) {
            state1.encodeSymbol(ctable, bc, symbols[idx]);
        } else {
            state2.encodeSymbol(ctable, bc, symbols[idx]);
        }
    }
    state2.flushState(bc);
    state1.flushState(bc);
}

/// Upper bound on a tree description, used to decide whether re-using the
/// remembered table beats describing a fresh one without having to serialise
/// anything. The FSE form is only ever accepted when it is smaller than the
/// direct form, so the direct form is a valid bound.
fn descriptionBound(table: *const Table) u32 {
    const max_sym: usize = table.max_symbol;
    if (max_sym < 1) return 0;
    var distinct: u32 = 0;
    for (table.weights[0..max_sym]) |w| {
        if (w != 0) distinct += 1;
    }
    if (distinct <= 1) return 1; // RLE description
    return @intCast(1 + (max_sym + 1) / 2);
}

/// Serialises the tree description of `table` into `dst`.
///
/// Picks the FSE form only when it is genuinely smaller than the direct nibble
/// table, which is the decoder's own acceptance test.
pub fn writeTreeDescription(dst: []u8, table: *const Table, scratch: *Scratch) errors.ZstdError!usize {
    const max_sym: usize = table.max_symbol;
    if (max_sym < 1) return error.InvalidHuffmanTable;
    if (dst.len < 1) return error.DstSizeTooSmall;
    const weights = table.weights[0..max_sym];
    if (max_sym >= 3) {
        if (writeFseWeights(dst[1..], weights, scratch)) |h_size| {
            if (h_size > 1 and h_size < max_sym / 2 and h_size + 1 < dst.len) {
                dst[0] = @intCast(h_size);
                return h_size + 1;
            }
        } else |_| {}
    }
    // Direct form: one nibble per weight except the last, which the decoder
    // infers from the rest. The header byte carries the weight count in its
    // low seven bits, so this form cannot describe more than 128 weights.
    if (max_sym > 128) return error.DstSizeTooSmall;
    const osize = (max_sym + 1) / 2;
    if (1 + osize > dst.len) return error.DstSizeTooSmall;
    dst[0] = @intCast(128 + (max_sym - 1));
    var n: usize = 0;
    while (n < max_sym) : (n += 2) {
        const hi = weights[n];
        const lo: u8 = if (n + 1 < max_sym) weights[n + 1] else 0;
        dst[1 + n / 2] = (hi << 4) | lo;
    }
    return 1 + osize;
}

/// Encodes `src` into a single Huffman bitstream. Returns 0 for an empty input.
pub fn compress1X(dst: []u8, src: []const u8, table: *const Table) errors.ZstdError!usize {
    if (src.len == 0) return 0;
    var bc = try bitstream_mod.BIT_CStream.init(dst);
    var ip: usize = src.len;
    while (ip > 0) {
        ip -= 1;
        const s = src[ip];
        const length = table.lengths[s];
        if (length == 0) return error.Corruption;
        bc.addBits(table.codes[s], length);
    }
    return bc.close();
}

/// Encodes `src` into four independent bitstreams preceded by the 6-byte jump
/// table. Returns 0 when the layout cannot be represented, letting the caller
/// fall back to a single stream.
pub fn compress4X(dst: []u8, src: []const u8, table: *const Table) errors.ZstdError!usize {
    if (src.len < min_literals_4_stream_size) return 0;
    // Jump table plus the minimum room each of the four streams needs.
    if (dst.len < 6 + 4 * 9) return 0;

    const segment = (src.len + 3) / 4;
    const ends = [_]usize{ segment, 2 * segment, 3 * segment, src.len };
    // The source split and the destination cursor are independent: a stream's
    // compressed size is not its regenerated size, so the jump table records
    // the destination offsets rather than the source ones.
    var src_pos: usize = 0;
    var dst_pos: usize = 6;
    var sizes: [4]usize = undefined;
    for (0..4) |i| {
        const written = compress1X(dst[dst_pos..], src[src_pos..ends[i]], table) catch return 0;
        if (written == 0 or written > 0xFFFF) return 0;
        sizes[i] = written;
        src_pos = ends[i];
        dst_pos += written;
    }
    dst[0] = @truncate(sizes[0]);
    dst[1] = @truncate(sizes[0] >> 8);
    dst[2] = @truncate(sizes[1]);
    dst[3] = @truncate(sizes[1] >> 8);
    dst[4] = @truncate(sizes[2]);
    dst[5] = @truncate(sizes[2] >> 8);
    return dst_pos;
}

/// Describes how a payload was encoded, which the literals section header has
/// to record: the stream count changes the size format the decoder expects.
pub const PayloadLayout = struct {
    size: usize = 0,
    four_streams: bool = false,
};

/// Encodes `src` with `table` using the stream layout the section header can
/// describe. A single stream is always smaller, but the format only offers
/// single-stream sizes in a 3-byte header, so a payload of 1024 bytes or more must
/// use four. `header_allows_single` says whether the header width for `src.len` is
/// 3 bytes; below 256 regenerated bytes a single stream wins anyway, as four
/// cannot pay for their jump table.
pub fn compressPayload(
    dst: []u8,
    src: []const u8,
    table: *const Table,
    header_allows_single: bool,
) errors.ZstdError!PayloadLayout {
    if (src.len == 0) return .{};
    if (header_allows_single) return .{ .size = try compress1X(dst, src, table) };
    const four = try compress4X(dst, src, table);
    if (four != 0) return .{ .size = four, .four_streams = true };
    // Four streams were impossible after all, and only a 3-byte header may
    // still describe a single stream, which is the case handled above.
    return .{};
}

fn writeLE24(dst: []u8, value: u32) void {
    dst[0] = @truncate(value);
    dst[1] = @truncate(value >> 8);
    dst[2] = @truncate(value >> 16);
}

fn writeRawSection(out: []u8, src: []const u8) usize {
    const n: u32 = @intCast(src.len);
    if (n < 32) {
        out[0] = @truncate(n << 3);
        std.mem.copyForwards(u8, out[1 .. 1 + src.len], src);
        return 1 + src.len;
    }
    if (n < 4096) {
        out[0] = @truncate(0x04 | ((n & 0xF) << 4));
        out[1] = @truncate(n >> 4);
        std.mem.copyForwards(u8, out[2 .. 2 + src.len], src);
        return 2 + src.len;
    }
    writeLE24(out, 0x0C | (n << 4));
    std.mem.copyForwards(u8, out[3 .. 3 + src.len], src);
    return 3 + src.len;
}

fn writeRleSection(out: []u8, src: []const u8) usize {
    const n: u32 = @intCast(src.len);
    if (n < 32) {
        out[0] = @truncate(1 | (n << 3));
        out[1] = src[0];
        return 2;
    }
    if (n < 4096) {
        const v: u16 = @intCast(1 | (1 << 2) | (n << 4));
        out[0] = @truncate(v);
        out[1] = @truncate(v >> 8);
        out[2] = src[0];
        return 3;
    }
    writeLE24(out, 1 | (3 << 2) | (n << 4));
    out[3] = src[0];
    return 4;
}

/// Writes a compressed or treeless literals section header and returns its
/// size in bytes. `headerSize(regen)` must match the width chosen here.
fn writeHuffmanHeader(out: []u8, mode: Mode, single_stream: bool, regen: u32, compressed: u32) usize {
    const header: usize = 3 + @as(usize, @intFromBool(regen >= 1024)) + @as(usize, @intFromBool(regen >= 16384));
    const base: u32 = @backingInt(mode);
    const stream_bit: u32 = if (single_stream) 0 else 1;
    switch (header) {
        3 => writeLE24(out, base | (stream_bit << 2) | (regen << 4) | (compressed << 14)),
        4 => std.mem.writeInt(u32, out[0..4], base | (2 << 2) | (regen << 4) | (compressed << 18), .little),
        else => {
            // 18-bit regenerated size in the first four bytes, 18-bit
            // compressed size split as 10 + 8.
            std.mem.writeInt(u32, out[0..4], base | (3 << 2) | (regen << 4) | ((compressed & 0x3FF) << 22), .little);
            out[4] = @truncate(compressed >> 10);
        },
    }
    return header;
}

/// Serialises a complete literals section (header plus payload) for `src`. The
/// result is always valid: when Huffman coding cannot pay for itself the section
/// degrades to RLE or raw literals. `dst` must hold at least `src.len + 5` bytes,
/// exactly what the raw fallback needs. `state` carries the table between the
/// blocks of a frame so a repeated section can omit the description.
pub fn compressLiteralsSection(dst: []u8, src: []const u8, state: *LiteralsState) errors.ZstdError!usize {
    if (src.len == 0) {
        dst[0] = 0;
        return 1;
    }
    if (dst.len < src.len + 5) return error.DstSizeTooSmall;

    const uniform = blk: {
        for (src[1..]) |b| {
            if (b != src[0]) break :blk false;
        }
        break :blk true;
    };
    if (uniform) return writeRleSection(dst, src);

    const scratch = &state.scratch;
    const stats = analyze(&scratch.counts, src);
    const header: usize = 3 + @as(usize, @intFromBool(src.len >= 1024)) + @as(usize, @intFromBool(src.len >= 16384));
    // Only a 3-byte literals header can describe a single stream, which caps
    // the regenerated size at 1023 bytes.
    const header_allows_single = header == 3;

    // A remembered table needs no description, so it is worth trying whenever
    // it covers the input and a fresh code would not come out smaller.
    var fresh: Table = .{};
    var have_fresh = false;
    if (state.covers(&scratch.counts, stats)) {
        const reused = compressPayload(dst[header..], src, &state.table, header_allows_single) catch PayloadLayout{};
        if (reused.size != 0) {
            const reused_cost = state.table.payloadSize(&scratch.counts);
            if (buildTable(&fresh, &scratch.counts, stats, default_table_log, scratch)) |_| {
                have_fresh = true;
            } else |_| {}
            if (!have_fresh or reused_cost <= fresh.payloadSize(&scratch.counts) + descriptionBound(&fresh)) {
                const size = writeHuffmanHeader(dst, .treeless, !reused.four_streams, @intCast(src.len), @intCast(reused.size));
                std.debug.assert(size == header);
                return size + reused.size;
            }
        }
    }

    if (src.len < min_literals_to_compress) return writeRawSection(dst, src);

    if (!have_fresh) {
        buildTable(&fresh, &scratch.counts, stats, default_table_log, scratch) catch return writeRawSection(dst, src);
    }
    const description = writeTreeDescription(dst[header..], &fresh, scratch) catch 0;
    if (description != 0) {
        const payload = compressPayload(dst[header + description ..], src, &fresh, header_allows_single) catch PayloadLayout{};
        if (payload.size != 0 and header + description + payload.size < src.len) {
            const size = writeHuffmanHeader(
                dst,
                .compressed,
                !payload.four_streams,
                @intCast(src.len),
                @intCast(description + payload.size),
            );
            std.debug.assert(size == header);
            state.table = fresh;
            state.available = true;
            return size + description + payload.size;
        }
    }

    return writeRawSection(dst, src);
}

const testing = std.testing;

// Tests

fn testSource(seed: u64, len: usize) []u8 {
    const out = testing.allocator.alloc(u8, len) catch @panic("out of memory");
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    for (out, 0..) |*b, i| {
        b.* = switch (i % 4) {
            0 => random.intRangeAtMost(u8, 0, 3),
            1 => @intCast((i / 7) % 251),
            2 => if (i % 32 == 0) random.int(u8) else 'x',
            else => random.intRangeAtMost(u8, 0, 15),
        };
    }
    return out;
}

/// Decodes a literals section exactly the way the frame block decoder does, so
/// the encoder tests exercise the real parsing path rather than a private one.
fn decodeLiteralsSection(
    allocator: std.mem.Allocator,
    out: []u8,
    src: []const u8,
    state: *LiteralsState,
) errors.ZstdError!usize {
    const huff_decompress = @import("decompress.zig");
    if (src.len < 1) return error.Corruption;
    const mode: Mode = @fromBackingInt(@intCast(@as(u2, @truncate(src[0] & 3))));
    const size_format = (src[0] >> 2) & 3;
    switch (mode) {
        .raw, .rle => {
            var regen: usize = undefined;
            var off: usize = 1;
            switch (size_format) {
                0, 2 => regen = src[0] >> 3,
                1 => {
                    if (src.len < 2) return error.Corruption;
                    regen = (src[0] >> 4) + (@as(usize, src[1]) << 4);
                    off = 2;
                },
                else => {
                    if (src.len < 3) return error.Corruption;
                    regen = (src[0] >> 4) + (@as(usize, src[1]) << 4) + (@as(usize, src[2]) << 12);
                    off = 3;
                },
            }
            if (regen > out.len) return error.Corruption;
            if (mode == .raw) {
                if (off + regen > src.len) return error.Corruption;
                std.mem.copyForwards(u8, out[0..regen], src[off .. off + regen]);
            } else {
                // An RLE section stores one byte, not `regen` of them.
                if (off >= src.len) return error.Corruption;
                @memset(out[0..regen], src[off]);
            }
            return regen;
        },
        .compressed, .treeless => {},
    }
    var regen: usize = undefined;
    var compressed: usize = undefined;
    var single = false;
    var off: usize = 3;
    switch (size_format) {
        0, 1 => {
            if (src.len < 3) return error.Corruption;
            single = size_format == 0;
            regen = (src[0] >> 4) + (@as(usize, src[1] & 0x3F) << 4);
            compressed = (src[1] >> 6) + (@as(usize, src[2]) << 2);
        },
        2 => {
            if (src.len < 4) return error.Corruption;
            const v = std.mem.readInt(u32, src[0..4], .little);
            regen = (v >> 4) & 0x3FFF;
            compressed = v >> 18;
            off = 4;
        },
        else => {
            if (src.len < 5) return error.Corruption;
            const v = std.mem.readInt(u32, src[0..4], .little);
            regen = (v >> 4) & 0x3FFFF;
            compressed = (v >> 22) + (@as(usize, src[4]) << 10);
            off = 5;
        },
    }
    if (off + compressed > src.len or regen > out.len) return error.Corruption;
    const payload = src[off .. off + compressed];

    if (mode == .compressed) {
        var weights: [256]u8 = @splat(0);
        var ranks: [16]u32 = @splat(0);
        var nb_symbols: usize = 0;
        var table_log: u8 = 0;
        const used = try huff_decompress.readStats(&weights, &ranks, &nb_symbols, &table_log, payload, allocator);
        var decoder = try huff_decompress.buildDecoder(allocator, weights[0..nb_symbols], table_log);
        defer decoder.deinit();
        state.table = Table{ .table_log = table_log, .max_symbol = @intCast(nb_symbols - 1) };
        state.table.weights = weights;
        state.available = true;
        if (single) {
            try huff_decompress.decodeSingleStream(out[0..regen], payload[used..], &decoder);
        } else {
            try huff_decompress.decode4Streams(out[0..regen], payload[used..], &decoder);
        }
    } else {
        if (!state.available) return error.Corruption;
        var decoder = try huff_decompress.buildDecoder(
            allocator,
            state.table.weights[0 .. @as(usize, state.table.max_symbol) + 1],
            state.table.table_log,
        );
        defer decoder.deinit();
        if (single) {
            try huff_decompress.decodeSingleStream(out[0..regen], payload, &decoder);
        } else {
            try huff_decompress.decode4Streams(out[0..regen], payload, &decoder);
        }
    }
    return regen;
}

test "analyze reports the histogram shape" {
    var counts: [256]u32 = @splat(0);
    const stats = analyze(&counts, "aabaaa!");
    try testing.expectEqual(@as(u8, 'b'), stats.max_symbol);
    try testing.expectEqual(@as(u16, 3), stats.cardinality);
    try testing.expectEqual(@as(u32, 5), stats.largest);
    try testing.expectEqual(@as(u32, 7), stats.total);
    try testing.expectEqual(@as(u32, 5), counts['a']);
}

test "buildTable produces a complete code" {
    var counts: [256]u32 = @splat(0);
    const stats = analyze(&counts, "aaaaaaaabbbbccdde");
    var table: Table = .{};
    var scratch: Scratch = .{};
    try buildTable(&table, &counts, stats, default_table_log, &scratch);
    try testing.expectEqual(stats.cardinality, table.cardinality);
    try testing.expect(table.table_log >= 1 and table.table_log <= max_table_log);
    var cells: u32 = 0;
    for (table.lengths) |l| {
        if (l == 0) continue;
        cells += @as(u32, 1) << @intCast(table.table_log - l);
    }
    try testing.expectEqual(@as(u32, 1) << @intCast(table.table_log), cells);
    try testing.expect(table.lengths['a'] <= table.lengths['d']);
}

test "buildTable rejects a single-symbol alphabet" {
    var counts: [256]u32 = @splat(0);
    const stats = analyze(&counts, "aaaaa");
    var table: Table = .{};
    var scratch: Scratch = .{};
    try testing.expectError(
        error.InvalidHuffmanTable,
        buildTable(&table, &counts, stats, default_table_log, &scratch),
    );
}

test "buildTable limits depth for a skewed alphabet" {
    // Fibonacci weights make the optimal code as deep as the alphabet allows,
    // which is the case the length-limited path exists for.
    var counts: [256]u32 = @splat(0);
    var a: u32 = 1;
    var b: u32 = 1;
    for (0..10) |s| {
        counts[s] = a;
        const next = a +% b;
        a = b;
        b = next;
    }
    var stats: Stats = .{ .max_symbol = 9, .cardinality = 10 };
    for (0..10) |s| {
        stats.total += counts[s];
        if (counts[s] > stats.largest) stats.largest = counts[s];
    }
    var table: Table = .{};
    var scratch: Scratch = .{};
    // The unconstrained code needs nine levels, so the format's ceiling of 12
    // is not what limits it.
    var deep: Table = .{};
    try buildTable(&deep, &counts, stats, max_table_log, &scratch);
    try testing.expectEqual(@as(u8, 9), deep.table_log);

    try buildTable(&table, &counts, stats, 6, &scratch);
    try testing.expect(table.table_log <= 6);
    for (table.lengths) |l| try testing.expect(l <= 6);
    var cells: u32 = 0;
    for (table.lengths) |l| {
        if (l == 0) continue;
        cells += @as(u32, 1) << @intCast(table.table_log - l);
    }
    try testing.expectEqual(@as(u32, 1) << @intCast(table.table_log), cells);
    // The most frequent symbol still gets the shortest code, and the capped
    // code is no cheaper than the optimal one it replaced.
    try testing.expectEqual(@as(u8, 1), table.lengths[9]);
    var capped_bits: u64 = 0;
    var optimal_bits: u64 = 0;
    for (0..10) |s| {
        capped_bits += @as(u64, counts[s]) * table.lengths[s];
        optimal_bits += @as(u64, counts[s]) * deep.lengths[s];
    }
    try testing.expect(capped_bits > optimal_bits);
}

test "buildTable raises a depth cap that cannot hold the alphabet" {
    // 256 symbols at depth 8 exhaust the code space exactly, so every symbol
    // must take an 8-bit code; a request for 6 is raised to the floor rather
    // than producing an undecodable table.
    var counts: [256]u32 = @splat(0);
    for (0..256) |s| counts[s] = 1;
    for (0..2000) |_| counts[7] += 1;
    const stats = Stats{
        .max_symbol = 255,
        .cardinality = 256,
        .largest = 2001,
        .total = 2256,
    };
    var table: Table = .{};
    var scratch: Scratch = .{};
    try buildTable(&table, &counts, stats, 6, &scratch);
    try testing.expectEqual(@as(u8, 8), table.table_log);
    for (table.lengths) |l| try testing.expectEqual(@as(u8, 8), l);
    try testing.expectEqual(@as(u8, 8), minDepthFor(stats.cardinality));
}

test "buildTable is optimal when the depth limit allows it" {
    var counts: [256]u32 = @splat(0);
    // Weights a=8 b=4 c=2 d=2 e=1. The optimal code is (1, 2, 4, 3, 4):
    // e(1) merges with c(2), then d(2), then b(4), then a(8).
    const stats = analyze(&counts, "aaaaaaaabbbbccdde");
    try testing.expectEqual(@as(u32, 8), stats.largest);
    var table: Table = .{};
    var scratch: Scratch = .{};
    try buildTable(&table, &counts, stats, default_table_log, &scratch);
    try testing.expectEqual(@as(u8, 1), table.lengths['a']);
    try testing.expectEqual(@as(u8, 2), table.lengths['b']);
    try testing.expectEqual(@as(u8, 4), table.lengths['c']);
    try testing.expectEqual(@as(u8, 3), table.lengths['d']);
    try testing.expectEqual(@as(u8, 4), table.lengths['e']);
    try testing.expectEqual(@as(u8, 4), table.table_log);
}

test "writeTreeDescription direct form for a tiny alphabet" {
    var counts: [256]u32 = @splat(0);
    const src = [_]u8{ 0, 1, 0, 1, 0, 1, 0, 1 };
    const stats = analyze(&counts, &src);
    var table: Table = .{};
    var scratch: Scratch = .{};
    try buildTable(&table, &counts, stats, default_table_log, &scratch);
    var dst: [64]u8 = undefined;
    const n = try writeTreeDescription(&dst, &table, &scratch);
    // Only one weight is stored (the second is implied): 1 header byte plus
    // one nibble byte. Too few weights for the FSE form to be considered.
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(dst[0] >= 128);
}

test "writeTreeDescription uses FSE for a wide alphabet" {
    const src = testSource(7, 4096);
    defer testing.allocator.free(src);
    var counts: [256]u32 = @splat(0);
    const stats = analyze(&counts, src);
    var table: Table = .{};
    var scratch: Scratch = .{};
    try buildTable(&table, &counts, stats, default_table_log, &scratch);
    var dst: [512]u8 = undefined;
    const n = try writeTreeDescription(&dst, &table, &scratch);
    try testing.expect(dst[0] < 128);
    try testing.expect(n > 1);
}

test "compressLiteralsSection round trips small payloads" {
    const cases = [_][]const u8{
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaab",
        "the quick brown fox jumps over the lazy dog, the quick brown fox again and again",
        "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/",
    };
    for (cases) |src| {
        var state: LiteralsState = .{};
        var decoder_state: LiteralsState = .{};
        var dst: [512]u8 = undefined;
        const n = try compressLiteralsSection(&dst, src, &state);
        try testing.expect(n > 0);
        var out: [512]u8 = undefined;
        const m = try decodeLiteralsSection(testing.allocator, &out, dst[0..n], &decoder_state);
        try testing.expectEqualStrings(src, out[0..m]);
    }
}

test "compressLiteralsSection round trips a wide alphabet" {
    const src = testSource(11, 8192);
    defer testing.allocator.free(src);
    var state: LiteralsState = .{};
    var decoder_state: LiteralsState = .{};
    var dst: [16384]u8 = undefined;
    const n = try compressLiteralsSection(&dst, src, &state);
    try testing.expect(n > 0);
    try testing.expectEqual(Mode.compressed, @as(Mode, @fromBackingInt(@intCast(@as(u2, @truncate(dst[0] & 3))))));
    var out: [16384]u8 = undefined;
    const m = try decodeLiteralsSection(testing.allocator, &out, dst[0..n], &decoder_state);
    try testing.expectEqualSlices(u8, src, out[0..m]);
    try testing.expect(state.available);
}

test "compressLiteralsSection re-uses the table on the second block" {
    const src = testSource(13, 6000);
    defer testing.allocator.free(src);
    var state: LiteralsState = .{};
    var dst: [16384]u8 = undefined;
    const first = try compressLiteralsSection(&dst, src, &state);
    try testing.expectEqual(Mode.compressed, @as(Mode, @fromBackingInt(@intCast(@as(u2, @truncate(dst[0] & 3))))));
    try testing.expect(first > 0);

    var dst2: [16384]u8 = undefined;
    const second = try compressLiteralsSection(&dst2, src, &state);
    try testing.expectEqual(Mode.treeless, @as(Mode, @fromBackingInt(@intCast(@as(u2, @truncate(dst2[0] & 3))))));
    try testing.expect(second < first);
}

test "compressLiteralsSection emits RLE for identical bytes" {
    var state: LiteralsState = .{};
    var dst: [64]u8 = undefined;
    var src: [40]u8 = @splat('q');
    const n = try compressLiteralsSection(&dst, &src, &state);
    // 40 bytes need the 12-bit size form: 2 header bytes plus the value.
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u8, 1), dst[0] & 3);
    try testing.expectEqual(@as(u8, 'q'), dst[2]);
}

test "compressLiteralsSection emits raw for a tiny alternating payload" {
    var state: LiteralsState = .{};
    var dst: [512]u8 = undefined;
    const src = [_]u8{ 0, 1, 0, 1, 0, 1 };
    const n = try compressLiteralsSection(&dst, &src, &state);
    try testing.expectEqual(Mode.raw, @as(Mode, @fromBackingInt(@intCast(@as(u2, @truncate(dst[0] & 3))))));
    try testing.expectEqual(src.len + 1, n);
}

test "compressLiteralsSection handles empty literals" {
    var state: LiteralsState = .{};
    var dst: [16]u8 = undefined;
    const n = try compressLiteralsSection(&dst, &[_]u8{}, &state);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u8, 0), dst[0]);
}

test "compressLiteralsSection describes a fresh table after a reset" {
    const src = testSource(17, 5000);
    defer testing.allocator.free(src);
    var state: LiteralsState = .{};
    var dst: [16384]u8 = undefined;
    _ = try compressLiteralsSection(&dst, src, &state);
    state.reset();
    const n = try compressLiteralsSection(&dst, src, &state);
    try testing.expectEqual(Mode.compressed, @as(Mode, @fromBackingInt(@intCast(@as(u2, @truncate(dst[0] & 3))))));
    try testing.expect(n > 0);
}

test "compressPayload uses four streams when the header demands them" {
    const src = testSource(19, 5000);
    defer testing.allocator.free(src);
    var counts: [256]u32 = @splat(0);
    const stats = analyze(&counts, src);
    var table: Table = .{};
    var scratch: Scratch = .{};
    try buildTable(&table, &counts, stats, default_table_log, &scratch);
    var dst: [16384]u8 = undefined;
    // 5000 regenerated bytes need a 4-byte header, which can only describe four
    // streams.
    const layout = try compressPayload(&dst, src, &table, false);
    try testing.expect(layout.four_streams);
    // 6-byte jump table plus four streams of at least one byte each.
    try testing.expect(layout.size >= 10);

    // A payload a 3-byte header can describe uses the smaller single stream.
    const small = try compressPayload(&dst, src[0..900], &table, true);
    try testing.expect(!small.four_streams);
    try testing.expect(small.size > 0);
}

test "literals sections round trip over many payload shapes" {
    // Sizes cross the raw/RLE/Huffman thresholds, the 1-stream/4-stream switch
    // and the 3/4/5-byte header widths, and the payloads mix entropy levels.
    var prng = std.Random.DefaultPrng.init(0x51F7);
    const random = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const sizes = [_]usize{ 0, 1, 2, 3, 5, 6, 7, 8, 31, 32, 33, 63, 64, 65, 255, 256, 257, 1023, 1024, 1025, 4095, 4096, 16383, 16384, 20000 };
    var src: [20000]u8 = undefined;
    var dst: [40000]u8 = undefined;
    var out: [20000]u8 = undefined;
    for (sizes) |n| {
        for (0..4) |shape| {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                src[i] = switch (shape) {
                    0 => random.int(u8),
                    1 => @intCast(i % 251),
                    2 => if (i % 64 == 0) random.int(u8) else 'q',
                    else => random.intRangeAtMost(u8, 0, 2),
                };
            }
            var state: LiteralsState = .{};
            var dec_state: LiteralsState = .{};
            const written = try compressLiteralsSection(&dst, src[0..n], &state);
            try testing.expect(written > 0);
            const got = try decodeLiteralsSection(alloc, &out, dst[0..written], &dec_state);
            try testing.expectEqual(n, got);
            try testing.expectEqualSlices(u8, src[0..n], out[0..got]);
        }
    }
}

test "treeless sections keep decoding across many blocks" {
    // A frame carries one table forward, so consecutive blocks drawn from the
    // same distribution should mostly re-use it instead of describing a new
    // one, and the decoder state must track every transition.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var prng = std.Random.DefaultPrng.init(99);
    const random = prng.random();

    // A fixed skewed alphabet: block-to-block the histogram barely moves.
    const alphabet = [_]u8{ 'a', 'a', 'a', 'a', 'b', 'b', 'b', 'c', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n' };

    var src: [4000]u8 = undefined;
    var dst: [9000]u8 = undefined;
    var out: [4000]u8 = undefined;
    var state: LiteralsState = .{};
    var dec_state: LiteralsState = .{};
    var treeless_seen = false;
    for (0..12) |block| {
        const n = 600 + block * 137;
        for (src[0..n]) |*b| {
            b.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        }
        const written = try compressLiteralsSection(&dst, src[0..n], &state);
        const got = try decodeLiteralsSection(alloc, &out, dst[0..written], &dec_state);
        try testing.expectEqual(n, got);
        try testing.expectEqualSlices(u8, src[0..n], out[0..got]);
        if (@as(Mode, @fromBackingInt(@intCast(@as(u2, @truncate(dst[0] & 3))))) == .treeless) treeless_seen = true;
    }
    try testing.expect(treeless_seen);
}
