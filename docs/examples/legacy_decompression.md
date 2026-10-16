---
title: Legacy Decompression
description: Historic frame detection and native decompression for v0.1 through v0.7.
---

# Legacy Decompression

Before the Zstandard specification finalized on magic number `0xFD2FB528`, historical versions from v0.1 to v0.7 used distinct magic numbers and evolving frame layouts. `zstd.zig` includes pure Zig decoding support for all seven historical versions (v0.1 through v0.7).

## Usage Example

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Contrast against a modern Zstandard frame
    const modern = try zstd.compress(allocator, "a modern frame is decoded by the normal path");
    defer allocator.free(modern);
    std.debug.print("modern frame magic 0x{X:0>8}: isLegacy={} version={?d}\n\n", .{
        @as(u32, 0xFD2FB528),
        zstd.legacy.isLegacy(modern),
        zstd.legacyDetect.legacyVersion(modern),
    });

    // 2. Historic magic numbers across all seven versions
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
        const supported = zstd.legacyDetect.supportsDecode(h.version);
        std.debug.print("v0.{d} magic 0x{X:0>8}: isLegacy={} version={?d} decodes={}\n", .{
            h.version,
            h.magic,
            zstd.legacy.isLegacy(&header),
            detected,
            supported,
        });
        std.debug.assert(detected.? == h.version);
        std.debug.assert(supported);
    }

    // 3. Near-miss non-frame validation
    var near_miss = modern;
    near_miss[3] ^= 0x01;
    std.debug.print("\nnear miss: isLegacy={}\n", .{zstd.legacy.isLegacy(near_miss)});
    std.debug.assert(!zstd.legacy.isLegacy(near_miss));

    // 4. Safe rejection of malformed legacy frame
    var malformed: [32]u8 = @splat(0);
    std.mem.writeInt(u32, malformed[0..4], 0xFD2FB526, .little);
    @memset(malformed[4..], 0x5A);
    var out: [64]u8 = @splat(0x11);
    const outcome = zstd.legacy.decompressLegacy(allocator, &out, &malformed);
    std.debug.print("\nv0.6 magic on a malformed body: decode safely rejected with {any}\n", .{outcome});
    if (outcome) |_| {
        return error.UnexpectedSuccess;
    } else |_| {
        for (out) |byte| std.debug.assert(byte == 0x11);
    }

    std.debug.print("\nHistoric frames: all seven versions (v0.1..v0.7) recognised, versioned, and supported.\n", .{});
}
```

## Output

```text
modern frame magic 0xFD2FB528: isLegacy=false version=null

v0.1 magic 0xFD2FB51E: isLegacy=true version=1 decodes=true
v0.2 magic 0xFD2FB522: isLegacy=true version=2 decodes=true
v0.3 magic 0xFD2FB523: isLegacy=true version=3 decodes=true
v0.4 magic 0xFD2FB524: isLegacy=true version=4 decodes=true
v0.5 magic 0xFD2FB525: isLegacy=true version=5 decodes=true
v0.6 magic 0xFD2FB526: isLegacy=true version=6 decodes=true
v0.7 magic 0xFD2FB527: isLegacy=true version=7 decodes=true

near miss: isLegacy=false

v0.6 magic on a malformed body: decode safely rejected with error.SrcSizeWrong

Historic frames: all seven versions (v0.1..v0.7) recognised, versioned, and supported.
```

## Explanation

1. **`zstd.legacy.isLegacy(src)`**: Detects any historical Zstandard frame magic number (`0xFD2FB51E` through `0xFD2FB527`).
2. **`zstd.legacyDetect.legacyVersion(src)`**: Returns the detected numeric major version (`1` through `7`) or `null` for modern/non-legacy frames.
3. **Full Native Decoding**: All seven versions (v0.1, v0.2, v0.3, v0.4, v0.5, v0.6, and v0.7) have dedicated native Zig decoders implementing their respective historical entropy models and block structures.
4. **Safety**: Corrupted or incomplete historical frames return clean errors without writing out of bounds or leaking memory.

## Run Command

```bash
zig build run-legacy_decompression
```
