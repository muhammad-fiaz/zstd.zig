---
title: DecompressionContext
description: Reusable decompression context.
---

> **Spec conformance:** zstd.zig implements the [Zstandard 1.6.0 specification](https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md) natively in Zig — every algorithm, frame element, and default table in this document follows that version.


# DecompressionContext

A reusable decompression context for decompressing multiple buffers. Defined in `src/decompress/context.zig:6` and re-exported as `zstd.DecompressionContext` (`src/zstd.zig:24`).

## Definition

```zig
pub const DecompressionContext = struct {
    allocator: std.mem.Allocator,
    stream: StreamingDecompressor,
    max_window_size: usize, // default 1<<27
    // ...
};
```

## Methods

### `init`

Create a new decompressor (no options struct):

```zig
pub fn init(allocator: std.mem.Allocator) DecompressionContext
```

```zig
var dctx = zstd.DecompressionContext.init(allocator);
defer dctx.deinit();
```

### `deinit`

Release streaming buffers:

```zig
pub fn deinit(self: *DecompressionContext) void
```

### `decompress`

Decompress into preallocated buffer:

```zig
pub fn decompress(self: *DecompressionContext, dst: []u8, src: []const u8) !usize
```

```zig
var out: [4096]u8 = undefined;
const n = try dctx.decompress(&out, compressed);
```

### `decompressAlloc`

Decompress with allocator:

```zig
pub fn decompressAlloc(self: *DecompressionContext, src: []const u8) anyerror![]u8
```

```zig
const decompressed = try dctx.decompressAlloc(compressed);
defer allocator.free(decompressed);
```

### `setMaxWindowSize`

Set window size limit:

```zig
pub fn setMaxWindowSize(self: *DecompressionContext, size: usize) void
```

```zig
dctx.setMaxWindowSize(1 << 27);
```

### `reset`

Reset internal stream state:

```zig
pub fn reset(self: *DecompressionContext) void
```

## Example

```zig
var dctx = zstd.DecompressionContext.init(allocator);
defer dctx.deinit();

dctx.setMaxWindowSize(1 << 26);

// Decompress multiple buffers
const d1 = try dctx.decompressAlloc(c1);
defer allocator.free(d1);

var buf: [4096]u8 = undefined;
const n = try dctx.decompress(&buf, c2);

dctx.reset();
```

> Removed names: old `Decompressor`, `Decompressor.init(allocator, opts)`, `decompress(src)` returning owned slice without `decompressAlloc`, and per-call `DecompressOptions` are replaced by `DecompressionContext` above.
