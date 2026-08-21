---
title: Streaming Decompression
description: Streaming decompression with StreamingDecompressor and backpressure.
---

# Streaming Decompression

`examples/streaming_decompression.zig` — `StreamingDecompressor` / `DStream`.

## Client Code

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

// Convenience
var dstream2 = zstd.StreamingDecompressor.init(allocator);
defer dstream2.deinit();
var out2: [1 << 16]u8 = undefined;
const n = try dstream2.decompressAll(&out2, compressed);
```

## Output

```text
Stream decompressed 840 bytes
Verified streaming decompression
```

## Explanation

- `StreamingDecompressor` maintains `in_buffer`/`out_buffer`, `stage` (`header` → `blocks` → `checksum` → `done`) and `frame_header`.
- Handles `1-byte` chunks, `skippable` frames, `multiple frames`, `truncated` checks, and `ChecksumWrong`.
- `decompressAll` is a one-shot helper delegating to `decompress/decompress.zig:92`.

Run:

```bash
zig build run-streaming_decompression
```
