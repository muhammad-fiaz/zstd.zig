---
title: CompressionOptions
description: Options struct for zstd.compressWithOptions().
---

> **Spec conformance:** zstd.zig implements the [Zstandard 1.6.0 specification](https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md) natively in Zig — every algorithm, frame element, and default table in this document follows that version.


# CompressionOptions

Options for `zstd.compressWithOptions` and `StreamingCompressor.initWithOptions`. Defined in `src/compress/compress.zig:8` and re-exported as `zstd.CompressionOptions` (`src/zstd.zig:21`).

## Definition

```zig
pub const CompressionOptions = struct {
    level: i32 = 3,
    window_log: u8 = 0,
    hash_log: u8 = 0,
    chain_log: u8 = 0,
    search_log: u8 = 0,
    min_match: u8 = 0,
    target_length: u32 = 0,
    strategy: Strategy = .fast,
    checksum: bool = false,
    dict_id: u32 = 0,
    content_size: ?u64 = null,
    enable_ldm: bool = false,
};

pub const Strategy = enum(u8) {
    fast = 1, dfast = 2, greedy = 3, lazy = 4, lazy2 = 5, btlazy2 = 6, btopt = 7, btultra = 8, btultra2 = 9,
};
```

## Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `level` | `i32` | `3` | Compression level (`-131072`..`22`; `defaultCLevel()=3`). Used by `getCompressionParameters` to derive other params |
| `window_log` | `u8` | `0` | Window log override (`0` = auto, otherwise `10`..`31`) |
| `hash_log` | `u8` | `0` | Hash table log size override |
| `chain_log` | `u8` | `0` | Chain log size override |
| `search_log` | `u8` | `0` | Search log size override |
| `min_match` | `u8` | `0` | Minimum match length (3..7) |
| `target_length` | `u32` | `0` | Target length (0..131072) |
| `strategy` | `Strategy` | `.fast` | Compression strategy |
| `checksum` | `bool` | `false` | Enable XXH64 frame checksum (`checksum_flag` in header) |
| `dict_id` | `u32` | `0` | Dictionary ID written to frame header |
| `content_size` | `?u64` | `null` | Pledged source size (`null` = auto from `src.len`) |
| `enable_ldm` | `bool` | `false` | Enable long distance matching (reserved) |

## Usage

```zig
const zstd = @import("zstd");

// Default options via compress()
const c1 = try zstd.compress(allocator, data);

// With explicit level
const c2 = try zstd.compressWithLevel(allocator, data, 9);

// With CompressionOptions
const c3 = try zstd.compressWithOptions(allocator, data, .{
    .level = 9,
    .checksum = true,
});

// All options + strategy
const c4 = try zstd.compressWithOptions(allocator, data, .{
    .level = 12,
    .window_log = 22,
    .hash_log = 18,
    .chain_log = 18,
    .search_log = 6,
    .min_match = 4,
    .target_length = 32,
    .strategy = .btopt,
    .checksum = true,
    .dict_id = 42,
    .content_size = @as(?u64, data.len),
    .enable_ldm = false,
});

// Derive tuned options then tweak
var tuned = zstd.getCompressionParameters(12, data.len, 20);
tuned.checksum = true;
const c5 = try zstd.compressWithOptions(allocator, data, tuned);
```

> Removed names: old `CompressOptions { level: CLevel = .default, checksum, dict_id, use_dict_id, strategy: ?Strategy, window_log: ?u32 }` no longer exists. Use the struct above with `i32 level` and `u8` logs.
