//! Container layer parsing for historic Zstandard formats (v0.1 to v0.7).
//!
//! ## Frame headers, version by version
//!
//! ```text
//! v0.1  4 bytes   magic only, stored BIG-endian (0xFD2FB51E)
//! v0.2  4 bytes   magic only, little-endian
//! v0.3  4 bytes   magic only, little-endian
//! v0.4  5 bytes   magic + 1 window descriptor byte
//! v0.5  5 bytes   magic + 1 window descriptor byte
//! v0.6  5..13     magic + 1 descriptor byte (windowLog, reserved bit, fcsId) + fcs
//! v0.7  5..18     magic + 1 descriptor byte (dictId size, checksum, reserved,
//!                 direct mode, fcsId) + optional window byte + dictId + fcs
//!       + 4 byte XXH64 content checksum, when the checksum flag is set
//! ```
//!
//! No version before v0.7 has a skippable frame type; v0.7 is the first that
//! recognises one, and does so before it looks at the magic.
//!
//! ## Window descriptor
//!
//! - v0.4 and v0.5: `windowLog = (b & 15) + MIN`, and the top nibble is reserved
//!   and must be zero. `MIN` is 10 for v0.4 and 11 for v0.5.
//! - v0.6: `windowLog = (b & 15) + 12`; bit 5 is reserved and must be zero; the
//!   top two bits select the frame-content-size field width (0, 1, 2 or 8 bytes).
//! - v0.7: the descriptor no longer carries the window log directly. Bit 5 is a
//!   "direct mode" flag; when it is clear a separate window-log byte follows,
//!   from which `windowSize = (1 << windowLog) + ((1 << windowLog) >> 3) * (b & 7)`.
//!
//! ## Block headers: one layout, seven versions
//!
//! ```text
//!   byte 0   bits 7..6   block type: 0 compressed, 1 raw, 2 RLE, 3 end
//!   byte 0   bits 2..0   \  size
//!   byte 1               |  of the block
//!   byte 2               /
//! ```
//!
//! `size = in[2] + (in[1] << 8) + ((in[0] & 7) << 16)`.
//!
//! For a compressed or raw block `size` is how many payload bytes follow. For an
//! RLE block `size` is the *regenerated* size and exactly one payload byte
//! follows. Type 3 ends the frame and carries no payload; there is no last-block
//! flag, which is the main structural difference from the current format (where
//! the last-block flag is bit 0, the type is bits 1..2, and the size is bits
//! 3..23).
//!
//! The reference readers reject RLE blocks outright - they return a generic error
//! rather than expanding them - even though the header reserves the type and the
//! frame walk already accounts for its single payload byte. This implementation
//! expands them, because doing so is a strict superset: no historic encoder ever
//! emitted one, so no reference frame depends on the refusal.

const std = @import("std");
const bits = @import("../common/bits.zig");
const errors = @import("../common/errors.zig");

