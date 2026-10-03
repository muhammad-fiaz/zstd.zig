---
title: StreamingDecompressor
description: Chunk-based streaming decompression for large data.
---

> **Spec conformance:** zstd.zig implements the [Zstandard 1.6.0 specification](https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md) natively in Zig - every algorithm, frame element, and default table in this document follows that version.


# StreamingDecompressor

Process compressed data in chunks for streaming decompression. Re-exported as `zstd.StreamingDecompressor` / `zstd.DStream`.

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
    ZstdError!struct { inConsumed: usize, outProduced: usize, needsMore: bool }
```

```zig
var out: [1 << 16]u8 = undefined;
var out_pos: usize = 0;
var in_pos: usize = 0;
while (in_pos < compressed.len) {
    const chunk = compressed[in_pos..@min(in_pos + 64, compressed.len)];
    const res = try dstream.decompressStream(out[out_pos..], chunk);
    in_pos += res.inConsumed; // equals chunk.len
    out_pos += res.outProduced;
    if (!res.needsMore) break;
}
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
    in_pos += res.inConsumed;
    out_pos += res.outProduced;
}
std.debug.assert(std.mem.eql(u8, original, out[0..out_pos]));
```

The loop above is the whole streaming contract: feed input, take output, repeat
until the input is consumed, then drain what is still buffered. There is no
one-shot helper on this type - `zstd.decompress` is the one-shot path, and using it
here would defeat the purpose of a streaming decompressor.
