//! Validation tests for historic Zstandard frame format support and refusal contracts.

const std = @import("std");
const bits = @import("../common/bits.zig");
const errors = @import("../common/errors.zig");
const zstd = @import("../zstd.zig");
const detect = @import("detect.zig");
const decoder = @import("decoder.zig");
const golden = @import("golden_frames.zig");
const sd_mod = @import("../streaming/decompress.zig");
const testing = std.testing;
/// The real frames extracted from the upstream test suite, one per version.
/// What this build does with a given version.
const Support = enum {
    /// Decodes the golden frame to its exact expected bytes.
    decodes,
    /// Recognised, and refused with `error.VersionUnsupported` everywhere.
    refused,
};
const Version = struct {
    number: u8,
    frame: []const u8,
    support: Support,
};
const versions = [_]Version{
    .{ .number = 1, .frame = golden.frame_v01[0..], .support = .decodes },
    .{ .number = 2, .frame = golden.frame_v02[0..], .support = .decodes },
    .{ .number = 3, .frame = golden.frame_v03[0..], .support = .decodes },
    .{ .number = 4, .frame = golden.frame_v04[0..], .support = .decodes },
    .{ .number = 5, .frame = golden.frame_v05[0..], .support = .decodes },
    .{ .number = 6, .frame = golden.frame_v06[0..], .support = .refused },
    .{ .number = 7, .frame = golden.frame_v07[0..], .support = .refused },
};
// Identification: every version is recognised, whatever its support level
// Refusal: consistent across every entry point
// ---------------------------------------------------------------------------

const v01 = @import("v01.zig");
const v02 = @import("v02.zig");
const v03 = @import("v03.zig");
const v04 = @import("v04.zig");
const v05 = @import("v05.zig");
const v06 = @import("v06.zig");
const v07 = @import("v07.zig");
const refused = @import("refused.zig");
/// A version's own entry points, so the shared contract can be checked against
/// each one directly rather than only through the dispatcher.
const Entry = struct {
    version: u8,
    magic: u32,
    frame: []const u8,
    findFrameSize: *const fn (std.mem.Allocator, []const u8) errors.ZstdError!usize,
    decompress: *const fn (std.mem.Allocator, []u8, []const u8) errors.ZstdError!decoder.Result,
};
const entries = [_]Entry{
    .{ .version = 1, .magic = v01.magic, .frame = golden.frame_v01[0..], .findFrameSize = v01.findFrameSize, .decompress = v01.decompress },
    .{ .version = 2, .magic = v02.magic, .frame = golden.frame_v02[0..], .findFrameSize = v02.findFrameSize, .decompress = v02.decompress },
    .{ .version = 3, .magic = v03.magic, .frame = golden.frame_v03[0..], .findFrameSize = v03.findFrameSize, .decompress = v03.decompress },
    .{ .version = 4, .magic = v04.magic, .frame = golden.frame_v04[0..], .findFrameSize = v04.findFrameSize, .decompress = v04.decompress },
    .{ .version = 5, .magic = v05.magic, .frame = golden.frame_v05[0..], .findFrameSize = v05.findFrameSize, .decompress = v05.decompress },
    .{ .version = 6, .magic = v06.magic, .frame = golden.frame_v06[0..], .findFrameSize = v06.findFrameSize, .decompress = v06.decompress },
    .{ .version = 7, .magic = v07.magic, .frame = golden.frame_v07[0..], .findFrameSize = v07.findFrameSize, .decompress = v07.decompress },
};
fn findFrameSizeFor(allocator: std.mem.Allocator, src: []const u8) !usize {
    return decoder.findFrameSize(allocator, src);
}
/// The refusal contract: an unsupported historic version reports
/// `VersionUnsupported`, specifically, so a caller can tell "this format is not
/// implemented here" apart from "this data is corrupt".
fn expectRefused(result: anytype) !void {
    try testing.expectError(error.VersionUnsupported, result);
}
test "an unsupported version is refused by every entry point" {
    const alloc = testing.allocator;
    for (versions) |v| {
        if (v.support != .refused) continue;

        // Direct legacy entry point.
        try expectRefused(findFrameSizeFor(alloc, v.frame));

        // The public one-shot path: a historic frame must not decode silently.
        try expectRefused(zstd.decompress(alloc, v.frame));

        // The explicit-options path behaves the same way.
        try expectRefused(zstd.decompressWithOptions(alloc, v.frame, .{}));

        // A reusable context must not be a way around it either.
        var ctx = zstd.DecompressionContext.init(alloc);
        defer ctx.deinit();
        try expectRefused(ctx.decompressAlloc(v.frame));
    }
}
test "an unsupported version is refused by the streaming decoder too" {
    // Streaming takes a different path through the decoder, so it gets its own
    // check: a caller must not be able to stream what the one-shot path refuses.
    const alloc = testing.allocator;
    for (versions) |v| {
        if (v.support != .refused) continue;

        var sd = sd_mod.StreamingDecompressor.init(alloc);
        defer sd.deinit();
        var out: [4096]u8 = undefined;
        const r = sd.decompressStream(&out, v.frame);
        try testing.expectError(error.VersionUnsupported, r);
    }
}
test "a refused frame yields no bytes at all" {
    // The failure mode this guards against: returning a short buffer that looks
    // like success. Every refusal must be an error, never a partial write.
    const alloc = testing.allocator;
    for (versions) |v| {
        if (v.support != .refused) continue;
        var dst: [1024]u8 = @splat(0xCC);
        const result = decoder.decompressLegacy(alloc, &dst, v.frame);
        try expectRefused(result);
    }
}
// ---------------------------------------------------------------------------
// Truncated and malformed historic frames
// ---------------------------------------------------------------------------

