---
title: Basic Decompression
description: Decompression with verification.
---

# Basic Decompression

`examples/basic_decompression.zig` — decompress and verify.

## Client Code

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const original = "Example data to compress and then decompress using zstd.zig";
    const compressed = try zstd.compress(allocator, original);
    defer allocator.free(compressed);
    const decompressed = try zstd.decompress(allocator, compressed);
    defer allocator.free(decompressed);
    std.debug.assert(std.mem.eql(u8, original, decompressed));
    std.debug.print("Decompression successful: {s}\n", .{decompressed});
}
```

## Output

```text
Decompression successful: Example data to compress and then decompress using zstd.zig
```

## Explanation

- Compresses `original` with `zstd.compress`, then immediately decompresses with `zstd.decompress`.
- Validates `FrameHeader` (`getFrameHeader`) and content size; `decompress` checks `Checksum` if `checksum_flag` is set and validates `Content_Size`.
- Shows the minimal decompression path used when receiving a `.zst` payload.

Run:

```bash
zig build run-basic_decompression
```
