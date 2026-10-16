---
title: Explicit IO Pipeline
description: Explicit std.Io Reader and Writer pipeline streaming compression, decompression, and multithreading in native Zig 0.17.
---

# Explicit std.Io Reader & Writer Pipeline Streaming

This example demonstrates connecting native Zig Zstandard to Zig 0.17.0's explicit I/O subsystem (`std.Io`) via memory readers (`std.Io.Reader.fixed`), dynamic allocating writers (`std.Io.Writer.Allocating`), bounded fixed-buffer writers (`std.Io.Writer.fixed`), and multithreaded explicit I/O (`std.Io.Threaded`).

## Usage Example

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.debug.print("==================================================\n", .{});
    std.debug.print("Explicit std.Io Reader/Writer Pipeline Streaming\n", .{});
    std.debug.print("==================================================\n", .{});

    // 1. Prepare sample payload (structured repeating log stream)
    const line = "2026-10-16T22:20:00Z [INFO] worker=01 latency=1.42ms payload=explicit_std_io_pipeline\n";
    const repeat_count = 500;
    const total_input_size = line.len * repeat_count;

    var input_buffer = try allocator.alloc(u8, total_input_size);
    defer allocator.free(input_buffer);

    for (0..repeat_count) |i| {
        const offset = i * line.len;
        @memcpy(input_buffer[offset .. offset + line.len], line);
    }
    std.debug.print("1. Generated input stream: {d} bytes ({d} records)\n", .{ total_input_size, repeat_count });

    // 2. Short explicit std.Io Reader & Writer pipeline compression
    var comp_allocating = std.Io.Writer.Allocating.init(allocator);
    defer comp_allocating.deinit();

    var in_reader = std.Io.Reader.fixed(input_buffer);
    try zstd.io.compressPipeline(allocator, &in_reader, &comp_allocating.writer, 5);

    const compressed_frame = comp_allocating.written();
    const comp_ratio = @as(f64, @floatFromInt(compressed_frame.len)) / @as(f64, @floatFromInt(total_input_size)) * 100.0;
    std.debug.print("2. Stream-compressed: {d} -> {d} bytes (ratio: {d:.2}%)\n", .{
        total_input_size,
        compressed_frame.len,
        comp_ratio,
    });

    // 3. Short explicit std.Io Reader & Writer pipeline decompression
    var decomp_reader = std.Io.Reader.fixed(compressed_frame);

    var restored_buffer = try allocator.alloc(u8, total_input_size);
    defer allocator.free(restored_buffer);

    var decomp_writer = std.Io.Writer.fixed(restored_buffer);
    try zstd.io.decompressPipeline(allocator, &decomp_reader, &decomp_writer);

    const decomp_written_len = decomp_writer.end;
    std.debug.print("3. Stream-decompressed: {d} -> {d} bytes\n", .{ compressed_frame.len, decomp_written_len });
    std.debug.assert(decomp_written_len == total_input_size);
    std.debug.assert(std.mem.eql(u8, input_buffer, restored_buffer[0..decomp_written_len]));
    std.debug.print("4. Verified restored data matches input bit-for-bit!\n", .{});

    // 4. Multithreaded compression using explicit std.Io
    {
        std.debug.print("\n--- Explicit std.Io Multithreaded Pipeline ---\n", .{});
        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();

        const mt_compressed = try zstd.compressMT(allocator, threaded.io(), input_buffer, .{
            .level = 3,
            .checksum = true,
        }, 4);
        defer allocator.free(mt_compressed);

        const mt_restored = try zstd.decompress(allocator, mt_compressed);
        defer allocator.free(mt_restored);

        std.debug.assert(std.mem.eql(u8, input_buffer, mt_restored));
        std.debug.print("4-worker parallel compression: {d} -> {d} bytes (verified bit-for-bit)\n", .{
            total_input_size,
            mt_compressed.len,
        });
    }

    _ = io;
    std.debug.print("==================================================\n", .{});
    std.debug.print("Explicit std.Io pipeline completed successfully.\n", .{});
}
```

## Output

```text
==================================================
Explicit std.Io Reader/Writer Pipeline Streaming
==================================================
1. Generated input stream: 43000 bytes (500 records)
2. Stream-compressed: 43000 -> 222 bytes (ratio: 0.52%)
3. Stream-decompressed: 222 -> 43000 bytes
4. Verified restored data matches input bit-for-bit!

--- Explicit std.Io Multithreaded Pipeline ---
4-worker parallel compression: 43000 -> 227 bytes (verified bit-for-bit)
==================================================
Explicit std.Io pipeline completed successfully.
```

## Explanation

1. **`zstd.io.compressPipeline`**: One-shot / short streaming compression taking explicit `*std.Io.Reader` and `*std.Io.Writer` parameters.
2. **`zstd.io.decompressPipeline`**: One-shot / short streaming decompression taking explicit `*std.Io.Reader` and `*std.Io.Writer` parameters.
3. **`std.Io.Reader.fixed`**: Creates an explicit, zero-allocation reader over any immutable in-memory byte slice.
4. **`std.Io.Writer.Allocating`**: Manages an auto-growing buffer that collects stream-compressed bytes via `comp_allocating.writer`.
5. **`std.Io.Writer.fixed`**: Writes directly into a bounded caller-provided buffer slice with exact position tracking (`writer.end`).
6. **`std.Io.Threaded`**: Exposes the explicit `io` handle needed by the thread pool for multi-threaded chunk compression.

## Run Command

```bash
zig build run-explicit_io_pipeline
```
