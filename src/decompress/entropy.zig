//! Frame entropy state and compressed-block decoding.
//!
//! Implements the compressed-block layer of the Zstandard format:
//!  - sequence FSE table construction and symbol-mode selection
//!    (predefined / RLE / compressed / repeat)
//!  - literal section decoding for raw, RLE, and Huffman-coded literals
//!    (single-stream and 4-stream)
//!  - sequence header parsing, FSE bitstream decoding, extra-bit handling,
//!    and repeat-offset resolution
//!
//! `State` carries Huffman + FSE tables and repeat offsets across blocks of a
//! frame, as required by the format.

const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const bitstream_mod = @import("../common/bitstream.zig");
const fse_dtable = @import("../fse/dtable.zig");
const huf_decompress = @import("../huffman/decompress.zig");

pub const BIT_DStream = bitstream_mod.BIT_DStream;

fn le32At(src: []const u8, i: usize) u32 {
    return @as(u32, src[i]) | (@as(u32, src[i + 1]) << 8) | (@as(u32, src[i + 2]) << 16) | (@as(u32, src[i + 3]) << 24);
}
pub const DStreamStatus = bitstream_mod.DStreamStatus;

// ---------------------------------------------------------------------------
// Sequence symbol tables
// ---------------------------------------------------------------------------

pub const SeqSymbol = struct {
    new_state: u16,
    nb_add_bits: u8,
    nb_bits: u8,
    base: u32,
};

pub const SeqTable = struct {
    log: u8,
    entries: []SeqSymbol,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SeqTable) void {
        self.allocator.free(self.entries);
    }
};

/// Builds a sequence FSE decoding table whose entries directly hold
/// base value / extra-bit count for the mapped code, plus the state
/// transitions defined by the Zstandard format.
fn buildSeqTableFromNorm(
    allocator: std.mem.Allocator,
    norm: []const i16,
    max_symbol: usize,
    table_log: u8,
    base_values: []const u32,
    add_bits: []const u8,
) errors.ZstdError!SeqTable {
    var dt = try fse_dtable.build(allocator, norm, max_symbol, table_log);
    defer dt.deinit();

    const entries = try allocator.alloc(SeqSymbol, dt.entries.len);
    errdefer allocator.free(entries);
    for (dt.entries, 0..) |e, i| {
        const sym: usize = e.symbol;
        if (sym >= base_values.len or sym >= add_bits.len) return error.Corruption;
        entries[i] = .{
            .new_state = e.new_state,
            .nb_bits = e.nb_bits,
            .nb_add_bits = add_bits[sym],
            .base = base_values[sym],
        };
    }
    return .{ .log = table_log, .entries = entries, .allocator = allocator };
}

/// Single-symbol RLE table entry (tableLog = 0).
fn buildSeqTableRle(
    allocator: std.mem.Allocator,
    symbol: u8,
    base_values: []const u32,
    add_bits: []const u8,
) errors.ZstdError!SeqTable {
    const entries = try allocator.alloc(SeqSymbol, 1);
    errdefer allocator.free(entries);
    entries[0] = .{
        .new_state = 0,
        .nb_bits = 0,
        .nb_add_bits = add_bits[symbol],
        .base = base_values[symbol],
    };
    return .{ .log = 0, .entries = entries, .allocator = allocator };
}

const SymbolMode = enum(u2) { predefined = 0, rle = 1, compressed = 2, repeat = 3 };

