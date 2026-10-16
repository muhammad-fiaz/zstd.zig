//! Block and sequence decompression algorithm for legacy frames.

const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const bitstream_mod = @import("../common/bitstream.zig");
const bits = @import("../common/bits.zig");
const xxhash = @import("../common/xxhash.zig");
const fse_dtable = @import("../fse/dtable.zig");
const ncount_mod = @import("../fse/ncount.zig");
const huf_decompress = @import("../huffman/decompress.zig");
const format = @import("format.zig");
const decoder = @import("decoder.zig");

const BIT_DStream = bitstream_mod.BIT_DStream;

const v06_of_base = [29]u32{
    0,        1,         3,         7,       0xF,     0x1F,     0x3F,     0x7F,
    0xFF,     0x1FF,     0x3FF,     0x7FF,   0xFFF,   0x1FFF,   0x3FFF,   0x7FFF,
    0xFFFF,   0x1FFFF,   0x3FFFF,   0x7FFFF, 0xFFFFF, 0x1FFFFF, 0x3FFFFF, 0x7FFFFF,
    0xFFFFFF, 0x1FFFFFF, 0x3FFFFFF, 1,       1,
};

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

const State = struct {
    allocator: std.mem.Allocator,
    huf: ?huf_decompress.HuffDecoder = null,
    ll: ?SeqTable = null,
    of: ?SeqTable = null,
    ml: ?SeqTable = null,
    rep: [3]u32,

    pub fn init(allocator: std.mem.Allocator, version: format.Version) State {
        return .{
            .allocator = allocator,
            .rep = if (version == .v06) [3]u32{ 1, 1, 1 } else [3]u32{ 1, 4, 8 },
        };
    }

    pub fn deinit(self: *State) void {
        if (self.huf) |*h| h.deinit();
        if (self.ll) |*t| t.deinit();
        if (self.of) |*t| t.deinit();
        if (self.ml) |*t| t.deinit();
    }
};

fn updateState(ds: *BIT_DStream, entry: SeqSymbol) u16 {
    const bits_needed = entry.nbBits;
    const rest: u16 = if (bits_needed > 0)
        @intCast(ds.readBits(bits_needed))
    else
        0;
    return entry.newState + rest;
}

fn copyMatch(
    dst: []u8,
    outPos: usize,
    offset: usize,
    len: usize,
) errors.ZstdError!void {
    if (offset == 0 or offset > outPos) return error.InvalidOffset;
    if (len == 0) return error.Corruption;
    if (outPos + len > dst.len) return error.DstSizeTooSmall;
    var m: usize = 0;
    while (m < len) : (m += 1) {
        dst[outPos + m] = dst[outPos + m - offset];
    }
}

pub fn findFrameSizeFor(
    ver: format.Version,
    allocator: std.mem.Allocator,
    src: []const u8,
) errors.ZstdError!usize {
    _ = allocator;
    if (src.len < 4) return error.SrcSizeWrong;
    const header = try format.readFrameHeader(ver, src);
    var pos = header.size;
    while (true) {
        if (src.len < pos + format.block_header_size) return error.SrcSizeWrong;
        const block = try format.readBlockHeader(src[pos..]);
        pos += format.block_header_size + block.block_type.payloadLen(block.size);
        if (block.block_type == .end) return pos;
        if (pos > src.len) return error.SrcSizeWrong;
    }
}

