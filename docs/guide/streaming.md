---
title: Streaming
description: Process large data with chunk-based streaming compression and decompression.
---

# Streaming

For data that doesn't fit in memory, use `StreamingCompressor` and `StreamingDecompressor` (aliases `CStream` / `DStream`).

## Streaming Compression

`StreamingCompressor` is defined in `src/streaming/compress.zig:11`. Two initializers:

```zig
pub fn init(allocator: std.mem.Allocator, level: i32) !StreamingCompressor
pub fn initWithOptions(allocator: std.mem.Allocator, options: CompressionOptions) StreamingCompressor
pub const CStream = StreamingCompressor;
```

```zig
const zstd = @import("zstd");

// Simple — numeric level
var comp = try zstd.StreamingCompressor.init(allocator, 3);
defer comp.deinit();

// Or with full options
var comp2 = zstd.StreamingCompressor.initWithOptions(allocator, .{
    .level = 9,
    .checksum = true,
    .window_log = 20,
});
defer comp2.deinit();

var out: [1 << 16]u8 = undefined;
var total: usize = 0;

const r1 = try comp.compressStream(out[total..], chunk1, .cont);
total += r1.out_produced; // r1 = { in_consumed, out_produced, remaining }

const r2 = try comp.compressStream(out[total..], chunk2, .flush);
total += r2.out_produced;

const r3 = try comp.compressStream(out[total..], &[_]u8{}, .end);
total += r3.out_produced;
```

### Method

```zig
pub fn compressStream(self: *StreamingCompressor, out: []u8, in_data: []const u8, directive: EndDirective)
    ZstdError!struct { in_consumed: usize, out_produced: usize, remaining: usize }
```

### EndDirective (`src/streaming/compress.zig:9`)

```zig
pub const EndDirective = enum { cont, flush, end };
```

| Directive | Description |
|-----------|-------------|
| `.cont` | Keep stream open, buffer input |
| `.flush` | Flush buffered data as block(s) |
| `.end` | Finalize stream, write checksum if enabled |

### Configuration

```zig
comp.setPledgedSrcSize(@as(?u64, expected_total));
comp.setChecksumFlag(true);
comp.reset(); // reuse for new job
```

| Method | Signature | Description |
|--------|-----------|-------------|
| `init` | `init(allocator, level: i32) !StreamingCompressor` | Create with level |
| `initWithOptions` | `initWithOptions(allocator, CompressionOptions) StreamingCompressor` | Create with options |
| `deinit` | `deinit(self: *StreamingCompressor) void` | Free internal buffer |
| `setPledgedSrcSize` | `setPledgedSrcSize(self: *StreamingCompressor, size: ?u64) void` | Set pledged size |
| `setChecksumFlag` | `setChecksumFlag(self: *StreamingCompressor, flag: bool) void` | Enable/disable checksum |
| `compressStream` | `compressStream(self: *StreamingCompressor, out: []u8, in: []const u8, directive: EndDirective) !struct{in_consumed,out_produced,remaining}` | Stream compress |
| `reset` | `reset(self: *StreamingCompressor) void` | Clear buffered state |

> Removed names: old `StreamCompressor`, `StreamCompressOptions`, `compressChunk`, `endStream`, `flushStream`, `recommendedOutSize()`, `setParameter` no longer exist.

## Streaming Decompression

`StreamingDecompressor` is defined in `src/streaming/decompress.zig:11`:

```zig
pub const DStream = StreamingDecompressor;
pub fn init(allocator: std.mem.Allocator) StreamingDecompressor
```

```zig
var decomp = zstd.StreamingDecompressor.init(allocator);
defer decomp.deinit();

var out: [1 << 16]u8 = undefined;
var out_pos: usize = 0;
var in_pos: usize = 0;
const chunk_size: usize = 64;
while (in_pos < compressed.len) {
    const chunk = compressed[in_pos..@min(in_pos + chunk_size, compressed.len)];
    const res = try decomp.decompressStream(out[out_pos..], chunk);
    // res = { in_consumed, out_produced, needs_more }
    in_pos += res.in_consumed; // equals chunk.len in current impl
    out_pos += res.out_produced;
    if (!res.needs_more) break;
}

// Convenience: decompress entire buffer via stream context
var dstream2 = zstd.StreamingDecompressor.init(allocator);
defer dstream2.deinit();
var out2: [1 << 16]u8 = undefined;
const n = try dstream2.decompressAll(&out2, compressed);
```

### Methods

```zig
pub fn decompressStream(self: *StreamingDecompressor, out: []u8, in_data: []const u8)
    ZstdError!struct { in_consumed: usize, out_produced: usize, needs_more: bool }

pub fn decompressAll(self: *StreamingDecompressor, out: []u8, in_data: []const u8) ZstdError!usize

pub fn reset(self: *StreamingDecompressor) void
pub fn deinit(self: *StreamingDecompressor) void
```

| Method | Signature | Description |
|--------|-----------|-------------|
| `init` | `init(allocator) StreamingDecompressor` | Create |
| `deinit` | `deinit(self: *StreamingDecompressor) void` | Free buffers |
| `decompressStream` | `decompressStream(self: *StreamingDecompressor, out: []u8, in: []const u8) !{in_consumed,out_produced,needs_more}` | Incremental decompress |
| `decompressAll` | `decompressAll(self: *StreamingDecompressor, out: []u8, in: []const u8) !usize` | One-shot via stream |
| `reset` | `reset(self: *StreamingDecompressor) void` | Reset state |

> Removed names: old `StreamDecompressor.init(allocator, opts)`, `StreamDecompressOptions { dict }`, `decompressChunk`, `recommendedDecompressInSize/OutSize` no longer exist.

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
const compressed = c_buf[0..c_pos];

// Then decompress
var dstream = zstd.StreamingDecompressor.init(allocator);
defer dstream.deinit();

var d_buf: [4096]u8 = undefined;
var d_pos: usize = 0;
var i: usize = 0;
const chunk_sz: usize = 8;
while (i < compressed.len) {
    const chunk = compressed[i..@min(i + chunk_sz, compressed.len)];
    const res = try dstream.decompressStream(d_buf[d_pos..], chunk);
    i += res.in_consumed;
    d_pos += res.out_produced;
}
std.debug.print("{s}\n", .{d_buf[0..d_pos]}); // "Hello, World!"
```

## Reusing Streams

```zig
// Reset after .end to reuse without reallocating
cstream.reset();
dstream.reset();
// Ready for a new compression/decompression job
```
