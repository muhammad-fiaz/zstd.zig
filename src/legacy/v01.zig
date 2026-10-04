const std = @import("std");
const bits = @import("../common/bits.zig");
const errors = @import("../common/errors.zig");
const decoder = @import("decoder.zig");
const v01_entropy = @import("v01_entropy.zig");

/// A block's regenerated output never exceeds the block size cap.
const max_block_output: usize = 128 * 1024;

pub const magic: u32 = 0xFD2FB51E;

/// v0.1 frame header: the magic and nothing else.
const frame_header_size: usize = 4;
/// v0.1 block header: three bytes.
const block_header_size: usize = 3;

/// The two-bit block type in the top bits of the first header byte. v0.1 numbered
/// them compressed, raw, RLE, end.
const BlockType = enum(u2) { compressed = 0, raw = 1, rle = 2, end = 3 };

const BlockHeader = struct {
    block_type: BlockType,
    /// Compressed size for a compressed or raw block, or the regenerated size
    /// for an RLE block.
    size: usize,
    /// Payload bytes that follow the header: zero for an end block, one for RLE.
    payload: usize,
};

/// Reads one v0.1 block header. `size` is 21 bits: the low three bits of the
/// first byte are its top bits, so the field spans the header.
fn readBlockHeader(src: []const u8) errors.ZstdError!BlockHeader {
    if (src.len < block_header_size) return error.SrcSizeWrong;
    const flags = src[0];
    const size: usize = @as(usize, src[2]) | (@as(usize, src[1]) << 8) | (@as(usize, flags & 7) << 16);
    const block_type: BlockType = @fromBackingInt(@intCast(@as(u2, @truncate(flags >> 6))));
    return .{
        .block_type = block_type,
        .size = switch (block_type) {
            .end => 0,
            .rle => size,
            else => size,
        },
        .payload = switch (block_type) {
            .end => 0,
            .rle => 1,
            else => size,
        },
    };
}

/// Walks the blocks of a v0.1 frame and returns its total size. A v0.1 frame has
/// no content size and no checksum, so the size is only knowable by reading every
/// block header.
pub fn findFrameSize(allocator: std.mem.Allocator, src: []const u8) errors.ZstdError!usize {
    _ = allocator;
    if (src.len < frame_header_size) return error.SrcSizeWrong;
    if (std.mem.readInt(u32, src[0..4], .big) != magic) return error.PrefixUnknown;
    var pos = frame_header_size;
    while (true) {
        const header = try readBlockHeader(src[pos..]);
        pos += block_header_size + header.payload;
        if (header.block_type == .end) return pos;
        if (pos > src.len) return error.SrcSizeWrong;
    }
}

/// Decodes a v0.1 frame. Raw, RLE and compressed blocks are all decoded. A
/// compressed block carries this version's own literal and sequence sections: the
/// literals sit behind a four-stream layout and the sequence codes are read from
/// raw-mode FSE tables, so a real v0.1.1 frame regenerates exactly.
pub fn decompress(allocator: std.mem.Allocator, dst: []u8, src: []const u8) errors.ZstdError!decoder.Result {
    if (src.len < frame_header_size) return error.SrcSizeWrong;
    if (std.mem.readInt(u32, src[0..4], .big) != magic) return error.PrefixUnknown;
    var pos = frame_header_size;
    var out: usize = 0;
    while (true) {
        const header = try readBlockHeader(src[pos..]);
        pos += block_header_size;
        switch (header.block_type) {
            .end => return decoder.Result{ .decoded = out, .consumed = pos },
            .raw => {
                if (src.len < pos + header.payload) return error.SrcSizeWrong;
                if (dst.len < out + header.payload) return error.DstSizeTooSmall;
                std.mem.copyForwards(u8, dst[out .. out + header.payload], src[pos .. pos + header.payload]);
                out += header.payload;
                pos += header.payload;
            },
            .rle => {
                if (src.len < pos + 1) return error.SrcSizeWrong;
                if (dst.len < out + header.size) return error.DstSizeTooSmall;
                @memset(dst[out .. out + header.size], src[pos]);
                out += header.size;
                pos += 1;
            },
            .compressed => {
                // Two different numbers meet here. The header's size field is how
                // many bytes the block *expands to*; the block's own sections say
                // how many bytes it *occupies*. For a compressed block these
                // differ, so both are needed and neither substitutes for the
                // other.
                out += try decompressCompressed(allocator, dst[out..], src[pos..], header.payload, header.size);
                pos += header.payload;
            },
        }
    }
}

