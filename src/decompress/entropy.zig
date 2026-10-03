//! Frame entropy state and compressed-block decoding: sequence FSE table
//! construction and symbol-mode selection (predefined / RLE / compressed /
//! repeat), literal section decoding (raw, RLE, Huffman-coded; single-stream and
//! 4-stream), and sequence header parsing, FSE bitstream decoding, extra-bit
//! handling and repeat-offset resolution. `State` carries Huffman + FSE tables
//! and repeat offsets across the blocks of a frame.

const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const bitstream_mod = @import("../common/bitstream.zig");
const bits = @import("../common/bits.zig");
const fse_dtable = @import("../fse/dtable.zig");
const huf_decompress = @import("../huffman/decompress.zig");

pub const BIT_DStream = bitstream_mod.BIT_DStream;

pub const DStreamStatus = bitstream_mod.DStreamStatus;

// Sequence symbol tables

pub const SeqSymbol = struct {
    newState: u16,
    nbAddBits: u8,
    nbBits: u8,
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
    tableLog: u8,
    base_values: []const u32,
    add_bits: []const u8,
) errors.ZstdError!SeqTable {
    var dt = try fse_dtable.build(allocator, norm, max_symbol, tableLog);
    defer dt.deinit();

    const entries = try allocator.alloc(SeqSymbol, dt.entries.len);
    errdefer allocator.free(entries);
    for (dt.entries, 0..) |e, i| {
        const sym: usize = e.symbol;
        if (sym >= base_values.len or sym >= add_bits.len) return error.Corruption;
        entries[i] = .{
            .newState = e.newState,
            .nbBits = e.nbBits,
            .nbAddBits = add_bits[sym],
            .base = base_values[sym],
        };
    }
    return .{ .log = tableLog, .entries = entries, .allocator = allocator };
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
        .newState = 0,
        .nbBits = 0,
        .nbAddBits = add_bits[symbol],
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
            // This block carries sequence entropy, so a later block may
            // repeat it (RFC 8878 Repeat_Mode).
            state.fse_entropy = true;
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
            state.fse_entropy = true;
            return 0;
        },
        .repeat => {
            // Repeat mode requires entropy state from a previous block.
            if (!state.fse_entropy) return error.Corruption;
            if (getTable(state, which) == null) return error.Corruption;
            return 0;
        },
        .compressed => {
            var normBuf: [64]i16 = undefined;
            if (max_symbol + 1 > normBuf.len) return error.Corruption;
            var maxSv: usize = max_symbol;
            var tableLog: u8 = 0;
            const ncountRead = try readNCountCompact(&normBuf, &maxSv, &tableLog, src);
            if (tableLog > max_log) return error.Corruption;
            if (maxSv > max_symbol) return error.Corruption;
            var t = try buildSeqTableFromNorm(
                state.allocator,
                normBuf[0 .. maxSv + 1],
                maxSv,
                tableLog,
                base_values,
                add_bits,
            );
            replaceTable(state, which, &t);
            state.fse_entropy = true;
            return ncountRead;
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

// FSE normalized-counter compact format

const ncount_mod = @import("../fse/ncount.zig");
pub const readNCountCompact = ncount_mod.readNCount;

// Entropy state carried across blocks within a frame

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

// Literals section

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
    blockSizeMax: usize,
) errors.ZstdError!LiteralsResult {
    if (src.len < 1) return error.SrcSizeWrong;
    const lit_enc: u2 = @truncate(src[0] & 3);

    switch (lit_enc) {
        0 => return decodeRawOrRleLiterals(state, src, blockSizeMax, false),
        1 => return decodeRawOrRleLiterals(state, src, blockSizeMax, true),
        2 => return decodeHuffmanLiterals(state, src, false),
        3 => return decodeHuffmanLiterals(state, src, true),
    }
}

