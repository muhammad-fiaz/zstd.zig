---
title: Window Limit
description: Bounding how large a declared window the decoder will accept.
---

# Window Limit

Every Zstandard frame header declares the window size required to decompress it. To prevent denial-of-service attacks from untrusted data declaring arbitrary window sizes (e.g. multi-gigabyte windows), the decoder provides configurable ceiling limits via `maxWindowSize`.

## Usage Example

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Two frames with distinct window sizes
    const small = try zstd.compressWithOptions(allocator, "a small frame", .{ .windowLog = 10 });
    defer allocator.free(small);

    var payload: [200_000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(4242);
    for (&payload) |*b| b.* = if (prng.random().boolean()) 'a' else 'b';
    const large = try zstd.compressWithOptions(allocator, &payload, .{ .windowLog = 18 });
    defer allocator.free(large);

    const small_window: usize = @intCast((try zstd.inspectFrame(allocator, small)).header.windowSize);
    const large_window: usize = @intCast((try zstd.inspectFrame(allocator, large)).header.windowSize);
    std.debug.print("small frame declares a {d} byte window\n", .{small_window});
    std.debug.print("large frame declares a {d} byte window\n", .{large_window});

    // The limit is a ceiling: equal or higher limits succeed
    try tryLimit(allocator, small, small_window, true);
    try tryLimit(allocator, small, small_window + 1, true);
    // Lower limits are safely refused
    try tryLimit(allocator, small, small_window - 1, false);
    try tryLimit(allocator, small, 0, false);

    // Concatenated streams enforce the limit per-frame
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);
    try joined.appendSlice(allocator, small);
    try joined.appendSlice(allocator, large);
    try tryLimit(allocator, joined.items, small_window + 1, false);
    try tryLimit(allocator, joined.items, large_window, true);

    // Streaming decoder enforces the same limit
    var sd = zstd.StreamingDecompressor.init(allocator);
    defer sd.deinit();
    sd.setMaxWindowSize(large_window);
    var out_buf2: [8192]u8 = undefined;
    const r = try sd.decompressStream(&out_buf2, large);
    std.debug.print("streaming with a matching limit accepted {d} bytes\n", .{r.outProduced});

    var tight = zstd.StreamingDecompressor.init(allocator);
    defer tight.deinit();
    tight.setMaxWindowSize(small_window);
    if (tight.decompressStream(&out_buf2, large)) |_| {
        return error.LimitNotEnforced;
    } else |e| {
        std.debug.print("streaming refused it as {s}\n", .{@errorName(e)});
    }
}

fn tryLimit(
    allocator: std.mem.Allocator,
    src: []const u8,
    limit: usize,
    expect_ok: bool,
) !void {
    const outcome = zstd.decompressWithOptions(allocator, src, .{ .maxWindowSize = limit });
    if (outcome) |out| {
        defer allocator.free(out);
        if (!expect_ok) {
            return error.LimitNotEnforced;
        }
        std.debug.print("limit {d}: accepted, {d} bytes\n", .{ limit, out.len });
    } else |e| {
        if (expect_ok) return e;
        std.debug.print("limit {d}: refused as {s}\n", .{ limit, @errorName(e) });
    }
}
```

## Output

```text
small frame declares a 13 byte window
large frame declares a 200000 byte window
limit 13: accepted, 13 bytes
limit 14: accepted, 13 bytes
limit 12: refused as WindowTooLarge
limit 0: refused as WindowTooLarge
limit 14: refused as WindowTooLarge
limit 200000: accepted, 200013 bytes
streaming with a matching limit accepted 8192 bytes
streaming refused it as WindowTooLarge
```

## Explanation

1. **Ceiling Semantics**: `maxWindowSize` sets the maximum allowable history window. A frame declaring a window less than or equal to this ceiling succeeds; a frame demanding more is immediately rejected with `error.WindowTooLarge`.
2. **One-Shot and Streaming Support**: Limits can be configured in `DecompressionOptions.maxWindowSize` for one-shot calls, on `DecompressionContext.setMaxWindowSize()`, and on `StreamingDecompressor.setMaxWindowSize()`.
3. **Protection**: Rejection happens before internal window memory is allocated, safeguarding servers against out-of-memory crashes when parsing untrusted data.

## Run Command

```bash
zig build run-window_limit
```
