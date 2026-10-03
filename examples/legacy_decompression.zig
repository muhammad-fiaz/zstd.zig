//! Historic frames: how they are recognised, and what happens next.
//!
//! Zstandard's frame magic changed several times before v0.8.0 settled on
//! 0xFD2FB528. A frame from one of those versions is still a Zstandard frame, so
//! it is worth recognising: `isLegacy` and `legacyVersion` identify it, and
//! `findFrameSize` measures it.
//!
//! Decoding those bodies is a separate matter, and this example is explicit
//! about it. Five of the seven formats decode: v0.1 through v0.5 each
//! have their own reader, one per format change, and each regenerates a real
//! frame of that version byte for byte to the content it was made from. The
//! v0.6 and v0.7 layouts are not implemented, so those frames report
//! `error.VersionUnsupported`. That is deliberate: a decoder that reports
//! success while producing bytes that were never in the frame is worse than one
//! that refuses.
//!
//! Run with: `zig build run-legacy_decompression`

const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // A frame from the current format, for contrast.
    const modern = try zstd.compress(allocator, "a modern frame is decoded by the normal path");
    defer allocator.free(modern);
    std.debug.print("modern frame magic 0x{X:0>8}: isLegacy={} version={?d}\n\n", .{
        @as(u32, 0xFD2FB528), zstd.legacy.isLegacy(modern), zstd.legacyDetect.legacyVersion(modern),
    });

    // Historic magics, in the byte order each version wrote them. v0.1 wrote its
    // magic big-endian; every later version wrote it little-endian.
    const historic = [_]struct { version: u8, magic: u32, big_endian: bool }{
        .{ .version = 1, .magic = 0xFD2FB51E, .big_endian = true },
        .{ .version = 2, .magic = 0xFD2FB522, .big_endian = false },
        .{ .version = 3, .magic = 0xFD2FB523, .big_endian = false },
        .{ .version = 4, .magic = 0xFD2FB524, .big_endian = false },
        .{ .version = 5, .magic = 0xFD2FB525, .big_endian = false },
        .{ .version = 6, .magic = 0xFD2FB526, .big_endian = false },
        .{ .version = 7, .magic = 0xFD2FB527, .big_endian = false },
    };

    for (historic) |h| {
        var header: [8]u8 = @splat(0);
        if (h.big_endian) {
            std.mem.writeInt(u32, header[0..4], h.magic, .big);
        } else {
            std.mem.writeInt(u32, header[0..4], h.magic, .little);
        }
        const detected = zstd.legacyDetect.legacyVersion(&header);
        std.debug.print("v0.{d} magic 0x{X:0>8}: isLegacy={} version={?d}\n", .{
            h.version, h.magic, zstd.legacy.isLegacy(&header), detected,
        });
        std.debug.assert(detected.? == h.version);
    }

    // Anything that is not a frame is not a historic frame: a one-bit change to a
    // magic number is a different number, not a near miss.
    var near_miss = modern;
    near_miss[3] ^= 0x01;
    std.debug.print("\nnear miss: isLegacy={}\n", .{zstd.legacy.isLegacy(near_miss)});
    std.debug.assert(!zstd.legacy.isLegacy(near_miss));

    // A recognised magic is not a promise to decode. v0.6 and v0.7 have no reader,
    // so a frame carrying one of their magics is refused rather than read as
    // something it is not, and the refusal writes nothing at all.
    var refused: [32]u8 = @splat(0);
    std.mem.writeInt(u32, refused[0..4], 0xFD2FB526, .little);
    @memset(refused[4..], 0x5A);
    var out: [64]u8 = @splat(0x11);
    const outcome = zstd.legacy.decompressLegacy(allocator, &out, &refused);
    std.debug.print("\nv0.6 magic on a body: decode says {any}\n", .{outcome});
    if (outcome) |_| {
        std.debug.print("FAILED: a v0.6 frame reported a result\n", .{});
        return error.UnexpectedSuccess;
    } else |e| {
        std.debug.assert(e == error.VersionUnsupported);
        // Nothing was written: the buffer still holds what the caller put there.
        for (out) |byte| std.debug.assert(byte == 0x11);
    }

    std.debug.print("\nHistoric frames: all seven magics recognised and versioned;\n", .{});
    std.debug.print("v0.1 through v0.5 decode, v0.6 and v0.7 are refused without writing output.\n", .{});
}
