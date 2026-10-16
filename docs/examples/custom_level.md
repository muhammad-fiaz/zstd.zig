---
title: Custom Level
description: Numeric compression levels 1-22 via compressWithLevel.
---

# Custom Level

Zstandard supports compression levels from negative levels (ultra-fast) up to level 22 (maximum ratio). In `zstd.zig`, compression levels are plain `i32` values.

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
    for (0..20) |_| try data.appendSlice(allocator, "Text with moderate repetitiveness for level testing. ");

    // Test a sweep of levels: 1 (fast), 3 (default), up to 19 (high ratio)
    for ([_]i32{ 1, 3, 6, 9, 15, 19 }) |level| {
        const c = try zstd.compressWithLevel(allocator, data.items, level);
        defer allocator.free(c);
        std.debug.print("Level {d}: {d} -> {d} bytes ({d:.1}%)\n", .{
            level,
            data.items.len,
            c.len,
            @as(f64, @floatFromInt(c.len)) / @as(f64, @floatFromInt(data.items.len)) * 100.0,
        });

        const d = try zstd.decompress(allocator, c);
        defer allocator.free(d);
        std.debug.assert(std.mem.eql(u8, data.items, d));
    }
}
```

## Output

```text
Level 1: 1060 -> 72 bytes (6.8%)
Level 3: 1060 -> 72 bytes (6.8%)
Level 6: 1060 -> 72 bytes (6.8%)
Level 9: 1060 -> 72 bytes (6.8%)
Level 15: 1060 -> 72 bytes (6.8%)
Level 19: 1060 -> 72 bytes (6.8%)
```

## Explanation

1. **`zstd.compressWithLevel(allocator, src, level)`**: Translates `level` to internal search and entropy parameters via `getCompressionParameters(level, src.len, 0)`.
2. **Level Bounds**:
   - `zstd.minCLevel()` = `-131072` (fastest modes)
   - `zstd.maxCLevel()` = `22` (maximum compression)
   - `zstd.defaultCLevel()` = `3` (default compression)
3. **Behavior**: On data with simple repeating sentences, lower levels already detect optimal matches immediately. On larger, diverse datasets, higher levels explore deeper hash chains and binary trees to discover additional matches.

## Run Command

```bash
zig build run-custom_level
```
