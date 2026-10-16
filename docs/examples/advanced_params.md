---
title: Advanced Params
description: Custom window size, checksums, and search strategies via CompressionOptions.
---

# Advanced Params

`CompressionOptions` allows fine-grained customization of frame generation, including window size limits, checksums, hash logs, chain logs, and search strategy overrides.

## Usage Example

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    for (0..30) |_| try data.appendSlice(allocator, "Advanced parameters example: custom window, checksum, and strategy tuning. ");

    // Derive tuned base parameters for level 12 and windowLog 20
    var base = zstd.getCompressionParameters(12, data.items.len, 20);
    // Explicitly enable XXH64 content checksum verification
    base.checksum = true;

    const compressed = try zstd.compressWithOptions(allocator, data.items, base);
    defer allocator.free(compressed);

    std.debug.print("Advanced compress: {d} -> {d} (strategy={s}, window_log={d})\n", .{
        data.items.len,
        compressed.len,
        @tagName(base.strategy),
        base.windowLog,
    });

    // Inspect frame header without decompressing
    const hdr = try zstd.getFrameHeader(compressed);
    std.debug.assert(hdr.checksumFlag);
    std.debug.assert(hdr.windowSize >= data.items.len);

    const decompressed = try zstd.decompress(allocator, compressed);
    defer allocator.free(decompressed);
    std.debug.assert(std.mem.eql(u8, data.items, decompressed));
    std.debug.print("Decompressed {d} bytes, checksum validated\n", .{decompressed.len});
}
```

## Output

```text
Advanced compress: 2250 -> 94 (strategy=btopt, window_log=20)
Decompressed 2250 bytes, checksum validated
```

## Explanation

1. **`zstd.getCompressionParameters(level, srcSize, windowLog)`**: Computes optimal log table dimensions (`hashLog`, `chainLog`, `searchLog`, `minMatch`, `targetLength`, and `strategy`) for the given compression level and source size.
2. **`checksum = true`**: Generates a 4-byte XXH64 frame content checksum at the end of the frame, ensuring data integrity during decompression.
3. **`zstd.getFrameHeader`**: Reads frame metadata (`windowSize`, `checksumFlag`, `dictId`, `contentSize`) in a zero-allocation call before decoding blocks.

## Run Command

```bash
zig build run-advanced_params
```
