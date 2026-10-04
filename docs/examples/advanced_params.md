---
title: Advanced Params
description: Custom window, checksum and strategy via CompressionOptions.
---

# Advanced Params

`examples/advanced_params.zig` - `CompressionOptions` and `getCompressionParameters`.

## Client Code

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

    var base = zstd.getCompressionParameters(12, data.items.len, 20);
    base.checksum = true;
    const compressed = try zstd.compressWithOptions(allocator, data.items, base);
    defer allocator.free(compressed);
    std.debug.print("Advanced compress: {d} -> {d} (strategy={s}, windowLog={d})\n", .{ data.items.len, compressed.len, @tagName(base.strategy), base.windowLog });
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
Advanced compress: 2250 -> 94 (strategy=btlazy2, window_log=20)
Decompressed 2250 bytes, checksum validated
```

## Explanation

- `getCompressionParameters(12, len, 20)` returns tuned `windowLog`, `hashLog`, `chainLog`, `searchLog`, `targetLength`, `strategy` for level 12.
- Setting `checksum=true` adds `Content_Checksum` (XXH64 low 32) validated on `decompress`.
- `getFrameHeader` confirms `checksumFlag` and `windowSize`.

Run:

```bash
zig build run-advanced_params
```