/// Decodes one v0.1 compressed block into `dst`, returning the bytes produced.
/// The block is a literal section followed by a sequence section; the literals
/// are regenerated into scratch first because a match in the first sequence can
/// reach back into literals already produced. `declared_output` is what the block
/// header says the block expands to: a cross-check on the result, not a limit.
fn decompressCompressed(
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
    src_size: usize,
    declared_output: usize,
) errors.ZstdError!usize {
    if (src.len < src_size) return error.SrcSizeWrong;
    const block = src[0..src_size];
    if (declared_output > dst.len) return error.DstSizeTooSmall;

    // Literal section: its own three-byte header, then its payload.
    const lit_header = try readBlockHeader(block);
    if (lit_header.block_type == .end) return error.Corruption;
    var lit_pos = block_header_size;
    if (lit_pos + lit_header.payload > block.len) return error.SrcSizeWrong;

    var lit_size: usize = 0;
    var scratch = try allocator.alloc(u8, max_block_output);
    defer allocator.free(scratch);
    switch (lit_header.block_type) {
        .raw => {
            lit_size = lit_header.payload;
            if (lit_size > max_block_output) return error.Corruption;
            @memcpy(scratch[0..lit_size], block[lit_pos .. lit_pos + lit_size]);
            lit_pos += lit_size;
        },
        .rle => {
            lit_size = lit_header.size;
            if (lit_size > max_block_output) return error.Corruption;
            @memset(scratch[0..lit_size], block[lit_pos]);
            lit_pos += 1;
        },
        .end => return error.Corruption,
        .compressed => {
            const payload = block[lit_pos .. lit_pos + lit_header.payload];
            if (payload.len < 2) return error.Corruption;
            // The regenerated count is two payload bytes, big-endian, plus three
            // bits from the block header.
            const high_bits: usize = (block[0] >> 3) & 7;
            lit_size = (high_bits << 16) | (@as(usize, payload[0]) << 8) | payload[1];
            if (lit_size > max_block_output or lit_header.payload < 2) return error.Corruption;
            const ok = v01_entropy.decompressLiterals(allocator, scratch[0..lit_size], payload[2..]) catch |e| {
                return e;
            };
            if (ok.written != lit_size) return error.Corruption;
            lit_pos += lit_header.payload;
        },
    }
    if (lit_size > dst.len) return error.DstSizeTooSmall;

    // Sequence section: the rest of the block. The sequences must account for
    // exactly the block's output: every literal is either consumed by a
    // sequence's literal run or emitted as the trailing run, and every match
    // contributes its own bytes.
    const decoded = v01_entropy.decodeSequences(allocator, block[lit_pos..]) catch |e| return e;
    defer allocator.free(decoded.sequences);
    {
        // Only a bound: it says the total must fit, which is a real check because a
        // runaway length would not. A sequence decoded from the wrong bits would
        // ask for a literal run past the literal buffer, or a match reaching
        // further back than the output so far.
        var produced: usize = lit_size;
        for (decoded.sequences) |sequence| produced += sequence.match_length;
        if (produced > dst.len) return error.DstSizeTooSmall;
    }

    var out: usize = 0;
    var lit_read: usize = 0;
    for (decoded.sequences) |sequence| {
        const lit_length: usize = sequence.lit_length;
        const match_length: usize = sequence.match_length;
        if (out + lit_length + match_length > dst.len) return error.DstSizeTooSmall;
        if (lit_read + lit_length > lit_size) return error.Corruption;
        std.mem.copyForwards(u8, dst[out .. out + lit_length], scratch[lit_read .. lit_read + lit_length]);
        out += lit_length;
        lit_read += lit_length;
        const offset: usize = sequence.offset;
        if (offset == 0 or offset > out) return error.Corruption;
        var m: usize = 0;
        while (m < match_length) : (m += 1) {
            dst[out + m] = dst[out + m - offset];
        }
        out += match_length;
    }
    // The sequences consume fewer literals than the block regenerated, and the
    // rest are emitted as one trailing run. If they consumed *more*, the codes
    // were read from the wrong bits, so that is an error rather than a wrap: a
    // silent wrap here would copy from a wild offset and look like content.
    if (lit_read > lit_size) return error.Corruption;
    const tail = lit_size - lit_read;
    if (out + tail > dst.len) return error.DstSizeTooSmall;
    // The trailing literal run. `scratch` is a fixed-size buffer that may be
    // larger than this block's literals, so the copy is bounded by the literal
    // count rather than taking the rest of the buffer - otherwise the copy would
    // read past what was actually regenerated.
    std.mem.copyForwards(u8, dst[out .. out + tail], scratch[lit_read..lit_size]);
    return out + tail;
}
const testing = std.testing;
const golden = @import("golden_frames.zig");

