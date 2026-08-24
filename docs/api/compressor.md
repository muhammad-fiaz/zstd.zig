---
title: CompressionContext
description: Reusable compression context with parameter control.
---

> **Spec conformance:** zstd.zig implements the [Zstandard 1.6.0 specification](https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md) natively in Zig — every algorithm, frame element, and default table in this document follows that version.


# CompressionContext

A reusable compression context. Create once, compress multiple buffers with the same settings. Defined in `src/compress/context.zig:6` and re-exported as `zstd.CompressionContext` (`src/zstd.zig:23`).

## Definition

```zig
pub const CompressionContext = struct {
    allocator: std.mem.Allocator,
    options: CompressionOptions,
    stream: StreamingCompressor,
    // ...
};
```

## Methods

### `init`

Create with default level (`3`):

```zig
pub fn init(allocator: std.mem.Allocator) CompressionContext
```

```zig
var cctx = zstd.CompressionContext.init(allocator);
defer cctx.deinit();
```

### `initWithLevel`

Create with numeric `i32` level:

```zig
pub fn initWithLevel(allocator: std.mem.Allocator, level: i32) CompressionContext
```

```zig
var cctx = zstd.CompressionContext.initWithLevel(allocator, 9);
defer cctx.deinit();
```

### `deinit`

Release streaming buffer:

```zig
pub fn deinit(self: *CompressionContext) void
```

### `setLevel`

Change compression level:

```zig
pub fn setLevel(self: *CompressionContext, level: i32) void
```

```zig
cctx.setLevel(5);
```

### `setChecksum`

Enable/disable checksum:

```zig
pub fn setChecksum(self: *CompressionContext, flag: bool) void
```

### `setWindowLog`

Set window log override:

```zig
pub fn setWindowLog(self: *CompressionContext, log: u8) void
```

### `setPledgedSrcSize`

Set content size for frame header:

```zig
pub fn setPledgedSrcSize(self: *CompressionContext, size: ?u64) void
```

```zig
cctx.setPledgedSrcSize(@as(?u64, data.len));
cctx.setPledgedSrcSize(null); // unknown
```

### `compress`

Compress into pre-allocated buffer:

```zig
pub fn compress(self: *CompressionContext, dst: []u8, src: []const u8) !usize
```

```zig
var buf: [4096]u8 = undefined;
const written = try cctx.compress(&buf, data);
```

### `compressAlloc`

Compress with allocator (convenience):

```zig
pub fn compressAlloc(self: *CompressionContext, src: []const u8) anyerror![]u8
```

```zig
const compressed = try cctx.compressAlloc(data);
defer allocator.free(compressed);
```

### `reset`

Reset streaming state for reuse:

```zig
pub fn reset(self: *CompressionContext) void
```

```zig
cctx.reset();
```

## Example

```zig
var cctx = zstd.CompressionContext.init(allocator);
defer cctx.deinit();

// First compression (default 3)
const c1 = try cctx.compressAlloc(data1);
defer allocator.free(c1);

// Change level and compress again
cctx.setLevel(9);
cctx.setChecksum(true);
const c2 = try cctx.compressAlloc(data2);
defer allocator.free(c2);

// Into fixed buffer
var buf: [8192]u8 = undefined;
const n = try cctx.compress(&buf, data3);
```

> Removed names: old `Compressor`, `Compressor.init(opts: CompressOptions)`, `compressAlloc(alloc,src)`, `compress2(dst,src)`, `setParameter(.compression_level, .checksum_flag)`, `reset(ResetDirective)` are replaced by the `CompressionContext` API above.
