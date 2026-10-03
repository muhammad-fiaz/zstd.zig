---
title: Constants
description: Library constants for magic numbers, sizes, and limits.
---

# Constants

All constants are exposed as top-level aliases (not under `zstd.constants`).

## Top-Level Aliases

```zig
pub const MAGICNUMBER: u32 = 0xFD2FB528;
pub const MAGIC_DICTIONARY: u32 = 0xEC30A437;
pub const MAGIC_SKIPPABLE_START: u32 = 0x184D2A50;
pub const MAGIC_SKIPPABLE_MASK: u32 = 0xFFFFFFF0;
pub const BLOCKSIZE_MAX: usize = 1 << 17; // 131072
pub const CONTENTSIZE_UNKNOWN: u64 = 0xFFFFFFFFFFFFFFFF - 1;
pub const CONTENTSIZE_ERROR: u64 = 0xFFFFFFFFFFFFFFFF - 2;
pub const CLEVEL_DEFAULT: i32 = 3;
pub const MAX_INPUT_SIZE: usize = 0xFF00FF00FF00FF00 (64-bit) or 0xFF00FF00 (32-bit);
```

Usage:

```zig
const zstd = @import("zstd");

if (data.len >= 4) {
    const magic = std.mem.readInt(u32, data[0..4], .little);
    if (magic == zstd.MAGICNUMBER) { /* zstd frame */ }
    if ((magic & zstd.MAGIC_SKIPPABLE_MASK) == zstd.MAGIC_SKIPPABLE_START) { /* skippable */ }
}
const max_block = zstd.BLOCKSIZE_MAX; // 131072
if (zstd.getFrameContentSize(data) == zstd.CONTENTSIZE_UNKNOWN) { /* ... */ }
```

## Magic Numbers

| Constant | Value | Description |
|----------|-------|-------------|
| `magic_number` | `0xFD2FB528` | Zstandard frame magic number |
| `magic_dictionary` | `0xEC30A437` | Dictionary format magic number |
| `magic_skippable_start` | `0x184D2A50` | Skippable frame start magic |
| `magic_skippable_mask` | `0xFFFFFFF0` | Mask for skippable frame detection |

## Sizes and Limits

| Constant | Value | Description |
|----------|-------|-------------|
| `blockSizeMax` | `131072` (128 KB) | Maximum block size (`1 << 17`) |
| `block_size_log_max` | `17` | Log2 of maximum block size |
| `contentsize_unknown` | `0xFFFFFFFFFFFFFFFF - 1` | Sentinel for unknown content size |
| `contentsize_error` | `0xFFFFFFFFFFFFFFFF - 2` | Sentinel for content size error |
| `max_input_size` | platform-dependent | Maximum input size |
| `window_log_min/max` | `10` / `30` (32-bit) or `31` (64-bit) | Window log range |
| `c_level_min/max/default` | `-131072` / `22` / `3` | Compression level range |

## Version (, `134-151`)

```zig
pub const version: []const u8 = "1.6.0";
pub const version_number: u32 = 1*100*100 + 6*100 + 0; // 10600

pub fn versionString() []const u8 // "1.6.0"
pub fn versionNumber() u32         // 10600
pub fn minCLevel() i32             // -131072
pub fn maxCLevel() i32             // 22
pub fn defaultCLevel() i32         // 3
```

```zig
std.debug.print("Version: {s}\n", .{zstd.versionString()});
std.debug.print("Number: {d}\n", .{zstd.versionNumber()});
std.debug.print("Default level: {d}\n", .{zstd.defaultCLevel()});
```

## Version Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `zstd.version` | `"0.0.4"` | This library's release version, as a comptime string |
| `zstd.versionString()` | `"0.0.4"` | The same string, as a function |
| `zstd.versionNumber()` | `4` | `major*100*100 + minor*100 + patch` for `0.0.4` |
| `zstd.specVersionString()` | `"1.6.0"` | Zstandard format specification implemented |
| `zstd.specVersionNumber()` | `10600` | `major*100*100 + minor*100 + patch` for `1.6.0` |

`zstd.version` and `zstd.versionString()` both report the library; the `spec*`
pair reports the format it reads and writes. They move independently, so a reader
that needs the format version must use the `spec*` pair.

## Level Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `zstd.minCLevel()` | `-131072` | Lowest accepted level (fastest) |
| `zstd.maxCLevel()` | `22` | Highest accepted level |
| `zstd.defaultCLevel()` | `3` | Level used when none is given |
| `zstd.CLEVEL_DEFAULT` | `3` | The same default, as a constant |

Levels are plain `i32`, not an enum, matching the specification's own range.