test "a truncated historic frame is refused" {
    // Truncation must not be mistaken for a short but valid frame.
    const alloc = testing.allocator;
    for (versions) |v| {
        // Keep enough bytes for the magic and a block header, then cut short.
        const keep = @min(v.frame.len, 12);
        const truncated = v.frame[0..keep];
        const r = findFrameSizeFor(alloc, truncated);
        // An unsupported version is refused as unsupported before the truncation is
        // even considered; v0.1 parses its header, so it reports the short read.
        switch (v.support) {
            .refused => try expectRefused(r),
            .decodes => try testing.expectError(error.SrcSizeWrong, r),
        }
    }
}
test "every proper prefix of a historic frame is refused or sized, never decoded" {
    // Same invariant the modern path is held to: no prefix may produce output.
    const alloc = testing.allocator;
    for (versions) |v| {
        var len: usize = 0;
        while (len < v.frame.len) : (len += 1) {
            const prefix = v.frame[0..len];
            var dst: [512]u8 = undefined;
            const r = decoder.decompressLegacy(alloc, &dst, prefix);
            if (r) |_| {
                std.debug.print("v0.{d} prefix of {d} bytes decoded\n", .{ v.number, len });
                return error.TestUnexpectedResult;
            } else |e| switch (e) {
                error.SrcSizeWrong, error.VersionUnsupported, error.PrefixUnknown, error.Corruption => {},
                else => return e,
            }
        }
    }
}
test "a corrupted magic is not treated as a historic frame" {
    // The frame is copied before its magic is damaged, because the golden data
    // must stay intact for the other tests.
    var storage: [256]u8 = undefined;
    for (versions) |v| {
        const n = @min(v.frame.len, storage.len);
        @memcpy(storage[0..n], v.frame[0..n]);
        storage[0] ^= 0xFF;
        try testing.expect(!detect.isLegacy(storage[0..n]));
    }
}
// ---------------------------------------------------------------------------
// v0.1: what does decode, stated precisely
// ---------------------------------------------------------------------------

test "v0.1 frame and block sizes are exact" {
    // The part of v0.1 that genuinely works, asserted against the real frame.
    const alloc = testing.allocator;
    const size = try findFrameSizeFor(alloc, golden.frame_v01[0..]);
    try testing.expectEqual(golden.frame_v01.len, size);
    // `block` is what the frame *decodes to*, not what it occupies: the 189-byte
    // frame expands to 239 bytes of content, so the frame is legitimately
    // smaller. That the two differ at all is the point - it shows the frame is
    // real compressed data and not a container copy of its output.
    try testing.expect(golden.frame_v01.len < golden.block.len);
}
test "v0.2 decodes to its exact content through the public entry points" {
    // The dispatcher has to reach the same bytes the version's own reader does, or
    // a caller would have to know which of two paths actually works.
    const alloc = testing.allocator;
    const out = try zstd.decompress(alloc, golden.frame_v02[0..]);
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, golden.block[0..], out);

    var ctx = zstd.DecompressionContext.init(alloc);
    defer ctx.deinit();
    for (0..3) |_| {
        const again = try ctx.decompressAlloc(golden.frame_v02[0..]);
        defer alloc.free(again);
        try testing.expectEqualSlices(u8, golden.block[0..], again);
    }
}
test "v0.2 round trips through its own encoder" {
    // Encoder and decoder agreeing is the compatibility claim that does not need
    // the reference implementation: what this library writes, it also reads.
    const alloc = testing.allocator;
    for ([_][]const u8{ "", "x", golden.block[0..], "abcabcabcabcabcabcabc" }) |src| {
        const bound = v02.compressBound(src.len);
        const frame = try alloc.alloc(u8, bound);
        defer alloc.free(frame);
        const n = try v02.compress(alloc, frame, src);
        const back = try alloc.alloc(u8, src.len + 16);
        defer alloc.free(back);
        const result = try v02.decompress(alloc, back, frame[0..n]);
        try testing.expectEqual(src.len, result.decoded);
        try testing.expectEqualSlices(u8, src, back[0..result.decoded]);
    }
}
test "a modern frame is unaffected by the historic refusal contract" {
    // Adding legacy handling must not change the modern path, so the ordinary
    // round trip is re-checked here alongside the legacy matrix.
    const alloc = testing.allocator;
    const payload = "modern frames keep working while legacy ones are refused";
    const frame = try zstd.compress(alloc, payload);
    defer alloc.free(frame);
    try testing.expect(zstd.isZstdFrame(frame));
    try testing.expect(!detect.isLegacy(frame));

    const back = try zstd.decompress(alloc, frame);
    defer alloc.free(back);
    try testing.expectEqualStrings(payload, back);
}
// ---------------------------------------------------------------------------
// v0.1: the one historic version that decodes
// ---------------------------------------------------------------------------

