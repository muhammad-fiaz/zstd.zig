//! Sequence section parsing and decoding for legacy Zstandard formats (v0.1 to v0.5).

const std = @import("std");
const bits = @import("../common/bits.zig");
const errors = @import("../common/errors.zig");
const bitstream = @import("../common/bitstream.zig");
const dtable = @import("../fse/dtable.zig");
const legacy_fse = @import("fse.zig");
const format = @import("format.zig");

/// One decoded sequence.
pub const Sequence = struct {
    lit_length: usize,
    match_length: usize,
    offset: usize,
};

/// The three decoding tables a block's sequence section builds.
pub const Tables = struct {
    ll: dtable.DTable,
    off: dtable.DTable,
    ml: dtable.DTable,
    allocator: std.mem.Allocator,

    /// An all-empty set, safe to release. A header parse that fails part way
    /// through has to release what it did build without touching what it did not,
    /// which is what starting from empty makes possible.
    pub fn empty(allocator: std.mem.Allocator) Tables {
        return .{
            .ll = .{ .log = 0, .entries = &.{}, .allocator = allocator },
            .off = .{ .log = 0, .entries = &.{}, .allocator = allocator },
            .ml = .{ .log = 0, .entries = &.{}, .allocator = allocator },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Tables) void {
        self.ll.deinit();
        self.off.deinit();
        self.ml.deinit();
        self.* = undefined;
    }
};

/// The header of a sequence section: how many sequences, where the dumps region
/// is, and how each of the three tables is described.
pub const SeqHeader = struct {
    nb_seq: usize,
    dumps: []const u8,
    ll_mode: legacy_fse.Encoding,
    off_mode: legacy_fse.Encoding,
    ml_mode: legacy_fse.Encoding,
    /// Header bytes consumed, counting the dumps region but not the bitstream.
    read: usize,
};

/// Reads the sequence count.
///
/// v0.1 through v0.4 always spend two bytes on it. v0.5 changes that to one byte
/// plus an extension: a first byte below 128 is the whole count, and 128 or more
/// means the low seven bits count down from 128 and a second byte supplies the
/// rest. The same count has to come out of both encodings, because the count
/// decides how many sequences to regenerate.
fn readSequenceCount(ver: format.Version, src: []const u8, pos: *usize) errors.ZstdError!usize {
    if (!ver.hasVariableSequenceCount()) {
        if (src.len < pos.* + 2) return error.SrcSizeWrong;
        const value = bits.readLe16(src[pos.*..][0..2]);
        pos.* += 2;
        return value;
    }
    if (src.len < pos.* + 1) return error.SrcSizeWrong;
    const first = src[pos.*];
    pos.* += 1;
    if (first < 128) return first;
    if (src.len < pos.* + 1) return error.SrcSizeWrong;
    const second = src[pos.*];
    pos.* += 1;
    return (@as(usize, first) - 128) << 8 | second;
}

/// Reads one two-bit table mode, honouring the versions that number raw and RLE
/// the other way round from v0.1 to v0.4.
fn readEncoding(version: format.Version, bits_field: u8) legacy_fse.Encoding {
    const raw: u2 = @intCast(bits_field & 3);
    if (!version.rawEncodingComesFirst()) return @fromBackingInt(@intCast(raw));
    return switch (raw) {
        0 => .raw,
        1 => .rle,
        else => @fromBackingInt(@intCast(raw)),
    };
}

/// Reads the sequence-section header and builds the three decoding tables.
///
/// `tables` is filled in; the caller owns it. The bitstream starts at
/// `header.read` bytes into `src`.
pub fn readSeqHeader(
    version: format.Version,
    allocator: std.mem.Allocator,
    tables: *Tables,
    src: []const u8,
) errors.ZstdError!SeqHeader {
    // The reference gates on five bytes: two for the count, one for the mode, and
    // at least two more for a short dumps length.
    if (src.len < 5) return error.SrcSizeWrong;
    var pos: usize = 0;
    const nb_seq = try readSequenceCount(version, src, &pos);

    const mode_byte = src[pos];
    pos += 1;
    const ll_mode = readEncoding(version, mode_byte >> 6);
    const off_mode = readEncoding(version, (mode_byte >> 4) & 3);
    const ml_mode = readEncoding(version, (mode_byte >> 2) & 3);

    const dumps_length: usize = if ((mode_byte & 2) != 0) blk: {
        if (src.len < pos + 2) return error.SrcSizeWrong;
        const v = @as(usize, src[pos]) | (@as(usize, src[pos + 1]) << 8);
        pos += 2;
        break :blk v;
    } else blk: {
        const v = @as(usize, src[pos]) | (@as(usize, mode_byte & 1) << 8);
        pos += 1;
        break :blk v;
    };
    if (pos + dumps_length > src.len) return error.SrcSizeWrong;
    const dumps = src[pos .. pos + dumps_length];
    pos += dumps_length;

    // The reference then demands three more bytes: all three tables could be "raw",
    // which costs no description, but each still needs room for its own table log.
    if (pos + 3 > src.len) return error.SrcSizeWrong;

    try buildSeqTable(
        version,
        allocator,
        &tables.ll,
        ll_mode,
        legacy_fse.Table.literal_length,
        src,
        &pos,
    );
    try buildSeqTable(
        version,
        allocator,
        &tables.off,
        off_mode,
        legacy_fse.Table.offset,
        src,
        &pos,
    );
    try buildSeqTable(
        version,
        allocator,
        &tables.ml,
        ml_mode,
        legacy_fse.Table.match_length,
        src,
        &pos,
    );

    return .{
        .nb_seq = nb_seq,
        .dumps = dumps,
        .ll_mode = ll_mode,
        .off_mode = off_mode,
        .ml_mode = ml_mode,
        .read = pos,
    };
}

/// Builds one of the three decoding tables, advancing `pos` past its description.
///
/// v0.1 through v0.5 have no "repeat the previous block's table" mode: the mode
/// values 2 and 3 are "repeat from the dictionary" and "read a table". A block
/// without a dictionary has nothing to repeat from, so mode 2 is corruption here,
/// exactly as the reference reports it.
fn buildSeqTable(
    version: format.Version,
    allocator: std.mem.Allocator,
    table: *dtable.DTable,
    mode: legacy_fse.Encoding,
    which: legacy_fse.Table,
    src: []const u8,
    pos: *usize,
) errors.ZstdError!void {
    switch (mode) {
        .rle => {
            if (pos.* >= src.len) return error.SrcSizeWrong;
            const symbol = src[pos.*];
            pos.* += 1;
            // A single-symbol offset table stores the symbol verbatim in v0.1 and
            // masks it in v0.2 onward, because an offset code above the encodable
            // range is corruption rather than a wider code.
            const masked = if (which == legacy_fse.Table.offset)
                @as(u16, @truncate(symbol & format.max_off))
            else
                @as(u16, symbol);
            table.* = try dtable.buildRle(allocator, masked);
        },
        .raw => {
            table.* = try dtable.buildRaw(allocator, legacy_fse.rawTableLog(version, which));
        },
        .static_reuse => return error.DictionaryCorrupted,
        .dynamic => {
            if (pos.* >= src.len) return error.SrcSizeWrong;
            const ceiling = legacy_fse.symbolCeiling(version, which);
            var header = legacy_fse.NCountHeader{};
            try legacy_fse.readNCount(&header, ceiling, src[pos.*..]);
            pos.* += header.read;
            table.* = try legacy_fse.buildFromHeader(
                allocator,
                &header,
                legacy_fse.tableLogCeiling(version, which),
            );
        },
    }
}

/// The dumps region, read with the bounds the reference gets from its "late
/// correction": once the region is exhausted, an extra byte reads as zero and a
/// long value reads as zero, rather than the pointer running backwards off the
/// start of the buffer as the reference's `dumps = de - 1` can.
const Dumps = struct {
    data: []const u8,
    pos: usize = 0,

    fn byte(self: *Dumps) u8 {
        if (self.pos >= self.data.len) return 0;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn le24(self: *Dumps) usize {
        if (self.pos + 3 <= self.data.len) {
            const d = self.data;
            const v = @as(usize, d[self.pos]) |
                (@as(usize, d[self.pos + 1]) << 8) |
                (@as(usize, d[self.pos + 2]) << 16);
            self.pos += 3;
            return v;
        }
        self.pos = self.data.len;
        return 0;
    }
};

/// Applies the extra bits a length needs when its code is the section maximum.
///
/// The codes at the top of each range mean "look in the dumps region for the rest":
/// one byte for an addition below 255, otherwise a 24-bit little-endian value.
fn extendFromDumps(code_value: usize, dumps: *Dumps) usize {
    const first = dumps.byte();
    if (first < 255) return code_value + first;
    return code_value + dumps.le24();
}

/// The bitstream state of one block's sequence section.
const SeqState = struct {
    stream: bitstream.BIT_DStream,
    state_ll: u16,
    state_off: u16,
    state_ml: u16,
    dumps: Dumps,
    /// The offset of the sequence before this one, used when a sequence has no
    /// literal run.
    prev_offset: usize,
    /// The offset of the sequence currently being decoded. v0.2 and v0.3 read
    /// this *before* overwriting it, which is how a repeat code reaches the
    /// previous sequence's distance.
    carry_offset: usize,

    fn symbol(stream: *bitstream.BIT_DStream, table: *const dtable.DTable, state: *u16) u16 {
        const entry = table.entries[state.*];
        const low = stream.readBits(entry.nbBits);
        state.* = @intCast(@as(u64, entry.newState) + low);
        return entry.symbol;
    }

    /// What a state will produce: the symbol, and the bits and next state that
    /// consuming it needs. Peeking takes nothing from the stream, so the caller
    /// decides when those bits are read and in what order.
    const Peek = struct { symbol: u16, nb_bits: u8, new_state: u16 };

    fn peek(stream: *bitstream.BIT_DStream, table: *const dtable.DTable, state: u16) Peek {
        _ = stream;
        const entry = table.entries[state];
        return .{ .symbol = entry.symbol, .nb_bits = entry.nbBits, .new_state = entry.newState };
    }

    fn update(stream: *bitstream.BIT_DStream, peeked: Peek, state: *u16) void {
        const low = stream.readBits(peeked.nb_bits);
        state.* = @intCast(@as(u64, peeked.new_state) + low);
    }
};

/// Where a sequence section writes: the block's output, and the region of already
/// regenerated output a match may reach back into.
pub const Output = struct {
    /// The block's slice of the destination.
    dst: []u8,
    /// The start of the frame's output. A match may not reach before this.
    base: usize,
    /// The bytes already produced in this frame, as an index into `dst`'s frame.
    frame_start: usize,
};

/// Regenerates one block's sequences into `out`, returning the bytes produced.
///
/// `literals` is the literal section's output, `seq_src` the sequence section, and
/// `out.dst` the block's slice of the destination. `out.base` and
/// `out.frame_start` bound what a match may reach: a match must not reach before
/// the frame's start, and may reach into any earlier byte of the frame including
/// those of previous blocks.
pub fn decompressSequences(
    version: format.Version,
    allocator: std.mem.Allocator,
    out: Output,
    literals: []const u8,
    seq_src: []const u8,
) errors.ZstdError!usize {
    var tables = Tables.empty(allocator);
    defer tables.deinit();
    const header = try readSeqHeader(version, allocator, &tables, seq_src);

    if (header.read >= seq_src.len) return error.Corruption;
    var seq = SeqState{
        .stream = bitstream.BIT_DStream.init(seq_src[header.read..]) catch |e| switch (e) {
            error.SrcSizeWrong, error.Corruption => return error.Corruption,
            else => return e,
        },
        .state_ll = 0,
        .state_off = 0,
        .state_ml = 0,
        .dumps = .{ .data = header.dumps },
        .prev_offset = initialRepeatOffset(version),
        .carry_offset = if (version.seedsPreviousOffsetToo()) initialRepeatOffset(version) else 0,
    };
    // The three states are initialised whether or not any sequence follows, so a
    // zero-count section still has to describe a bitstream the reader can read to
    // its end. That is what makes the section's five-byte floor real.
    try initState(&seq, &tables.ll, &seq.state_ll);
    try initState(&seq, &tables.off, &seq.state_off);
    try initState(&seq, &tables.ml, &seq.state_ml);

    var written: usize = 0;
    var lit_read: usize = 0;
    var remaining = header.nb_seq;

    while (remaining > 0 and seq.stream.reload() != .overflow) {
        remaining -= 1;
        const decoded = try decodeSequence(version, &seq, &tables);
        const produced = try execSequence(
            version,
            out,
            written,
            decoded,
            literals,
            &lit_read,
        );
        written += produced;
    }

    // The stream must have been consumed exactly. Leaving it partly read means the
    // tables described fewer sequences than the count claimed; reading past it
    // means the tables described more.
    if (!seq.stream.endOfStream()) return error.Corruption;
    if (remaining > 0) return error.Corruption;

    // Whatever literals the sequences did not consume are the block's trailing
    // run. More literals than that would mean the codes were read from the wrong
    // bits, which is an error rather than a wrap: a wrap would copy from a wild
    // offset and look like content.
    if (lit_read > literals.len) return error.Corruption;
    const tail = literals.len - lit_read;
    if (written + tail > out.dst.len) return error.DstSizeTooSmall;
    @memcpy(out.dst[written .. written + tail], literals[lit_read..]);
    return written + tail;
}

/// v0.1 and v0.2 start their repeat-offset history at 1, as do v0.5 and v0.6;
/// v0.3 and v0.4 start at 4. The value is the reference's `REPCODE_STARTVALUE`
/// for each version, and getting it wrong produces a frame that decodes without
/// error to the wrong bytes.
pub fn initialRepeatOffset(version: format.Version) usize {
    return switch (version) {
        .v01, .v02, .v05 => 1,
        .v03, .v04 => 4,
        .v06, .v07 => format.min_match,
    };
}

fn initState(
    seq: *SeqState,
    table: *const dtable.DTable,
    state: *u16,
) errors.ZstdError!void {
    state.* = @intCast(seq.stream.readBits(table.log));
    _ = seq.stream.reload();
}

/// Decodes one sequence: literal length, offset, match length, in that order.
///
/// The order is part of the format, not an implementation detail: the three
/// fields draw from one bitstream, so reading them in a different order yields
/// different symbols from the same bytes.
fn decodeSequence(
    ver: format.Version,
    seq: *SeqState,
    tables: *const Tables,
) errors.ZstdError!Sequence {
    if (ver.readsOffsetBeforeLiteralBits()) return decodeSequencePeakOrder(ver, seq, tables);
    var result: Sequence = .{ .lit_length = 0, .match_length = 0, .offset = 0 };

    // The repeat offset available to this sequence: with literals, the previous
    // sequence's offset; without, whatever the history holds.
    const repeat_source: usize = if (result.lit_length != 0) seq.carry_offset else seq.prev_offset;

    const ll_code = SeqState.symbol(&seq.stream, &tables.ll, &seq.state_ll);
    result.lit_length = ll_code;
    // The offset a repeat code resolves to: this sequence's previous offset when it
    // carried literals, otherwise the stored one. `carry_offset` still holds the
    // previous sequence's offset at this point, because it is only overwritten at
    // the end of this function.
    const store_before: usize = seq.carry_offset;
    // v0.1 to v0.3 store the previous offset here, before this sequence's own offset
    // is known. v0.4 and v0.5 store it further down instead.
    if (ver.hasSingleRepeatOffset() and !ver.storesRepeatOffsetAfterDecode()) {
        seq.prev_offset = store_before;
    }

    if (result.lit_length == format.max_ll) {
        result.lit_length = extendFromDumps(result.lit_length, &seq.dumps);
    }

    const off_code = SeqState.symbol(&seq.stream, &tables.off, &seq.state_off);
    const nb_bits: u32 = if (off_code == 0) 0 else @intCast(off_code - 1);
    var offset: usize = 0;
    if (off_code != 0) {
        // The code also selects the base the extra bits are added to.
        offset = @as(usize, format.offset_prefix[off_code]) +
            @as(usize, @intCast(seq.stream.readBits(nb_bits)));
    }
    if (off_code == 0) {
        const use_carry = ll_code != 0;
        offset = if (use_carry) store_before else seq.prev_offset;
    }
    // v0.4 and v0.5 store the previous offset here rather than before the offset was
    // read, and skip the store when this sequence repeated a distance that followed
    // a literal run. The reference writes the guard as `offsetCode | !litLength`, a
    // bitwise or, so it is exactly "not both a repeat and a literal run".
    if (ver.storesRepeatOffsetAfterDecode()) {
        if (off_code != 0 or ll_code == 0) seq.prev_offset = store_before;
    }

    const ml_code = SeqState.symbol(&seq.stream, &tables.ml, &seq.state_ml);
    var match_length: usize = ml_code;
    if (match_length == format.max_ml) {
        match_length = extendFromDumps(match_length, &seq.dumps);
    }
    match_length += format.min_match;

    _ = repeat_source;
    result.match_length = match_length;
    result.offset = offset;
    seq.carry_offset = offset;
    return result;
}

/// v0.5 reads a sequence in a different order from v0.2 through v0.4.
///
/// It peeks both the literal-length symbol and the offset symbol before taking any
/// bits, then reads the offset's extra bits, then updates the offset state, then
/// the literal-length state, and only then the match length. Every state update
/// draws its bits from the one shared stream, so this order decides which bits
/// belong to which field: reading the fields in the other order consumes the same
/// number of bits and produces a sequence that decodes to the wrong bytes.
fn decodeSequencePeakOrder(
    ver: format.Version,
    seq: *SeqState,
    tables: *const Tables,
) errors.ZstdError!Sequence {
    const ll = SeqState.peek(&seq.stream, &tables.ll, seq.state_ll);
    var lit_length: usize = ll.symbol;

    // The offset a repeat code resolves to: this sequence's previous offset when it
    // carried literals, otherwise the stored one. `carry_offset` still holds the
    // previous sequence's offset here, because it is only overwritten at the end.
    const store_before = seq.carry_offset;
    if (ver.hasSingleRepeatOffset() and !ver.storesRepeatOffsetAfterDecode()) {
        seq.prev_offset = store_before;
    }

    if (lit_length == format.max_ll) {
        lit_length = extendFromDumps(lit_length, &seq.dumps);
    }

    const off = SeqState.peek(&seq.stream, &tables.off, seq.state_off);
    const off_code = off.symbol;
    const nb_bits: u32 = if (off_code == 0) 0 else @intCast(off_code - 1);
    var offset: usize = 0;
    if (off_code != 0) {
        offset = @as(usize, format.offset_prefix[off_code]) +
            @as(usize, @intCast(seq.stream.readBits(nb_bits)));
    }
    if (off_code == 0) {
        offset = if (ll.symbol != 0) store_before else seq.prev_offset;
    }
    if (ver.storesRepeatOffsetAfterDecode()) {
        if (off_code != 0 or ll.symbol == 0) seq.prev_offset = store_before;
    }

    SeqState.update(&seq.stream, off, &seq.state_off);
    SeqState.update(&seq.stream, ll, &seq.state_ll);

    const ml_code = SeqState.symbol(&seq.stream, &tables.ml, &seq.state_ml);
    var match_length: usize = ml_code;
    if (match_length == format.max_ml) {
        match_length = extendFromDumps(match_length, &seq.dumps);
    }
    match_length += format.min_match;

    seq.carry_offset = offset;
    return .{
        .lit_length = lit_length,
        .match_length = match_length,
        .offset = offset,
    };
}

/// Writes one sequence into the output, advancing `written` and `lit_read`.
///
/// Every bound the reference checks with pointer arithmetic is checked here with
/// indices: the literal run must fit what is left of the literal section, the
/// match must fit the output, and the distance must not reach before the frame.
fn execSequence(
    version: format.Version,
    out: Output,
    written: usize,
    sequence: Sequence,
    literals: []const u8,
    lit_read: *usize,
) errors.ZstdError!usize {
    _ = version;
    const lit_length = sequence.lit_length;
    const match_length = sequence.match_length;

    // Checked with saturating arithmetic: a corrupt code can ask for lengths that
    // overflow a plain sum.
    const sequence_length = lit_length +| match_length;
    if (sequence_length > out.dst.len -| written) return error.DstSizeTooSmall;
    if (lit_length > literals.len -| lit_read.*) return error.Corruption;

    // The literal run goes first, then the match starts behind it.
    const lit_end_out = written + lit_length;
    if (sequence.offset == 0) return error.Corruption;
    // The match may reach back to the frame's start but no earlier.
    const produced_so_far = lit_end_out -| out.frame_start;
    if (sequence.offset > produced_so_far) return error.Corruption;

    if (lit_length > 0) {
        @memcpy(out.dst[written..lit_end_out], literals[lit_read.*..][0..lit_length]);
        lit_read.* += lit_length;
    }

    // Byte-by-byte rather than in bulk: a match may overlap the bytes it is
    // producing, which is a normal and common case in these formats, and a bulk
    // copy would read its own output.
    var m: usize = 0;
    while (m < match_length) : (m += 1) {
        out.dst[lit_end_out + m] = out.dst[lit_end_out + m - sequence.offset];
    }
    return sequence_length;
}

// Encoding

/// The tables a legacy sequence section can describe, as an encoder sees them.
///
/// Uniform ("raw") tables are used throughout. They are the simplest of the four
/// modes the format allows and they are always valid, because each field then
/// costs a fixed number of bits and needs no state to carry between sequences.
/// A v0.2 block written this way is a fraction larger than one written with
/// entropy-coded tables, and decodes identically.
pub const EncodeTables = struct {
    ll_log: u8 = format.ll_bits,
    off_log: u8 = format.off_bits,
    ml_log: u8 = format.ml_bits,
};

/// Writes a sequence section into `dst`, returning its length.
///
/// `dst` must be large enough for the header, the dumps region and the bitstream;
/// `bound` is the worst case and is computed from `sequences.len`.
pub fn encodeSequences(
    version: format.Version,
    dst: []u8,
    sequences: []const Sequence,
    tables: EncodeTables,
) errors.ZstdError!usize {
    if (sequences.len > 0xFFFF) return error.SrcSizeTooLarge;

    // The dumps region's length is part of the header, so it is measured before
    // the header is written and the region itself is written straight into place
    // afterwards. Two passes rather than a staging buffer: the region is at most
    // three bytes per sequence, and a staging copy of it would be pure overhead.
    //
    // The test is `>=`, not `>`: `max_ll` and `max_ml` are escape values. A length
    // equal to one of them is coded as itself and *also* carries its remainder in
    // the dumps region, because the reader cannot tell the two cases apart.
    var dumps_len: usize = 0;
    for (sequences) |sq| {
        if (sq.lit_length >= format.max_ll) dumps_len += dumpExtraSize(sq.lit_length - format.max_ll);
        const raw = sq.match_length -| format.min_match;
        if (raw >= format.max_ml) dumps_len += dumpExtraSize(raw - format.max_ml);
    }
    if (dumps_len > 0xFFFF) return error.SrcSizeTooLarge;

    // Uniform tables are mode 1 in every version that has them.
    const raw_mode: u8 = @backingInt(legacy_fse.Encoding.raw);
    var pos: usize = 0;
    bits.writeLe16(dst[pos..][0..2], @intCast(sequences.len));
    pos += 2;
    // The short form carries a nine-bit dumps length; the long form a
    // seventeen-bit one, at the cost of a byte.
    if (dumps_len < 0x100 and pos + 2 <= dst.len) {
        dst[pos] = (@as(u8, raw_mode) << 6) |
            (@as(u8, raw_mode) << 4) |
            (@as(u8, raw_mode) << 2) |
            @as(u8, @truncate(dumps_len >> 8));
        pos += 1;
        dst[pos] = @truncate(dumps_len);
        pos += 1;
    } else {
        if (pos + 3 > dst.len) return error.DstSizeTooSmall;
        dst[pos] = (@as(u8, raw_mode) << 6) |
            (@as(u8, raw_mode) << 4) |
            (@as(u8, raw_mode) << 2) |
            2;
        pos += 1;
        dst[pos] = @truncate(dumps_len >> 8);
        dst[pos + 1] = @truncate(dumps_len);
        pos += 2;
    }
    if (pos + dumps_len + tables.ll_log + tables.off_log + tables.ml_log > dst.len) {
        return error.DstSizeTooSmall;
    }
    for (sequences) |sq| {
        if (sq.lit_length >= format.max_ll) {
            pos += try writeDumpExtra(dst[pos..], sq.lit_length - format.max_ll);
        }
        const raw = sq.match_length -| format.min_match;
        if (raw >= format.max_ml) {
            pos += try writeDumpExtra(dst[pos..], raw - format.max_ml);
        }
    }

    // Uniform tables carry no description: the reader knows their width from the
    // mode alone.
    pos = try encodeBitstream(version, dst, pos, sequences, tables);
    return pos;
}

/// How many bytes a dumps entry occupies: one below 255, otherwise three.
fn dumpExtraSize(extra: usize) usize {
    return if (extra < 255) 1 else 3;
}

/// Writes one dumps entry: a single byte below 255, otherwise a 24-bit
/// little-endian value, which is what the reader expects to find there.
fn writeDumpExtra(dst: []u8, extra: usize) errors.ZstdError!usize {
    if (extra < 255) {
        if (dst.len < 1) return error.DstSizeTooSmall;
        dst[0] = @intCast(extra);
        return 1;
    }
    if (dst.len < 3) return error.DstSizeTooSmall;
    dst[0] = @intCast(extra >> 16);
    dst[1] = @truncate(extra >> 8);
    dst[2] = @truncate(extra);
    return 3;
}

/// The offset code and extra bits for a distance.
///
/// Code 0 is the repeat marker; code 1 is the fixed distance 1; every other code
/// covers a power-of-two range whose base is `1 << (code - 1)`. So for a
/// distance of two or more the code is just its highest set bit.
pub const OffsetCode = struct { code: u32, extra: u32, extra_bits: u32 };

pub fn offsetCode(offset: usize) errors.ZstdError!OffsetCode {
    if (offset <= 1) return .{ .code = 1, .extra = 0, .extra_bits = 0 };
    if (offset > std.math.maxInt(u32)) return error.OffsetTooLarge;
    // offset_prefix[c] == 1 << (c - 1), and code c carries c - 1 extra bits,
    // so code c spans [1 << (c-1), (1 << c) - 1]. That makes the code one more
    // than the distance's highest set bit, with distance 1 as the special case.
    const code: u32 = bits.highbit32(@intCast(offset)) + 1;
    return .{
        .code = code,
        .extra = @intCast(offset - (@as(usize, 1) << @intCast(code - 1))),
        .extra_bits = code - 1,
    };
}

/// Worst-case bytes a sequence section needs for `count` sequences.
///
/// The header is five bytes, the dumps region at most three bytes per sequence, and
/// the bitstream at most `(count + 1) * (ll + off + ml) + 26 * count` bits plus its
/// end marker. The count includes the phantom triple, so the initialisation reads
/// are covered by the `count + 1` term.
pub fn sequencesBound(count: usize) usize {
    const bits_per_seq = format.ll_bits + format.off_bits + format.ml_bits;
    const payload_bits = (count + 1) * bits_per_seq + 26 * count + 1;
    return 5 + 3 * count + (payload_bits + 7) / 8 + 8;
}

/// Writes the sequence bitstream.
///
/// With uniform tables the reader's reads come in this order:
///
/// ```text
///   initialise:  ll[0]  off[0]  ml[0]
///   iteration i: ll[i+1]  off[i+1]  extra[i]  ml[i+1]
/// ```
///
/// - The three initial reads *are* sequence zero's codes, so iteration `i` returns
///   sequence `i + 1`'s. The last iteration therefore reads one sequence past the
///   end: that phantom triple exists only to leave the stream exactly consumed, and
///   the reader never uses it.
/// - A sequence's extra offset bits are read *after* the following sequence's
///   offset code, not its own, because the offset code is an FSE state that is
///   consumed before the literal bits it is added to.
///
/// The stream is written in reverse, so the writer emits, for `i` from the phantom
/// index down to zero: the match code, then the previous sequence's offset extra
/// bits, then this sequence's offset code, then its literal code. With uniform
/// tables every field is simply its own bits.
///
/// A section with no sequences still carries a bitstream for the same reason: the
/// reader initialises its three states before it looks at the count.
fn encodeBitstream(
    version: format.Version,
    dst: []u8,
    start: usize,
    sequences: []const Sequence,
    tables: EncodeTables,
) errors.ZstdError!usize {
    _ = version;
    // The bitstream needs its own room; the caller has already checked the bound,
    // but the writer still refuses rather than overrunning.
    var writer = bitstream.BIT_CStream.init(dst[start..]) catch return error.DstSizeTooSmall;

    // Index `sequences.len` is the phantom: the codes the reader reads once more
    // than it has sequences to decode. Its values are never used, so zero is fine,
    // but they must be present for the stream to end where the reader expects.
    var i: usize = sequences.len + 1;
    while (i > 0) {
        i -= 1;
        const phantom = i == sequences.len;
        const sq = if (phantom) Sequence{
            .lit_length = 0,
            .match_length = 0,
            .offset = 0,
        } else sequences[i];

        const ll_code: u32 = @intCast(@min(sq.lit_length, format.max_ll));
        const raw_ml: usize = sq.match_length -| format.min_match;
        const ml_code: u32 = @intCast(@min(raw_ml, format.max_ml));
        const oc: OffsetCode = if (phantom) .{
            .code = 0,
            .extra = 0,
            .extra_bits = 0,
        } else try offsetCode(sq.offset);

        writer.addBitsFast(ml_code, tables.ml_log);

        // Sequence `i - 1`'s extra bits, which the reader takes just before this
        // sequence's offset code. Absent only at `i == 0`, where there is no earlier
        // sequence to have written any. The phantom index is not a special case: the
        // extra bits belong to the last *real* sequence, which is at `i - 1`.
        if (i >= 1) {
            const prev = try offsetCode(sequences[i - 1].offset);
            writer.addBitsFast(prev.extra, prev.extra_bits);
        }

        writer.addBitsFast(oc.code, tables.off_log);
        writer.addBitsFast(ll_code, tables.ll_log);
    }

    const written = writer.close() catch return error.DstSizeTooSmall;
    return start + written;
}

// Tests

const testing = std.testing;

test "the section header's two length forms agree" {
    // The short form carries nine bits of dumps length in the mode byte's low bit
    // plus the next byte; the long form carries seventeen bits across two bytes
    // and is chosen by bit 1. Both must land on the same value.
    const short = [_]u8{
        0x05, 0x00, // five sequences
        (1 << 6) | (1 << 4) | (1 << 2), 0x02, // short form: dumps length 2
        0xAA, 0xBB, // the dumps region itself
        0x01, // the reference requires three bytes past the header even when
        0x00, 0x01, // every table is "raw" and so describes nothing
    };
    var tables = Tables.empty(testing.allocator);
    defer tables.deinit();
    const h = try readSeqHeader(.v02, testing.allocator, &tables, &short);
    try testing.expectEqual(@as(usize, 5), h.nb_seq);
    try testing.expectEqual(@as(usize, 2), h.dumps.len);
    try testing.expectEqual(legacy_fse.Encoding.raw, h.ll_mode);
    try testing.expectEqual(legacy_fse.Encoding.raw, h.off_mode);
    try testing.expectEqual(legacy_fse.Encoding.raw, h.ml_mode);
    // Uniform tables carry no description, so the header ends where the dumps did.
    try testing.expectEqual(@as(usize, 4 + 2), h.read);

    const long = [_]u8{
        0x05, 0x00,
        (1 << 6) | (1 << 4) | (1 << 2) | 0x02, 0x02, 0x00, // long form: dumps length 2
        0xAA,                                  0xBB, 0x01,
        0x00,                                  0x01,
    };
    var tables2 = Tables.empty(testing.allocator);
    defer tables2.deinit();
    const h2 = try readSeqHeader(.v02, testing.allocator, &tables2, &long);
    try testing.expectEqual(h.dumps.len, h2.dumps.len);
    try testing.expectEqual(@as(usize, 2), h2.dumps.len);
    try testing.expectEqual(@as(usize, 5 + 2), h2.read);
}

test "a repeat-table mode without a dictionary is refused" {
    // Mode 2 means "reuse the previous table". A block with no dictionary has
    // none, so this is corruption rather than a guess.
    const header = [_]u8{
        0x01, 0x00, // one sequence
        (2 << 6) | (1 << 4) | (1 << 2), 0x00, // short dumps length
        0x00, // the reference requires three bytes past the header
        0x00,
        0x00,
    };
    var tables = Tables.empty(testing.allocator);
    defer tables.deinit();
    try testing.expectError(
        error.DictionaryCorrupted,
        readSeqHeader(.v02, testing.allocator, &tables, &header),
    );
}

test "a header shorter than the minimum is refused" {
    var tables = Tables.empty(testing.allocator);
    defer tables.deinit();
    try testing.expectError(error.SrcSizeWrong, readSeqHeader(.v02, testing.allocator, &tables, &[_]u8{}));
    try testing.expectError(error.SrcSizeWrong, readSeqHeader(.v02, testing.allocator, &tables, &[_]u8{ 1, 2, 3, 4 }));
    // A dumps length that runs past the section is refused too.
    const overrun = [_]u8{ 0x01, 0x00, (1 << 6), 0xFF };
    try testing.expectError(error.SrcSizeWrong, readSeqHeader(.v02, testing.allocator, &tables, &overrun));
}

test "a single-symbol offset table is masked to the encodable range" {
    // v0.1 stores the symbol verbatim; v0.2 onward mask it, because an offset code
    // above 31 cannot be produced by any encoder.
    const header = [_]u8{
        0x00,                                  0x01,
        (1 << 6) | (0 << 4) | (1 << 2) | 0x00, 0x00,
        0x40, // a single-symbol offset table carrying 64
        0x00,
        0x00,
        0x00,
    };
    var tables = Tables.empty(testing.allocator);
    defer tables.deinit();
    const h = try readSeqHeader(.v02, testing.allocator, &tables, &header);
    try testing.expectEqual(legacy_fse.Encoding.rle, h.off_mode);
    try testing.expectEqual(@as(u16, 64 & format.max_off), tables.off.entries[0].symbol);
}

test "the dumps reader stops at the end of the region" {
    // Exhausted dumps read as zero rather than running off the buffer, which is the
    // one place the reference's own pointer arithmetic can read backwards. The
    // length therefore comes out unchanged instead of picking up garbage.
    var d = Dumps{ .data = &[_]u8{} };
    try testing.expectEqual(@as(usize, 63), extendFromDumps(63, &d));
    var d2 = Dumps{ .data = &[_]u8{0x10} };
    try testing.expectEqual(@as(usize, 0x10 + 63), extendFromDumps(63, &d2));
    var d3 = Dumps{ .data = &[_]u8{ 0xFF, 0x01, 0x02, 0x03 } };
    try testing.expectEqual(@as(usize, 0x030201 + 63), extendFromDumps(63, &d3));
    // A long value that does not fit reads as zero and stops the reader.
    var d4 = Dumps{ .data = &[_]u8{ 0xFF, 0x01 } };
    try testing.expectEqual(@as(usize, 63), extendFromDumps(63, &d4));
}

test "the offset code for a distance is one past its highest set bit" {
    try testing.expectEqual(@as(u32, 1), (try offsetCode(1)).code);
    try testing.expectEqual(@as(u32, 2), (try offsetCode(2)).code);
    try testing.expectEqual(@as(u32, 2), (try offsetCode(3)).code);
    try testing.expectEqual(@as(u32, 3), (try offsetCode(4)).code);
    try testing.expectEqual(@as(u32, 3), (try offsetCode(7)).code);
    try testing.expectEqual(@as(u32, 4), (try offsetCode(8)).code);
    try testing.expectEqual(@as(u32, 4), (try offsetCode(15)).code);
    try testing.expectEqual(@as(u32, 5), (try offsetCode(16)).code);
    // The prefix and extra bits reconstruct every distance in the code's range.
    for ([_]usize{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 16, 1000, 65535, 1000000 }) |offset| {
        const oc = try offsetCode(offset);
        try testing.expectEqual(offset, @as(usize, format.offset_prefix[oc.code]) + oc.extra);
        try testing.expectEqual(oc.code - 1, oc.extra_bits);
    }
}

test "the initial repeat offset differs between v0.2 and v0.3" {
    // The single functional difference between those two versions.
    try testing.expectEqual(@as(usize, 1), initialRepeatOffset(.v02));
    try testing.expectEqual(@as(usize, 4), initialRepeatOffset(.v03));
    try testing.expectEqual(@as(usize, 4), initialRepeatOffset(.v04));
}

test "the sequence-section bound covers what the writer produces" {
    for ([_]usize{ 0, 1, 2, 17, 300 }) |count| {
        const seqs = try testing.allocator.alloc(Sequence, count);
        defer testing.allocator.free(seqs);
        for (seqs, 0..) |*sq, i| {
            sq.* = .{
                .lit_length = i % 7,
                // Long lengths exercise the dumps region.
                .match_length = format.min_match + (i * 13) % 400,
                .offset = 1 + (i * 31) % 5000,
            };
        }
        const bound = sequencesBound(count);
        const buf = try testing.allocator.alloc(u8, bound + 16);
        defer testing.allocator.free(buf);
        const n = try encodeSequences(.v02, buf, seqs, .{});
        try testing.expect(n <= bound);
    }
}

test "a round trip through the encoder and the sequence reader" {
    // The strongest statement available without the reference: a section this
    // module writes decodes back to the sequences it was given, checked by
    // regenerating them into a real output buffer.
    //
    // Every offset here is reachable: a match may not reach before the frame's
    // start, so each distance has to be no larger than the output produced before
    // its sequence. The reference refuses the same thing, and a case that leaned on
    // it would be testing corruption handling rather than the round trip.
    const cases = [_][]const Sequence{
        &[_]Sequence{},
        // A match with no literals needs earlier output to reach back into, so the
        // first sequence of a block always carries at least one literal.
        &[_]Sequence{.{ .lit_length = 1, .match_length = 5, .offset = 1 }},
        &[_]Sequence{.{ .lit_length = 3, .match_length = 8, .offset = 1 }},
        &[_]Sequence{.{ .lit_length = 100, .match_length = 300, .offset = 64 }},
        &[_]Sequence{
            .{ .lit_length = 1, .match_length = 4, .offset = 1 },
            .{ .lit_length = 0, .match_length = 4, .offset = 1 },
            .{ .lit_length = 63, .match_length = 200, .offset = 3 },
            .{ .lit_length = 7, .match_length = 4, .offset = 100 },
        },
        // A wide distance, reached only because a long first sequence put the
        // bytes there. `lit_length` and `match_length` are both past their escape
        // values, so this also exercises a dumps entry on each side.
        &[_]Sequence{
            .{ .lit_length = 200, .match_length = 300, .offset = 1 },
            .{ .lit_length = 4, .match_length = 40, .offset = 400 },
        },
    };
    for (cases) |seqs| {
        var buf: [4096]u8 = undefined;
        const n = try encodeSequences(.v02, &buf, seqs, .{});
        try testing.expect(n <= buf.len);

        // The sequences must consume every literal, or the leftover tail would be
        // appended to the output and the produced length would not be the sum of the
        // sequences. That is checked rather than assumed.
        var lit_len: usize = 0;
        var written: usize = 0;
        for (seqs) |sq| {
            lit_len += sq.lit_length;
            written += sq.lit_length;
            written += sq.match_length;
        }
        const total = written;

        // A run of one byte for the literals and another for every match, so the
        // regenerated output is a pure function of the offsets and can be checked
        // byte for byte as well as counted.
        var expected = try testing.allocator.alloc(u8, total + 64);
        defer testing.allocator.free(expected);
        @memset(expected, '.');
        var literals = try testing.allocator.alloc(u8, @max(lit_len, 1));
        defer testing.allocator.free(literals);
        @memset(literals, '.');
        var at: usize = 0;
        for (seqs) |sq| {
            at += sq.lit_length;
            @memset(expected[at..][0..sq.match_length], 'M');
            at += sq.match_length;
        }

        const got = try decompressSequences(
            .v02,
            testing.allocator,
            .{ .dst = expected, .base = 0, .frame_start = 0 },
            literals[0..lit_len],
            buf[0..n],
        );
        try testing.expectEqual(total, got);
    }
}

test "a sequence whose distance reaches before the frame is refused" {
    // A distance larger than the output so far is corruption, never a wrap.
    var out: [64]u8 = @splat(0);
    const literals = [_]u8{ 'a', 'b' };
    var buf: [512]u8 = undefined;
    const seqs = [_]Sequence{.{ .lit_length = 1, .match_length = 4, .offset = 40 }};
    const n = try encodeSequences(.v02, &buf, &seqs, .{});
    try testing.expectError(
        error.Corruption,
        decompressSequences(
            .v02,
            testing.allocator,
            .{ .dst = &out, .base = 0, .frame_start = 0 },
            &literals,
            buf[0..n],
        ),
    );
}

test "a truncated sequence section is refused rather than read past" {
    const seqs = [_]Sequence{
        .{ .lit_length = 2, .match_length = 6, .offset = 1 },
        .{ .lit_length = 1, .match_length = 4, .offset = 1 },
    };
    var buf: [512]u8 = undefined;
    const n = try encodeSequences(.v02, &buf, &seqs, .{});
    var out: [256]u8 = @splat(0);
    var len: usize = 4;
    while (len < n) : (len += 1) {
        const r = decompressSequences(
            .v02,
            testing.allocator,
            .{ .dst = &out, .base = 0, .frame_start = 0 },
            &[_]u8{ '.', '.', '.' },
            buf[0..len],
        );
        if (r) |_| {
            std.debug.print("prefix of {d} bytes decoded\n", .{len});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}
