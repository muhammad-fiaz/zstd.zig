---
title: Streaming Compression
description: Streaming compression with StreamingCompressor and EndDirective.
---

# Streaming Compression

`examples/streaming_compression.zig` — `StreamingCompressor` / `CStream`.

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
    var out_buf: [1 << 16]u8 = undefined;
    var total: usize = 0;
    const chunks = [_][]const u8{ "Streaming ", "compression ", "processes ", "data incrementally ", "without buffering all at once. " };
    var expected_len: usize = 0;
    for (chunks) |c| expected_len += c.len;
    for (chunks, 0..) |chunk, i| {
        const is_last = i == chunks.len - 1;
        const directive: zstd.EndDirective = if (is_last) .end else .flush;
        const res = try cstream.compressStream(out_buf[total..], chunk, directive);
        std.debug.assert(res.in_consumed == chunk.len);
        total += res.out_produced;
        std.debug.print("Chunk {d}: {d} bytes -> {d} bytes produced (remaining {d})\n", .{ i, chunk.len, res.out_produced, res.remaining });
    }
    std.debug.print("Total compressed: {d} bytes\n", .{total});
    const decompressed = try zstd.decompress(allocator, out_buf[0..total]);
    defer allocator.free(decompressed);
    std.debug.assert(decompressed.len == expected_len);
    std.debug.print("Decompressed: {s}\n", .{decompressed});
    std.debug.assert(std.mem.eql(u8, "Streaming compression processes data incrementally without buffering all at once. ", decompressed));
}
```

## Output

```text
Chunk 0: 10 bytes -> 19 bytes produced (remaining 0)
Chunk 1: 12 bytes -> 15 bytes produced (remaining 0)
Chunk 2: 10 bytes -> 13 bytes produced (remaining 0)
Chunk 3: 19 bytes -> 22 bytes produced (remaining 0)
Chunk 4: 31 bytes -> 34 bytes produced (remaining 0)
Total compressed: 103 bytes
Decompressed: Streaming compression processes data incrementally without buffering all at once.
```

## Explanation

- `StreamingCompressor.init(allocator, level)` or `initWithOptions` with `CompressionOptions`.
- `compressStream(out, in, .cont/.flush/.end)` returns `{in_consumed, out_produced, remaining}`.
- `.flush` emits a block without closing the frame; `.end` writes `Last_Block` + `Checksum` if enabled and marks `finished`.
- `cstream.reset()` clears `buffer`/`checksum_state`/`header_written` for reuse.

Run:

```bash
zig build run-streaming_compression
```