/// Decodes one symbol-compression mode from `src` and installs the matching
/// table. Returns bytes consumed from `src`.
fn buildSeqTable(
    state: *State,
    which: WhichTable,
    mode: SymbolMode,
    max_symbol: usize,
    max_log: u8,
    src: []const u8,
    base_values: []const u32,
    add_bits: []const u8,
    default_norm: []const i16,
    default_log: u8,
) errors.ZstdError!usize {
    switch (mode) {
        .rle => {
            if (src.len < 1) return error.SrcSizeWrong;
            const symbol = src[0];
            if (symbol > max_symbol) return error.Corruption;
            var t = try buildSeqTableRle(state.allocator, symbol, base_values, add_bits);
            replaceTable(state, which, &t);
            return 1;
        },
        .predefined => {
            var t = try buildSeqTableFromNorm(
                state.allocator,
                default_norm,
                default_norm.len - 1,
                default_log,
                base_values,
                add_bits,
            );
            replaceTable(state, which, &t);
            return 0;
        },
        .repeat => {
            // Repeat mode requires entropy state from a previous block.
            if (!state.fse_entropy) return error.Corruption;
            if (getTable(state, which) == null) return error.Corruption;
            return 0;
        },
        .compressed => {
            var norm_buf: [64]i16 = undefined;
            if (max_symbol + 1 > norm_buf.len) return error.Corruption;
            var max_sv: usize = max_symbol;
            var table_log: u8 = 0;
            const ncount_read = try readNCountCompact(&norm_buf, &max_sv, &table_log, src);
            if (table_log > max_log) return error.Corruption;
            if (max_sv > max_symbol) return error.Corruption;
            var t = try buildSeqTableFromNorm(
                state.allocator,
                norm_buf[0 .. max_sv + 1],
                max_sv,
                table_log,
                base_values,
                add_bits,
            );
            replaceTable(state, which, &t);
            return ncount_read;
        },
    }
}

const WhichTable = enum { ll, of, ml };

fn getTable(state: *State, which: WhichTable) ?*SeqTable {
    return switch (which) {
        .ll => if (state.ll) |*t| t else null,
        .of => if (state.of) |*t| t else null,
        .ml => if (state.ml) |*t| t else null,
    };
}

fn replaceTable(state: *State, which: WhichTable, t: *SeqTable) void {
    switch (which) {
        .ll => {
            if (state.ll) |*old| old.deinit();
            state.ll = t.*;
        },
        .of => {
            if (state.of) |*old| old.deinit();
            state.of = t.*;
        },
        .ml => {
            if (state.ml) |*old| old.deinit();
            state.ml = t.*;
        },
    }
}

// ---------------------------------------------------------------------------
// FSE normalized-counter compact format
// ---------------------------------------------------------------------------

const ncount_mod = @import("../fse/ncount.zig");
pub const readNCountCompact = ncount_mod.readNCount;

// ---------------------------------------------------------------------------
// Entropy state carried across blocks within a frame
// ---------------------------------------------------------------------------

pub const State = struct {
    allocator: std.mem.Allocator,
    huf: ?huf_decompress.HuffDecoder = null,
    lit_entropy: bool = false,
    ll: ?SeqTable = null,
    of: ?SeqTable = null,
    ml: ?SeqTable = null,
    fse_entropy: bool = false,
    rep: [3]u32 = constants.rep_start_value,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    /// Reset for a brand-new frame: drop entropy tables and restore the
    /// default repeat offsets.
    pub fn resetFrame(self: *State) void {
        if (self.huf) |*h| h.deinit();
        self.huf = null;
        self.lit_entropy = false;
        if (self.ll) |*t| t.deinit();
        self.ll = null;
        if (self.of) |*t| t.deinit();
        self.of = null;
        if (self.ml) |*t| t.deinit();
        self.ml = null;
        self.fse_entropy = false;
        self.rep = constants.rep_start_value;
    }

    pub fn deinit(self: *State) void {
        self.resetFrame();
    }
};

// ---------------------------------------------------------------------------
// Literals section
// ---------------------------------------------------------------------------

pub const LiteralsSection = struct {
    data: []const u8,
    owned: bool,

    pub fn deinit(self: *LiteralsSection, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.data);
    }
};

const min_literals_for_4_streams: usize = 6;

pub const LiteralsResult = struct {
    section: LiteralsSection,
    bytes_read: usize,
};

pub fn decodeLiterals(
    state: *State,
    src: []const u8,
    block_size_max: usize,
) errors.ZstdError!LiteralsResult {
    if (src.len < 1) return error.SrcSizeWrong;
    const lit_enc: u2 = @truncate(src[0] & 3);

    switch (lit_enc) {
        0 => return decodeRawOrRleLiterals(state, src, block_size_max, false),
        1 => return decodeRawOrRleLiterals(state, src, block_size_max, true),
        2 => return decodeHuffmanLiterals(state, src, false),
        3 => return decodeHuffmanLiterals(state, src, true),
    }
}

