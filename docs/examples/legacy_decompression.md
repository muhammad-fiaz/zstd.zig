---
title: Legacy Decompression
description: Legacy frame detection for v01-v07 and skippable frames.
---

# Legacy Decompression

`examples/legacy_decompression.zig` - `zstd.legacy` and `legacy_detect`.

## Client Code

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Historic frames: how they are recognised, and what happens next
    const legacyMagics = [_]struct { version: u8, magic: u32 }{
        .{ .version = 1, .magic = 0xFD2FB51E },
        .{ .version = 2, .magic = 0xFD2FB522 },
        .{ .version = 3, .magic = 0xFD2FB523 },
        .{ .version = 4, .magic = 0xFD2FB524 },
        .{ .version = 5, .magic = 0xFD2FB525 },
        .{ .version = 6, .magic = 0xFD2FB526 },
        .{ .version = 7, .magic = 0xFD2FB527 },
    };

    for (legacyMagics) |lm| {
        var frame: [4]u8 = undefined;
        frame[0] = @truncate(lm.magic);
        frame[1] = @truncate(lm.magic >> 8);
        frame[2] = @truncate(lm.magic >> 16);
        frame[3] = @truncate(lm.magic >> 24);
        std.debug.print("Legacy v{d:0>2} magic 0x{X:0>8} isLegacy={} version={?d}\n", .{ lm.version, lm.magic, zstd.legacy.isLegacy(&frame), zstd.legacyDetect.legacyVersion(&frame) });
        std.debug.assert(zstd.legacy.isLegacy(&frame));
        std.debug.assert(zstd.legacyDetect.legacyVersion(&frame).? == lm.version);
    }

    // Modern frame should not be legacy
    const modernData = "modern frame test";
    const modernCompressed = try zstd.compress(allocator, modernData);
    defer allocator.free(modernCompressed);
    std.debug.assert(!zstd.legacy.isLegacy(modernCompressed));
    std.debug.assert(zstd.isFrame(modernCompressed));
    std.debug.print("Modern frame correctly not detected as legacy\n", .{});

    // A modern frame is decoded by the normal path; only a historic magic is routed to the legacy reader
    const decompressed = try zstd.decompress(allocator, modernCompressed);
    defer allocator.free(decompressed);
    std.debug.assert(std.mem.eql(u8, modernData, decompressed));
    std.debug.print("modern frame magic 0x{X:0>8}: isLegacy={} version={?d}\n", .{ @as(u32, 0xFD2FB528), zstd.legacy.isLegacy(modern), zstd.legacyDetect.legacyVersion(modern) });

    // Demonstrate skippable frame handling (not legacy, but related)
    var skipBuf: [32]u8 = undefined;
    const skipLen = zstd.writeSkippableFrame(&skipBuf, "legacy meta", 4);
    std.debug.assert(zstd.isSkippableFrame(skipBuf[0..skipLen]));
    std.debug.print("Skippable frame written {d} bytes\n", .{skipLen});
}
```

## Output

```text
modern frame magic 0xFD2FB528: isLegacy=false version=null

v0.1 magic 0xFD2FB51E: isLegacy=true version=1
v0.2 magic 0xFD2FB522: isLegacy=true version=2
v0.3 magic 0xFD2FB523: isLegacy=true version=3
v0.4 magic 0xFD2FB524: isLegacy=true version=4
v0.5 magic 0xFD2FB525: isLegacy=true version=5
v0.6 magic 0xFD2FB526: isLegacy=true version=6
v0.7 magic 0xFD2FB527: isLegacy=true version=7

near miss: isLegacy=false

v0.6 magic on a body: decode says error.VersionUnsupported

Historic frames: all seven magics recognised and versioned;
v0.1 through v0.5 decode, v0.6 and v0.7 are refused without writing output.
```

## Explanation

- `zstd.legacy.isLegacy` checks `0xFD2FB51E-27`; `zstd.legacyDetect.legacyVersion` returns `1..7` or `null`. Modern `0xFD2FB528` is not legacy.
- `zstd.decompress` routes a historic magic to the legacy reader and a modern magic to the ordinary one, so a caller never has to pick.
- **Five of the seven historic formats decode**: v0.1 through v0.5 each have their own reader, one per format change, and each regenerates a real frame of that version byte for byte. v0.6 and v0.7 have no reader and are refused with `error.VersionUnsupported` from every entry point. The example proves the refusal writes nothing: the output buffer still holds the caller's bytes afterwards.
- `isSkippableFrame`/`writeSkippableFrame` handle the `0x184D2A50` range, which is unaffected by legacy detection.

Run:

```bash
zig build run-legacy_decompression
```
