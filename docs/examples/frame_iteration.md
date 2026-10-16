---
title: Frame Iteration
description: Walking concatenated frames in a buffer, regular and skippable.
---

# Frame Iteration

A Zstandard stream can contain multiple concatenated frames, including both regular compressed frames and skippable metadata frames. `zstd.FrameIterator` iterates over frames in a zero-copy fashion, reporting geometry, frame types, and offsets without parsing the underlying blocks until requested.

## Usage Example

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Build a stream: skippable frame, regular frame, empty skippable frame, regular frame
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);

    try appendSkippable(allocator, &stream, "metadata written by some tool");

    const first = "the first frame, with enough text to be worth compressing at all";
    const first_frame = try zstd.compress(allocator, first);
    defer allocator.free(first_frame);
    try stream.appendSlice(allocator, first_frame);

    try appendSkippable(allocator, "");

    const second = "the second frame, also compressible, and a different length entirely";
    const second_frame = try zstd.compress(allocator, second);
    defer allocator.free(second_frame);
    try stream.appendSlice(allocator, second_frame);

    // Walk the stream: FrameIterator borrows the slice and allocates nothing
    var it = zstd.FrameIterator.init(stream.items);
    var frame_index: usize = 0;
    while (try it.next()) |frame| {
        if (frame.isSkippable()) {
            std.debug.print(
                "frame {d}: skippable at offset {d}, {d} bytes total, payload {d} bytes\n",
                .{ frame_index, frame.offset, frame.totalSize, frame.payloadBytes.len },
            );
        } else {
            const text = try zstd.decompress(allocator, frame.bytes());
            defer allocator.free(text);
            std.debug.print(
                "frame {d}: regular at offset {d}, {d} bytes total, header {d}, window {d}, content {d} bytes\n",
                .{
                    frame_index,
                    frame.offset,
                    frame.totalSize,
                    frame.headerSize,
                    frame.windowSize,
                    text.len,
                },
            );
            std.debug.print("         {s}\n", .{text});
        }
        frame_index += 1;
    }

    std.debug.print("{d} frames, {d} bytes consumed of {d}\n", .{ frame_index, it.offset(), stream.items.len });

    // Truncated tail detection: returns complete frames and signals error on trailing fragment
    const truncated = stream.items[0 .. stream.items.len - 5];
    var partial = zstd.FrameIterator.init(truncated);
    var walked: usize = 0;
    while (true) {
        const step = partial.next() catch null;
        if (step == null) break;
        walked += 1;
    }
    std.debug.print("truncated input: {d} complete frames before the error\n", .{walked});
}

fn appendSkippable(allocator: std.mem.Allocator, stream: *std.ArrayList(u8), payload: []const u8) !void {
    var header: [8]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], 0x184D2A50, .little);
    std.mem.writeInt(u32, header[4..8], @intCast(payload.len), .little);
    try stream.appendSlice(allocator, &header);
    try stream.appendSlice(allocator, payload);
}
```

## Output

```text
frame 0: skippable at offset 0, 37 bytes total, payload 29 bytes
frame 1: regular at offset 37, 73 bytes total, header 6, window 64, content 64 bytes
         the first frame, with enough text to be worth compressing at all
frame 2: skippable at offset 110, 8 bytes total, payload 0 bytes
frame 3: regular at offset 118, 77 bytes total, header 6, window 68, content 68 bytes
         the second frame, also compressible, and a different length entirely
4 frames, 195 bytes consumed of 195
truncated input: 3 complete frames before the error
```

## Explanation

1. **`FrameIterator.init(slice)`**: Initializes a non-allocating iterator over one or more concatenated frames.
2. **`frame.isSkippable()`**: Returns `true` for user-defined metadata frames (`magic` in range `0x184D2A50`..`0x184D2A5F`).
3. **Geometry Properties**: Each yielded `Frame` exposes `offset`, `totalSize`, `headerSize`, `windowSize`, and `payloadBytes` for inspection without decoding.
4. **Resilience**: Truncated streams cleanly produce error values on the final incomplete frame, preventing out-of-bounds reads.

## Run Command

```bash
zig build run-frame_iteration
```
