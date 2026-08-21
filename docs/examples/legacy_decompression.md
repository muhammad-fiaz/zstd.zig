---
title: Legacy Decompression
description: Legacy frame detection for v01-v07 and skippable frames.
---

# Legacy Decompression

`examples/legacy_decompression.zig` — `zstd.legacy` and `legacy_detect`.

## Client Code

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const legacy_magics = [_]struct { version: u8, magic: u32 }{
        .{ .version = 1, .magic = 0xFD2FB521 },
        .{ .version = 2, .magic = 0xFD2FB522 },
        .{ .version = 3, .magic = 0xFD2FB523 },
        .{ .version = 4, .magic = 0xFD2FB524 },
        .{ .version = 5, .magic = 0xFD2FB525 },
        .{ .version = 6, .magic = 0xFD2FB526 },
        .{ .version = 7, .magic = 0xFD2FB527 },
    };

    for (legacy_magics) |lm| {
        var frame: [4]u8 = undefined;
        frame[0] = @truncate(lm.magic);
        frame[1] = @truncate(lm.magic >> 8);
        frame[2] = @truncate(lm.magic >> 16);
        frame[3] = @truncate(lm.magic >> 24);
        std.debug.print("Legacy v{d:0>2} magic 0x{X:0>8} isLegacy={} version={?d}\n", .{ lm.version, lm.magic, zstd.legacy.isLegacy(&frame), zstd.legacy_detect.legacyVersion(&frame) });
        std.debug.assert(zstd.legacy.isLegacy(&frame));
        std.debug.assert(zstd.legacy_detect.legacyVersion(&frame).? == lm.version);
    }

    const modern_data = "modern frame test";
    const modern_compressed = try zstd.compress(allocator, modern_data);
    defer allocator.free(modern_compressed);
    std.debug.assert(!zstd.legacy.isLegacy(modern_compressed));
    std.debug.assert(zstd.isFrame(modern_compressed));
    std.debug.print("Modern frame correctly not detected as legacy\n", .{});

    const decompressed = try zstd.decompress(allocator, modern_compressed);
    defer allocator.free(decompressed);
    std.debug.assert(std.mem.eql(u8, modern_data, decompressed));
    std.debug.print("Legacy decoder transparently handles modern frames\n", .{});

    var skip_buf: [32]u8 = undefined;
    const skip_len = zstd.writeSkippableFrame(&skip_buf, "legacy meta", 4);
    std.debug.assert(zstd.isSkippableFrame(skip_buf[0..skip_len]));
    std.debug.print("Skippable frame written {d} bytes\n", .{skip_len});
}
```

## Output

```text
Legacy v01 magic 0xFD2FB521 isLegacy=true version=1
Legacy v02 magic 0xFD2FB522 isLegacy=true version=2
Legacy v03 magic 0xFD2FB523 isLegacy=true version=3
Legacy v04 magic 0xFD2FB524 isLegacy=true version=4
Legacy v05 magic 0xFD2FB525 isLegacy=true version=5
Legacy v06 magic 0xFD2FB526 isLegacy=true version=6
Legacy v07 magic 0xFD2FB527 isLegacy=true version=7
Modern frame correctly not detected as legacy
Legacy decoder transparently handles modern frames
Skippable frame written 19 bytes
```

## Explanation

- `zstd.legacy.isLegacy` checks `0xFD2FB521-27`; `legacyVersion` returns `1..7` or `null`. Modern `0xFD2FB528` is not legacy.
- `zstd.decompress` transparently delegates to `src/legacy/decoder.zig` when legacy is detected, otherwise to `src/decompress/decompress.zig`.
- `isSkippableFrame`/`writeSkippableFrame` handle `0x184D2A50` range, preserved across legacy detection.

Run:

```bash
zig build run-legacy_decompression
```