/// The seven historic formats, numbered as their magics number them.
pub const Version = enum(u8) {
    v01 = 1,
    v02 = 2,
    v03 = 3,
    v04 = 4,
    v05 = 5,
    v06 = 6,
    v07 = 7,

    /// The magic this version's frames start with, in the byte order the reader
    /// sees it: v0.1 wrote its magic big-endian and every later version
    /// little-endian. Reading them all one way recognises nothing at all.
    pub fn magic(self: Version) u32 {
        return switch (self) {
            .v01 => 0xFD2FB51E,
            .v02 => 0xFD2FB522,
            .v03 => 0xFD2FB523,
            .v04 => 0xFD2FB524,
            .v05 => 0xFD2FB525,
            .v06 => 0xFD2FB526,
            .v07 => 0xFD2FB527,
        };
    }

    pub fn magicIsBigEndian(self: Version) bool {
        return self == .v01;
    }

    /// The offset the window log is biased from, per version. Versions that have
    /// no window log report 0.
    /// The value the frame header's window-log nibble is relative to, taken from
    /// each reference's own `ZSTD*_WINDOWLOG_ABSOLUTEMIN`.
    pub fn windowLogBase(self: Version) u8 {
        return switch (self) {
            .v01, .v02, .v03 => 0,
            .v04 => 11,
            .v05 => 11,
            .v06 => 12,
            .v07 => 10,
        };
    }

    /// The first version that can carry a frame content size, a dictionary id, a
    /// content checksum or a skippable frame.
    pub fn hasContentSize(self: Version) bool {
        return self != .v01 and self != .v02 and self != .v03 and self != .v04 and self != .v05;
    }

    /// The first version whose literals section uses the 2/2/10/10, 2/2/14/14 and
    /// 2/2/18/18 header shapes rather than the 20-bit/24-bit pair.
    pub fn hasScaledLiteralHeader(self: Version) bool {
        return self != .v01 and self != .v02 and self != .v03 and self != .v04;
    }

    /// True when literal section type 3 is refused rather than read as compressed.
    /// v0.1 to v0.3 put the switch's `default` label on the compressed arm, so type
    /// 3 decoded as compressed. v0.4 gave the switch an explicit `default` reporting
    /// corruption, and v0.5 on kept that. This is independent of the literal header
    /// layout, which is why it is its own predicate rather than
    /// `hasScaledLiteralHeader`.
    pub fn rejectsLiteralType3(self: Version) bool {
        return self != .v01 and self != .v02 and self != .v03;
    }

    /// The first version whose sequence section uses the modern code-plus-extra
    /// bits layout with a three-slot repeat history, instead of a FSE symbol per
    /// field plus a shared "dumps" region.
    pub fn hasModernSequences(self: Version) bool {
        return self == .v06 or self == .v07;
    }

    /// True for the versions that keep a *single* stored repeat offset, which
    /// resolves as "this sequence's own offset if it carried literals, otherwise
    /// whatever was stored". v0.6 and v0.7 instead keep three and index them.
    pub fn hasSingleRepeatOffset(self: Version) bool {
        return self != .v06 and self != .v07;
    }

    /// True when the stored repeat offset is written *after* the sequence's own
    /// offset has resolved. v0.1 to v0.3 write it before, from the same value, so
    /// the two orders agree on what is stored; v0.4 and v0.5 additionally skip the
    /// store when the sequence repeated a distance that followed a literal run,
    /// which is the behaviour difference this predicate exists for.
    pub fn storesRepeatOffsetAfterDecode(self: Version) bool {
        return self == .v04 or self == .v05;
    }

    /// True for the versions whose sequence count is one byte plus an optional
    /// extension, rather than the fixed two bytes v0.1 through v0.4 always spend.
    /// The two encodings overlap below 128, which is why a v0.5 count of 120 reads
    /// the same either way and only the wide form separates them.
    pub fn hasVariableSequenceCount(self: Version) bool {
        return self == .v05 or self == .v06 or self == .v07;
    }

    /// True for the versions that read a sequence by peeking the literal-length and
    /// offset symbols before consuming any bits. Every state update draws its bits
    /// from the one shared stream, so the order of the updates decides which bits
    /// belong to which field; reading the same fields in the other order produces a
    /// frame that decodes without error to the wrong bytes.
    pub fn readsOffsetBeforeLiteralBits(self: Version) bool {
        return self == .v05;
    }

    /// True for the versions whose reference seeds *both* the stored repeat offset
    /// and the sequence's own previous offset with the start value. v0.1 and v0.2
    /// seed only the stored one, leaving the sequence's own offset at zero, so a
    /// repeat code in a first sequence would resolve to zero there and is not
    /// something an encoder emits.
    pub fn seedsPreviousOffsetToo(self: Version) bool {
        return self == .v03 or self == .v04 or self == .v05;
    }

    /// True for the versions that number the sequence tables' encoding modes with
    /// raw first. v0.1 through v0.4 put RLE at zero and raw at one; v0.5 on puts raw
    /// at zero and RLE at one, with the other two unchanged. The two bits are read
    /// the same either way, so reading a v0.5 mode byte as a v0.2 one turns a raw
    /// table into an RLE table and shifts everything after it.
    pub fn rawEncodingComesFirst(self: Version) bool {
        return self == .v05 or self == .v06 or self == .v07;
    }
};

pub const block_header_size: usize = 3;