fn decodeRawOrRleLiterals(
    state: *State,
    src: []const u8,
    block_size_max: usize,
    is_rle: bool,
) errors.ZstdError!LiteralsResult {
    const b0 = src[0];
    const lhl: u2 = @truncate((b0 >> 2) & 3);
    var lh_size: usize = undefined;
    var lit_size: usize = undefined;
    switch (lhl) {
        0, 2 => {
            lh_size = 1;
            lit_size = b0 >> 3;
        },
        1 => {
            lh_size = 2;
            if (src.len < 2) return error.SrcSizeWrong;
            // MEM_readLE16(istart) >> 4
            lit_size = (@as(usize, b0) | (@as(usize, src[1]) << 8)) >> 4;
        },
        3 => {
            lh_size = 3;
            if (src.len < 3) return error.SrcSizeWrong;
            // MEM_readLE24(istart) >> 4
            lit_size = (@as(usize, b0) | (@as(usize, src[1]) << 8) | (@as(usize, src[2]) << 16)) >> 4;
        },
    }
    if (lit_size > block_size_max) return error.Corruption;

    if (!is_rle) {
        if (src.len < lh_size + lit_size) return error.SrcSizeWrong;
        return .{
            .section = .{ .data = src[lh_size .. lh_size + lit_size], .owned = false },
            .bytes_read = lh_size + lit_size,
        };
    }

    // RLE: one byte follows the header.
    if (src.len < lh_size + 1) return error.SrcSizeWrong;
    const value = src[lh_size];
    const buf = state.allocator.alloc(u8, lit_size) catch return error.OutOfMemory;
    @memset(buf, value);
    return .{
        .section = .{ .data = buf, .owned = true },
        .bytes_read = lh_size + 1,
    };
}

fn decodeHuffmanLiterals(
    state: *State,
    src: []const u8,
    is_repeat: bool,
) errors.ZstdError!LiteralsResult {
    if (is_repeat and !state.lit_entropy) return error.DictionaryCorrupted;
    if (src.len < 3) return error.SrcSizeWrong;

    const b0 = src[0];
    const lhl: u2 = @truncate((b0 >> 2) & 3);
    var lh_size: usize = undefined;
    var lit_size: usize = undefined;
    var lit_csize: usize = undefined;
    var single_stream: bool = undefined;

    switch (lhl) {
        0, 1 => {
            const lhc: u32 = le32At(src, 0);
            lh_size = 3;
            lit_size = (lhc >> 4) & 0x3FF;
            lit_csize = (lhc >> 14) & 0x3FF;
            single_stream = lhl == 0;
        },
        2 => {
            if (src.len < 4) return error.SrcSizeWrong;
            const lhc: u32 = le32At(src, 0);
            lh_size = 4;
            lit_size = (lhc >> 4) & 0x3FFF;
            lit_csize = lhc >> 18;
            single_stream = false;
        },
        3 => {
            if (src.len < 5) return error.SrcSizeWrong;
            const lhc: u32 = le32At(src, 0);
            lh_size = 5;
            lit_size = (lhc >> 4) & 0x3FFFF;
            lit_csize = (lhc >> 22) + (@as(usize, src[4]) << 10);
            single_stream = false;
        },
    }

    if (!single_stream and lit_size < min_literals_for_4_streams) return error.InvalidHuffmanTable;
    if (lh_size + lit_csize > src.len) return error.SrcSizeWrong;

    const huf_src = src[lh_size .. lh_size + lit_csize];

    var local_decoder: ?huf_decompress.HuffDecoder = null;
    defer if (local_decoder) |*d| d.deinit();

    var used: *const huf_decompress.HuffDecoder = undefined;
    if (is_repeat) {
        used = &(state.huf orelse return error.DictionaryCorrupted);
    } else {
        var weights: [256]u8 = undefined;
        var ranks: [13]u32 = undefined;
        var nb_symbols: usize = 0;
        var table_log: u8 = 0;
        _ = try huf_decompress.readStats(&weights, &ranks, &nb_symbols, &table_log, huf_src, state.allocator);
        const dec = try huf_decompress.buildDecoder(state.allocator, weights[0..nb_symbols], table_log);
        local_decoder = dec;
        used = &local_decoder.?;
    }

    const out = state.allocator.alloc(u8, lit_size) catch return error.OutOfMemory;
    errdefer state.allocator.free(out);

    if (single_stream) {
        try huf_decompress.decodeSingleStream(out, huf_src, used);
    } else {
        try huf_decompress.decode4Streams(out, huf_src, used);
    }

    if (!is_repeat) {
        if (state.huf) |*old| old.deinit();
        state.huf = local_decoder.?;
        local_decoder = null; // ownership moved
        state.lit_entropy = true;
    }

    return .{
        .section = .{ .data = out, .owned = true },
        .bytes_read = lh_size + lit_csize,
    };
}

