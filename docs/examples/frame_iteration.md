---
title: Frame Iteration
description: Walking the frames in a buffer, regular and skippable.
---

# Frame Iteration

`examples/frame_iteration.zig`

A Zstandard stream is a sequence of frames, and each may be a regular frame or a
skippable frame carrying opaque bytes. `FrameIterator` walks them, reporting each
frame's boundaries - which is what you need to split a file into frames, report
per-frame metadata, or skip the parts that are not compressed data.

## Source

```zig
// Build a stream: skippable, regular, skippable, regular.
try appendSkippable(allocator, &stream, "metadata written by some tool");
{
    const f = try zstd.compress(allocator, "the first frame, ...");
    try stream.appendSlice(allocator, f);
}
try appendSkippable(allocator, &stream, "");
{
    const f = try zstd.compress(allocator, "the second frame, ...");
    try stream.appendSlice(allocator, f);
}

// Walk it. The iterator borrows the buffer and copies nothing, so the views it
// hands back are valid as long as `stream` is.
var it = zstd.FrameIterator.init(stream.items);
while (try it.next()) |frame| {
    if (frame.isSkippable()) {
        // opaque bytes, not content
    } else {
        const text = try zstd.decompress(allocator, frame.bytes());
    }
}
```

## Output

```text
frame 0: skippable at offset 0, 37 bytes total, payload 29 bytes
frame 1: regular at offset 37, 73 bytes total, header 6, window 64, content 64 bytes
         the first frame, with enough text to be worth compressing at all
frame 2: skippable at offset 110, 8 bytes total, payload 0 bytes
frame 3: regular at offset 118, 71 bytes total, header 6, window 68, content 68 bytes
         the second frame, also compressible, and a different length entirely
4 frames, 189 bytes consumed of 189
truncated input: 3 complete frames before the error
```

## Notes

- **Offsets are absolute within the buffer**, and `frame.totalSize` is header plus
  payload, so the next frame starts at `frame.offset + frame.totalSize`. The
  final line is the check that this holds: 189 bytes consumed of 189, with no gap
  and no overlap.
- **A skippable frame with an empty payload is 8 bytes** - the magic plus the
  length field, nothing else. Frame 2 is exactly that.
- **`isSkippable()` distinguishes the two kinds.** Skippable frames hold bytes the
  format does not interpret; passing one to a decompressor is an error, not an
  empty frame.
- **Truncation is reported, not yielded.** The last three lines feed the
  iterator a stream with its final five bytes removed. It returns the three
  complete frames and then fails. Yielding a partial frame would leave the caller
  decoding at an offset past the end of the data.
- The iterator borrows the buffer and copies nothing, so `frame.bytes()` and the
  other views stay valid exactly as long as the input does. It allocates nothing
  per frame.

## API used

| Member | Role |
|---|---|
| `zstd.FrameIterator.init(buf)` | Start at offset 0 |
| `it.next()` | Next `?Frame`, or the error that stopped it |
| `it.offset()` | Bytes consumed so far |
| `frame.isSkippable()` | Skippable or regular |
| `frame.bytes()` | The whole frame, header first |
| `frame.offset` / `totalSize` / `headerSize` / `windowSize` / `payloadBytes` | Frame geometry |
| `frame.header` | Parsed `FrameHeader`, meaningful for regular frames |

Run:

```bash
zig build run-frame_iteration
```
