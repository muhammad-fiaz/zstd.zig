---
title: Strategy & Compression Levels
description: Strategy enum and numeric compression levels.
---

# Strategy & Compression Levels

There is no `CLevel` enum — compression levels are plain `i32`.

## Levels

Levels are `i32` in range `c_level_min = -131072` to `c_level_max = 22`, with `c_level_default = 3` (`src/common/constants.zig:23-25`). Helpers in `src/zstd.zig:142-151`:

```zig
pub fn minCLevel() i32     // -131072
pub fn maxCLevel() i32     // 22
pub fn defaultCLevel() i32 // 3
pub fn versionString() []const u8 // "1.6.0"
pub fn versionNumber() u32        // 10600
```

Use with `zstd.compressWithLevel` or `CompressionContext.initWithLevel`:

```zig
// Numeric levels
const c1 = try zstd.compressWithLevel(allocator, data, 1);  // fast
const c2 = try zstd.compressWithLevel(allocator, data, 3);  // default
const c3 = try zstd.compressWithLevel(allocator, data, 19); // best

// With context
var cctx = zstd.CompressionContext.initWithLevel(allocator, 12);
defer cctx.deinit();
cctx.setLevel(6);

// Via options
const opts = zstd.CompressionOptions{ .level = 9 };
const c4 = try zstd.compressWithOptions(allocator, data, opts);

// Tuned via getCompressionParameters
var tuned = zstd.getCompressionParameters(12, data.len, 20);
```

## Strategy

`Strategy` is defined in `src/common/constants.zig:98` and re-exported as `zstd.Strategy` (`src/zstd.zig:37`):

```zig
pub const Strategy = enum(u8) {
    fast = 1,
    dfast = 2,
    greedy = 3,
    lazy = 4,
    lazy2 = 5,
    btlazy2 = 6,
    btopt = 7,
    btultra = 8,
    btultra2 = 9,
};
```

Set via `CompressionOptions.strategy`:

```zig
const opts = zstd.CompressionOptions{
    .level = 12,
    .strategy = .btopt,
    .window_log = 20,
};
const compressed = try zstd.compressWithOptions(allocator, data, opts);
```

Available strategies:

| Strategy | Value | Description |
|----------|-------|-------------|
| `.fast` | 1 | Fast mode |
| `.dfast` | 2 | Double-fast |
| `.greedy` | 3 | Greedy |
| `.lazy` | 4 | Lazy |
| `.lazy2` | 5 | Lazy2 |
| `.btlazy2` | 6 | BT + Lazy2 |
| `.btopt` | 7 | BT Opt |
| `.btultra` | 8 | BT Ultra |
| `.btultra2` | 9 | BT Ultra2 |

## Removed Old API

| Old (removed) | New |
|---------------|-----|
| `CLevel` enum (`fastest=1, default=3, best=19, @enumFromInt`) | `i32` + `minCLevel()/maxCLevel()/defaultCLevel()` |
| `CLevel.toInt()` / `CLevel.fromInt()` | plain `i32` |
| `CompressOptions { level: CLevel }` | `CompressionOptions { level: i32 }` |
