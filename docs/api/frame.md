---
title: FrameHeader
description: Inspect zstd frame metadata without decompressing.
---

> **Spec conformance:** zstd.zig implements the [Zstandard 1.6.0 specification](https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md) natively in Zig - every algorithm, frame element, and default table in this document follows that version.


# FrameHeader

Functions and struct for inspecting zstd frame headers without decompressing the data. Re-exported as `zstd.FrameHeader` and the frame-inspection functions.

## FrameHeader Struct

```zig
pub const FrameType = enum { regular, skippable };

pub const FrameHeader = struct {
    frameType: FrameType, // .regular or .skippable
    headerSize: u32,
    windowSize: u64,
    blockSizeMax: u32,
    dictId: u32,
    checksumFlag: bool,
    contentSize: u64, // or CONTENTSIZE_UNKNOWN / CONTENTSIZE_ERROR
};
```

| Field | Type | Description |
|-------|------|-------------|
| `frameType` | `FrameType` | `.regular` or `.skippable` |
| `headerSize` | `u32` | Size of frame header in bytes |
| `windowSize` | `u64` | Window size (0 if unknown) |
| `blockSizeMax` | `u32` | Maximum block size (min(window_size, BLOCKSIZE_MAX)) |
| `dictId` | `u32` | Dictionary ID (0 if none) |
| `checksumFlag` | `bool` | Whether frame has XXH64 checksum |
| `contentSize` | `u64` | Original content size or `CONTENTSIZE_UNKNOWN` / `CONTENTSIZE_ERROR` |

## `isFrame`

Check if data starts with a valid zstd or skippable frame magic:

```zig
pub fn isFrame(src: []const u8) bool // detects zstd, skippable and historic frames
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
pub fn getFrameHeader(src: []const u8) ZstdError!FrameHeader
```

```zig
const hdr = try zstd.getFrameHeader(compressed);
std.debug.print("contentSize={d} windowSize={d} dictId={d} checksum={} headerSize={d}\n",
    .{ hdr.contentSize, hdr.windowSize, hdr.dictId, hdr.checksumFlag, hdr.headerSize });
```

## `getFrameContentSize`

Get original content size with sentinels:

```zig
pub fn getFrameContentSize(src: []const u8) u64
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
pub fn findFrameCompressedSize(allocator: std.mem.Allocator, src: []const u8) ZstdError!usize
```

```zig
const size = try zstd.findFrameCompressedSize(allocator, compressed);
```

## Content Size Helpers

`getFrameContentSize` returns a `u64` sentinel rather than a result union. Compare
against the two exported sentinels instead of matching on a tag:

```zig
const size = zstd.getFrameContentSize(frame);
if (size == zstd.CONTENTSIZE_UNKNOWN) {
    // The frame does not declare its content size.
} else if (size == zstd.CONTENTSIZE_ERROR) {
    // The frame is malformed.
}
```

Other top-level constants: `MAGICNUMBER` (`0xFD2FB528`), `MAGIC_DICTIONARY`
(`0xEC30A437`), `MAGIC_SKIPPABLE_START` (`0x184D2A50`),
`MAGIC_SKIPPABLE_MASK` (`0xFFFFFFF0`).
