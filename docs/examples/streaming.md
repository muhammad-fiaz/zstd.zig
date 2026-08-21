---
title: Streaming
description: Streaming compression and decompression examples.
---

# Streaming Examples

These examples mirror `examples/streaming_compression.zig` and `examples/streaming_decompression.zig`. The current API uses `StreamingCompressor` / `StreamingDecompressor` (aliases `CStream` / `DStream`) with `compressStream` / `decompressStream`.

## Streaming Compression

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
    for (chunks, 0..) |chunk, i| {
        const is_last = i == chunks.len - 1;
        const directive: zstd.EndDirective = if (is_last) .end else .flush;
        const res = try cstream.compressStream(out_buf[total..], chunk, directive);
        // res = { in_consumed: usize, out_produced: usize, remaining: usize }
        std.debug.assert(res.in_consumed == chunk.len);
        total += res.out_produced;
    }
    const decompressed = try zstd.decompress(allocator, out_buf[0..total]);
    defer allocator.free(decompressed);
}
```

Key points:

- `StreamingCompressor.init(allocator, level i32)!` or `initWithOptions(allocator, CompressionOptions)`
- `compressStream(out, in, directive: EndDirective)` where `EndDirective = enum{ cont, flush, end }`
- Return struct is `{ in_consumed, out_produced, remaining }`

```bash
zig build run-streaming_compression
```

## With Options

```zig
var cstream = zstd.StreamingCompressor.initWithOptions(allocator, .{
    .level = 9,
    .checksum = true,
    .window_log = 20,
});
defer cstream.deinit();
cstream.setPledgedSrcSize(@as(?u64, expected_total));
cstream.setChecksumFlag(true);
```

## Streaming Decompression

```zig
const original = "Streaming decompression handles partial input and output buffers with backpressure. " ** 10;
const compressed = try zstd.compress(allocator, original);
defer allocator.free(compressed);

var dstream = zstd.StreamingDecompressor.init(allocator);
defer dstream.deinit();

var out: [1 << 16]u8 = undefined;
var out_pos: usize = 0;
var in_pos: usize = 0;
const chunk_size: usize = 64;
while (in_pos < compressed.len) {
    const chunk = compressed[in_pos..@min(in_pos + chunk_size, compressed.len)];
    const res = try dstream.decompressStream(out[out_pos..], chunk);
    // res = { in_consumed: usize, out_produced: usize, needs_more: bool }
    in_pos += res.in_consumed;
    out_pos += res.out_produced;
    if (res.needs_more and in_pos >= compressed.len) break;
}
std.debug.assert(std.mem.eql(u8, original, out[0..out_pos]));

// Alternative convenience
var dstream2 = zstd.StreamingDecompressor.init(allocator);
defer dstream2.deinit();
var out2: [1 << 16]u8 = undefined;
const n = try dstream2.decompressAll(&out2, compressed);
```

```bash
zig build run-streaming_decompression
```

## Multi-Chunk Round Trip

```zig
// Compress in chunks
var cstream = try zstd.StreamingCompressor.init(allocator, 3);
defer cstream.deinit();

var c_buf: [1 << 16]u8 = undefined;
var c_pos: usize = 0;
{
    const r = try cstream.compressStream(c_buf[c_pos..], "Hello, ", .cont);
    c_pos += r.out_produced;
}
{
    const r = try cstream.compressStream(c_buf[c_pos..], "World!", .end);
    c_pos += r.out_produced;
}

// Then decompress incrementally
var dstream = zstd.StreamingDecompressor.init(allocator);
defer dstream.deinit();

var d_buf: [4096]u8 = undefined;
var d_pos: usize = 0;
var i: usize = 0;
while (i < c_pos) {
    const sz: usize = @min(8, c_pos - i);
    const res = try dstream.decompressStream(d_buf[d_pos..], c_buf[i..i+sz]);
    i += res.in_consumed;
    d_pos += res.out_produced;
}
std.debug.print("{s}\n", .{d_buf[0..d_pos]}); // "Hello, World!"
```

## Resetting Streams

```zig
cstream.reset(); // clear buffer, checksum, finished/header flags
dstream.reset(); // clear in/out buffers, stage, frame_header
// Ready for a new job without reallocating
```

> Removed names: old `StreamCompressor` / `StreamDecompressor`, `compressChunk` / `decompressChunk`, `endStream` / `flushStream`, `recommendedInSize/OutSize`, `setParameter`, `StreamCompressOptions { level = .default }`, and `EndDirective @"continue"` are replaced by the API above (`Streaming*`, `compressStream`, `decompressStream`, `.cont/.flush/.end`).