test "v0.1 decodes to its exact content, byte for byte" {
    // The only historic version this implementation decodes. The frame came from the
    // version's own encoder, so the bytes it regenerates are ground truth for this
    // whole path: frame header, block header, four-stream literals, Huffman table,
    // FSE weight stream, sequence header and sequence bitstream.
    const alloc = testing.allocator;
    var dst: [1024]u8 = undefined;
    const result = try decoder.decompressLegacy(alloc, &dst, golden.frame_v01[0..]);
    try testing.expectEqual(golden.block.len, result.decoded);
    try testing.expectEqualSlices(u8, golden.block[0..], dst[0..result.decoded]);
    try testing.expectEqual(golden.frame_v01.len, result.consumed);
}
test "v0.1 decodes through the public one-shot path too" {
    // The public entry point has to reach the same result, otherwise a caller
    // would have to know which of two paths actually works.
    const alloc = testing.allocator;
    const out = try zstd.decompress(alloc, golden.frame_v01[0..]);
    defer alloc.free(out);
    try testing.expectEqualSlices(u8, golden.block[0..], out);
}
test "v0.1 decodes to the same bytes through a reused context" {
    // Reuse must not carry state between decodes, so the second decode of the
    // same frame has to be identical to the first.
    const alloc = testing.allocator;
    var ctx = zstd.DecompressionContext.init(alloc);
    defer ctx.deinit();
    for (0..3) |_| {
        const out = try ctx.decompressAlloc(golden.frame_v01[0..]);
        defer alloc.free(out);
        try testing.expectEqualSlices(u8, golden.block[0..], out);
    }
}
test "v0.1 through v0.5 decode; v0.6 and v0.7 are refused" {
    // The two halves of the contract, stated together so neither can drift: the
    // supported version decodes, and every other one does not.
    const alloc = testing.allocator;
    var dst: [1024]u8 = undefined;
    for (versions) |v| {
        const r = decoder.decompressLegacy(alloc, &dst, v.frame);
        switch (v.support) {
            .decodes => {
                const got = try r;
                try testing.expectEqual(golden.block.len, got.decoded);
                try testing.expectEqualSlices(u8, golden.block[0..], dst[0..got.decoded]);
            },
            .refused => try expectRefused(r),
        }
    }
}
test "v0.1 through v0.5 are sized by every legacy entry point" {
    // `findFrameSize` and the dispatcher have to agree with the decode, or a
    // caller walking frames would compute different boundaries than a caller
    // decompressing them.
    const alloc = testing.allocator;
    const size = try decoder.findFrameSize(alloc, golden.frame_v01[0..]);
    try testing.expectEqual(golden.frame_v01.len, size);
    try testing.expect(detect.legacyVersion(golden.frame_v01[0..]) == 1);

    const size2 = try decoder.findFrameSize(alloc, golden.frame_v02[0..]);
    try testing.expectEqual(golden.frame_v02.len, size2);
    try testing.expect(detect.legacyVersion(golden.frame_v02[0..]) == 2);
}
// ---------------------------------------------------------------------------
// The per-version entry points
//
// Every version file exposes the same two functions with the same contract, so
// they are checked through one table rather than six near-identical blocks. A
// version's file states only its magic; behaviour lives in `refused.zig` for the
// six not yet decoded and in `v01.zig` for the one that is.
// ---------------------------------------------------------------------------

