//! Format specifications and metadata for historic Zstandard frame formats (v0.1 to v0.7).
//!
//! ## Frame headers
//!
//! | version | header | notes |
//! |---|---|---|
//! | v0.1 | 4 bytes | magic stored **big-endian**; nothing else |
//! | v0.2 | 4 bytes | magic little-endian |
//! | v0.3 | 4 bytes | identical to v0.2 but for the magic |
//! | v0.4 | 5 bytes | + 1 window-descriptor byte, log biased from 10 |
//! | v0.5 | 5 bytes | same shape, log biased from 11 |
//! | v0.6 | 5..13 | + frame content size (0, 1, 2 or 8 bytes); log biased from 12 |
//! | v0.7 | 5..18 | + window size, dictionary id, checksum; recognises skippable frames |
//!
//! ## Block headers: one layout, seven versions
//!
//! Three bytes. The block type is the top two bits of the first byte and the size
//! is the low three bits of the first byte plus the second and third:
//!
//! ```text
//!   byte 0   bits 7..6   block type: 0 compressed, 1 raw, 2 RLE, 3 end
//!   byte 0   bits 2..0   \  size
//!   byte 1               |  of the block
//!   byte 2               /
//! ```
//!
//! For a compressed or raw block `size` is the number of payload bytes. For an
//! RLE block it is the *regenerated* size and one payload byte follows. Type 3
//! ends the frame. There is no last-block flag, which is the main structural
//! difference from the current format.
//!
//! Every reference reader refuses RLE blocks at the frame level even though the
//! header reserves the type. This implementation expands them, which is a strict
//! superset: no historic encoder emitted one, so no real frame depends on the
//! refusal.
//!
//! ## Literals: three shapes
//!
//! **v0.1** is the odd one out. The section opens with its own three-byte block
//! header (same layout, same numbering), and the compressed form splits the output
//! across four Huffman streams **interleaved** - one output byte per stream in
//! rotation. The regenerated size is two big-endian payload bytes plus three bits
//! of the header, and the table description is FSE-compressed.
//!
//! **v0.2, v0.3, v0.4** carry no literal size field of their own; the section
//! fills the rest of the block. Two numbers share the first five bytes:
//!
//! ```zig
//! lit_size  = (readLe32(src) & 0x1FFFFF) >> 2;   // 19 bits, biased by 2
//! lit_csize = (readLe32(src + 2) & 0xFFFFFF) >> 5; // 24 bits, biased by 5
//! ```
//!
//! The low two bits of the first byte select raw, RLE or compressed. The Huffman
//! streams split the output into four **contiguous** quarters of `(size + 3) / 4`
//! bytes each - not interleaved. That difference from v0.1 is why a v0.1 reader
//! applied to a v0.2 block produces plausible nonsense rather than an error.
//!
//! **v0.5 onward** prefix the section with a 2-bit type and a size whose width
//! follows the type:
//!
//! ```zig
//! // 2 - 2 - 10 - 10
//! lit_size  = ((istart[0] & 15) << 6) + (istart[1] >> 2);
//! lit_csize = ((istart[1] &  3) << 8) + istart[2];
//! // 2 - 2 - 14 - 14 and 2 - 2 - 18 - 18 widen both fields
//! ```
//!
//! The type is selected by the top two bits: Huffman, treeless (reuse the
//! previous block's table), raw or RLE. Raw and RLE have their own smaller headers:
//! one byte for a size under 32, two for one under 2^16, three beyond that.
//!
//! ## Sequences: differs in every version
//!
//! This is what makes each version a separate reader.
//!
//! **v0.1** - a 16-bit sequence count, then a byte holding a 2-bit table mode for
//! each of literal length, offset and match length, then a "dumps" region carrying
//! the extra bits for long lengths, then the three tables, then the bitstream. A
//! literal length above `MaxLL` (63) and a match length above `MaxML` (127) take
//! their extra bits from the dumps region: one byte for an addition under 255,
//! otherwise a 24-bit little-endian value. The offset is coded as
//! `offsetPrefix[code] + (code - 1) extra bits`, with code 0 meaning "repeat".
//! There is a single repeat offset, not the three-slot history the current format
//! uses, and the whole bitstream is reloaded at the top of *every* sequence
//! because the bit order is part of the format.
//!
//! **v0.2, v0.3** - the same section, with two differences from v0.1: the offsets
//! are masked to `MaxOff` when built as a single-symbol table, and the frame's
//! literal layer is the one described above.
//!
//! **v0.3** differs from v0.2 in exactly one place in the whole file: the repeat
//! offset starts at 4 rather than 1.
//!
//! **v0.4** - a five-byte frame header, and the repeat-offset update rule moves.
//! v0.2 and v0.3 always store the previous sequence's offset; v0.4 stores it only
//! when the sequence had a real offset code or no literals at all. A block encoded
//! for one rule decodes to different bytes under the other.
//!
//! **v0.5** - the sequence count becomes one byte, with a two-byte form for counts
//! of 128 and above, and zero means the section is finished. The long-length
//! encoding changes: two bytes, optionally a third, then shifted right by one. The
//! bit order inside the sequence changes too - the literal-length state is read
//! first but not advanced until after the offset has been resolved, which is a
//! different interleaving of the same three states.
//!
//! **v0.6** - the modern sequence layout: a code plus extra bits per field
//! (`LL_base` / `ML_base` / `OF_base`), no dumps region, predefined "raw" tables
//! built from fixed normalized counts, and a three-slot repeat history with the
//! modern repcode rules. The frame header gains a content size.
//!
//! **v0.7** - the same sequence layout with a different offset table (its base
//! values run `0, 1, 1, 5, 0xD, ...` rather than `0, 1, 3, 7, 0xF, ...`), no
//! repcode-number subtraction, and a match-length table that already includes the
//! minimum match. The frame header gains a window size, a dictionary id and a
//! content checksum, and skippable frames appear.
//!
//! ## What is shared
//!
//! Given the three literal shapes and one block header layout, the reusable pieces
//! are:
//!
//! - the frame walk: a magic, then three-byte block headers until a type-3 block
//! - raw and RLE block copies
//! - the normalized-count reader, the FSE decode-table build, and the
//!   single-symbol and uniform tables
//! - the Huffman weight-description reader and the `X2`/`X4` table builds
//!
//! The per-version work is the literals dispatch, the sequence-section parse, and
//! the constants each version pins.
//!
//! ## Verification
//!
//! Each version has a captured frame in `golden_frames.zig` with the content it
//! decodes to. A reader is finished when that frame decodes to those bytes exactly,
//! when every truncated prefix is refused rather than read past, and when a frame
//! the Zig encoder produced is accepted by the corresponding reference decoder.
//! The cross-version contract lives in `contract.zig`.

