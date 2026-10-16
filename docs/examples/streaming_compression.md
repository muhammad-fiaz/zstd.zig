---
title: Streaming Compression
description: Incremental streaming compression with StreamingCompressor and EndDirective.
---

# Streaming Compression

`StreamingCompressor` (also exported as `CStream`) enables incremental compression of data streams chunk by chunk. Input data is consumed progressively without requiring the entire uncompressed stream to fit in memory.

## Usage Example

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const line = "Streaming compression processes data incrementally, without buffering all of it at once. ";
    var cstream = try zstd.StreamingCompressor.init(allocator, 5);
    defer cstream.deinit();

    // Buffer sized for chunks rather than the entire stream
    var outBuf: [1 << 17]u8 = undefined;
    var frame = std.ArrayList(u8).empty;
    defer frame.deinit(allocator);

    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(allocator);

    var produced_early = false;
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        try expected.appendSlice(allocator, line);
        const res = try cstream.compressStream(&outBuf, line, .cont);
        try frame.appendSlice(allocator, outBuf[0..res.outProduced]);
        if (i == 100) {
            std.debug.print("after {d} lines: {d} compressed bytes, {d} still buffered\n", .{ i + 1, frame.items.len, res.remaining });
            produced_early = frame.items.len > 0;
        }
    }
    if (!produced_early) {
        return error.NotIncremental;
    }

    // Finalize the frame using .end directive
    var calls: usize = 0;
    while (true) : (calls += 1) {
        const res = try cstream.compressStream(&outBuf, "", .end);
        try frame.appendSlice(allocator, outBuf[0..res.outProduced]);
        if (res.remaining == 0) break;
        if (calls > 1000) return error.TooManyCalls;
    }
    std.debug.print("frame finished across {d} final calls: {d} -> {d} bytes\n", .{ calls + 1, expected.items.len, frame.items.len });

    // Verify lossless round trip
    const restored = try zstd.decompress(allocator, frame.items);
    defer allocator.free(restored);
    if (!std.mem.eql(u8, expected.items, restored)) {
        return error.RoundTripFailed;
    }
    std.debug.print("Verified streaming compression\n", .{});
}
```

## Output

```text
after 101 lines: 6 compressed bytes, 8989 still buffered
frame finished across 1 final calls: 35600 -> 191 bytes
Verified streaming compression
```

## Explanation

1. **`compressStream(out, in, directive)`**: Consumes input from `in` and writes available compressed bytes to `out`. It returns `{ inConsumed, outProduced, remaining }`.
2. **`EndDirective`**:
   - `.cont`: Continues streaming, buffering data across block boundaries.
   - `.flush`: Flushes buffered data into complete compressed blocks without terminating the frame.
   - `.end`: Emits the final block marker, optional checksum, and closes the frame. If `remaining > 0`, call again with empty input until `remaining == 0`.
3. **`cstream.reset()`**: Clears internal stream buffers and flags, allowing the compressor to be reused for subsequent frames.

## Run Command

```bash
zig build run-streaming_compression
```
