---
title: DecompressionOptions
description: Options struct for decompression contexts.
---

> **Spec conformance:** zstd.zig implements the [Zstandard 1.6.0 specification](https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md) natively in Zig — every algorithm, frame element, and default table in this document follows that version.


# DecompressionOptions

Options for decompression safety limits. Defined in `src/decompress/context.zig:41` and re-exported as `zstd.DecompressionOptions` (`src/zstd.zig:22`).

## Definition

```zig
pub const DecompressionOptions = struct {
    max_window_size: usize = 1 << 27,
    force_ignore_checksum: bool = false,
};
```

## Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_window_size` | `usize` | `1 << 27` (128 MiB) | Maximum allowed window size for decompression safety |
| `force_ignore_checksum` | `bool` | `false` | If true, skip XXH64 checksum verification |

## Usage

Top-level `zstd.decompress(allocator, src)` does not take options â€” configure via `DecompressionContext`:

```zig
const zstd = @import("zstd");

var dctx = zstd.DecompressionContext.init(allocator);
defer dctx.deinit();

// Apply limits from options struct
const opts = zstd.DecompressionOptions{
    .max_window_size = 1 << 27,
    .force_ignore_checksum = false,
};
dctx.setMaxWindowSize(opts.max_window_size);
// (force_ignore_checksum is stored for future use; currently validated in frame checksum path)

const data = try dctx.decompressAlloc(compressed);
defer allocator.free(data);
```

Legacy per-call options pattern no longer exists:

```zig
// Old (removed):
// try zstd.decompress(allocator, compressed, .{ .dict = dict_data, .max_output_size = ... })

// New:
var dctx = zstd.DecompressionContext.init(allocator);
defer dctx.deinit();
dctx.setMaxWindowSize(1 << 27);
const out = try dctx.decompressAlloc(compressed);
```

> Removed: old `DecompressOptions { dict: ?[]const u8, max_window_size: ?u64, max_output_size: ?usize }` no longer exists. Dictionary handling uses `Dictionary` + `loadDictionary` instead of raw `dict` bytes.