/// The largest regenerated block any historic version allows. Every version's
/// reference reader hard-codes 128 KB for its literal buffer, so a literal count
/// above this is corruption in every one of them.
pub const block_size_max: usize = 128 * 1024;

/// The bit-count and alphabet limits v0.1 through v0.5 pinned. v0.6 and v0.7 use
/// the modern values instead, which live in `common/constants.zig`.
pub const min_match: usize = 4;
pub const ll_bits: u8 = 6;
pub const ml_bits: u8 = 7;
pub const off_bits: u8 = 5;
pub const max_ll: usize = (@as(usize, 1) << ll_bits) - 1;
pub const max_ml: usize = (@as(usize, 1) << ml_bits) - 1;
pub const max_off: usize = (@as(usize, 1) << off_bits) - 1;
pub const ll_fse_log: u8 = 10;
pub const ml_fse_log: u8 = 10;
pub const off_fse_log: u8 = 9;

/// The smallest sequence section a compressed block can carry: a one-byte
/// "zero sequences" marker, and nothing else. Every version's reference reader
/// gates on this before parsing.
pub const min_sequences_size: usize = 1;

pub const BlockType = enum(u2) {
    compressed = 0,
    raw = 1,
    rle = 2,
    end = 3,

    /// The payload bytes that follow the header, and the bytes the block
    /// regenerates. For a raw or compressed block these differ: the header size
    /// is the compressed length, and the regenerated length comes from the
    /// block's own sections.
    pub fn payloadLen(self: BlockType, size: usize) usize {
        return switch (self) {
            .end => 0,
            .rle => 1,
            .raw, .compressed => size,
        };
    }
};

pub const BlockHeader = struct {
    block_type: BlockType,
    /// The header's size field: bytes of payload for a raw or compressed block,
    /// regenerated bytes for an RLE block.
    size: usize,
};

/// Reads one block header. `src` must hold at least `block_header_size` bytes.
pub fn readBlockHeader(src: []const u8) errors.ZstdError!BlockHeader {
    if (src.len < block_header_size) return error.SrcSizeWrong;
    const flags = src[0];
    const size: usize = @as(usize, src[2]) |
        (@as(usize, src[1]) << 8) |
        (@as(usize, flags & 7) << 16);
    return .{
        .block_type = @fromBackingInt(@intCast(@as(u2, @truncate(flags >> 6)))),
        .size = size,
    };
}

/// Writes a block header. `size` is the header's size field, which means
/// regenerated bytes for an RLE block.
pub fn writeBlockHeader(dst: []u8, block_type: BlockType, size: usize) void {
    std.debug.assert(dst.len >= block_header_size);
    // The size field is 19 bits wide: three in the first byte, eight in each of
    // the other two.
    std.debug.assert(size <= 0x7FFFF);
    dst[0] = (@as(u8, @backingInt(block_type)) << 6) | @as(u8, @intCast(size >> 16));
    dst[1] = @truncate(size >> 8);
    dst[2] = @truncate(size);
}

pub const FrameHeader = struct {
    version: Version,
    /// Bytes the header occupies, including the magic.
    size: usize,
    /// Log2 of the maximum match distance, where the format records one.
    window_log: ?u8 = null,
    /// Decoded window size in bytes, where the format records a size rather than
    /// a log. v0.7 is the only version whose header stores the size directly.
    window_size: ?u32 = null,
    /// Regenerated size the header promises, where the format records one.
    frame_content_size: ?u64 = null,
    dict_id: ?u32 = null,
    checksum: bool = false,
    /// True when the frame is a v0.7 skippable frame, which carries no content.
    skippable: bool = false,
    /// Bytes the skippable frame's payload occupies, when `skippable`.
    skippable_size: usize = 0,
};

/// The largest frame header any version can produce, used to bound lookahead.
pub const frame_header_size_max: usize = 18;

/// The skippable-frame magic range, shared with the current format.
pub const skippable_magic_start: u32 = 0x184D2A50;
pub const skippable_magic_mask: u32 = 0xFFFFFFF0;

