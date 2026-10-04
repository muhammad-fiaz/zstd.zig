---
title: Window Limit
description: Bounding how large a declared window the decoder will accept.
---

# Window Limit

`examples/window_limit.zig`

A frame header states the window it wants. Honouring that blindly would let a
hostile header demand an enormous buffer, so the decoder refuses frames above a
caller-supplied limit. The limit is a **ceiling**, not a target: a frame at or
below it decodes, one byte above it does not.

## Source

```zig
const small = try zstd.compressWithOptions(allocator, &payload, .{ .windowLog = 10 });
const large = try zstd.compressWithOptions(allocator, &payload, .{ .windowLog = 18 });

const small_window: usize = @intCast((try zstd.inspectFrame(allocator, small)).header.windowSize);
const large_window: usize = @intCast((try zstd.inspectFrame(allocator, large)).header.windowSize);
```

## Output

```text
small frame declares a 13 byte window
large frame declares a 200000 byte window
limit 13: accepted, 13 bytes
limit 14: accepted, 13 bytes
limit 12: refused as WindowTooLarge
limit 0: refused as WindowTooLarge
limit 14: refused as WindowTooLarge
limit 200000: accepted, 200013 bytes
streaming with a matching limit accepted 8192 bytes
streaming refused it as WindowTooLarge
```

## The boundary

The first three lines are the whole contract, and the third is the one that
matters:

- **limit 13** - the frame's own window. Accepted.
- **limit 14** - one above. Accepted, because the limit is a ceiling and a frame
  smaller than the limit is fine.
- **limit 12** - one below. **Refused.** A frame needing exactly `window` bytes of
  history has no slack, so the boundary is exact and the off-by-one is in the
  refusing direction.

`limit 0` is refused for the same reason, and `limit 14` against the large frame
is refused because 200000 > 14. The last two lines repeat the check through
`StreamingDecompressor`, which must reach the same verdict as the one-shot path  - 
otherwise a caller would get different answers depending on how it happened to
read the data.

## Where the limit goes

| Path | How to set it |
|---|---|
| One-shot | `zstd.decompressWithOptions(..., .{ .maxWindowSize = limit })` |
| Context | `ctx.setMaxWindowSize(limit)` |
| Streaming | `StreamingDecompressor` + `setMaxWindowSize(limit)` |

The default is `1 << 27` (128 MiB), which is the format's own maximum window log.
Lowering it is how you bound memory for untrusted input; a frame that declares
more than you allow is refused before any buffer of that size is allocated.

Run:

```bash
zig build run-window_limit
```
