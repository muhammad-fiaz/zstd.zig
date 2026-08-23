---
title: StreamingDecompressor
description: Chunk-based streaming decompression for large data.
---

> **Spec conformance:** zstd.zig implements the [Zstandard 1.6.0 specification](https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md) natively in Zig — every algorithm, frame element, and default table in this document follows that version.


# StreamingDecompressor

Process compressed data in chunks for streaming decompression. Defined in `src/streaming/decompress.zig:11` and re-exported as `zstd.StreamingDecompressor` / `zstd.DStream` (`src/zstd.zig:29-31`).

## Definition

```zig
pub const StreamingDecompressor = struct {
    allocator: std.mem.Allocator,
    in_buffer: std.ArrayList(u8),
    out_buffer: std.ArrayList(u8),
    stage: Stage, // .header, .blocks, .checksum, .done
    frame_header: ?FrameHeader,
    checksum_state: ChecksumState,
    finished: bool,
    // ...
};
pub const DStream = StreamingDecompressor;
```

## Methods

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) StreamingDecompressor
```

```zig
var dstream = zstd.StreamingDecompressor.init(allocator);
defer dstream.deinit();
// alias
var dstream2 = zstd.DStream.init(allocator);
defer dstream2.deinit();
```

### `deinit`

```zig
pub fn deinit(self: *StreamingDecompressor) void
```

### `decompressStream`

Incrementally decompress a chunk:

```zig
pub fn decompressStream(self: *StreamingDecompressor, out: []u8, in_data: []const u8)
    ZstdError!struct { in_consumed: usize, out_produced: usize, needs_more: bool }
```

```zig
var out: [1 << 16]u8 = undefined;
var out_pos: usize = 0;
var in_pos: usize = 0;
while (in_pos < compressed.len) {
    const chunk = compressed[in_pos..@min(in_pos + 64, compressed.len)];
    const res = try dstream.decompressStream(out[out_pos..], chunk);
    in_pos += res.in_consumed; // equals chunk.len
    out_pos += res.out_produced;
    if (!res.needs_more) break;
}
```

### `decompressAll`

Convenience: decompress entire buffer via the stream context (delegates to `decompressInto`):

```zig
pub fn decompressAll(self: *StreamingDecompressor, out: []u8, in_data: []const u8) ZstdError!usize
```

```zig
var out: [1 << 16]u8 = undefined;
const n = try dstream.decompressAll(&out, compressed);
```

### `reset`

Reset for reuse:

```zig
pub fn reset(self: *StreamingDecompressor) void
```

## Example

```zig
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
    in_pos += res.in_consumed;
    out_pos += res.out_produced;
}
std.debug.assert(std.mem.eql(u8, original, out[0..out_pos]));
```

> Removed names: old `StreamDecompressor.init(allocator, opts)`, `StreamDecompressOptions { dict: ?[]const u8 }`, `decompressChunk`, `recommendedDecompressInSize/OutSize` no longer exist â€” use `StreamingDecompressor` / `DStream` with `decompressStream` / `decompressAll`.