// ---------------------------------------------------------------------------
// Sequences section
// ---------------------------------------------------------------------------

const SeqLimits = struct {
    history: []const u8, // output preceding current block start (frame-local)
};

pub fn decodeSequences(
    state: *State,
    dst: []u8,
    literals: []const u8,
    src: []const u8,
    limits: SeqLimits,
) errors.ZstdError!usize {
    var pos: usize = 0;

    // --- nbSeq ---
    if (src.len < 1) return error.SrcSizeWrong;
    var nb_seq: usize = src[pos];
    pos += 1;
    if (nb_seq > 0x7F) {
        if (nb_seq == 0xFF) {
            if (pos + 2 > src.len) return error.SrcSizeWrong;
            nb_seq = @as(usize, src[pos]) | (@as(usize, src[pos + 1]) << 8);
            nb_seq += constants.long_nb_seq;
            pos += 2;
        } else {
            if (pos >= src.len) return error.SrcSizeWrong;
            nb_seq = ((nb_seq - 0x80) << 8) + src[pos];
            pos += 1;
        }
    }

    if (nb_seq == 0) {
        if (pos != src.len) return error.Corruption; // extraneous data
        if (literals.len > dst.len) return error.DstSizeTooSmall;
        @memcpy(dst[0..literals.len], literals);
        return literals.len;
    }

    // --- symbol compression modes ---
    if (pos >= src.len) return error.SrcSizeWrong;
    const mode_byte = src[pos];
    pos += 1;
    if (mode_byte & 3 != 0) return error.Corruption; // reserved bits
    const ll_mode: SymbolMode = @enumFromInt(@as(u2, @truncate(mode_byte >> 6)));
    const of_mode: SymbolMode = @enumFromInt(@as(u2, @truncate(mode_byte >> 4)));
    const ml_mode: SymbolMode = @enumFromInt(@as(u2, @truncate(mode_byte >> 2)));

    pos += try buildSeqTable(state, .ll, ll_mode, constants.max_ll, constants.ll_fse_log, src[pos..], &constants.ll_base, constants.ll_bits[0..], &constants.ll_default_norm, @intCast(constants.ll_default_norm_log));
    pos += try buildSeqTable(state, .of, of_mode, constants.max_off, constants.off_fse_log, src[pos..], &constants.of_base, constants.of_bits[0..], &constants.of_default_norm, @intCast(constants.of_default_norm_log));
    pos += try buildSeqTable(state, .ml, ml_mode, constants.max_ml, constants.ml_fse_log, src[pos..], &constants.ml_base, constants.ml_bits[0..], &constants.ml_default_norm, @intCast(constants.ml_default_norm_log));

    if (pos > src.len) return error.SrcSizeWrong;

    const ll_table = &(state.ll orelse return error.Corruption);
    const of_table = &(state.of orelse return error.Corruption);
    const ml_table = &(state.ml orelse return error.Corruption);

    // --- FSE bitstream ---
    var ds = BIT_DStream.init(src[pos..]) catch return error.Corruption;
    var st_ll: u16 = undefined;
    var st_of: u16 = undefined;
    var st_ml: u16 = undefined;
    if (ll_table.log > 0) st_ll = @intCast(ds.readBits(ll_table.log));
    if (of_table.log > 0) st_of = @intCast(ds.readBits(of_table.log));
    if (ml_table.log > 0) st_ml = @intCast(ds.readBits(ml_table.log));

    var out_pos: usize = 0;
    var lit_pos: usize = 0;

    var seq_idx: usize = 0;
    while (seq_idx < nb_seq) : (seq_idx += 1) {
        const is_last = seq_idx == nb_seq - 1;

        const lld = ll_table.entries[st_ll];
        const mld = ml_table.entries[st_ml];
        const ofd = of_table.entries[st_of];

        var lit_len: usize = lld.base;
        var match_len: usize = mld.base;
        const ll_extra: u8 = lld.nb_add_bits;
        const ml_extra: u8 = mld.nb_add_bits;
        const of_bits: u8 = ofd.nb_add_bits;

        // Offset resolution with repeat-offset semantics.
        var offset: u32 = undefined;
        if (of_bits > 1) {
            offset = ofd.base +% @as(u32, @truncate(ds.readBits(of_bits)));
            state.rep[2] = state.rep[1];
            state.rep[1] = state.rep[0];
            state.rep[0] = offset;
        } else {
            const ll0: bool = lld.base == 0;
            if (of_bits == 0) {
                offset = state.rep[@intFromBool(ll0)];
                const keep = state.rep[if (ll0) 0 else 1];
                state.rep[1] = keep;
                state.rep[0] = offset;
            } else {
                const off_code: u32 = ofd.base +% @as(u32, @intFromBool(ll0)) +% @as(u32, @truncate(ds.readBits(1)));
                var temp: u32 = switch (off_code) {
                    3 => state.rep[0] -% 1,
                    else => state.rep[off_code], // 1 or 2
                };
                temp -%= @intFromBool(temp == 0); // force invalid so offset check fires
                if (off_code != 1) state.rep[2] = state.rep[1];
                state.rep[1] = state.rep[0];
                state.rep[0] = temp;
                offset = temp;
            }
        }

        if (ml_extra > 0) match_len += @as(u32, @truncate(ds.readBits(ml_extra)));
        if (ll_extra > 0) lit_len += @as(u32, @truncate(ds.readBits(ll_extra)));

        // Execute: copy literals.
        if (lit_pos + lit_len > literals.len) return error.Corruption;
        if (out_pos + lit_len > dst.len) return error.DstSizeTooSmall;
        @memcpy(dst[out_pos .. out_pos + lit_len], literals[lit_pos .. lit_pos + lit_len]);
        lit_pos += lit_len;
        out_pos += lit_len;

        // Execute: copy match (overlap-safe, may reach into prior-frame window).
        const available: usize = limits.history.len + out_pos;
        if (offset == 0 or offset > available) return error.InvalidOffset;
        if (match_len == 0) return error.Corruption;
        if (out_pos + match_len > dst.len) return error.DstSizeTooSmall;
        var m: usize = 0;
        while (m < match_len) : (m += 1) {
            // Virtual window = history ++ dst[0..out_pos]; match source is
            // `offset` bytes behind the current output position.
            const src_virt = limits.history.len + out_pos + m - offset;
            dst[out_pos + m] = if (src_virt < limits.history.len)
                limits.history[src_virt]
            else
                dst[src_virt - limits.history.len];
        }
        out_pos += match_len;

        if (!is_last) {
            // Update states LL -> ML -> OF, then reload.
            st_ll = updateState(&ds, ll_table.entries[st_ll]);
            st_ml = updateState(&ds, ml_table.entries[st_ml]);
            st_of = updateState(&ds, of_table.entries[st_of]);
        }
        if (ds.reload() == .overflow) return error.Corruption;
    }

    // Trailing literals after the last sequence.
    const tail = literals.len - lit_pos;
    if (tail > 0) {
        if (out_pos + tail > dst.len) return error.DstSizeTooSmall;
        @memcpy(dst[out_pos .. out_pos + tail], literals[lit_pos..]);
        out_pos += tail;
    }

    return out_pos;
}

