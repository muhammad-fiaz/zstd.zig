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
defer allocator.free(c1);

// With explicit level
const c2 = try zstd.compressWithLevel(allocator, data, 9);
defer allocator.free(c2);

// With CompressionOptions
const c3 = try zstd.compressWithOptions(allocator, data, .{
    .level = 9,
    .checksum = true,
});
defer allocator.free(c3);

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
defer allocator.free(c4);

// Derive tuned options then tweak
var tuned = zstd.getCompressionParameters(12, data.len, 20);
tuned.checksum = true;
const c5 = try zstd.compressWithOptions(allocator, data, tuned);
defer allocator.free(c5);
```

## Memory Management & Safety

1. **Client Allocator Passing**: All compression routines accept an explicit `allocator: std.mem.Allocator`. The library never allocates on a hidden or global heap.
2. **Result Ownership**: Returned byte slices (`[]u8`) are freshly allocated with the provided allocator. The caller is responsible for freeing them via `defer allocator.free(...)`.
3. **Zero-Allocation Alternative**: Callers wishing to avoid allocations can use `compressInto(allocator, dst, src, level)` with a pre-sized destination buffer bounded by `compressBound(src.len)`.
4. **Parameter Validation**: Window, hash, chain, and search logs are checked against architectural limits (`window_log_min`/`window_log_max`). Out-of-range parameters return `error.ParameterOutOfBound` rather than causing memory faults or invalid buffer sizing.

