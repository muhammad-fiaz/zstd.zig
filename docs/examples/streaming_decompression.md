---
title: Streaming Decompression
description: Streaming decompression with StreamingDecompressor and backpressure handling.
---

# Streaming Decompression

`StreamingDecompressor` (also exported as `DStream`) decompresses streams incrementally in chunks. This enables decompressing large streams with bounded output buffers, handling backpressure from downstream writers.

## Usage Example

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var original: std.ArrayList(u8) = .empty;
    defer original.deinit(allocator);
    for (0..200) |_| try original.appendSlice(allocator, "Streaming decompression handles partial input and output buffers with backpressure. ");

    const compressed = try zstd.compress(allocator, original.items);
    defer allocator.free(compressed);

    var dstream = zstd.StreamingDecompressor.init(allocator);
    defer dstream.deinit();

    // A small output window: the decompressor decodes blocks into its buffer
    // and hands bytes over in whatever pieces fit.
    var window: [1024]u8 = undefined;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    const chunkSize: usize = 64;
    var inPos: usize = 0;
    while (true) {
        const chunk = if (inPos < compressed.len)
            compressed[inPos..@min(inPos + chunkSize, compressed.len)]
        else
            compressed[compressed.len..];

        const res = try dstream.decompressStream(&window, chunk);
        inPos += res.inConsumed;
        try out.appendSlice(allocator, window[0..res.outProduced]);
        if (res.outProduced == 0 and inPos >= compressed.len) break;
    }

    std.debug.print("Stream decompressed {d} bytes from {d} bytes of input\n", .{ out.items.len, compressed.len });
    if (!std.mem.eql(u8, original.items, out.items)) {
        return error.RoundTripFailed;
    }
    std.debug.print("Verified streaming decompression\n", .{});
}
```

## Output

```text
Stream decompressed 16800 bytes from 135 bytes of input
Verified streaming decompression
```

## Explanation

1. **`decompressStream(out, in)`**: Consumes input from `in` and emits decompressed bytes into `out`. Returns `{ inConsumed, outProduced, needsMore }`.
2. **Backpressure & Windowing**: If the destination buffer `out` is smaller than a decompressed block, `StreamingDecompressor` buffers the remaining unread block bytes and yields them on subsequent calls with empty input (`in.len == 0`).
3. **Safety**: Handles arbitrary chunk splits across headers, literals, and sequence sections without requiring caller-side framing.

## Run Command

```bash
zig build run-streaming_decompression
```