pub fn decompressFor(
    version: format.Version,
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
) errors.ZstdError!decoder.Result {
    const header = try format.readFrameHeader(version, src);
    var pos = header.size;
    var out: usize = 0;

    var state = State.init(allocator, version);
    defer state.deinit();

    while (true) {
        if (pos + format.block_header_size > src.len) return error.SrcSizeWrong;
        const block = try format.readBlockHeader(src[pos..]);
        pos += format.block_header_size;
        switch (block.block_type) {
            .end => {
                if (version == .v07 and header.checksum) {
                    const h64 = xxhash.xxhash64(dst[0..out], 0);
                    const h32 = @as(u32, @truncate(h64 >> 11)) & ((1 << 22) - 1);
                    const in = src[pos - format.block_header_size .. pos];
                    const check32: u32 = std.mem.readInt(u24, in[0..3], .big) & 0x3FFFFF;
                    if (check32 != h32) return error.ChecksumWrong;
                }
                if (pos != src.len) return error.SrcSizeWrong;
                return .{ .decoded = out, .consumed = pos };
            },
            .raw => {
                if (src.len < pos + block.size) return error.SrcSizeWrong;
                if (dst.len < out + block.size) return error.DstSizeTooSmall;
                @memcpy(dst[out..][0..block.size], src[pos..][0..block.size]);
                out += block.size;
                pos += block.size;
            },
            .rle => {
                if (src.len < pos + 1) return error.SrcSizeWrong;
                if (dst.len < out + block.size) return error.DstSizeTooSmall;
                @memset(dst[out..][0..block.size], src[pos]);
                out += block.size;
                pos += 1;
            },
            .compressed => {
                if (src.len < pos + block.size) return error.SrcSizeWrong;
                const produced = try decompressCompressedBlock(
                    version,
                    &state,
                    dst,
                    out,
                    src[pos..][0..block.size],
                );
                out += produced;
                pos += block.size;
            },
        }
    }
}

fn decompressCompressedBlock(
    version: format.Version,
    state: *State,
    dst: []u8,
    out_start: usize,
    block: []const u8,
) errors.ZstdError!usize {
    if (block.len < 1) return error.SrcSizeWrong;

    // Literals
    const lit_res = try decodeLiterals(state, block);
    defer if (lit_res.owned) state.allocator.free(lit_res.data);

    if (lit_res.read >= block.len) {
        if (out_start + lit_res.data.len > dst.len) return error.DstSizeTooSmall;
        @memcpy(dst[out_start .. out_start + lit_res.data.len], lit_res.data);
        return lit_res.data.len;
    }

    return decodeSequences(
        version,
        state,
        dst,
        out_start,
        lit_res.data,
        block[lit_res.read..],
    );
}

const LiteralsResult = struct {
    data: []const u8,
    owned: bool,
    read: usize,
};