/// Reads a version's frame header. `src` must be the start of a frame carrying
/// `version`'s magic; a mismatched magic reports `error.PrefixUnknown`.
///
/// `src` may be shorter than the full header only when the caller wants to know
/// how much more it needs; every version here either has a fixed header size or
/// reports the size it needs, so this never reads past `src`.
pub fn readFrameHeader(version: Version, src: []const u8) errors.ZstdError!FrameHeader {
    if (src.len < 4) return error.SrcSizeWrong;
    const be = std.mem.readInt(u32, src[0..4], .big);
    const le = bits.readLe32(src[0..4]);
    const want_be = version.magicIsBigEndian();
    if ((if (want_be) @as(u32, be) else le) != version.magic()) {
        // v0.7 recognises a skippable frame before it recognises its own magic.
        if (version == .v07 and (le & skippable_magic_mask) == skippable_magic_start) {
            if (src.len < 8) return error.SrcSizeWrong;
            const payload: usize = bits.readLe32(src[4..8]);
            return .{
                .version = version,
                .size = 8,
                .window_size = 0,
                .skippable = true,
                .skippable_size = payload,
            };
        }
        return error.PrefixUnknown;
    }

    switch (version) {
        .v01, .v02, .v03 => return .{ .version = version, .size = 4 },
        .v04, .v05 => {
            if (src.len < 5) return error.SrcSizeWrong;
            const desc = src[4];
            if ((desc >> 4) != 0) return error.FrameParameterUnsupported;
            return .{
                .version = version,
                .size = 5,
                .window_log = (desc & 15) + version.windowLogBase(),
            };
        },
        .v06 => {
            if (src.len < 5) return error.SrcSizeWrong;
            const desc = src[4];
            if ((desc & 0x20) != 0) return error.FrameParameterUnsupported;
            const fcs_id = desc >> 6;
            const fcs_size: usize = switch (fcs_id) {
                0 => 0,
                1 => 1,
                2 => 2,
                else => 8,
            };
            const size = 5 + fcs_size;
            if (src.len < size) return error.SrcSizeWrong;
            var header = FrameHeader{
                .version = version,
                .size = size,
                .window_log = (desc & 15) + version.windowLogBase(),
            };
            if (fcs_size != 0) {
                const fcs: u64 = switch (fcs_size) {
                    1 => src[5],
                    2 => @as(u64, bits.readLe16(src[5..])) + 256,
                    else => bits.readLe64(src[5..]),
                };
                header.frame_content_size = fcs;
            }
            return header;
        },
        .v07 => {
            if (src.len < 5) return error.SrcSizeWrong;
            const fhd = src[4];
            if ((fhd & 0x08) != 0) return error.FrameParameterUnsupported;
            const dict_id_size_code = fhd & 3;
            const checksum = ((fhd >> 2) & 1) != 0;
            const direct = ((fhd >> 5) & 1) != 0;
            const fcs_id = fhd >> 6;
            const dict_id_size: usize = switch (dict_id_size_code) {
                0 => 0,
                1 => 1,
                2 => 2,
                else => 4,
            };
            const fcs_size: usize = switch (fcs_id) {
                0 => if (direct) 1 else 0,
                1 => 2,
                2 => 4,
                else => 8,
            };
            const window_size: usize = if (direct) 0 else 1;
            var size = 5 + window_size + dict_id_size + fcs_size;
            if (checksum) size += 4;
            if (src.len < size) return error.SrcSizeWrong;

            var pos: usize = 5;
            var header = FrameHeader{ .version = version, .size = size, .checksum = checksum };
            if (window_size != 0) {
                const wl = src[pos];
                pos += 1;
                const window_log = (wl >> 3) + version.windowLogBase();
                // 31 would shift a 32-bit value out of range and the reference
                // rejects it, so the cap is checked before the shift.
                if (window_log > 31) return error.FrameParameterUnsupported;
                const base: u32 = @as(u32, 1) << @intCast(window_log);
                const total = base + (base >> 3) * @as(u32, wl & 7);
                if (total > (1 << 27)) return error.FrameParameterUnsupported;
                header.window_log = window_log;
                header.window_size = total;
            }
            header.dict_id = switch (dict_id_size_code) {
                0 => null,
                1 => blk: {
                    const v = src[pos];
                    pos += 1;
                    break :blk @as(u32, v);
                },
                2 => blk: {
                    const v = bits.readLe16(src[pos..]);
                    pos += 2;
                    break :blk @as(u32, v);
                },
                else => blk: {
                    const v = bits.readLe32(src[pos..]);
                    pos += 4;
                    break :blk v;
                },
            };
            header.frame_content_size = switch (fcs_id) {
                0 => if (direct) @as(u64, src[pos]) else 0,
                1 => @as(u64, bits.readLe16(src[pos..])) + 256,
                2 => bits.readLe32(src[pos..]),
                else => bits.readLe64(src[pos..]),
            };
            if (header.window_size == null) {
                header.window_size = @truncate(@min(
                    header.frame_content_size.?,
                    @as(u64, 1 << 27),
                ));
            }
            return header;
        },
    }
}

