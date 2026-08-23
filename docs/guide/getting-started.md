---
title: Getting Started
description: Get up and running with zstd.zig in minutes.
---

> **Spec conformance:** zstd.zig implements the [Zstandard 1.6.0 specification](https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md) natively in Zig � every algorithm, frame element, and default table in this document follows that version.


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
    .url = "https://github.com/muhammad-fiaz/zstd.zig/archive/refs/tags/0.0.3.tar.gz",
    .hash = "...",  // use zig fetch --save to get the hash
},
```

Then in your `build.zig`:

```zig
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});
const zstd_dep = b.dependency("zstd", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zstd", zstd_dep.module("zstd"));
```

## Basic Usage

### One-Shot Compression

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const original = "Hello, zstd.zig! This text will be compressed.";

    // Compress with default level
    const compressed = try zstd.compress(allocator, original);
    defer allocator.free(compressed);

    // Decompress
    const decompressed = try zstd.decompress(allocator, compressed);
    defer allocator.free(decompressed);

    std.debug.print("Original: {s}\n", .{original});
    std.debug.print("Compressed: {d} bytes\n", .{compressed.len});
    std.debug.print("Decompressed: {s}\n", .{decompressed});
}
```

### With Compression Level

```zig
// Use fast compression (level 1)
const fast = try zstd.compressWithLevel(allocator, data, 1);

// Use best compression (level 19)
const best = try zstd.compressWithLevel(allocator, data, 19);

// Use a custom level 12
const custom = try zstd.compressWithLevel(allocator, data, 12);
```

### With Options

```zig
const opts = zstd.CompressionOptions{ .level = 9, .checksum = true, .window_log = 20 };
const compressed = try zstd.compressWithOptions(allocator, data, opts);
```

## Reusable Contexts

For repeated operations with the same settings:

```zig
var cctx = zstd.CompressionContext.init(allocator);
defer cctx.deinit();

var dctx = zstd.DecompressionContext.init(allocator);
defer dctx.deinit();

// Compress multiple buffers
const c1 = try cctx.compressAlloc(data1);
defer allocator.free(c1);

const c2 = try cctx.compressAlloc(data2);
defer allocator.free(c2);

const d1 = try dctx.decompressAlloc(c1);
defer allocator.free(d1);
```

## What's Next

- [Installation](/guide/installation) — Detailed setup instructions
- [Compression](/guide/compression) — All compression options
- [Decompression](/guide/decompression) — Decompression and frame inspection
- [Streaming](/guide/streaming) — Chunk-based processing
- [Dictionaries](/guide/dictionaries) — Dictionary compression