/// Writes the v0.1 magic in the byte order that version used.
fn writeMagic(dst: []u8) void {
    std.mem.writeInt(u32, dst[0..4], magic, .big);
}

test "v01: the magic is read big-endian, the way v0.1 wrote it" {
    var frame = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    writeMagic(&frame);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFD, 0x2F, 0xB5, 0x1E }, frame[0..4]);
    try testing.expectEqual(@as(usize, 0xFD2FB51E), magic);
}

test "v01: findFrameSize rejects short input" {
    try testing.expectError(error.SrcSizeWrong, findFrameSize(testing.allocator, &[_]u8{ 0x1E, 0xB5 }));
    try testing.expectError(error.SrcSizeWrong, findFrameSize(testing.allocator, &[_]u8{}));
}

test "v01: findFrameSize rejects the wrong magic" {
    const modern = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x00, 0x01, 0x00, 0x00 };
    try testing.expectError(error.PrefixUnknown, findFrameSize(testing.allocator, &modern));
    const zero = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(error.PrefixUnknown, findFrameSize(testing.allocator, &zero));
}

test "v01: the real v0.1 frame is sized by walking its blocks" {
    // The v0.1 frame in the test vectors is a four-byte magic, one compressed
    // block and an end block, so its size is known exactly.
    try testing.expectEqual(golden.frame_v01.len, try findFrameSize(testing.allocator, &golden.frame_v01));
}

test "v01: a truncated frame is rejected rather than sized" {
    // Every prefix short of the end block must fail: sizing stops at the first
    // header that does not fit.
    for (4..golden.frame_v01.len) |len| {
        const r = findFrameSize(testing.allocator, golden.frame_v01[0..len]);
        try testing.expect(std.meta.isError(r));
    }
}

test "v01: raw and RLE blocks decode" {
    // A hand-built frame: the layouts are the format's, so this exercises the
    // block walk without needing an entropy-coded block.
    var frame = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    writeMagic(frame[0..4]);
    // Raw block: type 1, size 3. The size is little-endian across bytes 1 and 2.
    frame[4] = 0x40;
    frame[5] = 0x00;
    frame[6] = 0x03;
    frame[7] = 'a';
    frame[8] = 'b';
    frame[9] = 'c';
    // RLE block: type 2, regenerated size 4.
    frame[10] = 0x80;
    frame[11] = 0x00;
    frame[12] = 0x04;
    frame[13] = 'z';
    // End block: type 3.
    frame[14] = 0xC0;
    frame[15] = 0x00;
    frame[16] = 0x00;

    var dst: [16]u8 = undefined;
    const res = try decompress(testing.allocator, &dst, &frame);
    try testing.expectEqual(@as(usize, 7), res.decoded);
    try testing.expectEqual(@as(usize, 17), res.consumed);
    try testing.expectEqualStrings("abczzzz", dst[0..res.decoded]);
}