/// Writes a frame header. Only what `header` carries is emitted: a version with
/// no window log gets no descriptor byte, and so on.
pub fn writeFrameHeader(dst: []u8, header: FrameHeader) errors.ZstdError!usize {
    const version = header.version;
    if (dst.len < frame_header_size_max) return error.DstSizeTooSmall;
    if (version.magicIsBigEndian()) {
        std.mem.writeInt(u32, dst[0..4], version.magic(), .big);
    } else {
        bits.writeLe32(dst[0..4], version.magic());
    }
    switch (version) {
        .v01, .v02, .v03 => return 4,
        .v04, .v05 => {
            const base = version.windowLogBase();
            const log = header.window_log orelse return error.FrameParameterUnsupported;
            if (log < base) return error.FrameParameterUnsupported;
            dst[4] = @truncate(log - base);
            return 5;
        },
        .v06 => {
            const base = version.windowLogBase();
            const log = header.window_log orelse return error.FrameParameterUnsupported;
            if (log < base) return error.FrameParameterUnsupported;
            const fcs = header.frame_content_size;
            // fcsId 1, 2 and 3 carry 1, 2 and 8 bytes. A size of zero cannot be
            // distinguished from "absent", so it uses the absent form.
            const fcs_id: u8, const fcs_size: usize = if (fcs == null or fcs.? == 0)
                .{ 0, 0 }
            else if (fcs.? < 256)
                .{ 1, 1 }
            else if (fcs.? < 65536 + 256)
                .{ 2, 2 }
            else
                .{ 3, 8 };
            dst[4] = @as(u8, @truncate(log - base)) | (fcs_id << 6);
            if (fcs_size == 1) {
                dst[5] = @truncate(fcs.?);
            } else if (fcs_size == 2) {
                bits.writeLe16(dst[5..7], @intCast(fcs.? - 256));
            } else if (fcs_size == 8) {
                bits.writeLe64(dst[5..13], fcs.?);
            }
            return 5 + fcs_size;
        },
        .v07 => {
            // Written with a window log, a dictionary id and a content size, but
            // without a checksum: the encoder here never emits one, so it always
            // takes the shortest header that can carry those three.
            var fhd: u8 = 0;
            var pos: usize = 5;
            if (header.window_log) |log| {
                if (log < 10 or log > 27) return error.FrameParameterUnsupported;
                // The format stores a log plus a 3-bit mantissa that scales the
                // window by eighths. Writing mantissa 0 makes the window exactly
                // 1 << log, which is what the caller asked for, so no rounding
                // is needed: an encoder that wants a larger window just asks for
                // a larger log.
                dst[pos] = @truncate((log - 10) << 3);
                pos += 1;
            } else {
                // Direct mode: the window size is exactly the content size.
                fhd |= 1 << 5;
            }
            const dict_id = header.dict_id orelse 0;
            if (dict_id != 0) {
                if (dict_id <= 0xFF) {
                    fhd |= 1;
                    dst[pos] = @truncate(dict_id);
                    pos += 1;
                } else if (dict_id <= 0xFFFF) {
                    fhd |= 2;
                    bits.writeLe16(dst[pos..][0..2], @truncate(dict_id));
                    pos += 2;
                } else {
                    fhd |= 3;
                    bits.writeLe32(dst[pos..][0..4], dict_id);
                    pos += 4;
                }
            }
            const fcs = header.frame_content_size orelse 0;
            if (fcs != 0) {
                // The two-byte form is biased by 256, so a content size below
                // that can only be stored in the one-byte form, and v0.7 only has
                // a one-byte form in direct mode - where the window size *is* the
                // content size. A frame that wants both a window log and a small
                // content size therefore cannot state its content size, and the
                // field is omitted rather than written wrong.
                const storable = (fhd & (1 << 5)) != 0 and fcs < 256 or
                    (fcs >= 256 and fcs < 65536 + 256);
                if (storable) {
                    if (fcs < 256) {
                        dst[pos] = @truncate(fcs);
                        pos += 1;
                    } else {
                        fhd |= 1 << 6;
                        bits.writeLe16(dst[pos..][0..2], @intCast(fcs - 256));
                        pos += 2;
                    }
                } else if (fcs <= std.math.maxInt(u32)) {
                    fhd |= 2 << 6;
                    bits.writeLe32(dst[pos..][0..4], @truncate(fcs));
                    pos += 4;
                } else {
                    fhd |= 3 << 6;
                    bits.writeLe64(dst[pos..][0..8], fcs);
                    pos += 8;
                }
            }
            dst[4] = fhd;
            return pos;
        },
    }
}

