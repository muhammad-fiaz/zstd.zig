---
title: Streaming Decompression
description: Streaming decompression with StreamingDecompressor and backpressure.
---

# Streaming Decompression

`examples/streaming_decompression.zig` - `StreamingDecompressor` / `DStream`.

## Client Code

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var original: std.ArrayList(u8) = .empty;
    defer original.deinit(allocator);
    for (0..10) |_| try original.appendSlice(allocator, "Streaming decompression handles partial input and output buffers with backpressure. ");

    const compressed = try zstd.compress(allocator, original.items);
    defer allocator.free(compressed);
    var dstream = zstd.StreamingDecompressor.init(allocator);
    defer dstream.deinit();
    var out: [1 << 16]u8 = undefined;
    var outPos: usize = 0;
    var inPos: usize = 0;
    const chunkSize: usize = 64;
    while (inPos < compressed.len) {
        const chunk = compressed[inPos..@min(inPos + chunkSize, compressed.len)];
        const res = try dstream.decompressStream(out[outPos..], chunk);
        inPos += res.inConsumed;
        outPos += res.outProduced;
        if (res.needsMore and inPos >= compressed.len) break;
    }
    std.debug.print("Stream decompressed {d} bytes\n", .{outPos});
    std.debug.assert(std.mem.eql(u8, original.items, out[0..outPos]));
    std.debug.print("Verified streaming decompression\n", .{});
}
```

## Output

```text
Stream decompressed 16800 bytes from 135 bytes of input
Verified streaming decompression
```

## Explanation

- `StreamingDecompressor` keeps input and output buffers, the current stage, and the frame header across calls, so a frame split across any number of calls decodes identically to a whole-buffer decode.
- Handles `1-byte` chunks, `skippable` frames, `multiple frames`, `truncated` checks, and `ChecksumWrong`.
- There is no one-shot method. `zstd.decompress` is the one-shot path; driving `decompressStream` is the point of this type.

Run:

```bash
zig build run-streaming_decompression
```