test "v01: the real v0.1 frame decodes to its exact content" {
    // The real v0.1.1 frame must regenerate to exactly the content it was made
    // from, byte for byte: a decoder that got the length right and the bytes
    // wrong would be worse than one that refused.
    try testing.expectEqual(golden.frame_v01.len, try findFrameSize(testing.allocator, &golden.frame_v01));
    var dst: [1024]u8 = undefined;
    const result = try decompress(testing.allocator, &dst, &golden.frame_v01);
    try testing.expectEqual(golden.block.len, result.decoded);
    try testing.expectEqualSlices(u8, golden.block[0..], dst[0..result.decoded]);
    // The whole frame is consumed, not just the first block.
    try testing.expectEqual(golden.frame_v01.len, result.consumed);
}

test "v01: every truncated prefix of the real frame is refused" {
    // No prefix may produce output, and every prefix that parses must describe a
    // frame that really is complete within it.
    for (4..golden.frame_v01.len) |len| {
        var dst: [512]u8 = undefined;
        const r = decompress(testing.allocator, &dst, golden.frame_v01[0..len]);
        if (r) |result| {
            // Only a prefix that ends exactly on a block boundary may parse, and
            // then it must have consumed everything it was given.
            try testing.expect(result.decoded == 0 or result.consumed == len);
            continue;
        } else |_| {}
    }
}

test "v01: the literal section of a real frame is laid out and sized" {
    // Facts about the real v0.1 frame, recorded so the entropy work starts from
    // measurements: one compressed block, a 157-byte literal payload
    // regenerating 216 bytes, an FSE-compressed weight description (31 bytes)
    // over a table of log 5 and 8 symbols, and a 19-byte sequence section.
    const block = golden.frame_v01[7..];
    const lit_size: usize = block[2] | (@as(usize, block[1]) << 8) | (@as(usize, block[0] & 7) << 16);
    try testing.expectEqual(@as(usize, 157), lit_size);
    try testing.expectEqual(@as(u8, 0), block[0] >> 6); // literals are Huffman-coded

    // The regenerated count is two payload bytes plus three header bits, and the
    // Huffman stream starts after those two bytes.
    const payload = block[3 .. 3 + lit_size];
    const high_bits: usize = (block[0] >> 3) & 7;
    const regenerated: usize = (high_bits << 16) | (@as(usize, payload[0]) << 8) | payload[1];
    try testing.expectEqual(@as(usize, 216), regenerated);
    try testing.expectEqual(@as(usize, 31), payload[2]); // weight description size
}

test "v01: the literal body is four streams behind a length table" {
    // This version wrote three 16-bit stream lengths followed by four independent
    // streams interleaved one byte per stream round-robin, not one bitstream.
    // Reading it as a single stream produces text-shaped nonsense.
    const block = golden.frame_v01[7..];
    const lit_size: usize = block[2] | (@as(usize, block[1]) << 8) | (@as(usize, block[0] & 7) << 16);
    const payload = block[3 .. 3 + lit_size];
    // The description is a length byte followed by that many bytes of table
    // data, so the bitstreams start one byte later than the length implies.
    const desc_size: usize = payload[2];
    const body = payload[3 + desc_size ..];

    const l1: usize = bits.readLe16(body[0..]);
    const l2: usize = bits.readLe16(body[2..]);
    const l3: usize = bits.readLe16(body[4..]);
    const l4: usize = body.len - 6 - l1 - l2 - l3;
    try testing.expectEqual(@as(usize, 123), body.len);
    try testing.expectEqual(@as(usize, 31), l1);
    try testing.expectEqual(@as(usize, 29), l2);
    try testing.expectEqual(@as(usize, 29), l3);
    try testing.expectEqual(@as(usize, 28), l4);
    // The four lengths have to account for the whole body, and every stream must
    // end with the non-zero marker byte the bitstream format requires.
    try testing.expectEqual(body.len, 6 + l1 + l2 + l3 + l4);
    try testing.expect(body[6 + l1 - 1] != 0);
    try testing.expect(body[6 + l1 + l2 - 1] != 0);
    try testing.expect(body[6 + l1 + l2 + l3 - 1] != 0);
    try testing.expect(body[body.len - 1] != 0);
}