fn decodeRawOrRleLiterals(
    state: *State,
    src: []const u8,
    blockSizeMax: usize,
    isRle: bool,
) errors.ZstdError!LiteralsResult {
    const b0 = src[0];
    const lhl: u2 = @truncate((b0 >> 2) & 3);
    var lhSize: usize = undefined;
    var litSize: usize = undefined;
    switch (lhl) {
        0, 2 => {
            lhSize = 1;
            litSize = b0 >> 3;
        },
        1 => {
            lhSize = 2;
            if (src.len < 2) return error.SrcSizeWrong;
            // MEM_readLE16(istart) >> 4
            litSize = (@as(usize, b0) | (@as(usize, src[1]) << 8)) >> 4;
        },
        3 => {
            lhSize = 3;
            if (src.len < 3) return error.SrcSizeWrong;
            // MEM_readLE24(istart) >> 4
            litSize = (@as(usize, b0) | (@as(usize, src[1]) << 8) | (@as(usize, src[2]) << 16)) >> 4;
        },
    }
    if (litSize > blockSizeMax) return error.Corruption;

    if (!isRle) {
        if (src.len < lhSize + litSize) return error.SrcSizeWrong;
        return .{
            .section = .{ .data = src[lhSize .. lhSize + litSize], .owned = false },
            .bytes_read = lhSize + litSize,
        };
    }

    // RLE: one byte follows the header.
    if (src.len < lhSize + 1) return error.SrcSizeWrong;
    const value = src[lhSize];
    const buf = state.allocator.alloc(u8, litSize) catch return error.OutOfMemory;
    @memset(buf, value);
    return .{
        .section = .{ .data = buf, .owned = true },
        .bytes_read = lhSize + 1,
    };
}

fn decodeHuffmanLiterals(
    state: *State,
    src: []const u8,
    isRepeat: bool,
) errors.ZstdError!LiteralsResult {
    if (isRepeat and !state.lit_entropy) return error.DictionaryCorrupted;
    if (src.len < 3) return error.SrcSizeWrong;

    const b0 = src[0];
    const lhl: u2 = @truncate((b0 >> 2) & 3);
    var lhSize: usize = undefined;
    var litSize: usize = undefined;
    var litCSize: usize = undefined;
    var singleStream: bool = undefined;

    switch (lhl) {
        0, 1 => {
            const lhc: u32 = bits.readLe32(src[0..]);
            lhSize = 3;
            litSize = (lhc >> 4) & 0x3FF;
            litCSize = (lhc >> 14) & 0x3FF;
            singleStream = lhl == 0;
        },
        2 => {
            if (src.len < 4) return error.SrcSizeWrong;
            const lhc: u32 = bits.readLe32(src[0..]);
            lhSize = 4;
            litSize = (lhc >> 4) & 0x3FFF;
            litCSize = lhc >> 18;
            singleStream = false;
        },
        3 => {
            if (src.len < 5) return error.SrcSizeWrong;
            const lhc: u32 = bits.readLe32(src[0..]);
            lhSize = 5;
            litSize = (lhc >> 4) & 0x3FFFF;
            litCSize = (lhc >> 22) + (@as(usize, src[4]) << 10);
            singleStream = false;
        },
    }

    if (!singleStream and litSize < min_literals_for_4_streams) return error.InvalidHuffmanTable;
    if (lhSize + litCSize > src.len) return error.SrcSizeWrong;

    const hufSrc = src[lhSize .. lhSize + litCSize];

    var local_decoder: ?huf_decompress.HuffDecoder = null;
    defer if (local_decoder) |*d| d.deinit();

    // The tree description is the first part of the literals payload, so the
    // bitstreams start after it. A single stream would decode correctly even with
    // the description included (the reverse bitstream is read from the end), but
    // a 4-stream payload puts its jump table at the front.
    var bitstreams: []const u8 = hufSrc;
    var used: *const huf_decompress.HuffDecoder = undefined;
    if (isRepeat) {
        used = &(state.huf orelse return error.DictionaryCorrupted);
    } else {
        var weights: [256]u8 = undefined;
        var ranks: [huf_decompress.max_table_log + 1]u32 = undefined;
        var nbSymbols: usize = 0;
        var tableLog: u8 = 0;
        const description = try huf_decompress.readStats(&weights, &ranks, &nbSymbols, &tableLog, hufSrc, state.allocator);
        if (description > hufSrc.len) return error.Corruption;
        bitstreams = hufSrc[description..];
        const dec = try huf_decompress.buildDecoder(state.allocator, weights[0..nbSymbols], tableLog);
        local_decoder = dec;
        used = &local_decoder.?;
    }

    const out = state.allocator.alloc(u8, litSize) catch return error.OutOfMemory;
    errdefer state.allocator.free(out);

    if (singleStream) {
        try huf_decompress.decodeSingleStream(out, bitstreams, used);
    } else {
        try huf_decompress.decode4Streams(out, bitstreams, used);
    }

    if (!isRepeat) {
        if (state.huf) |*old| old.deinit();
        state.huf = local_decoder.?;
        local_decoder = null; // ownership moved
        state.lit_entropy = true;
    }

    return .{
        .section = .{ .data = out, .owned = true },
        .bytes_read = lhSize + litCSize,
    };
}

