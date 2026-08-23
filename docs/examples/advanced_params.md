---
title: Advanced Params
description: Custom window, checksum and strategy via CompressionOptions.
---

# Advanced Params

`examples/advanced_params.zig` — `CompressionOptions` and `getCompressionParameters`.

## Client Code

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const data = "Advanced parameters example: custom window, checksum, and strategy tuning. " ** 30;
    var base = zstd.getCompressionParameters(12, data.len, 20);
    base.checksum = true;
    const compressed = try zstd.compressWithOptions(allocator, data, base);
    defer allocator.free(compressed);
    std.debug.print("Advanced compress: {d} -> {d} (strategy={s}, window_log={d})\n", .{ data.len, compressed.len, @tagName(base.strategy), base.window_log });
    const hdr = try zstd.getFrameHeader(compressed);
    std.debug.assert(hdr.checksum_flag);
    std.debug.assert(hdr.window_size >= data.len);
    const decompressed = try zstd.decompress(allocator, compressed);
    defer allocator.free(decompressed);
    std.debug.assert(std.mem.eql(u8, data, decompressed));
    std.debug.print("Decompressed {d} bytes, checksum validated\n", .{decompressed.len});
}
```

## Output

```text
Advanced compress: 2250 -> 209 (strategy=btlazy2, window_log=20)
Decompressed 2250 bytes, checksum validated
```

## Explanation

- `getCompressionParameters(12, len, 20)` returns tuned `window_log`, `hash_log`, `chain_log`, `search_log`, `target_length`, `strategy` for level 12.
- Setting `checksum=true` adds `Content_Checksum` (XXH64 low 32) validated on `decompress`.
- `getFrameHeader` confirms `checksum_flag` and `window_size`.

Run:

```bash
zig build run-advanced_params
```