/// The v0.2 sequence section's repeat-offset prefix table: `offset = prefix[code]
/// + readBits(code - 1)`, with code 0 meaning "repeat the previous offset".
pub const offset_prefix = [max_off + 1]u32{
    1, // index 0 is never read as a prefix: it is the repeat marker
    1, //
    2, //
    4, //
    8, //
    16, //
    32, //
    64, //
    128, //
    256, //
    512, //
    1024, //
    2048, //
    4096, //
    8192, //
    16384, //
    32768, //
    65536, //
    131072, //
    262144, //
    524288, //
    1048576, //
    2097152, //
    4194304, //
    8388608, //
    16777216, //
    33554432, //
    1, // codes past the encodable range are unreachable
    1,
    1,
    1,
    1,
};

// Tests

const testing = std.testing;
const golden = @import("golden_frames.zig");

/// The golden frame for a version, by number. `n` is 1 - 7.
fn frameBytes(n: u8) []const u8 {
    return switch (n) {
        1 => golden.frame_v01[0..],
        2 => golden.frame_v02[0..],
        3 => golden.frame_v03[0..],
        4 => golden.frame_v04[0..],
        5 => golden.frame_v05[0..],
        6 => golden.frame_v06[0..],
        else => golden.frame_v07[0..],
    };
}

test "block type numbering is the one the reference writes" {
    // 0 compressed, 1 raw, 2 RLE, 3 end - in that order, in every version.
    try testing.expectEqual(@as(u2, 0), @backingInt(BlockType.compressed));
    try testing.expectEqual(@as(u2, 1), @backingInt(BlockType.raw));
    try testing.expectEqual(@as(u2, 2), @backingInt(BlockType.rle));
    try testing.expectEqual(@as(u2, 3), @backingInt(BlockType.end));
}

test "block header round trips every type" {
    inline for (.{ BlockType.compressed, .raw, .rle, .end }) |bt| {
        var buf: [3]u8 = undefined;
        writeBlockHeader(&buf, bt, 0x12345);
        const got = try readBlockHeader(&buf);
        try testing.expectEqual(bt, got.block_type);
        try testing.expectEqual(@as(usize, 0x12345), got.size);
    }
    // The end block contributes no payload whatever its size field holds, which
    // is what makes the frame walk stop.
    var ebuf: [3]u8 = undefined;
    writeBlockHeader(&ebuf, .end, 0);
    ebuf[1] = 0xFF;
    ebuf[2] = 0xFF;
    const end = try readBlockHeader(&ebuf);
    try testing.expectEqual(BlockType.end, end.block_type);
    try testing.expectEqual(@as(usize, 0), end.block_type.payloadLen(end.size));
    // An RLE block's one payload byte is counted against the same field that
    // states the regenerated size, which is why they must not be conflated.
    try testing.expectEqual(@as(usize, 1), BlockType.rle.payloadLen(999));
    try testing.expectEqual(@as(usize, 999), BlockType.compressed.payloadLen(999));
}

