---
title: Parallel Compression
description: Multithreaded Zstandard compression using isolated contexts or worker pools.
---

# Parallel Compression

Zstandard compression can be parallelized in two primary ways:

1. **One Context per Thread**: For handling many distinct files, network packets, or database records simultaneously, each worker thread maintains its own `CompressionContext` and `DecompressionContext`. Since contexts operate completely independently, no inter-thread locking is needed during compression.
2. **`zstd.compressMT` / `MTCompressor`**: For compressing a single large file or buffer in parallel, the input is partitioned across a pool of background worker threads (`zstd.pool`), which produce a single standard Zstandard frame.

## Usage Example

```zig
const std = @import("std");
const builtin = @import("builtin");
const zstd = @import("zstd");

const thread_count = 4;
const messages = 64;
const payload_len = 32 * 1024;
const mt_input_len = 4 * 1024 * 1024; // 4 MiB

const Totals = struct { in: usize, out: usize };

const Stripe = struct {
    allocator: std.mem.Allocator,
    totals: *Totals,
    id: usize,
    stride: usize,
    buffer: []u8,
};

fn payloadFor(index: usize, buffer: []u8) []const u8 {
    const header = "record:";
    @memset(buffer, 0);
    @memcpy(buffer[0..header.len], header);
    var pos = header.len;
    var value: u32 = @truncate(index *% 2654435761);
    while (pos < buffer.len) {
        value = value *% 1664525 +% 1013904223;
        const run = 4 + @as(usize, @intCast((value >> 16) & 7));
        const byte: u8 = if ((value >> 24) & 1 == 0) 'a' + @as(u8, @intCast((value >> 8) & 15)) else @truncate(value);
        for (buffer[pos..@min(pos + run, buffer.len)]) |*b| b.* = byte;
        pos += run;
    }
    return buffer;
}

fn runStripe(stripe: *Stripe) !void {
    var compressor = zstd.Compressor.initWithLevel(stripe.allocator, 9);
    defer compressor.deinit();
    var decompressor = zstd.Decompressor.init(stripe.allocator);
    defer decompressor.deinit();

    var total_in: usize = 0;
    var total_out: usize = 0;
    var index = stripe.id;
    while (index < messages) : (index += stripe.stride) {
        const payload = payloadFor(index, stripe.buffer);
        const frame = try compressor.compressAlloc(payload);
        defer stripe.allocator.free(frame);
        total_in += payload.len;
        total_out += frame.len;

        const restored = try decompressor.decompressAlloc(frame);
        defer stripe.allocator.free(restored);
        if (!std.mem.eql(u8, payload, restored)) return error.RoundTripFailed;
    }
    stripe.totals.* = .{ .in = total_in, .out = total_out };
}

fn threadEntry(stripe: *Stripe) void {
    runStripe(stripe) catch |e| std.debug.panic("worker {d} failed: {s}", .{ stripe.id, @errorName(e) });
}

fn runSequential(allocator: std.mem.Allocator) !Totals {
    var totals: Totals = .{ .in = 0, .out = 0 };
    var stripe = Stripe{
        .allocator = allocator,
        .totals = &totals,
        .id = 0,
        .stride = 1,
        .buffer = try allocator.alloc(u8, payload_len),
    };
    defer allocator.free(stripe.buffer);
    try runStripe(&stripe);
    return totals;
}

fn makeMtInput(allocator: std.mem.Allocator) ![]u8 {
    const buffer = try allocator.alloc(u8, mt_input_len);
    errdefer allocator.free(buffer);
    var prng = std.Random.DefaultPrng.init(0x4D54);
    const random = prng.random();
    for (buffer[0 .. mt_input_len / 2]) |*b| b.* = random.intRangeAtMost(u8, 0, 63);
    @memcpy(buffer[mt_input_len / 2 ..], buffer[0 .. mt_input_len / 2]);
    return buffer;
}

fn runMultithreaded(allocator: std.mem.Allocator, io: std.Io, payload: []const u8) !void {
    const options: zstd.CompressionOptions = .{ .level = 3, .checksum = true };

    const serial_frame = try zstd.compressWithOptions(allocator, payload, options);
    defer allocator.free(serial_frame);
    const mt_frame = try zstd.compressMT(allocator, io, payload, options, thread_count);
    defer allocator.free(mt_frame);

    std.debug.print("\none {d} MiB input, level 3 with a checksum:\n", .{mt_input_len / (1024 * 1024)});
    std.debug.print("  one frame, one thread:  {d} bytes\n", .{serial_frame.len});
    std.debug.print("  one frame, {d} workers: {d} bytes\n", .{ thread_count, mt_frame.len });

    for ([_][]const u8{ serial_frame, mt_frame }) |frame| {
        const restored = try zstd.decompress(allocator, frame);
        defer allocator.free(restored);
        if (!std.mem.eql(u8, payload, restored)) return error.RoundTripFailed;
    }
    std.debug.print("  both decode back to the {d} byte input\n", .{payload.len});
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    std.debug.print("{d} messages of {d} KiB, {d} threads\n\n", .{ messages, payload_len / 1024, thread_count });

    const serial = try runSequential(allocator);
    std.debug.print("one thread:  {d} -> {d} bytes\n", .{ serial.in, serial.out });

    var totals: [thread_count]Totals = undefined;
    var stripes: [thread_count]Stripe = undefined;
    var buffers: [thread_count][]u8 = undefined;
    var threads: [thread_count - 1]std.Thread = undefined;

    for (&totals, &stripes, &buffers, 0..) |*total, *stripe, *buffer, i| {
        total.* = .{ .in = 0, .out = 0 };
        buffer.* = try allocator.alloc(u8, payload_len);
        stripe.* = .{ .allocator = allocator, .totals = total, .id = i, .stride = thread_count, .buffer = buffer.* };
    }
    defer for (buffers) |buffer| allocator.free(buffer);

    try runStripe(&stripes[0]);
    if (builtin.single_threaded) {
        for (stripes[1..]) |*stripe| try runStripe(stripe);
    } else {
        for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, threadEntry, .{&stripes[i + 1]});
        for (threads) |t| t.join();
    }

    var parallel: Totals = .{ .in = 0, .out = 0 };
    for (totals) |total| {
        parallel.in += total.in;
        parallel.out += total.out;
    }
    std.debug.print("{d} threads:  {d} -> {d} bytes\n", .{ thread_count, parallel.in, parallel.out });

    if (parallel.in != serial.in or parallel.out != serial.out) {
        return error.TotalsDiffer;
    }
    std.debug.print("\nOK: {d} frames round tripped across {d} threads, identical totals\n", .{ messages, thread_count });

    const mt_input = try makeMtInput(allocator);
    defer allocator.free(mt_input);
    try runMultithreaded(allocator, init.io, mt_input);
    std.debug.print("\nOK: one frame compressed by {d} workers decodes like any other\n", .{thread_count});
}
```

## Output

```text
64 messages of 32 KiB, 4 threads

one thread:  2097152 -> 863087 bytes
4 threads:  2097152 -> 863087 bytes

OK: 64 frames round tripped across 4 threads, identical totals

one 4 MiB input, level 3 with a checksum:
  one frame, one thread:  3147174 bytes
  one frame, 4 workers: 3147400 bytes
  both decode back to the 4194304 byte input

OK: one frame compressed by 4 workers decodes like any other
```

## Explanation

1. **Deterministic Multi-threading**: The independent context pattern achieves the exact same compressed byte total across 4 threads as a sequential single-threaded run.
2. **Multithreaded Frame Compatibility**: Frames created by `zstd.compressMT` are fully standard Zstandard frames. Any standard Zstandard decoder decompresses them without multi-threading support required at decode time.
3. **Explicit I/O**: The worker thread pool relies on the caller-provided `std.Io` handle, maintaining explicit system resource ownership.

## Run Command

```bash
zig build run-parallel_compression
```