fn decodeLiterals(
    state: *State,
    src: []const u8,
) errors.ZstdError!LiteralsResult {
    if (src.len < 1) return error.SrcSizeWrong;
    const kind: u2 = @truncate(src[0] >> 6);
    const code: u2 = @truncate((src[0] >> 4) & 3);

    switch (kind) {
        0, 1 => { // 0 = Huffman, 1 = Treeless (repeat)
            const is_repeat = kind == 1;
            if (is_repeat and state.huf == null) return error.DictionaryCorrupted;

            const narrow = code <= 1;
            var header: usize = 3;
            var lit_size: usize = 0;
            var c_size: usize = 0;
            var single_stream = false;

            if (narrow) {
                if (src.len < 3) return error.SrcSizeWrong;
                single_stream = (src[0] & 16) != 0;
                lit_size = (@as(usize, src[0] & 15) << 6) + (src[1] >> 2);
                c_size = (@as(usize, src[1] & 3) << 8) + src[2];
            } else if (code == 2) {
                header = 4;
                if (src.len < 4) return error.SrcSizeWrong;
                lit_size = (@as(usize, src[0] & 15) << 10) + (@as(usize, src[1]) << 2) + (src[2] >> 6);
                c_size = (@as(usize, src[2] & 63) << 8) + src[3];
            } else {
                header = 5;
                if (src.len < 5) return error.SrcSizeWrong;
                lit_size = (@as(usize, src[0] & 15) << 14) + (@as(usize, src[1]) << 6) + (src[2] >> 2);
                c_size = (@as(usize, src[2] & 3) << 16) + (@as(usize, src[3]) << 8) + src[4];
            }

            if (c_size + header > src.len) return error.SrcSizeWrong;
            const huf_src = src[header .. header + c_size];

            var local_decoder: ?huf_decompress.HuffDecoder = null;
            defer if (local_decoder) |*d| d.deinit();

            var bitstreams = huf_src;
            var used: *const huf_decompress.HuffDecoder = undefined;

            if (is_repeat) {
                used = &(state.huf orelse return error.DictionaryCorrupted);
            } else {
                var weights: [256]u8 = undefined;
                var ranks: [huf_decompress.max_table_log + 1]u32 = undefined;
                var nbSymbols: usize = 0;
                var tableLog: u8 = 0;
                const desc_bytes = try huf_decompress.readStats(&weights, &ranks, &nbSymbols, &tableLog, huf_src, state.allocator);
                if (desc_bytes > huf_src.len) return error.Corruption;
                bitstreams = huf_src[desc_bytes..];
                const dec = try huf_decompress.buildDecoder(state.allocator, weights[0..nbSymbols], tableLog);
                local_decoder = dec;
                used = &local_decoder.?;
            }

            const out = try state.allocator.alloc(u8, lit_size);
            errdefer state.allocator.free(out);

            if (single_stream) {
                try huf_decompress.decodeSingleStream(out, bitstreams, used);
            } else {
                try huf_decompress.decode4Streams(out, bitstreams, used);
            }

            if (!is_repeat) {
                if (state.huf) |*old| old.deinit();
                state.huf = local_decoder.?;
                local_decoder = null;
            }

            return .{
                .data = out,
                .owned = true,
                .read = header + c_size,
            };
        },
        2 => { // Raw
            var header: usize = 1;
            var lit_size: usize = 0;
            switch (code) {
                0, 1 => {
                    lit_size = src[0] & 31;
                },
                2 => {
                    header = 2;
                    if (src.len < 2) return error.SrcSizeWrong;
                    lit_size = (@as(usize, src[0] & 15) << 8) + src[1];
                },
                3 => {
                    header = 3;
                    if (src.len < 3) return error.SrcSizeWrong;
                    lit_size = (@as(usize, src[0] & 15) << 16) + (@as(usize, src[1]) << 8) + src[2];
                },
            }
            if (header + lit_size > src.len) return error.SrcSizeWrong;
            return .{
                .data = src[header .. header + lit_size],
                .owned = false,
                .read = header + lit_size,
            };
        },
        3 => { // RLE
            var header: usize = 1;
            var lit_size: usize = 0;
            switch (code) {
                0, 1 => {
                    lit_size = src[0] & 31;
                },
                2 => {
                    header = 2;
                    if (src.len < 2) return error.SrcSizeWrong;
                    lit_size = (@as(usize, src[0] & 15) << 8) + src[1];
                },
                3 => {
                    header = 3;
                    if (src.len < 3) return error.SrcSizeWrong;
                    lit_size = (@as(usize, src[0] & 15) << 16) + (@as(usize, src[1]) << 8) + src[2];
                },
            }
            if (src.len < header + 1) return error.SrcSizeWrong;
            const val = src[header];
            const out = try state.allocator.alloc(u8, lit_size);
            @memset(out, val);
            return .{
                .data = out,
                .owned = true,
                .read = header + 1,
            };
        },
    }
}

