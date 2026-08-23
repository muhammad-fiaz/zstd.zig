---
title: FrameHeader
description: Inspect zstd frame metadata without decompressing.
---

> **Spec conformance:** zstd.zig implements the [Zstandard 1.6.0 specification](https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md) natively in Zig — every algorithm, frame element, and default table in this document follows that version.


# FrameHeader

Functions and struct for inspecting zstd frame headers without decompressing the data. Defined in `src/common/types.zig:3` and `src/zstd.zig:89-132`, `src/frame/header.zig`.

## FrameHeader Struct

```zig
pub const FrameType = enum { regular, skippable };

pub const FrameHeader = struct {
    frame_type: FrameType, // .regular or .skippable
    header_size: u32,
    window_size: u64,
    block_size_max: u32,
    dict_id: u32,
    checksum_flag: bool,
    content_size: u64, // or CONTENTSIZE_UNKNOWN / CONTENTSIZE_ERROR
};
```

| Field | Type | Description |
|-------|------|-------------|
| `frame_type` | `FrameType` | `.regular` or `.skippable` |
| `header_size` | `u32` | Size of frame header in bytes |
| `window_size` | `u64` | Window size (0 if unknown) |
| `block_size_max` | `u32` | Maximum block size (min(window_size, BLOCKSIZE_MAX)) |
| `dict_id` | `u32` | Dictionary ID (0 if none) |
| `checksum_flag` | `bool` | Whether frame has XXH64 checksum |
| `content_size` | `u64` | Original content size or `CONTENTSIZE_UNKNOWN` / `CONTENTSIZE_ERROR` |

## `isFrame`

Check if data starts with a valid zstd or skippable frame magic:

```zig
pub fn isFrame(src: []const u8) bool // src/zstd.zig:100 â€” detects zstd + skippable + legacy via detectFrame
```

```zig
if (zstd.isFrame(data)) {
    std.debug.print("Valid zstd frame\n", .{});
}
```

## `isSkippableFrame` / `writeSkippableFrame` / `readSkippableFrame`

```zig
pub fn isSkippableFrame(src: []const u8) bool
pub fn writeSkippableFrame(dst: []u8, data: []const u8, magic_variant: u32) usize
pub fn readSkippableFrame(dst: []u8, src: []const u8) ZstdError!usize
```

```zig
var buf: [32]u8 = undefined;
const n = zstd.writeSkippableFrame(&buf, "meta", 1);
std.debug.assert(zstd.isSkippableFrame(buf[0..n]));
var out: [16]u8 = undefined;
const m = try zstd.readSkippableFrame(&out, buf[0..n]);
```

## `getFrameHeader`

Parse header and return structured metadata:

```zig
pub fn getFrameHeader(src: []const u8) ZstdError!FrameHeader // src/zstd.zig:96
```

```zig
const hdr = try zstd.getFrameHeader(compressed);
std.debug.print("content_size={d} window_size={d} dict_id={d} checksum={} header_size={d}\n",
    .{ hdr.content_size, hdr.window_size, hdr.dict_id, hdr.checksum_flag, hdr.header_size });
```

## `getFrameContentSize`

Get original content size with sentinels:

```zig
pub fn getFrameContentSize(src: []const u8) u64 // src/zstd.zig:89
pub const CONTENTSIZE_UNKNOWN: u64 = 0xFFFFFFFFFFFFFFFF - 1;
pub const CONTENTSIZE_ERROR:   u64 = 0xFFFFFFFFFFFFFFFF - 2;
```

```zig
const size = zstd.getFrameContentSize(compressed);
if (size == zstd.CONTENTSIZE_UNKNOWN) std.debug.print("unknown\n", .{})
else if (size == zstd.CONTENTSIZE_ERROR) std.debug.print("error\n", .{})
else std.debug.print("size={d}\n", .{size});
```

## `findFrameCompressedSize`

Get total compressed size of the frame:

```zig
pub fn findFrameCompressedSize(src: []const u8) ZstdError!usize // src/zstd.zig:85
```

```zig
const size = try zstd.findFrameCompressedSize(compressed);
```

## Content Size Helpers

Alternative constants (same values):

```zig
pub const CONTENTSIZE_UNKNOWN = constants.contentsize_unknown; // 0xFF...FE? see constants
pub const CONTENTSIZE_ERROR   = constants.contentsize_error;
pub const MAGICNUMBER = 0xFD2FB528;
pub const MAGIC_DICTIONARY = 0xEC30A437;
pub const MAGIC_SKIPPABLE_START = 0x184D2A50;
```

## Removed Old API

| Old (removed) | New |
|---------------|-----|
| `zstd.Frame.isFrame` | `zstd.isFrame` |
| `zstd.Frame.inspect(...) -> FrameInfo` | `zstd.getFrameHeader` -> `FrameHeader` |
| `zstd.Frame.contentSize -> ContentSizeResult union` | `zstd.getFrameContentSize -> u64 sentinel` |
| `zstd.Frame.compressedSize` | `zstd.findFrameCompressedSize` |
| `zstd.Frame.dictId` | `(try zstd.getFrameHeader(data)).dict_id` |
| `FrameInfo{ content_size:?u64, window_size:?u64, dictionary_id:?u32, checksum }` | `FrameHeader{ window_size, content_size, dict_id, checksum_flag, ... }` |