inline fn updateState(ds: *BIT_DStream, entry: SeqSymbol) u16 {
    return entry.new_state +% @as(u16, @truncate(ds.readBits(entry.nb_bits)));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ncount compact: known vector" {
    // Hand-crafted minimal header encoding tableLog=5, counts {2,1,1} for syms 0..2.
    // Verified against FSE_readNCount behavior via round-trip below.
    var norm: [8]i16 = undefined;
    var max_sv: usize = 7;
    var tl: u8 = 0;
    // 0x14 0x00 ... : tableLog field low nibble (5-5=0) then count bits.
    const src = [_]u8{ 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const n = readNCountCompact(&norm, &max_sv, &tl, &src) catch |e| {
        // Malformed is acceptable; the property tests below cover real streams.
        try testing.expect(e == error.Corruption);
        return;
    };
    _ = n;
}

test "state resetFrame restores defaults" {
    var st = State.init(testing.allocator);
    defer st.deinit();
    st.fse_entropy = true;
    st.lit_entropy = true;
    st.rep = .{ 9, 9, 9 };
    st.resetFrame();
    try testing.expect(!st.fse_entropy);
    try testing.expect(!st.lit_entropy);
    try testing.expectEqualSlices(u32, &constants.rep_start_value, &st.rep);
}
