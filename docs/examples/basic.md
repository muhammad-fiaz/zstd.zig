---
title: Basic Compression
description: Simple one-shot compression and decompression examples.
---

# Basic Compression

## Simplest Usage

`examples/basic_compression.zig`:

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const input = "Hello, Zstandard! This is a basic compression example with some repetitive data. " ++ "Hello, Zstandard! " ** 5;
    const compressed = try zstd.compress(allocator, input);
    defer allocator.free(compressed);
    std.debug.print("Original: {d} bytes\nCompressed: {d} bytes\nRatio: {d:.2}%\n", .{ input.len, compressed.len, @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(input.len)) * 100 });
    const decompressed = try zstd.decompress(allocator, compressed);
    defer allocator.free(decompressed);
    std.debug.assert(std.mem.eql(u8, input, decompressed));
}
```

And `examples/basic_decompression.zig`:

```zig
const original = "Example data to compress and then decompress using zstd.zig";
const compressed = try zstd.compress(allocator, original);
defer allocator.free(compressed);
const decompressed = try zstd.decompress(allocator, compressed);
defer allocator.free(decompressed);
```

Run:

```bash
zig build run-basic_compression
zig build run-basic_decompression
```

## Different Compression Levels (`i32`)

There is no `CLevel` enum — levels are plain `i32` (`minCLevel`=-131072 .. `maxCLevel`=22). Use `zstd.compressWithLevel` (`examples/custom_level.zig`):

```zig
const data = "Text with moderate repetitiveness for level testing. " ** 20;
for ([_]i32{ 1, 3, 6, 9, 15, 19 }) |level| {
    const c = try zstd.compressWithLevel(allocator, data, level);
    defer allocator.free(c);
    const d = try zstd.decompress(allocator, c);
    defer allocator.free(d);
}

// Helpers
const min = zstd.minCLevel();
const max = zstd.maxCLevel();
const def = zstd.defaultCLevel(); // 3
```

```bash
zig build run-custom_level
```

## With Options / Checksum (`examples/advanced_params.zig`)

```zig
var base = zstd.getCompressionParameters(12, data.len, 20);
base.checksum = true;
const compressed = try zstd.compressWithOptions(allocator, data, base);
defer allocator.free(compressed);

// Also:
const opts = zstd.CompressionOptions{ .level = 9, .checksum = true, .window_log = 20, .strategy = .lazy2 };
const c2 = try zstd.compressWithOptions(allocator, data, opts);
defer allocator.free(c2);
```

```bash
zig build run-advanced_params
```

## Reusable CompressionContext

`src/compress/context.zig:6`:

```zig
var cctx = zstd.CompressionContext.init(allocator);
defer cctx.deinit();

var cctx2 = zstd.CompressionContext.initWithLevel(allocator, 6);
defer cctx2.deinit();

const c1 = try cctx.compressAlloc(data1);
defer allocator.free(c1);

var buf: [4096]u8 = undefined;
const n = try cctx.compress(&buf, data2);
cctx.setLevel(9);
cctx.setChecksum(true);
cctx.setWindowLog(22);
cctx.setPledgedSrcSize(@as(?u64, data2.len));
cctx.reset();
```

> Removed: old `zstd.Compressor`, `CompressOptions{ level = .fastest/.default/.best }`, `.use_dict_id`, `compress2`, `setParameter` no longer exist.

## Pre-allocated Buffer (`compressInto`)

```zig
const bound = zstd.compressBound(data.len); // usize, not error union
var buf = try allocator.alloc(u8, bound);
defer allocator.free(buf);
const written = try zstd.compressInto(buf, data, 3);

var out: [4096]u8 = undefined;
const n = try zstd.decompressInto(&out, compressed);
```

## Custom Allocator & Error Handling

```bash
zig build run-custom_allocator  # TrackingAllocator example
zig build run-error_handling    # corruption / truncation / small-buffer errors
```

## compressBound

```zig
const bound = zstd.compressBound(src.len);
// bound >= src.len is guaranteed (actually src + src>>8 + overhead)
var buf = try allocator.alloc(u8, bound);
defer allocator.free(buf);
```
