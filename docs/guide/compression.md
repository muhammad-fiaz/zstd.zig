---
title: Compression
description: Compress data with zstd.zig using CompressionOptions and numeric levels.
---

# Compression

## One-Shot Compression

The simplest way to compress data — default level `3`:

```zig
const zstd = @import("zstd");

const compressed = try zstd.compress(allocator, data);
defer allocator.free(compressed);
```

`compress` signature from `src/zstd.zig:55`:

```zig
pub fn compress(allocator: std.mem.Allocator, src: []const u8) anyerror![]u8
```

## Compression Levels (i32)

Levels are plain `i32`, range `-131072` to `22` (see `constants.c_level_min/max`). Use `zstd.compressWithLevel` for numeric control:

```zig
// Numeric levels 1-22 (and negative levels for fast modes)
const fast = try zstd.compressWithLevel(allocator, data, 1);
const balanced = try zstd.compressWithLevel(allocator, data, 3);
const best = try zstd.compressWithLevel(allocator, data, 19);
const custom = try zstd.compressWithLevel(allocator, data, 12);

// Helpers
const min = zstd.minCLevel();     // -131072
const max = zstd.maxCLevel();     // 22
const def = zstd.defaultCLevel(); // 3
```

`compressWithLevel` signature (`src/zstd.zig:63`):

```zig
pub fn compressWithLevel(allocator: std.mem.Allocator, src: []const u8, level: i32) anyerror![]u8
```

> **Note:** There is no `CLevel` enum. Earlier docs referenced `CLevel.fastest/default/best`; use plain `i32` instead.

## CompressionOptions

For fine-grained control use `zstd.compressWithOptions` (`src/zstd.zig:68`, `src/compress/compress.zig:8`):

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
```

```zig
const opts = zstd.CompressionOptions{
    .level = 9,
    .checksum = true,
    .window_log = 20,
    .strategy = .lazy2,
};
const compressed = try zstd.compressWithOptions(allocator, data, opts);
defer allocator.free(compressed);

// Or derive tuned options for a level + source size
var tuned = zstd.getCompressionParameters(12, data.len, 0);
tuned.checksum = true;
const c2 = try zstd.compressWithOptions(allocator, data, tuned);
defer allocator.free(c2);
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `level` | `i32` | `3` | Compression level (`minCLevel`..`maxCLevel`) |
| `window_log` | `u8` | `0` | Window log override (0 = auto) |
| `hash_log` | `u8` | `0` | Hash log override |
| `chain_log` | `u8` | `0` | Chain log override |
| `search_log` | `u8` | `0` | Search log override |
| `min_match` | `u8` | `0` | Minimum match length |
| `target_length` | `u32` | `0` | Target length |
| `strategy` | `Strategy` | `.fast` | `fast, dfast, greedy, lazy, lazy2, btlazy2, btopt, btultra, btultra2` |
| `checksum` | `bool` | `false` | Enable XXH64 checksum |
| `dict_id` | `u32` | `0` | Dictionary ID for frame header |
| `content_size` | `?u64` | `null` | Pledged source size (null = auto) |
| `enable_ldm` | `bool` | `false` | Enable long distance matching |

## Reusable CompressionContext

For compressing multiple buffers with the same settings (`src/compress/context.zig:6`):

```zig
var cctx = zstd.CompressionContext.init(allocator);
defer cctx.deinit();

// Or with level
var cctx2 = zstd.CompressionContext.initWithLevel(allocator, 9);
defer cctx2.deinit();

// Compress with allocator
const c1 = try cctx.compressAlloc(data1);
defer allocator.free(c1);

const c2 = try cctx.compressAlloc(data2);
defer allocator.free(c2);

// Compress into preallocated buffer
var buf: [4096]u8 = undefined;
const written = try cctx.compress(&buf, data);
```

### CompressionContext Methods (`src/compress/context.zig:6`)

| Method | Signature | Description |
|--------|-----------|-------------|
| `init` | `init(allocator: Allocator) CompressionContext` | Create with default level `3` |
| `initWithLevel` | `initWithLevel(allocator: Allocator, level: i32) CompressionContext` | Create with numeric level |
| `deinit` | `deinit(self: *CompressionContext) void` | Release resources |
| `setLevel` | `setLevel(self: *CompressionContext, level: i32) void` | Change compression level |
| `setChecksum` | `setChecksum(self: *CompressionContext, flag: bool) void` | Enable/disable checksum |
| `setWindowLog` | `setWindowLog(self: *CompressionContext, log: u8) void` | Set window log |
| `setPledgedSrcSize` | `setPledgedSrcSize(self: *CompressionContext, size: ?u64) void` | Set content size for header |
| `compress` | `compress(self: *CompressionContext, dst: []u8, src: []const u8) !usize` | Compress into preallocated buffer |
| `compressAlloc` | `compressAlloc(self: *CompressionContext, src: []const u8) anyerror![]u8` | Compress with allocator |
| `reset` | `reset(self: *CompressionContext) void` | Reset streaming state |

```zig
cctx.setLevel(5);
cctx.setChecksum(true);
cctx.setWindowLog(22);
cctx.setPledgedSrcSize(@as(?u64, data.len));
cctx.reset(); // reuse for new job
```

> Removed names: old `Compressor`, `CompressOptions`, `compress2`, `setParameter(CParameter)`, `reset(ResetDirective)` no longer exist — use `CompressionContext` above.

## compressBound / compressInto

Pre-allocate output buffers:

```zig
// Maximum compressed size (src/compress/compress.zig:23):  pub fn compressBound(src_size: usize) usize
const bound = zstd.compressBound(src.len);
var buf = try allocator.alloc(u8, bound);
defer allocator.free(buf);

// One-shot into fixed buffer with level (src/zstd.zig:72): pub fn compressInto(dst: []u8, src: []const u8, level: i32) ZstdError!usize
const written = try zstd.compressInto(&buf, src, 3);
```

## Checksum

Enable frame checksum for data integrity verification:

```zig
const opts = zstd.CompressionOptions{ .checksum = true };
const compressed = try zstd.compressWithOptions(allocator, data, opts);
// The decompressor will verify the checksum automatically; use DecompressionOptions.force_ignore_checksum to skip
```