fn buildTable(
    allocator: std.mem.Allocator,
    target: *?SeqTable,
    mode: u2,
    max_symbol: usize,
    max_log: u8,
    src: []const u8,
    base_values: []const u32,
    add_bits: []const u8,
    default_norm: []const i16,
    default_log: u8,
) errors.ZstdError!usize {
    switch (mode) {
        0 => { // RAW / Predefined
            const t = try buildSeqTableFromNorm(allocator, default_norm, max_symbol, default_log, base_values, add_bits);
            if (target.*) |*old| old.deinit();
            target.* = t;
            return 0;
        },
        1 => { // RLE
            if (src.len < 1) return error.SrcSizeWrong;
            const sym = src[0];
            if (sym > max_symbol) return error.Corruption;
            const t = try buildSeqTableRle(allocator, sym, base_values, add_bits);
            if (target.*) |*old| old.deinit();
            target.* = t;
            return 1;
        },
        2 => { // STATIC / Repeat
            if (target.* == null) return error.Corruption;
            return 0;
        },
        3 => { // DYNAMIC / Compressed
            var norm: [256]i16 = undefined;
            var max_sym: usize = max_symbol;
            var table_log: u8 = 0;
            const bytes_read = try ncount_mod.readNCount(&norm, &max_sym, &table_log, src);
            if (table_log > max_log) return error.Corruption;
            const t = try buildSeqTableFromNorm(allocator, norm[0 .. max_sym + 1], max_sym, table_log, base_values, add_bits);
            if (target.*) |*old| old.deinit();
            target.* = t;
            return bytes_read;
        },
    }
}