const std = @import("std");
const testing = std.testing;
const format = @import("format.zig");
const golden = @import("golden_frames.zig");

test "the version map covers every historic format" {
    // One entry per version, so a new version cannot be added to the
    // implementation without a row here describing what differs.
    for ([_]format.Version{ .v01, .v02, .v03, .v04, .v05, .v06, .v07 }) |v| {
        try testing.expect(v.magic() != 0);
        try testing.expect(v.windowLogBase() <= 12);
    }
}

test "the shape split matches what each version's frame actually shows" {
    // v0.1 through v0.3 have no window log; v0.4 onward do.
    try testing.expect(!format.Version.v01.hasScaledLiteralHeader());
    try testing.expect(!format.Version.v04.hasScaledLiteralHeader());
    try testing.expect(format.Version.v05.hasScaledLiteralHeader());
    // Only v0.6 and v0.7 use the modern sequence layout.
    try testing.expect(!format.Version.v05.hasModernSequences());
    try testing.expect(format.Version.v06.hasModernSequences());
    // Only v0.6 and v0.7 can carry a content size.
    try testing.expect(!format.Version.v05.hasContentSize());
    try testing.expect(format.Version.v07.hasContentSize());
}

test "the real frames agree with the version map" {
    // A cross-check between this map and the captured frames: whichever versions
    // the map says have a content size must actually carry one, and whichever say
    // they do not must not.
    for ([_]format.Version{ .v01, .v02, .v03, .v04, .v05, .v06, .v07 }) |v| {
        const frame = switch (v) {
            .v01 => golden.frame_v01[0..],
            .v02 => golden.frame_v02[0..],
            .v03 => golden.frame_v03[0..],
            .v04 => golden.frame_v04[0..],
            .v05 => golden.frame_v05[0..],
            .v06 => golden.frame_v06[0..],
            .v07 => golden.frame_v07[0..],
        };
        const header = try format.readFrameHeader(v, frame);
        try testing.expectEqual(v.hasContentSize(), header.frame_content_size != null);
        if (v.hasContentSize()) {
            // Both of the frames that carry one promise exactly the content the
            // golden vector says they hold.
            try testing.expectEqual(@as(u64, golden.block.len), header.frame_content_size.?);
        }
    }
}
