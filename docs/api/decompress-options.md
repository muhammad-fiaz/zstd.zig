---
title: DecompressionOptions
description: Options struct for decompression contexts.
---

> **Spec conformance:** zstd.zig implements the [Zstandard 1.6.0 specification](https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md) natively in Zig - every algorithm, frame element, and default table in this document follows that version.


# DecompressionOptions

Options for decompression safety limits, re-exported as `zstd.DecompressionOptions`.

## Definition

```zig
pub const DecompressionOptions = struct {
    maxWindowSize: usize = 1 << 27,
    forceIgnoreChecksum: bool = false,
};
```

## Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `maxWindowSize` | `usize` | `1 << 27` (128 MiB) | Maximum allowed window size for decompression safety |
| `forceIgnoreChecksum` | `bool` | `false` | If true, skip XXH64 checksum verification |

## Usage

Top-level `zstd.decompress(allocator, src)` does not take options - configure via `DecompressionContext`:

```zig
const zstd = @import("zstd");

var dctx = zstd.DecompressionContext.init(allocator);
defer dctx.deinit();

// Apply limits from options struct
const opts = zstd.DecompressionOptions{
    .maxWindowSize = 1 << 27,
    .forceIgnoreChecksum = false,
};
dctx.setMaxWindowSize(opts.maxWindowSize);
// (forceIgnoreChecksum is stored for future use; currently validated in frame checksum path)

const data = try dctx.decompressAlloc(compressed);
defer allocator.free(data);
```

Safety limits belong to the context, not to a one-shot call:

```zig
var dctx = zstd.DecompressionContext.init(allocator);
defer dctx.deinit();
dctx.setMaxWindowSize(1 << 27);
const out = try dctx.decompressAlloc(compressed);
defer allocator.free(out);
```

A dictionary is attached the same way, with `dctx.setDictionary(&dict)`, rather than
passed per call.