test "block header reads the real frames' first block" {
    // Every golden frame opens with one compressed block. The sizes below are
    // what each frame's own first header says, and they are what makes each
    // frame add up exactly.
    const cases = [_]struct { n: u8, version: Version, size: usize }{
        .{ .n = 1, .version = .v01, .size = 179 },
        .{ .n = 2, .version = .v02, .size = 177 },
        .{ .n = 3, .version = .v03, .size = 177 },
        .{ .n = 4, .version = .v04, .size = 187 },
        .{ .n = 5, .version = .v05, .size = 173 },
        .{ .n = 6, .version = .v06, .size = 166 },
        .{ .n = 7, .version = .v07, .size = 166 },
    };
    for (cases) |c| {
        const f = frameBytes(c.n);
        const header = try readFrameHeader(c.version, f);
        const bh = try readBlockHeader(f[header.size..]);
        try testing.expectEqual(BlockType.compressed, bh.block_type);
        try testing.expectEqual(c.size, bh.size);
    }
}

test "every golden frame's blocks account for its whole length" {
    // Four bytes of magic plus one compressed block plus one end block, except
    // where a version's frame header is longer. If this stops holding, the golden
    // vectors and the block header layout have drifted apart.
    var n: u8 = 1;
    while (n <= 7) : (n += 1) {
        const f = frameBytes(n);
        const version: Version = @fromBackingInt(@intCast(n));
        const header = try readFrameHeader(version, f);
        const bh = try readBlockHeader(f[header.size..]);
        const payload = bh.block_type.payloadLen(bh.size);
        const total = header.size + block_header_size + payload;
        const end = try readBlockHeader(f[total..]);
        try testing.expectEqual(BlockType.end, end.block_type);
        try testing.expectEqual(f.len, total + block_header_size);
    }
}

test "v0.1 stores its magic big-endian and the rest little-endian" {
    try testing.expect(std.mem.readInt(u32, golden.frame_v01[0..4], .big) == Version.v01.magic());
    try testing.expect(bits.readLe32(golden.frame_v02[0..4]) == Version.v02.magic());
    try testing.expect(bits.readLe32(golden.frame_v07[0..4]) == Version.v07.magic());
    // The two orders must disagree, or reading all seven one way would work.
    try testing.expect(bits.readLe32(golden.frame_v01[0..4]) != Version.v01.magic());
}

test "frame headers report what each version stores" {
    // v0.1 - v0.3 carry nothing beyond the magic.
    for ([_]Version{ .v01, .v02, .v03 }) |v| {
        const h = try readFrameHeader(v, frameBytes(@backingInt(v)));
        try testing.expectEqual(@as(usize, 4), h.size);
        try testing.expectEqual(@as(?u8, null), h.window_log);
        try testing.expectEqual(@as(?u64, null), h.frame_content_size);
    }

    // v0.4 and v0.5 add exactly one window descriptor byte, relative to that
    // version's own floor.
    const h4 = try readFrameHeader(.v04, golden.frame_v04[0..]);
    try testing.expectEqual(@as(usize, 5), h4.size);
    try testing.expectEqual(@as(?u8, 11), h4.window_log);
    const h5 = try readFrameHeader(.v05, golden.frame_v05[0..]);
    try testing.expectEqual(@as(usize, 5), h5.size);
    try testing.expectEqual(@as(?u8, 11), h5.window_log);

    // v0.6 adds the content size: the real frame's descriptor selects the
    // one-byte form and it promises exactly the 239 bytes the frame decodes to.
    const h6 = try readFrameHeader(.v06, golden.frame_v06[0..]);
    try testing.expectEqual(@as(usize, 6), h6.size);
    try testing.expectEqual(@as(?u8, 14), h6.window_log);
    try testing.expectEqual(@as(?u64, 239), h6.frame_content_size);

    // v0.7's real frame is in direct mode, so its window size is the content size.
    const h7 = try readFrameHeader(.v07, golden.frame_v07[0..]);
    try testing.expectEqual(@as(usize, 6), h7.size);
    try testing.expectEqual(@as(?u64, 239), h7.frame_content_size);
    try testing.expectEqual(@as(?u32, 239), h7.window_size);
    try testing.expect(!h7.checksum);
}

