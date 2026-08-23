---
title: StreamingCompressor
description: Chunk-based streaming compression for large data.
---

> **Spec conformance:** zstd.zig implements the [Zstandard 1.6.0 specification](https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md) natively in Zig — every algorithm, frame element, and default table in this document follows that version.


# StreamingCompressor

Process data in chunks for streaming compression. Useful when data doesn't fit in memory. Defined in `src/streaming/compress.zig:11` and re-exported as `zstd.StreamingCompressor` / `zstd.CStream` (`src/zstd.zig:28-30`).

## Definition

```zig
pub const StreamingCompressor = struct {
    allocator: std.mem.Allocator,
    options: CompressionOptions,
    buffer: std.ArrayList(u8),
    checksum_state: ChecksumState,
    finished: bool,
    header_written: bool,
    level: i32,
    // ...
};
pub const CStream = StreamingCompressor;
pub const EndDirective = enum { cont, flush, end };
```

## Methods

### `init`

Create with numeric level (`i32`):

```zig
pub fn init(allocator: std.mem.Allocator, level: i32) !StreamingCompressor
```

```zig
var comp = try zstd.StreamingCompressor.init(allocator, 3);
defer comp.deinit();
// alias
var comp2 = try zstd.CStream.init(allocator, 6);
defer comp2.deinit();
```

### `initWithOptions`

Create with full `CompressionOptions`:

```zig
pub fn initWithOptions(allocator: std.mem.Allocator, options: CompressionOptions) StreamingCompressor
```

```zig
var comp = zstd.StreamingCompressor.initWithOptions(allocator, .{
    .level = 9,
    .checksum = true,
    .window_log = 20,
    .strategy = .lazy2,
});
defer comp.deinit();
```

### `deinit`

```zig
pub fn deinit(self: *StreamingCompressor) void
```

### `setPledgedSrcSize`

```zig
pub fn setPledgedSrcSize(self: *StreamingCompressor, size: ?u64) void
```

### `setChecksumFlag`

```zig
pub fn setChecksumFlag(self: *StreamingCompressor, flag: bool) void
```

### `compressStream`

Feed data into the stream:

```zig
pub fn compressStream(self: *StreamingCompressor, out: []u8, in_data: []const u8, directive: EndDirective)
    ZstdError!struct { in_consumed: usize, out_produced: usize, remaining: usize }
```

```zig
var out: [1 << 16]u8 = undefined;
const r1 = try comp.compressStream(out[0..], chunk1, .cont);
// r1.in_consumed == chunk1.len, r1.out_produced = bytes written to out, r1.remaining = buffered bytes

const r2 = try comp.compressStream(out[r1.out_produced..], chunk2, .flush);
const fin = try comp.compressStream(out[r1.out_produced + r2.out_produced ..], &[_]u8{}, .end);
```

### `reset`

Reset for reuse:

```zig
pub fn reset(self: *StreamingCompressor) void
```

## EndDirective

```zig
pub const EndDirective = enum { cont, flush, end };
```

| Directive | Description |
|-----------|-------------|
| `.cont` | Buffer input, only header may be emitted initially |
| `.flush` | Flush buffered data as block(s) |
| `.end` | Finalize stream, emit last blocks + checksum if enabled |

## Complete Example

```zig
var cstream = try zstd.StreamingCompressor.init(allocator, 3);
defer cstream.deinit();
var out_buf: [1 << 16]u8 = undefined;
var total: usize = 0;
for (chunks, 0..) |chunk, i| {
    const dir: zstd.EndDirective = if (i == chunks.len - 1) .end else .flush;
    const res = try cstream.compressStream(out_buf[total..], chunk, dir);
    total += res.out_produced;
}
```

> Removed names: old `StreamCompressor`, `StreamCompressOptions { level: CLevel }`, `compressChunk`, `endStream`, `flushStream`, `recommendedInSize/OutSize`, `setParameter` no longer exist â€” use `StreamingCompressor` / `CStream` and `compressStream` with `EndDirective {cont,flush,end}`.
