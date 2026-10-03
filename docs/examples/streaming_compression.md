---
title: Streaming Compression
description: Streaming compression with StreamingCompressor and EndDirective.
---

# Streaming Compression

`examples/streaming_compression.zig` - `StreamingCompressor` / `CStream`.

## Client Code

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var cstream = try zstd.StreamingCompressor.init(allocator, 3);
    defer cstream.deinit();
    var outBuf: [1 << 16]u8 = undefined;
    var total: usize = 0;
    const chunks = [_][]const u8{ "Streaming ", "compression ", "processes ", "data incrementally ", "without buffering all at once. " };
    var expectedLen: usize = 0;
    for (chunks) |c| expectedLen += c.len;
    for (chunks, 0..) |chunk, i| {
        const isLast = i == chunks.len - 1;
        const directive: zstd.EndDirective = if (isLast) .end else .flush;
        const res = try cstream.compressStream(outBuf[total..], chunk, directive);
        std.debug.assert(res.inConsumed == chunk.len);
        total += res.outProduced;
        std.debug.print("Chunk {d}: {d} bytes -> {d} bytes produced (remaining {d})\n", .{ i, chunk.len, res.outProduced, res.remaining });
    }
    std.debug.print("Total compressed: {d} bytes\n", .{total});
    const decompressed = try zstd.decompress(allocator, outBuf[0..total]);
    defer allocator.free(decompressed);
    std.debug.assert(decompressed.len == expectedLen);
    std.debug.print("Decompressed: {s}\n", .{decompressed});
    std.debug.assert(std.mem.eql(u8, "Streaming compression processes data incrementally without buffering all at once. ", decompressed));
}
```

## Output

```text
after 101 lines: 6 compressed bytes, 8989 still buffered
frame finished across 1 final calls: 35600 -> 190 bytes
Verified streaming compression
```

## Explanation

- `StreamingCompressor.init(allocator, level)` or `initWithOptions` with `CompressionOptions`.
- `compressStream(out, in, .cont/.flush/.end)` returns `{inConsumed, outProduced, remaining}`.
- `.flush` emits a block without closing the frame; `.end` writes `Last_Block` + `Checksum` if enabled and marks `finished`.
- `cstream.reset()` clears `buffer`/`checksum_state`/`header_written` for reuse.

Run:

```bash
zig build run-streaming_compression
```
