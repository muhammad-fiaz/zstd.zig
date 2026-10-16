---
title: Error Handling
description: Corruption, truncation, and buffer error handling with ZstdError.
---

# Error Handling

Zstandard operations in `zstd.zig` return strongly-typed errors from the `ZstdError` error set. Corrupted, truncated, or malformed data is rejected safely without panicking, crashing, or triggering undefined behavior.

## Usage Example

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Generate valid compressed frame
    const good = try zstd.compress(allocator, "valid data");
    defer allocator.free(good);

    // 2. Test corrupted magic bytes
    var bad = try allocator.dupe(u8, good);
    defer allocator.free(bad);
    bad[0] ^= 0xFF;

    const result = zstd.decompress(allocator, bad);
    if (result) |data| {
        defer allocator.free(data);
        return error.TestFailed;
    } else |err| {
        std.debug.print("Correctly caught error: {s}\n", .{@errorName(err)});
    }

    // 3. Test truncated input buffer
    const truncated = good[0 .. good.len / 2];
    const r2 = zstd.decompress(allocator, truncated);
    if (r2) |data| {
        defer allocator.free(data);
        return error.TestFailed;
    } else |err| {
        std.debug.print("Truncated correctly failed: {s}\n", .{@errorName(err)});
    }

    // 4. Test undersized output buffer
    var small: [2]u8 = undefined;
    const r3 = zstd.decompressInto(allocator, &small, good);
    if (r3) |_| {
        return error.TestFailed;
    } else |err| {
        std.debug.print("Small buffer correctly failed: {s}\n", .{@errorName(err)});
    }

    std.debug.print("Error handling example complete\n", .{});
}
```

## Output

```text
Correctly caught error: PrefixUnknown
Truncated correctly failed: SrcSizeWrong
Small buffer correctly failed: DstSizeTooSmall
Error handling example complete
```

## Explanation

1. **`error.PrefixUnknown`**: Returned when the initial bytes do not match the standard Zstandard frame magic (`0xFD2FB528`), a skippable frame magic (`0x184D2A50`..`0x184D2A5F`), or a supported legacy format magic.
2. **`error.SrcSizeWrong`**: Returned when input data ends abruptly in the middle of a frame header, block header, or Huffman stream.
3. **`error.DstSizeTooSmall`**: Returned when destination buffers are smaller than the decompressed data.
4. **`zstd.errorToString(err)`**: Helper that converts any `ZstdError` to a lowercase canonical string identifier.

## Run Command

```bash
zig build run-error_handling
```
