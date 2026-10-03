---
title: Streaming
description: Process large data with chunk-based streaming compression and decompression.
---

> **Spec conformance:** zstd.zig implements the [Zstandard 1.6.0 specification](https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md) natively in Zig - every algorithm, frame element, and default table in this document follows that version.


# Streaming

For data that doesn't fit in memory, use `StreamingCompressor` and `StreamingDecompressor` (aliases `CStream` / `DStream`).

## Streaming Compression

`StreamingCompressor` is defined. Two initializers:

```zig
pub fn init(allocator: std.mem.Allocator, level: i32) !StreamingCompressor
pub fn initWithOptions(allocator: std.mem.Allocator, options: CompressionOptions) StreamingCompressor
pub const CStream = StreamingCompressor;
```

```zig
const zstd = @import("zstd");

// Simple - numeric level
var comp = try zstd.StreamingCompressor.init(allocator, 3);
defer comp.deinit();

// Or with full options
var comp2 = zstd.StreamingCompressor.initWithOptions(allocator, .{
    .level = 9,
    .checksum = true,
    .windowLog = 20,
});
defer comp2.deinit();

var out: [1 << 16]u8 = undefined;
var total: usize = 0;

const r1 = try comp.compressStream(out[total..], chunk1, .cont);
total += r1.outProduced; // r1 = { inConsumed, outProduced, remaining }

const r2 = try comp.compressStream(out[total..], chunk2, .flush);
total += r2.outProduced;

const r3 = try comp.compressStream(out[total..], &[_]u8{}, .end);
total += r3.outProduced;
```

### Method

```zig
pub fn compressStream(self: *StreamingCompressor, out: []u8, in_data: []const u8, directive: EndDirective)
    ZstdError!struct { inConsumed: usize, outProduced: usize, remaining: usize }
```

### EndDirective

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
| `compressStream` | `compressStream(self: *StreamingCompressor, out: []u8, in: []const u8, directive: EndDirective) !struct{inConsumed,outProduced,remaining}` | Stream compress |
| `reset` | `reset(self: *StreamingCompressor) void` | Clear buffered state |


## Streaming Decompression

`StreamingDecompressor` is defined:

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
    // res = { inConsumed, outProduced, needsMore }
    in_pos += res.inConsumed; // equals chunk.len in current impl
    out_pos += res.outProduced;
    if (!res.needsMore) break;
}
```

### Methods

```zig
pub fn decompressStream(self: *StreamingDecompressor, out: []u8, inData: []const u8)
    ZstdError!struct { inConsumed: usize, outProduced: usize, needsMore: bool }

pub fn setMaxWindowSize(self: *StreamingDecompressor, limit: usize) void
pub fn reset(self: *StreamingDecompressor) void
pub fn deinit(self: *StreamingDecompressor) void
```

| Method | Signature | Description |
|--------|-----------|-------------|
| `init` | `init(allocator) StreamingDecompressor` | Create |
| `deinit` | `deinit(self: *StreamingDecompressor) void` | Free buffers |
| `decompressStream` | `decompressStream(self: *StreamingDecompressor, out: []u8, inData: []const u8) !{inConsumed,outProduced,needsMore}` | Incremental decompress |
| `setMaxWindowSize` | `setMaxWindowSize(self: *StreamingDecompressor, limit: usize) void` | Refuse frames declaring a larger window |
| `reset` | `reset(self: *StreamingDecompressor) void` | Reset state |

There is no one-shot method here. For a whole buffer in one call use
`zstd.decompress`; driving a stream by hand is the point of this type.

## Multi-Chunk Round Trip

```zig
// Compress in chunks
var cstream = try zstd.StreamingCompressor.init(allocator, 3);
defer cstream.deinit();

var c_buf: [1 << 16]u8 = undefined;
var c_pos: usize = 0;
{
    const r = try cstream.compressStream(c_buf[c_pos..], "Hello, ", .cont);
    c_pos += r.outProduced;
}
{
    const r = try cstream.compressStream(c_buf[c_pos..], "World!", .end);
    c_pos += r.outProduced;
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
    i += res.inConsumed;
    d_pos += res.outProduced;
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