fn decodeSequences(
    version: format.Version,
    state: *State,
    dst: []u8,
    out_start: usize,
    literals: []const u8,
    src: []const u8,
) errors.ZstdError!usize {
    var pos: usize = 0;

    // Sequence count
    if (src.len < 1) return error.SrcSizeWrong;
    var nbSeq: usize = src[pos];
    pos += 1;
    if (nbSeq > 0x7F) {
        if (nbSeq == 0xFF) {
            if (pos + 2 > src.len) return error.SrcSizeWrong;
            nbSeq = std.mem.readInt(u16, src[pos..][0..2], .little);
            nbSeq += constants.long_nb_seq;
            pos += 2;
        } else {
            if (pos >= src.len) return error.SrcSizeWrong;
            nbSeq = ((nbSeq - 0x80) << 8) + src[pos];
            pos += 1;
        }
    }

    if (nbSeq == 0) {
        if (pos != src.len) return error.Corruption;
        if (out_start + literals.len > dst.len) return error.DstSizeTooSmall;
        @memcpy(dst[out_start .. out_start + literals.len], literals);
        return literals.len;
    }

    // Symbol modes
    if (pos >= src.len) return error.SrcSizeWrong;
    const mode_byte = src[pos];
    pos += 1;
    if (mode_byte & 3 != 0) return error.Corruption;
    const ll_mode: u2 = @truncate(mode_byte >> 6);
    const of_mode: u2 = @truncate(mode_byte >> 4);
    const ml_mode: u2 = @truncate(mode_byte >> 2);

    // Build LL table
    pos += try buildTable(
        state.allocator,
        &state.ll,
        ll_mode,
        constants.max_ll,
        constants.ll_fse_log,
        src[pos..],
        &constants.ll_base,
        constants.ll_bits[0..],
        &constants.ll_default_norm,
        @intCast(constants.ll_default_norm_log),
    );

    // Build OF table
    var v06_of_sym_base: [29]u32 = undefined;
    var v06_of_sym_bits: [29]u8 = undefined;
    for (0..29) |i| {
        v06_of_sym_base[i] = @intCast(i);
        v06_of_sym_bits[i] = @intCast(i);
    }

    if (version == .v06) {
        pos += try buildTable(
            state.allocator,
            &state.of,
            of_mode,
            constants.max_off,
            constants.off_fse_log,
            src[pos..],
            &v06_of_sym_base,
            &v06_of_sym_bits,
            &constants.of_default_norm,
            @intCast(constants.of_default_norm_log),
        );
    } else {
        pos += try buildTable(
            state.allocator,
            &state.of,
            of_mode,
            constants.max_off,
            constants.off_fse_log,
            src[pos..],
            &constants.of_base,
            constants.of_bits[0..],
            &constants.of_default_norm,
            @intCast(constants.of_default_norm_log),
        );
    }

    // Build ML table
    pos += try buildTable(
        state.allocator,
        &state.ml,
        ml_mode,
        constants.max_ml,
        constants.ml_fse_log,
        src[pos..],
        &constants.ml_base,
        constants.ml_bits[0..],
        &constants.ml_default_norm,
        @intCast(constants.ml_default_norm_log),
    );

    if (pos > src.len) return error.SrcSizeWrong;

    const ll_table = &(state.ll orelse return error.Corruption);
    const of_table = &(state.of orelse return error.Corruption);
    const ml_table = &(state.ml orelse return error.Corruption);

    // Reverse bitstream
    var ds = BIT_DStream.init(src[pos..]) catch return error.Corruption;
    var st_ll = ds.readBits(ll_table.log);
    var st_of = ds.readBits(of_table.log);
    var st_ml = ds.readBits(ml_table.log);
    if (ds.reload() == .overflow) return error.Corruption;

    var outPos: usize = out_start;
    var litPos: usize = 0;

    var seq_idx: usize = 0;
    while (seq_idx < nbSeq) : (seq_idx += 1) {
        const is_last = seq_idx == nbSeq - 1;

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

        const code_bits: u32 = @as(u32, ofBits) + mlExtra + llExtra;
        if (!ds.ensure(code_bits)) return error.Corruption;

        var offset: u32 = undefined;
        if (version == .v06) {
            const ofCode: u32 = ofd.base;
            var raw_offset: u32 = 0;
            if (ofCode != 0) {
                raw_offset = v06_of_base[ofCode] + @as(u32, @truncate(ds.readBits(ofBits)));
            }

            if (raw_offset < 3) {
                if (lld.base == 0 and raw_offset <= 1) raw_offset = 1 - raw_offset;
                if (raw_offset != 0) {
                    const temp = state.rep[raw_offset];
                    if (raw_offset != 1) state.rep[2] = state.rep[1];
                    state.rep[1] = state.rep[0];
                    state.rep[0] = temp;
                    offset = temp;
                } else {
                    offset = state.rep[0];
                }
            } else {
                raw_offset -= 2;
                state.rep[2] = state.rep[1];
                state.rep[1] = state.rep[0];
                state.rep[0] = raw_offset;
                offset = raw_offset;
            }
        } else {
            // v0.7
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
                        else => state.rep[offCode],
                    };
                    temp -%= @intFromBool(temp == 0);
                    if (offCode != 1) state.rep[2] = state.rep[1];
                    state.rep[1] = state.rep[0];
                    state.rep[0] = temp;
                    offset = temp;
                }
            }
        }

        if (mlExtra > 0) matchLen += @as(u32, @truncate(ds.readBits(mlExtra)));
        if (llExtra > 0) litLen += @as(u32, @truncate(ds.readBits(llExtra)));

        if (litPos + litLen > literals.len) return error.Corruption;
        if (outPos + litLen > dst.len) return error.DstSizeTooSmall;
        @memcpy(dst[outPos .. outPos + litLen], literals[litPos .. litPos + litLen]);
        litPos += litLen;
        outPos += litLen;

        try copyMatch(dst, outPos, offset, matchLen);
        outPos += matchLen;

        if (!is_last) {
            if (!ds.ensure(@as(u32, lld.nbBits) + mld.nbBits + ofd.nbBits)) return error.Corruption;
            st_ll = updateState(&ds, ll_table.entries[st_ll]);
            st_ml = updateState(&ds, ml_table.entries[st_ml]);
            st_of = updateState(&ds, of_table.entries[st_of]);
        }
        if (ds.reload() == .overflow) return error.Corruption;
    }

    try ds.requireCompleted();

    const tail = literals.len - litPos;
    if (tail > 0) {
        if (outPos + tail > dst.len) return error.DstSizeTooSmall;
        @memcpy(dst[outPos .. outPos + tail], literals[litPos..]);
        outPos += tail;
    }

    return outPos - out_start;
}