test "a reserved frame header bit is rejected" {
    // v0.4 and v0.5 reserve the top nibble of the descriptor byte.
    var f = golden.frame_v04;
    f[4] = 0x10;
    try testing.expectError(error.FrameParameterUnsupported, readFrameHeader(.v04, &f));
    var g = golden.frame_v05;
    g[4] = 0x10;
    try testing.expectError(error.FrameParameterUnsupported, readFrameHeader(.v05, &g));
    // v0.6 reserves bit 5.
    var h = golden.frame_v06;
    h[4] |= 0x20;
    try testing.expectError(error.FrameParameterUnsupported, readFrameHeader(.v06, &h));
    // v0.7 reserves bit 3.
    var k = golden.frame_v07;
    k[4] |= 0x08;
    try testing.expectError(error.FrameParameterUnsupported, readFrameHeader(.v07, &k));
}

test "a wrong magic is not this version's frame" {
    try testing.expectError(error.PrefixUnknown, readFrameHeader(.v02, golden.frame_v03[0..]));
    try testing.expectError(error.PrefixUnknown, readFrameHeader(.v01, golden.frame_v02[0..]));
    try testing.expectError(error.PrefixUnknown, readFrameHeader(.v07, golden.frame_v06[0..]));
    try testing.expectError(error.SrcSizeWrong, readFrameHeader(.v02, golden.frame_v02[0..3]));
}

test "v0.7 recognises a skippable frame before its own magic" {
    var buf = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    bits.writeLe32(buf[0..4], skippable_magic_start | 5);
    bits.writeLe32(buf[4..8], 12);
    const h = try readFrameHeader(.v07, &buf);
    try testing.expect(h.skippable);
    try testing.expectEqual(@as(usize, 12), h.skippable_size);
    try testing.expectEqual(@as(?u32, 0), h.window_size);
}

test "frame header writing round trips through the reader" {
    const cases = [_]FrameHeader{
        .{ .version = .v01, .size = 4 },
        .{ .version = .v02, .size = 4 },
        .{ .version = .v04, .size = 5, .window_log = 15 },
        .{ .version = .v05, .size = 5, .window_log = 17 },
        .{ .version = .v06, .size = 6, .window_log = 14, .frame_content_size = 239 },
        .{ .version = .v06, .size = 5, .window_log = 12 },
        .{ .version = .v06, .size = 13, .window_log = 20, .frame_content_size = 100000 },
        .{ .version = .v07, .size = 6, .window_log = 10, .frame_content_size = 200 },
        .{ .version = .v07, .size = 5, .frame_content_size = 200 },
        .{ .version = .v07, .size = 9, .window_log = 18 },
    };
    for (cases) |c| {
        var buf: [frame_header_size_max]u8 = undefined;
        const n = try writeFrameHeader(&buf, c);
        const got = try readFrameHeader(c.version, buf[0..n]);
        try testing.expectEqual(c.version, got.version);
        try testing.expectEqual(n, got.size);
        // The writer picks the shortest field that fits, so the reader must
        // recover the same values even though the encoded form may be shorter
        // than the value the case supplied.
        if (c.frame_content_size) |fcs| {
            if (fcs != 0) try testing.expectEqual(@as(?u64, fcs), got.frame_content_size);
        }
        if (c.window_log) |wl| {
            if (c.version != .v07) try testing.expectEqual(@as(?u8, wl), got.window_log.?);
        }
    }
}

test "offset prefix table matches the reference" {
    // v0.1 through v0.5 code an offset as prefix[code] plus (code-1) extra bits,
    // with code 0 selecting the repeat. A wrong table here silently mis-decodes
    // every match at distance 3 and above.
    try testing.expectEqual(@as(u32, 1), offset_prefix[1]);
    try testing.expectEqual(@as(u32, 2), offset_prefix[2]);
    try testing.expectEqual(@as(u32, 33554432), offset_prefix[26]);
    // Codes past 26 cannot be produced by the encoder, and the reference fills
    // them with 1 so a corrupt code still yields a usable value rather than
    // reading past the table.
    for (offset_prefix[27..]) |p| try testing.expectEqual(@as(u32, 1), p);
}
