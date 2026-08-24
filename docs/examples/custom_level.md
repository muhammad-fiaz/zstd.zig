---
title: Custom Level
description: Numeric compression levels 1-22 via compressWithLevel.
---

# Custom Level

`examples/custom_level.zig` — `i32` levels (not enum) via `zstd.compressWithLevel`.

## Client Code

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const data = "Text with moderate repetitiveness for level testing. " ** 20;
    for ([_]i32{ 1, 3, 6, 9, 15, 19 }) |level| {
        {
            const c = try zstd.compressWithLevel(allocator, data, level);
            defer allocator.free(c);
            std.debug.print("Level {d}: {d} -> {d} bytes ({d:.1}%)\n", .{ level, data.len, c.len, @as(f64, @floatFromInt(c.len)) / @as(f64, @floatFromInt(data.len)) * 100 });
            const d = try zstd.decompress(allocator, c);
            defer allocator.free(d);
            std.debug.assert(std.mem.eql(u8, data, d));
        }
    }
}
```

## Output

```text
Level 1: 1060 -> 123 bytes (11.6%)
Level 3: 1060 -> 123 bytes (11.6%)
Level 6: 1060 -> 123 bytes (11.6%)
Level 9: 1060 -> 123 bytes (11.6%)
Level 15: 1060 -> 123 bytes (11.6%)
Level 19: 1060 -> 123 bytes (11.6%)
```

*For this medium-entropy text, levels 1-19 all emit `Raw_Block`/`RLE_Block` (ratio ~100%). More repetitive data shows better ratios at higher levels. `minCLevel() = -131072`, `maxCLevel() = 22`, `defaultCLevel() = 3`.*

## Explanation

- `compressWithLevel` maps `level` → `CompressionOptions` via `getCompressionParameters` (`window_log`, `hash_log`, `chain_log`, `strategy`).
- Helpers `zstd.minCLevel()`, `maxCLevel()`, `defaultCLevel()` expose bounds.

Run:

```bash
zig build run-custom_level
```
