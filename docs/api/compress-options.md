---
title: CompressionOptions
description: Options struct for zstd.compressWithOptions().
---

> **Spec conformance:** zstd.zig implements the [Zstandard 1.6.0 specification](https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md) natively in Zig - every algorithm, frame element, and default table in this document follows that version.


# CompressionOptions

Options for `zstd.compressWithOptions` and `StreamingCompressor.initWithOptions`, re-exported as `zstd.CompressionOptions`.

## Definition

```zig
pub const CompressionOptions = struct {
    level: i32 = 3,
    windowLog: u8 = 0,
    hashLog: u8 = 0,
    chainLog: u8 = 0,
    searchLog: u8 = 0,
    minMatch: u8 = 0,
    targetLength: u32 = 0,
    strategy: Strategy = .fast,
    checksum: bool = false,
    dictId: u32 = 0,
    dictionary: ?*const Dictionary = null,
    contentSize: ?u64 = null,

};

pub const Strategy = enum(u8) {
    fast = 1, dfast = 2, greedy = 3, lazy = 4, lazy2 = 5, btlazy2 = 6, btopt = 7, btultra = 8, btultra2 = 9,
};
```

## Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `level` | `i32` | `3` | Compression level (`-131072`..`22`; `defaultCLevel()=3`). Used by `getCompressionParameters` to derive other params |
| `windowLog` | `u8` | `0` | Window log override (`0` = auto, otherwise `10`..`31`) |
| `hashLog` | `u8` | `0` | Hash table log size override |
| `chainLog` | `u8` | `0` | Chain log size override |
| `searchLog` | `u8` | `0` | Search log size override |
| `minMatch` | `u8` | `0` | Minimum match length (3..7) |
| `targetLength` | `u32` | `0` | Target length (0..131072) |
| `strategy` | `Strategy` | `.fast` | Compression strategy |
| `checksum` | `bool` | `false` | Enable XXH64 frame checksum (`checksumFlag` in header) |
| `dictId` | `u32` | `0` | Dictionary ID written to frame header |
| `contentSize` | `?u64` | `null` | Pledged source size (`null` = auto from `src.len`) |


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
    .windowLog = 22,
    .hashLog = 18,
    .chainLog = 18,
    .searchLog = 6,
    .minMatch = 4,
    .targetLength = 32,
    .strategy = .btopt,
    .checksum = true,
    .dictId = 42,
    .contentSize = @as(?u64, data.len),

});

// Derive tuned options then tweak
var tuned = zstd.getCompressionParameters(12, data.len, 20);
tuned.checksum = true;
const c5 = try zstd.compressWithOptions(allocator, data, tuned);
```