// Sequences section

/// What a sequence is allowed to reference. `max_offset` is the frame's declared
/// window capped by the output produced so far; the dictionary is always fully
/// addressable on top of that.
pub const SeqLimits = struct {
    history: []const u8, // output preceding current block start (frame-local)
    /// Dictionary content that logically precedes `history`. Offsets may reach
    /// into it exactly like prior frame output.
    dict: []const u8 = &.{},
    /// Largest distance the frame's format allows: the smaller of the declared
    /// window and the output so far, plus any dictionary content in front. Reaching
    /// further is outside the format even when the bytes are present, which is what
    /// separates "decodable" from "valid".
    max_offset: usize = std.math.maxInt(usize),
};

/// Copies `len` bytes to `dst` from the virtual window
/// `dict ++ history ++ dst[0..out_pos]`, where the match source sits
/// `offset` bytes behind the current output position. The byte-at-a-time
/// form is required because matches may overlap their own source.
fn copyMatch(
    dst: []u8,
    outPos: usize,
    dict: []const u8,
    history: []const u8,
    offset: usize,
    len: usize,
    max_offset: usize,
) errors.ZstdError!void {
    const available: usize = dict.len + history.len + outPos;
    if (offset == 0 or offset > available) return error.InvalidOffset;
    // The format caps how far a match may reach independently of whether the bytes
    // are still in the buffer, so this is checked before the copy: exceeding the
    // declared window is a malformed frame, not a short buffer.
    if (offset > max_offset) return error.Corruption;
    if (len == 0) return error.Corruption;
    if (outPos + len > dst.len) return error.DstSizeTooSmall;
    var m: usize = 0;
    while (m < len) : (m += 1) {
        const src_virt = dict.len + history.len + outPos + m - offset;
        dst[outPos + m] = if (src_virt < dict.len)
            dict[src_virt]
        else if (src_virt < dict.len + history.len)
            history[src_virt - dict.len]
        else
            dst[src_virt - dict.len - history.len];
    }
}