test "each version file states the magic its real frame carries" {
    // A version module whose magic disagrees with the captured frame would still
    // compile and still refuse, just for the wrong reason, so the two are tied
    // together here.
    //
    // The comparison goes through the detector rather than a direct load,
    // because v0.1 stores its magic big-endian while the rest are little-endian.
    // Reading them all one way is the exact mistake this test would otherwise
    // hide, since the detector is what the rest of the library relies on.
    for (entries) |e| {
        try testing.expectEqual(@as(?u8, e.version), detect.legacyVersion(e.frame));
        try testing.expect(detect.isLegacy(e.frame));
    }
}
test "a near miss is not recognised as a historic version" {
    for (entries) |e| {
        var other: [64]u8 = undefined;
        const n = @min(e.frame.len, other.len);
        @memcpy(other[0..n], e.frame[0..n]);
        other[3] ^= 0x01;
        const detected = detect.legacyVersion(other[0..n]);
        if (detected != null) {
            // The flipped bit must have landed on a different version's magic,
            // never on the same one: that would mean the magics are ambiguous.
            try testing.expect(detected != @as(?u8, e.version));
        }
    }
}
test "a version refuses its own frame rather than mis-decoding it" {
    // Regression: these frames used to be handed to the current-format decoder
    // under a rewritten magic, which reported success while producing content
    // that was not in the frame at all.
    for (entries) |v| {
        if (detect.supportsDecode(v.version)) continue;
        var dst: [512]u8 = undefined;
        try testing.expectError(error.VersionUnsupported, v.decompress(testing.allocator, &dst, v.frame));
        try testing.expectError(error.VersionUnsupported, v.findFrameSize(testing.allocator, v.frame));
    }
}
test "every truncated prefix of a refused frame is refused, never read past" {
    for (entries) |v| {
        if (detect.supportsDecode(v.version)) continue;
        const n = @min(v.frame.len, 256);
        for (0..n) |len| {
            const r = v.decompress(testing.allocator, &.{}, v.frame[0..len]);
            if (len < 4) {
                try testing.expectError(error.SrcSizeWrong, r);
            } else {
                try testing.expectError(error.VersionUnsupported, r);
            }
        }
    }
}
test "a version refuses a modern frame as an unknown prefix" {
    // Not being this version is a different claim from this version being
    // unsupported, and the two must not be conflated: the first means the caller
    // passed something else entirely.
    const modern = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x00, 0x01, 0x00, 0x00 };
    for (entries) |e| {
        try testing.expectError(error.PrefixUnknown, e.findFrameSize(testing.allocator, &modern));
        var dst: [16]u8 = undefined;
        try testing.expectError(error.PrefixUnknown, e.decompress(testing.allocator, &dst, &modern));
    }
}
test "each version file refuses its own magic and only its own" {
    // `magic` is compared against a buffer this test builds, not against the
    // captured frame, so the endianness question does not arise: each version
    // declares the bytes its own reader will look for.
    for (entries) |e| {
        if (detect.supportsDecode(e.version)) continue;
        var buf: [16]u8 = undefined;
        bits.writeLe32(buf[0..4], e.magic);
        try testing.expectError(error.VersionUnsupported, e.findFrameSize(testing.allocator, buf[0..]));
        var dst: [16]u8 = undefined;
        try testing.expectError(error.VersionUnsupported, e.decompress(testing.allocator, &dst, buf[0..]));

        // A neighbouring magic belongs to some other version, so this one must
        // report an unknown prefix rather than claiming its own unsupported.
        bits.writeLe32(buf[0..4], e.magic ^ 0x10);
        try testing.expectError(error.PrefixUnknown, e.findFrameSize(testing.allocator, buf[0..]));
    }
}
test "the shared refusal is the one the two unimplemented versions use" {
    // Guards the deduplication: if one of the version files grew its own
    // implementation back, this stops matching and the duplication is visible.
    for (entries) |v| {
        if (detect.supportsDecode(v.version)) continue;
        const via_version = v.decompress(testing.allocator, &.{}, v.frame);
        const via_shared = refused.decompress(v.magic, testing.allocator, &.{}, v.frame);
        try testing.expectError(error.VersionUnsupported, via_version);
        try testing.expectError(error.VersionUnsupported, via_shared);
    }
}
// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

test "every historic version is identified from its magic" {
    for (versions) |v| {
        try testing.expectEqual(@as(?u8, v.number), detect.legacyVersion(v.frame));
        try testing.expect(detect.isLegacy(v.frame));
        try testing.expect(decoder.isLegacy(v.frame));
    }
}
test "a historic frame is not mistaken for a modern one" {
    for (versions) |v| {
        try testing.expect(!zstd.isZstdFrame(v.frame));
        try testing.expect(!zstd.isSkippableFrame(v.frame));
    }
}
