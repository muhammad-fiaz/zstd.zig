---
title: Basic Compression
description: Basic one-shot compression and decompression round-trip in pure Zig.
---

# Basic Compression

A complete example demonstrating simple one-shot compression and decompression using `zstd.compress` and `zstd.decompress`.

## Usage Example

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Prepare a sample payload with repetitive patterns
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, "Hello, Zstandard! This is a basic compression example with some repetitive data. ");
    for (0..5) |_| try input.appendSlice(allocator, "Hello, Zstandard! ");

    // Compress with default compression level (level 3)
    const compressed = try zstd.compress(allocator, input.items);
    defer allocator.free(compressed);

    std.debug.print("Original: {d} bytes\nCompressed: {d} bytes\nRatio: {d:.2}%\n", .{
        input.items.len,
        compressed.len,
        @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(input.items.len)) * 100.0,
    });

    // Decompress and verify lossless restoration
    const decompressed = try zstd.decompress(allocator, compressed);
    defer allocator.free(decompressed);

    std.debug.assert(std.mem.eql(u8, input.items, decompressed));
    std.debug.print("Round-trip verified: {d} bytes\n", .{decompressed.len});
}
```

## Output

```text
Original: 171 bytes
Compressed: 85 bytes
Ratio: 49.71%
Round-trip verified: 171 bytes
```

## Explanation

1. **`zstd.compress(allocator, src)`**: Compresses the source data using default parameters (level 3, standard window) and returns an allocator-managed byte slice containing a standard Zstandard frame.
2. **`zstd.decompress(allocator, src)`**: Parses the frame header, validates frame integrity and checksums, and decompresses all blocks into an allocator-owned slice.
3. **Lossless Guarantee**: The decompressed slice matches the input byte-for-byte.

## Run Command

```bash
zig build run-basic_compression
```