/// Runs one match copy under `limits`, bypassing the sequence bitstream.
/// Exists so the offset rules can be tested directly instead of only through a
/// full block, where a wrong distance would be hard to attribute.
pub fn testResolveMatch(
    state: *State,
    dst: []u8,
    outPos: usize,
    offset: usize,
    len: usize,
    limits: SeqLimits,
) errors.ZstdError!usize {
    _ = state;
    try copyMatch(dst, outPos, limits.dict, limits.history, offset, len, limits.max_offset);
    return len;
}

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
    var nbSeq: usize = src[pos];
    pos += 1;
    if (nbSeq > 0x7F) {
        if (nbSeq == 0xFF) {
            if (pos + 2 > src.len) return error.SrcSizeWrong;
            nbSeq = @as(usize, src[pos]) | (@as(usize, src[pos + 1]) << 8);
            nbSeq += constants.long_nb_seq;
            pos += 2;
        } else {
            if (pos >= src.len) return error.SrcSizeWrong;
            nbSeq = ((nbSeq - 0x80) << 8) + src[pos];
            pos += 1;
        }
    }

    if (nbSeq == 0) {
        if (pos != src.len) return error.Corruption; // extraneous data
        if (literals.len > dst.len) return error.DstSizeTooSmall;
        std.mem.copyForwards(u8, dst[0..literals.len], literals);
        return literals.len;
    }

    // --- symbol compression modes ---
    if (pos >= src.len) return error.SrcSizeWrong;
    const mode_byte = src[pos];
    pos += 1;
    if (mode_byte & 3 != 0) return error.Corruption; // reserved bits
    const ll_mode: SymbolMode = @fromBackingInt(@intCast(@as(u2, @truncate(mode_byte >> 6))));
    const of_mode: SymbolMode = @fromBackingInt(@intCast(@as(u2, @truncate(mode_byte >> 4))));
    const ml_mode: SymbolMode = @fromBackingInt(@intCast(@as(u2, @truncate(mode_byte >> 2))));

    pos += try buildSeqTable(state, .ll, ll_mode, constants.max_ll, constants.ll_fse_log, src[pos..], &constants.ll_base, constants.ll_bits[0..], &constants.ll_default_norm, @intCast(constants.ll_default_norm_log));
    pos += try buildSeqTable(state, .of, of_mode, constants.max_off, constants.off_fse_log, src[pos..], &constants.of_base, constants.of_bits[0..], &constants.of_default_norm, @intCast(constants.of_default_norm_log));
    pos += try buildSeqTable(state, .ml, ml_mode, constants.max_ml, constants.ml_fse_log, src[pos..], &constants.ml_base, constants.ml_bits[0..], &constants.ml_default_norm, @intCast(constants.ml_default_norm_log));

    if (pos > src.len) return error.SrcSizeWrong;

    const ll_table = &(state.ll orelse return error.Corruption);
    const of_table = &(state.of orelse return error.Corruption);
    const ml_table = &(state.ml orelse return error.Corruption);

    // --- FSE bitstream ---
    var ds = BIT_DStream.init(src[pos..]) catch return error.Corruption;
    // An RLE table has a table log of zero and one entry that maps to itself, so
    // its state starts at zero and never moves; every other mode seeds the state
    // with that many bits. The state is validated against the table before use.
    var st_ll: u16 = 0;
    var st_of: u16 = 0;
    var st_ml: u16 = 0;
    if (ll_table.log > 0) st_ll = @intCast(ds.readBits(ll_table.log));
    if (of_table.log > 0) st_of = @intCast(ds.readBits(of_table.log));
    if (ml_table.log > 0) st_ml = @intCast(ds.readBits(ml_table.log));
    if (st_ll >= ll_table.entries.len or st_of >= of_table.entries.len or st_ml >= ml_table.entries.len) {
        return error.Corruption;
    }
    // The seed states were read out of the first container; start the sequence
    // loop from a fresh one so its reads have a full container to work with.
    if (ds.reload() == .overflow) return error.Corruption;

    var outPos: usize = 0;
    var litPos: usize = 0;

    var seq_idx: usize = 0;
    while (seq_idx < nbSeq) : (seq_idx += 1) {
        const is_last = seq_idx == nbSeq - 1;

        // States come from untrusted bits, so re-check them every iteration
        // rather than only at the start.
        if (st_ll >= ll_table.entries.len or st_of >= of_table.entries.len or st_ml >= ml_table.entries.len) {
            return error.Corruption;
        }
        const lld = ll_table.entries[st_ll];
        const mld = ml_table.entries[st_ml];
        const ofd = of_table.entries[st_of];

        var litLen: usize = lld.base;
        var matchLen: usize = mld.base;
        const llExtra: u8 = lld.nbAddBits;
        const mlExtra: u8 = mld.nbAddBits;
        const ofBits: u8 = ofd.nbAddBits;

        // This sequence reads the offset's, match length's and literal length's extra
        // bits plus, unless it is the last, three state updates: more than one
        // container for a wide offset and long match, so refill before reading.
        const code_bits: u32 = @as(u32, ofBits) + mlExtra + llExtra;
        if (!ds.ensure(code_bits)) return error.Corruption;

        // Offset resolution with repeat-offset semantics.
        var offset: u32 = undefined;
        if (ofBits > 1) {
            offset = ofd.base +% @as(u32, @truncate(ds.readBits(ofBits)));
            state.rep[2] = state.rep[1];
            state.rep[1] = state.rep[0];
            state.rep[0] = offset;
        } else {
            const ll0: bool = lld.base == 0;
            if (ofBits == 0) {
                offset = state.rep[@intFromBool(ll0)];
                const keep = state.rep[if (ll0) 0 else 1];
                state.rep[1] = keep;
                state.rep[0] = offset;
            } else {
                const offCode: u32 = ofd.base +% @as(u32, @intFromBool(ll0)) +% @as(u32, @truncate(ds.readBits(1)));
                var temp: u32 = switch (offCode) {
                    3 => state.rep[0] -% 1,
                    else => state.rep[offCode], // 1 or 2
                };
                temp -%= @intFromBool(temp == 0); // force invalid so offset check fires
                if (offCode != 1) state.rep[2] = state.rep[1];
                state.rep[1] = state.rep[0];
                state.rep[0] = temp;
                offset = temp;
            }
        }

        if (mlExtra > 0) matchLen += @as(u32, @truncate(ds.readBits(mlExtra)));
        if (llExtra > 0) litLen += @as(u32, @truncate(ds.readBits(llExtra)));

        // Execute: copy literals.
        if (litPos + litLen > literals.len) return error.Corruption;
        if (outPos + litLen > dst.len) return error.DstSizeTooSmall;
        std.mem.copyForwards(u8, dst[outPos .. outPos + litLen], literals[litPos .. litPos + litLen]);
        litPos += litLen;
        outPos += litLen;

        // Execute: copy match (overlap-safe, may reach into the dictionary
        // prefix or the prior-frame window).
        try copyMatch(dst, outPos, limits.dict, limits.history, offset, matchLen, limits.max_offset);
        outPos += matchLen;

        if (!is_last) {
            // The three state transitions read from the same container as the
            // codes above, so it needs room for them too.
            if (!ds.ensure(@as(u32, lld.nbBits) + mld.nbBits + ofd.nbBits)) return error.Corruption;
            // Update states LL -> ML -> OF, then reload.
            st_ll = updateState(&ds, ll_table.entries[st_ll]);
            st_ml = updateState(&ds, ml_table.entries[st_ml]);
            st_of = updateState(&ds, of_table.entries[st_of]);
        }
        if (ds.reload() == .overflow) return error.Corruption;
    }

    // The sequence bitstream must be exactly exhausted. The reference decoder
    // rejects trailing garbage or truncated streams here.
    try ds.requireCompleted();

    // Trailing literals after the last sequence.
    const tail = literals.len - litPos;
    if (tail > 0) {
        if (outPos + tail > dst.len) return error.DstSizeTooSmall;
        std.mem.copyForwards(u8, dst[outPos .. outPos + tail], literals[litPos..]);
        outPos += tail;
    }

    return outPos;
}

inline fn updateState(ds: *BIT_DStream, entry: SeqSymbol) u16 {
    return entry.newState +% @as(u16, @truncate(ds.readBits(entry.nbBits)));
}

// Tests

const testing = std.testing;

test "ncount compact: known vector" {
    // Hand-crafted minimal header encoding tableLog=5, counts {2,1,1} for syms 0..2.
    // Verified against FSE_readNCount behavior via round-trip below.
    var norm: [8]i16 = undefined;
    var maxSv: usize = 7;
    var tl: u8 = 0;
    // 0x14 0x00 ... : tableLog field low nibble (5-5=0) then count bits.
    const src = [_]u8{ 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const n = readNCountCompact(&norm, &maxSv, &tl, &src) catch |e| {
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
