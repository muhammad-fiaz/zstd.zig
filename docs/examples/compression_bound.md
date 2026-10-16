---
title: Compression Bound
description: Sizing output buffers with compressBound and safe preallocated compression.
---

# Compression Bound

`zstd.compressBound(src_size)` computes the maximum possible compressed frame size for an uncompressed input of `src_size` bytes. It provides an upper bound that guarantees any compression level or configuration will fit into a buffer of that size without resizing or retrying.

## Usage Example

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Sizing buffers for different payload lengths
    const sizes = [_]usize{ 0, 1, 1024, 64 * 1024, 1024 * 1024 };

    for (sizes) |size| {
        const payload = try allocator.alloc(u8, size);
        defer allocator.free(payload);

        // Fill with pseudorandom data (worst-case incompressible scenario)
        var prng = std.Random.DefaultPrng.init(@intCast(size +% 1));
        prng.random().bytes(payload);

        const bound = zstd.compressBound(size);
        const buf = try allocator.alloc(u8, bound);
        defer allocator.free(buf);

        const written = try zstd.compressInto(allocator, buf, payload, 19);
        std.debug.print("size {d:>8}: bound {d:>8}, wrote {d:>8}\n", .{ size, bound, written });

        // Verify round-trip decompression
        const back = try zstd.decompressInto(allocator, payload, buf[0..written]);
        if (back != size) {
            return error.RoundTripFailed;
        }
    }

    // Verify buffer safety: undersized buffers are strictly rejected
    const bound = zstd.compressBound(4096);
    const short_buf = try allocator.alloc(u8, bound - 1);
    defer allocator.free(short_buf);
    const small = try allocator.alloc(u8, 4096);
    defer allocator.free(small);
    @memset(small, 'a');

    if (zstd.compressInto(allocator, short_buf, small, 3)) |_| {
        return error.ShortBufferAccepted;
    } else |e| {
        std.debug.print("short buffer rejected as {s}, as documented\n", .{@errorName(e)});
    }
}
```

## Output

```text
size        0: bound       64, wrote        9
size        1: bound       64, wrote       10
size     1024: bound     1091, wrote     1034
size    65536: bound    65824, wrote    65546
size  1048576: bound  1052672, wrote  1048610
short buffer rejected as DstSizeTooSmall, as documented
```

## Explanation

1. **Upper-Bound Guarantee**: Even for completely random data where compression expands slightly due to headers, `compressBound(size)` is guaranteed to be large enough to hold the output frame.
2. **Fixed Frame Overhead**: For empty or 1-byte inputs, the output size is slightly larger than the input because a standard Zstandard frame requires at least a magic number (`0xFD2FB528`), a frame header descriptor, and a block header.
3. **Safety Protection**: If a destination buffer is even 1 byte smaller than required, `zstd.compressInto` cleanly fails with `error.DstSizeTooSmall` without corrupting memory or writing out of bounds.

## Run Command

```bash
zig build run-compression_bound
```
