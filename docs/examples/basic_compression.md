---
title: Basic Compression
description: Basic one-shot compression and decompression round-trip.
---

# Basic Compression

`examples/basic_compression.zig` — the simplest `zstd.compress` / `zstd.decompress` usage.

## Client Code

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
    std.debug.print("Round-trip verified: {d} bytes\n", .{decompressed.len});
}
```

## Output

```text
Original: 171 bytes
Compressed: 103 bytes
Ratio: 60.23%
Round-trip verified: 171 bytes
```

*Note: small payloads may expand slightly due to frame header (magic, FHD, window) — ratio >100% is expected for tiny inputs. Larger inputs compress well.*

## Explanation

1. `zstd.compress(allocator, input)` — one-shot compression with default level 3, emits a full Zstandard frame (`0xFD2FB528` magic, `FHD`, optional `Frame_Content_Size`, `Window_Descriptor`, `Block_Header`, `Checksum`).
2. `zstd.decompress(allocator, compressed)` — validates magic, parses `FHD`, decompresses `Raw_Block`/`RLE_Block` and verifies `Content_Checksum` if present.
3. Round-trip `assert` proves lossless.

Run:

```bash
zig build run-basic_compression
```
