---
title: Getting Started
description: Get up and running with zstd.zig in minutes.
---

# Getting Started

zstd.zig is a complete native Zig implementation of [Zstandard](https://facebook.github.io/zstd/) compression. No C bindings, no external dependencies — just Zig.

::: warning Version Requirement
This library targets **Zig 0.16.0** (stable). Download from [ziglang.org](https://ziglang.org/download/).

| Zig Version | Status |
|-------------|--------|
| 0.16.0 | Supported — required for this library |
:::

## Quick Start

Add zstd.zig to your `build.zig.zon`:

```zig
.zstd = .{
    .url = "https://github.com/muhammad-fiaz/zstd.zig/archive/refs/heads/dev.tar.gz",
    .hash = "...",  // use zig build to get the hash
},
```

Then in your `build.zig`:

```zig
const zstd = b.dependency("zstd", .{});
exe.root_module.addImport("zstd", zstd.module("zstd"));
```

## Basic Usage

### One-Shot Compression

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const original = "Hello, zstd.zig! This text will be compressed.";

    // Compress with default options
    const compressed = try zstd.compress(allocator, original, .{});
    defer allocator.free(compressed);

    // Decompress
    const decompressed = try zstd.decompress(allocator, compressed, .{});
    defer allocator.free(decompressed);

    std.debug.print("Original: {s}\n", .{original});
    std.debug.print("Compressed: {d} bytes\n", .{compressed.len});
    std.debug.print("Decompressed: {s}\n", .{decompressed});
}
```

### With Compression Level

```zig
// Use fastest compression
const fast = try zstd.compress(allocator, data, .{ .level = .fastest });

// Use best compression
const best = try zstd.compress(allocator, data, .{ .level = .best });

// Use a custom level (1-22)
const custom = try zstd.compress(allocator, data, .{
    .level = @enumFromInt(12),
});
```

### With Checksum

```zig
const compressed = try zstd.compress(allocator, data, .{
    .checksum = true,
});
```

## Reusable Contexts

For repeated operations with the same settings:

```zig
var comp = zstd.Compressor.init(.{ .level = .default });
defer comp.deinit();

// Compress multiple buffers
const c1 = try comp.compressAlloc(allocator, data1);
defer allocator.free(c1);

const c2 = try comp.compressAlloc(allocator, data2);
defer allocator.free(c2);
```

## What's Next

- [Installation](/guide/installation) — Detailed setup instructions
- [Compression](/guide/compression) — All compression options
- [Decompression](/guide/decompression) — Decompression and frame inspection
- [Streaming](/guide/streaming) — Chunk-based processing
- [Dictionaries](/guide/dictionaries) — Dictionary compression
