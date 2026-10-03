---
title: Custom Level
description: Numeric compression levels 1-22 via compressWithLevel.
---

# Custom Level

`examples/custom_level.zig` - `i32` levels (not enum) via `zstd.compressWithLevel`.

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
    for (0..20) |_| try data.appendSlice(allocator, "Text with moderate repetitiveness for level testing. ");

    for ([_]i32{ 1, 3, 6, 9, 15, 19 }) |level| {
        const c = try zstd.compressWithLevel(allocator, data.items, level);
        defer allocator.free(c);
        std.debug.print("Level {d}: {d} -> {d} bytes ({d:.1}%)\n", .{ level, data.items.len, c.len, @as(f64, @floatFromInt(c.len)) / @as(f64, @floatFromInt(data.items.len)) * 100 });
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

Every level gives the same size here, and that is the point of the example rather
than a disappointment. The input is 20 copies of one sentence, so the match finder
finds the repeat immediately at level 1 and no additional search effort can
improve on it. Level controls how hard the encoder looks for matches, and there is
nothing left to find. Levels separate on inputs with more structure, or where a
level trades speed for a better parse.

## Explanation

- `compressWithLevel(allocator, src, level)` maps the level through
  `getCompressionParameters` to a `CompressionOptions`, then calls the same
  one-shot path as `compressWithOptions`.
- Bounds: `zstd.minCLevel()` is `-131072`, `zstd.maxCLevel()` is `22`,
  `zstd.defaultCLevel()` is `3`. Levels are plain `i32` across that whole range.
- Each frame is decompressed and compared, so a level that produced a smaller but
  wrong frame would fail here rather than silently pass.

Run:

```bash
zig build run-custom_level
```
