//! Prepared dictionaries: dictionary state built once and reused.
//!
//! A raw dictionary is content a frame's first matches reach back into. A prepared
//! one also carries, after its magic and ID, the entropy tables describing that
//! content (a Huffman literal table, FSE normalized counts for the three sequence
//! code sets, and the three repeat offsets in use when it was built), which a
//! frame compressed against it can inherit instead of re-deriving.
//!
//! Layout, all little-endian: magic 0xEC30A437, dictionary ID, Huffman table,
//! then FSE normalized counts for offsets, match lengths and literal lengths in
//! that order, then three repeat offsets, then the content. A `PreparedDictionary`
//! owns its buffer and every table built from it, freeing all of them in `deinit`.
//! Several contexts may read from one prepared dictionary at once: preparation
//! produces no mutable state, and each context keeps what it advances.
const std = @import("std");
const bits = @import("../common/bits.zig");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const ncount = @import("../fse/ncount.zig");
const dtable = @import("../fse/dtable.zig");
const huff = @import("../huffman/decompress.zig");
/// Repeat offsets a dictionary was encoded with. They seed a fresh frame's
/// history so the first sequences can use them as repeat codes.
pub const RepeatOffsets = struct {
    r0: u32,
    r1: u32,
    r2: u32,

    pub const initial = RepeatOffsets{ .r0 = 1, .r1 = 4, .r2 = 8 };
};
/// How a code table is described in a prepared dictionary: FSE normalized counts
/// plus whether they may be reused as-is for the next frame. `reuse` is the
/// format's repeat mode: counts covering the full symbol range cleanly can be
/// copied forward, counts with gaps must be checked against each frame. Getting
/// this wrong produces frames no conforming decoder accepts.
const DictCode = struct {
    table: dtable.DTable,
    /// Largest symbol the counts described.
    max_symbol: u32,
    /// True when the counts may be reused verbatim for the next frame.
    reusable: bool,

    fn deinit(self: *DictCode) void {
        self.table.deinit();
    }
};
/// Entropy state read out of a prepared dictionary, ready for a frame.
pub const EntropyTables = struct {
    /// Huffman table for literals. A prepared dictionary always carries one, so a
    /// frame compressed against it can repeat this table instead of writing its
    /// own.
    literals: ?huff.HuffDecoder,
    offsets: DictCode,
    match_lengths: DictCode,
    literal_lengths: DictCode,
    repeats: RepeatOffsets,

    fn deinit(self: *EntropyTables) void {
        if (self.literals) |*table| table.deinit();
        self.offsets.deinit();
        self.match_lengths.deinit();
        self.literal_lengths.deinit();
    }
};
pub const PreparedDictionary = struct {
    /// The dictionary exactly as loaded, magic and ID included. Kept so the
    /// bytes can be handed to a match finder or written back out unchanged.
    data: []u8,
    id: u32,
    allocator: std.mem.Allocator,

    /// Entropy tables built from `data`, or null when the dictionary is raw
    /// content with no tables to load.
    entropy: ?EntropyTables,

    /// True when the source bytes carried the prepared-dictionary magic, meaning
    /// they describe a real dictionary rather than plain content.
    is_prepared: bool,

    /// Byte offset into `data` where the dictionary content begins. Only the
    /// loader knows this, because it is where the tables end.
    content_offset: ?usize = null,

    pub fn deinit(self: *PreparedDictionary) void {
        if (self.entropy) |*e| e.deinit();
        self.allocator.free(self.data);
        self.* = undefined;
    }

    /// The bytes a frame's first matches may reach into. For a prepared
    /// dictionary this is the content that follows the tables; for a magic-prefixed
    /// buffer with no tables it is everything past the magic and ID; for raw
    /// content it is the whole buffer.
    pub fn content(self: *const PreparedDictionary) []const u8 {
        return self.contentBytes();
    }

    fn contentBytes(self: *const PreparedDictionary) []const u8 {
        const start = self.content_offset orelse return &.{};
        if (start >= self.data.len) return &.{};
        return self.data[start..];
    }

    /// Builds a prepared dictionary from raw content by wrapping it in the
    /// magic and ID. No entropy tables are produced: there is nothing to derive
    /// them from, so a frame compressed against this dictionary describes its
    /// own tables.
    pub fn fromContent(allocator: std.mem.Allocator, body: []const u8, id: u32) errors.ZstdError!PreparedDictionary {
        const buf = try allocator.alloc(u8, body.len + 8);
        errdefer allocator.free(buf);
        bits.writeLe32(buf[0..4], constants.magic_dictionary);
        bits.writeLe32(buf[4..8], id);
        std.mem.copyForwards(u8, buf[8..], body);
        return .{
            .data = buf,
            .id = id,
            .allocator = allocator,
            .entropy = null,
            .is_prepared = true,
            .content_offset = 8,
        };
    }

    /// Loads a dictionary, building its entropy tables when the bytes describe a
    /// prepared dictionary and treating them as plain content when they do not.
    ///
    /// This is the entry point for both forms, so a caller holding either kind of
    /// dictionary can hand it over without inspecting it first.
    pub fn prepare(allocator: std.mem.Allocator, source: []const u8) errors.ZstdError!PreparedDictionary {
        const buf = try allocator.alloc(u8, source.len);
        errdefer allocator.free(buf);
        std.mem.copyForwards(u8, buf, source);

        const has_magic = buf.len >= 8 and bits.readLe32(buf[0..4]) == constants.magic_dictionary;
        if (!has_magic) {
            // Raw content: no magic, so no ID and no tables. The whole buffer is
            // the content.
            return .{ .data = buf, .id = 0, .allocator = allocator, .entropy = null, .is_prepared = false, .content_offset = 0 };
        }

        const id = bits.readLe32(buf[4..8]);
        const loaded = try loadEntropy(allocator, buf[8..]);
        errdefer loaded.tables.deinit();
        return .{
            .data = buf,
            .id = id,
            .allocator = allocator,
            .entropy = loaded.tables,
            .is_prepared = true,
            // loaded.consumed counts bytes from just after the magic and ID,
            // so the content starts that far into the whole buffer.
            .content_offset = 8 + loaded.consumed,
        };
    }

    /// The entropy tables, or null when the dictionary carries none. A caller
    /// that wants to reuse prepared state must handle the raw case by describing
    /// its own tables.
    pub fn entropyTables(self: *const PreparedDictionary) ?*const EntropyTables {
        if (self.entropy) |*e| return e;
        return null;
    }

    /// The repeat offsets to seed a new frame with, or the format's initial
    /// values when the dictionary supplies none.
    pub fn repeats(self: *const PreparedDictionary) RepeatOffsets {
        if (self.entropy) |*e| return e.repeats;
        return RepeatOffsets.initial;
    }
};
/// Tables read from a dictionary, plus how many bytes they occupied so the
/// caller can find the content that follows.
const LoadedEntropy = struct { tables: EntropyTables, consumed: usize };
/// Reads the tables from `body`, which starts just after the magic and ID.
fn loadEntropy(allocator: std.mem.Allocator, body: []const u8) errors.ZstdError!LoadedEntropy {
    var pos: usize = 0;

    // Everything allocated along the way is registered here as it is built, and
    // released together on any failure. Registering per allocation would need each
    // site to know about the others, and one of them inevitably would not; a single
    // collector that grows as tables appear cannot get that wrong.
    var held = LoadedTables{};

    // Literals: a Huffman table description, read exactly as a block's would be.
    // A dictionary always carries one, so this is a plain parse.
    {
        var weights: [256]u8 = undefined;
        var ranks: [huff.max_table_log + 1]u32 = undefined;
        var nb_symbols: usize = 0;
        var table_log: u8 = 0;
        const description = try huff.readStats(&weights, &ranks, &nb_symbols, &table_log, body[pos..], allocator);
        if (description > body.len - pos) return error.DictionaryCorrupted;
        pos += description;
        held.literals = try huff.buildDecoder(allocator, weights[0..nb_symbols], table_log);
    }
    errdefer held.deinit();

    held.offsets = try loadCode(allocator, body[pos..], .offsets);
    pos += held.offsets.read;
    held.match_lengths = try loadCode(allocator, body[pos..], .match_lengths);
    pos += held.match_lengths.read;
    held.literal_lengths = try loadCode(allocator, body[pos..], .literal_lengths);
    pos += held.literal_lengths.read;

    // Three repeat offsets close the header; the content follows.
    if (body.len < pos + 12) return error.DictionaryCorrupted;
    const rep_bytes = body[pos..][0..12];
    const repeats = RepeatOffsets{
        .r0 = bits.readLe32(rep_bytes[0..4]),
        .r1 = bits.readLe32(rep_bytes[4..8]),
        .r2 = bits.readLe32(rep_bytes[8..12]),
    };
    pos += 12;

    return .{
        .tables = .{
            // Ownership moves out of `held`; it is left empty so the `errdefer`
            // above has nothing left to release on the way out.
            .literals = held.literals,
            .offsets = held.offsets.code,
            .match_lengths = held.match_lengths.code,
            .literal_lengths = held.literal_lengths.code,
            .repeats = repeats,
        },
        .consumed = pos,
    };
}
/// The tables read so far, so a failure at any point can release all of them.
///
/// Fields default to empty and are filled in as their tables are built, so a
/// failure before a field is reached releases nothing for it rather than
/// releasing something uninitialised.
const LoadedTables = struct {
    literals: ?huff.HuffDecoder = null,
    offsets: LoadedCode = .{},
    match_lengths: LoadedCode = .{},
    literal_lengths: LoadedCode = .{},

    fn deinit(self: *LoadedTables) void {
        if (self.literals) |*t| t.deinit();
        self.offsets.deinit();
        self.match_lengths.deinit();
        self.literal_lengths.deinit();
    }
};
/// Which code table is being read, so the right symbol ceiling is applied.
const CodeKind = enum { offsets, match_lengths, literal_lengths };
/// A code table plus the bytes its description occupied.
const LoadedCode = struct {
    code: DictCode = .{ .table = undefined, .max_symbol = 0, .reusable = false },
    read: usize = 0,

    /// Whether a table has actually been built, as opposed to the field still
    /// holding its default. `deinit` consults this so an unbuilt slot is not
    /// released.
    built: bool = false,

    fn deinit(self: *LoadedCode) void {
        if (!self.built) return;
        self.code.deinit();
        self.built = false;
    }
};
fn loadCode(allocator: std.mem.Allocator, src: []const u8, kind: CodeKind) errors.ZstdError!LoadedCode {
    const max_symbol: usize = switch (kind) {
        .offsets => constants.max_off,
        .match_lengths => constants.max_ml,
        .literal_lengths => constants.max_ll,
    };
    // The buffer has to fit the largest of the three ceilings, not the smallest:
    // the reader is handed the destination and fills up to the symbol limit for
    // the table being read, and those limits differ per table.
    var counts: [constants.max_ml + 1]i16 = undefined;
    var max_seen: usize = max_symbol;
    var table_log: u8 = 0;
    const read = try ncount.readNCount(counts[0 .. max_symbol + 1], &max_seen, &table_log, src);
    // `readNCount` reports the largest symbol it found, which a malformed
    // description can put past the ceiling for this table. Building from it
    // unchecked would read outside the buffer, so it is validated first.
    if (max_seen >= max_symbol + 1) return error.DictionaryCorrupted;
    const table = try dtable.build(allocator, counts[0 .. max_seen + 1], max_seen, table_log);
    return .{
        .built = true,
        .code = .{
            .table = table,
            .max_symbol = @intCast(max_seen),
            // Counts that covered the whole range can be written forward into the
            // next frame unchanged; anything else has to be re-derived.
            .reusable = max_seen == max_symbol,
        },
        .read = read,
    };
}
// Tests
const testing = std.testing;
fn expectRejected(result: anytype) !void {
    if (result) |prepared| {
        var owned = prepared;
        owned.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
}
const dictionary_mod = @import("dictionary.zig");
const compress_mod = @import("../compress/compress.zig");
const decompress_mod = @import("../decompress/decompress.zig");
const context_mod = @import("../decompress/context.zig");
/// A dictionary trained by the reference tool from 400 word-list samples, kept
/// verbatim as an interoperability fixture: magic `0xEC30A437`, ID `0x34CC419E`,
/// then a Huffman literal table (bytes 8..26), three FSE code tables, three
/// repeat offsets (bytes 94..106, all 1/4/8), and 404 bytes of content.
///
/// The content is the word list the samples were drawn from, which is why the
/// ID and the trailing text are both checkable by eye.
const reference_dictionary = [_]u8{
    0x37, 0xA4, 0x30, 0xEC, 0x9E, 0x41, 0xCC, 0x34, 0x15, 0x10, 0xE0, 0x0A,
    0xE9, 0xFF, 0xFF, 0xFF, 0xFF, 0x03, 0x7A, 0x1B, 0xEE, 0x2F, 0xAB, 0xAA,
    0xF0, 0xFA, 0x01, 0xA2, 0xD6, 0x02, 0x03, 0x00, 0x00, 0x00, 0x00, 0x5C,
    0x4D, 0xEB, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x80, 0x03, 0x00, 0x00, 0x8E, 0x00, 0x00, 0x00, 0x00, 0x3A, 0x01,
    0x07, 0x00, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC3, 0x39, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xE4, 0x1D, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x08, 0x00,
    0x00, 0x00, 0x6C, 0x70, 0x68, 0x61, 0x20, 0x62, 0x72, 0x61, 0x76, 0x6F,
    0x20, 0x63, 0x68, 0x61, 0x72, 0x6C, 0x69, 0x65, 0x20, 0x64, 0x65, 0x6C,
    0x74, 0x61, 0x20, 0x65, 0x63, 0x68, 0x6F, 0x20, 0x66, 0x6F, 0x78, 0x74,
    0x72, 0x6F, 0x74, 0x20, 0x67, 0x6F, 0x6C, 0x66, 0x20, 0x68, 0x6F, 0x74,
    0x65, 0x6C, 0x0D, 0x0A, 0x72, 0x61, 0x76, 0x6F, 0x20, 0x63, 0x68, 0x61,
    0x72, 0x6C, 0x69, 0x65, 0x20, 0x64, 0x65, 0x6C, 0x74, 0x61, 0x20, 0x65,
    0x63, 0x68, 0x6F, 0x20, 0x66, 0x6F, 0x78, 0x74, 0x72, 0x6F, 0x74, 0x20,
    0x67, 0x6F, 0x6C, 0x66, 0x20, 0x68, 0x6F, 0x74, 0x65, 0x6C, 0x20, 0x69,
    0x6E, 0x64, 0x69, 0x61, 0x0D, 0x0A, 0x61, 0x20, 0x6A, 0x75, 0x6C, 0x69,
    0x65, 0x74, 0x0D, 0x0A, 0x61, 0x6C, 0x70, 0x68, 0x61, 0x20, 0x62, 0x72,
    0x61, 0x76, 0x6F, 0x20, 0x63, 0x68, 0x61, 0x72, 0x6C, 0x6C, 0x69, 0x65,
    0x20, 0x64, 0x65, 0x6C, 0x74, 0x61, 0x20, 0x65, 0x63, 0x68, 0x6F, 0x20,
    0x66, 0x6F, 0x78, 0x74, 0x72, 0x6F, 0x74, 0x0D, 0x0A, 0x74, 0x65, 0x6C,
    0x20, 0x69, 0x6E, 0x64, 0x69, 0x61, 0x20, 0x6A, 0x75, 0x6C, 0x69, 0x65,
    0x74, 0x0D, 0x0A, 0x61, 0x6C, 0x70, 0x68, 0x61, 0x20, 0x62, 0x72, 0x61,
    0x76, 0x6F, 0x20, 0x63, 0x68, 0x61, 0x72, 0x6C, 0x6C, 0x69, 0x65, 0x20,
    0x64, 0x65, 0x6C, 0x74, 0x61, 0x20, 0x65, 0x63, 0x68, 0x6F, 0x0D, 0x0A,
    0x69, 0x65, 0x74, 0x0D, 0x0A, 0x61, 0x6C, 0x70, 0x68, 0x61, 0x20, 0x62,
    0x72, 0x61, 0x76, 0x6F, 0x20, 0x63, 0x68, 0x61, 0x72, 0x6C, 0x6C, 0x69,
    0x65, 0x20, 0x64, 0x65, 0x6C, 0x74, 0x61, 0x20, 0x65, 0x63, 0x68, 0x6F,
    0x20, 0x66, 0x6F, 0x78, 0x74, 0x72, 0x6F, 0x74, 0x20, 0x67, 0x6F, 0x6C,
    0x66, 0x20, 0x68, 0x6F, 0x74, 0x65, 0x6C, 0x20, 0x0D, 0x0A, 0x72, 0x6F,
    0x74, 0x20, 0x67, 0x6F, 0x6C, 0x66, 0x20, 0x68, 0x6F, 0x74, 0x65, 0x6C,
    0x20, 0x69, 0x6E, 0x64, 0x69, 0x61, 0x20, 0x6A, 0x75, 0x6C, 0x69, 0x65,
    0x74, 0x0D, 0x0A, 0x61, 0x6C, 0x70, 0x68, 0x61, 0x20, 0x62, 0x72, 0x61,
    0x76, 0x6F, 0x20, 0x63, 0x68, 0x61, 0x72, 0x6C, 0x6C, 0x69, 0x65, 0x20,
    0x64, 0x65, 0x6C, 0x74, 0x61, 0x20, 0x65, 0x63, 0x68, 0x6F, 0x20, 0x66,
    0x6F, 0x78, 0x74, 0x72, 0x6F, 0x74, 0x0D, 0x0A, 0x6C, 0x66, 0x20, 0x68,
    0x6F, 0x74, 0x65, 0x6C, 0x20, 0x69, 0x6E, 0x64, 0x69, 0x61, 0x20, 0x6A,
    0x75, 0x6C, 0x69, 0x65, 0x74, 0x0D, 0x0A, 0x61, 0x6C, 0x70, 0x68, 0x61,
    0x20, 0x62, 0x72, 0x61, 0x76, 0x6F, 0x20, 0x63, 0x68, 0x61, 0x72, 0x6C,
    0x6C, 0x69, 0x65, 0x20, 0x64, 0x65, 0x6C, 0x74, 0x61, 0x20, 0x65, 0x63,
    0x68, 0x6F, 0x20, 0x66, 0x6F, 0x78, 0x74, 0x72, 0x6F, 0x74, 0x20, 0x67,
    0x6F, 0x6C, 0x66, 0x20, 0x68, 0x6F, 0x74, 0x65, 0x6C, 0x20,
};
const reference_dictionary_id: u32 = 0x34CC419E;
/// Decompresses `src` against `dict`, allocating the result. The ID travels with
/// the content, so leaving it unset would refuse every frame named by one.
fn decompressWithDictAlloc(
    allocator: std.mem.Allocator,
    src: []const u8,
    dict: *const dictionary_mod.Dictionary,
) ![]u8 {
    const bound = try decompress_mod.decompressBound(allocator, src);
    const out = try allocator.alloc(u8, if (bound == 0) src.len * 4 + 1024 else bound);
    errdefer allocator.free(out);
    const n = try decompress_mod.decompressIntoDictLimits(allocator, out, src, dict.content(), .{
        .dictId = dict.dictId(),
    });
    return allocator.realloc(out, n) catch out;
}
test "preparing raw content keeps every byte as match history" {
    const alloc = testing.allocator;
    const raw = "content with no dictionary magic at all, just bytes";
    var prepared = try PreparedDictionary.prepare(alloc, raw);
    defer prepared.deinit();

    try testing.expect(!prepared.is_prepared);
    try testing.expectEqual(@as(u32, 0), prepared.id);
    try testing.expectEqualStrings(raw, prepared.content());
    try testing.expect(prepared.entropyTables() == null);
    // With no tables to inherit, a frame starts from the format's own defaults.
    try testing.expectEqual(RepeatOffsets.initial, prepared.repeats());
}
test "a dictionary ID survives preparation" {
    const alloc = testing.allocator;
    var prepared = try PreparedDictionary.fromContent(alloc, "some content", 0xDEADBEEF);
    defer prepared.deinit();
    try testing.expectEqual(@as(u32, 0xDEADBEEF), prepared.id);
    try testing.expectEqualStrings("some content", prepared.content());
}
test "content wrapped with a magic but no tables stays usable" {
    // A buffer that starts with the magic and an ID is accepted as a dictionary
    // with ID, even when it carries no entropy tables - which is exactly what
    // `fromContent` produces. It must not be mistaken for a prepared dictionary
    // with tables to load.
    const alloc = testing.allocator;
    var prepared = try PreparedDictionary.fromContent(alloc, "plain bytes behind an id", 7);
    defer prepared.deinit();
    try testing.expect(prepared.is_prepared);
    try testing.expectEqual(@as(u32, 7), prepared.id);
    try testing.expectEqualStrings("plain bytes behind an id", prepared.content());
}
test "an empty dictionary prepares and yields no content" {
    const alloc = testing.allocator;
    var prepared = try PreparedDictionary.prepare(alloc, "");
    defer prepared.deinit();
    try testing.expectEqual(@as(usize, 0), prepared.content().len);
}
test "truncated table data is refused rather than half-parsed" {
    const alloc = testing.allocator;
    // Magic and ID followed by nothing: the tables cannot be read.
    const truncated = [_]u8{ 0x37, 0xA4, 0x30, 0xEC, 1, 0, 0, 0 };
    try expectRejected(PreparedDictionary.prepare(alloc, &truncated));
}
test "a garbage body after the magic is refused" {
    // Everything after the magic must parse as a table description. Random bytes
    // must not be accepted as one, and the exact error depends on where parsing
    // gives up.
    const alloc = testing.allocator;
    var garbage: [64]u8 = undefined;
    for (&garbage, 0..) |*b, i| b.* = @truncate(i *% 37 +% 11);
    var buffer: [8 + 64]u8 = undefined;
    bits.writeLe32(buffer[0..4], constants.magic_dictionary);
    bits.writeLe32(buffer[4..8], 1);
    @memcpy(buffer[8..], &garbage);
    try expectRejected(PreparedDictionary.prepare(alloc, &buffer));
}
test "preparation is reusable across many inputs" {
    // The point of preparing: the same dictionary, used repeatedly, produces the
    // same result each time and no state carries between uses.
    const alloc = testing.allocator;
    var prepared = try PreparedDictionary.fromContent(alloc, "reused dictionary content", 99);
    defer prepared.deinit();

    const first_content = prepared.content();
    for (0..5) |_| {
        try testing.expectEqualStrings(first_content, prepared.content());
        try testing.expectEqual(@as(u32, 99), prepared.id);
    }
}
// ---------------------------------------------------------------------------
// Loading a dictionary another implementation produced
//
// The fixture below was produced by the reference tool and kept verbatim, so this
// is a real interoperability check rather than a round trip with ourselves.
// ---------------------------------------------------------------------------

test "a reference-trained dictionary loads and keeps its ID" {
    const alloc = testing.allocator;
    var prepared = try PreparedDictionary.prepare(alloc, &reference_dictionary);
    defer prepared.deinit();

    try testing.expect(prepared.is_prepared);
    try testing.expectEqual(reference_dictionary_id, prepared.id);
    try testing.expectEqual(@as(u32, reference_dictionary_id), prepared.id);
}
test "a prepared dictionary exposes real entropy state, not just bytes" {
    // The point of preparing: tables that a frame can inherit. A dictionary that
    // loaded with no tables would still satisfy a byte-comparison test, so this
    // checks the state itself is present.
    const alloc = testing.allocator;
    var prepared = try PreparedDictionary.prepare(alloc, &reference_dictionary);
    defer prepared.deinit();

    const tables = prepared.entropyTables() orelse return error.TestUnexpectedResult;
    try testing.expect(tables.literals != null);
    try testing.expect(tables.offsets.table.tableSize() > 0);
    try testing.expect(tables.match_lengths.table.tableSize() > 0);
    try testing.expect(tables.literal_lengths.table.tableSize() > 0);
}
test "a prepared dictionary's content excludes its tables" {
    // The content is what a frame's first matches reach into. It must be shorter
    // than the whole buffer, because the tables are not content.
    const alloc = testing.allocator;
    var prepared = try PreparedDictionary.prepare(alloc, &reference_dictionary);
    defer prepared.deinit();

    const content = prepared.content();
    try testing.expect(content.len < reference_dictionary.len);
    try testing.expect(content.len > 0);
    // Content lives at the tail of the buffer, so it must be a suffix of it.
    try testing.expectEqualSlices(u8, content, reference_dictionary[reference_dictionary.len - content.len ..]);
}
test "a dictionary with a different ID is still a dictionary" {
    // Correct magic, wrong ID: still loadable, different ID. The ID is what a
    // frame is matched against, so it must be read rather than assumed.
    const alloc = testing.allocator;
    var wrong_id = reference_dictionary;
    wrong_id[4] ^= 0xFF;
    var with_wrong_id = try PreparedDictionary.prepare(alloc, &wrong_id);
    defer with_wrong_id.deinit();
    try testing.expect(with_wrong_id.id != reference_dictionary_id);
}
test "a dictionary truncated inside its header is refused" {
    // Truncating inside the header must be refused, never half-parsed. The
    // header is the magic, ID, tables and repeat offsets, so a cut short of
    // where the content starts cannot yield a usable dictionary. The exact cut
    // point is discovered by asking for the content, which is the only thing
    // that says where the tables ended.
    const alloc = testing.allocator;
    var whole = try PreparedDictionary.prepare(alloc, &reference_dictionary);
    const header_bytes = whole.data.len - whole.content().len;
    whole.deinit();
    try testing.expect(header_bytes > 0);
    try testing.expect(header_bytes < reference_dictionary.len);

    const cut = header_bytes - 1;
    const result = PreparedDictionary.prepare(alloc, reference_dictionary[0..cut]);
    if (result) |prepared| {
        var owned = prepared;
        owned.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
}
test "an empty and a zero-ID dictionary both prepare" {
    const alloc = testing.allocator;
    var empty = try PreparedDictionary.fromContent(alloc, "", 0);
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.content().len);
    try testing.expectEqual(@as(u32, 0), empty.id);

    var small = try PreparedDictionary.fromContent(alloc, "x", 1);
    defer small.deinit();
    try testing.expectEqual(@as(usize, 1), small.content().len);
    try testing.expectEqual(@as(u32, 1), small.id);
}
// ---------------------------------------------------------------------------
// Reuse: the reason preparation exists
//
// Every test below reuses one prepared dictionary across independent operations,
// so any state carried between them would make a later result differ from an
// earlier one.
test "one prepared dictionary serves many independent compressions" {
    const alloc = testing.allocator;
    var prepared = try PreparedDictionary.fromContent(
        alloc,
        "a dictionary body that appears throughout these payloads",
        1234,
    );
    defer prepared.deinit();

    var view = try dictionary_mod.loadDictionary(alloc, prepared.data);
    defer view.deinit();

    const inputs = [_][]const u8{
        "a dictionary body that appears throughout these payloads",
        "unrelated first input, quite short",
        "a dictionary body that appears throughout these payloads and then some",
        "",
        "a dictionary body that appears throughout these payloads",
    };

    var first_outputs: [inputs.len][]u8 = undefined;
    for (inputs, 0..) |text, i| {
        first_outputs[i] = try compress_mod.compress(alloc, text, .{ .dictionary = &view });
    }
    defer for (first_outputs) |o| alloc.free(o);

    // Every round must reproduce the first round byte for byte.
    for (0..3) |_| {
        for (inputs, 0..) |text, i| {
            const again = try compress_mod.compress(alloc, text, .{ .dictionary = &view });
            defer alloc.free(again);
            try testing.expectEqualSlices(u8, first_outputs[i], again);
        }
    }

    // And each still decodes to its own input.
    for (inputs, 0..) |text, i| {
        const back = try decompressWithDictAlloc(alloc, first_outputs[i], &view);
        defer alloc.free(back);
        try testing.expectEqualStrings(text, back);
    }
}
test "one prepared dictionary serves many independent decompressions" {
    const alloc = testing.allocator;
    var prepared = try PreparedDictionary.fromContent(alloc, "shared dictionary body for decompression", 55);
    defer prepared.deinit();
    var view = try dictionary_mod.loadDictionary(alloc, prepared.data);
    defer view.deinit();

    const texts = [_][]const u8{
        "shared dictionary body for decompression",
        "first unrelated payload",
        "shared dictionary body for decompression, repeated",
        "second unrelated payload, also short",
    };
    var frames: [texts.len][]u8 = undefined;
    for (texts, 0..) |text, i| {
        frames[i] = try compress_mod.compress(alloc, text, .{ .dictionary = &view });
    }
    defer for (frames) |f| alloc.free(f);

    var ctx = context_mod.DecompressionContext.init(alloc);
    defer ctx.deinit();
    ctx.setDictionary(&view);

    // Repeated decompression through one context, in an order that would expose
    // any state carried between operations.
    for (0..3) |_| {
        for (texts, 0..) |text, i| {
            const back = try ctx.decompressAlloc(frames[i]);
            defer alloc.free(back);
            try testing.expectEqualStrings(text, back);
        }
    }
}
test "two contexts sharing one prepared dictionary do not interfere" {
    const alloc = testing.allocator;
    var prepared = try PreparedDictionary.fromContent(alloc, "content shared by two contexts at once", 77);
    defer prepared.deinit();
    var view = try dictionary_mod.loadDictionary(alloc, prepared.data);
    defer view.deinit();

    var ctx_a = context_mod.DecompressionContext.init(alloc);
    defer ctx_a.deinit();
    var ctx_b = context_mod.DecompressionContext.init(alloc);
    defer ctx_b.deinit();
    ctx_a.setDictionary(&view);
    ctx_b.setDictionary(&view);

    const a_text = "content shared by two contexts at once, first";
    const b_text = "content shared by two contexts at once, second";
    const a_frame = try compress_mod.compress(alloc, a_text, .{ .dictionary = &view });
    defer alloc.free(a_frame);
    const b_frame = try compress_mod.compress(alloc, b_text, .{ .dictionary = &view });
    defer alloc.free(b_frame);

    // Interleaved, so any shared mutable state would cross over.
    for (0..3) |_| {
        const from_a = try ctx_a.decompressAlloc(a_frame);
        defer alloc.free(from_a);
        try testing.expectEqualStrings(a_text, from_a);
        const from_b = try ctx_b.decompressAlloc(b_frame);
        defer alloc.free(from_b);
        try testing.expectEqualStrings(b_text, from_b);
    }
}
test "a frame for one dictionary is refused by another" {
    // Dictionary identity is enforced, not just presence. Two dictionaries with
    // different IDs must not silently decode each other's frames.
    const alloc = testing.allocator;
    var first = try dictionary_mod.createDictionaryFromData(alloc, "dictionary one body", 111);
    defer first.deinit();
    var second = try dictionary_mod.createDictionaryFromData(alloc, "dictionary two body", 222);
    defer second.deinit();

    const text = "dictionary one body appears here";
    const frame = try compress_mod.compress(alloc, text, .{ .dictionary = &first });
    defer alloc.free(frame);

    // The matching dictionary decodes it.
    const good = try decompressWithDictAlloc(alloc, frame, &first);
    defer alloc.free(good);
    try testing.expectEqualStrings(text, good);

    // The other dictionary is refused rather than producing rubbish.
    try testing.expectError(
        error.DictionaryWrong,
        decompress_mod.decompressIntoDictLimits(alloc, &.{}, frame, second.content(), .{
            .dictId = second.dictId(),
        }),
    );
}
test "a frame needing a dictionary is refused without one" {
    // Matches that reach into dictionary content cannot be resolved otherwise, so
    // the decode must fail rather than read whatever is in the buffer.
    const alloc = testing.allocator;
    var dict = try dictionary_mod.createDictionaryFromData(alloc, "dictionary content the frame depends on entirely", 909);
    defer dict.deinit();

    const text = "dictionary content the frame depends on entirely";
    const frame = try compress_mod.compress(alloc, text, .{ .dictionary = &dict });
    defer alloc.free(frame);

    // The frame names a dictionary ID, so decoding without one is refused.
    const result = decompress_mod.decompressWithLimits(alloc, frame, .{ .dictId = dict.dictId() });
    if (result) |out| {
        alloc.free(out);
        return error.TestUnexpectedResult;
    } else |_| {}
}
test "randomized reuse across many payloads" {
    const alloc = testing.allocator;
    var prepared = try PreparedDictionary.fromContent(
        alloc,
        "the recurring dictionary phrase appears over and over",
        4242,
    );
    defer prepared.deinit();
    var view = try dictionary_mod.loadDictionary(alloc, prepared.data);
    defer view.deinit();

    var prng = std.Random.DefaultPrng.init(31337);
    for (0..25) |_| {
        const len = prng.random().intRangeAtMost(usize, 0, 400);
        var payload: [400]u8 = undefined;
        for (payload[0..len]) |*b| {
            b.* = if (prng.random().intRangeAtMost(u8, 0, 3) == 0) 'q' else 'a' + prng.random().intRangeAtMost(u8, 0, 25);
        }
        const text = payload[0..len];
        const frame = try compress_mod.compress(alloc, text, .{ .dictionary = &view });
        defer alloc.free(frame);

        const back = try decompressWithDictAlloc(alloc, frame, &view);
        defer alloc.free(back);
        try testing.expectEqualSlices(u8, text, back);
    }
}
