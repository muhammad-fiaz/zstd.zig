---
title: DecompressOptions
description: Options struct for zstd.decompress().
---

# DecompressOptions

Options for the `decompress` function.

## Definition

```zig
pub const DecompressOptions = struct {
    dict: ?[]const u8 = null,
    max_window_size: ?u64 = null,
    max_output_size: ?usize = null,
};
```

## Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `dict` | `?[]const u8` | `null` | Optional dictionary data for decompression |
| `max_window_size` | `?u64` | `null` | Maximum allowed window size (for safety) |
| `max_output_size` | `?usize` | `null` | Maximum output size limit (prevents unbounded allocation) |

## Usage

```zig
const zstd = @import("zstd");

// Default options
const d1 = try zstd.decompress(allocator, compressed, .{});

// With dictionary
const d2 = try zstd.decompress(allocator, compressed, .{
    .dict = dict_data,
});

// With safety limits
const d3 = try zstd.decompress(allocator, compressed, .{
    .max_window_size = 1 << 27,  // 128 MB
    .max_output_size = 1 << 30,  // 1 GB
});
```
