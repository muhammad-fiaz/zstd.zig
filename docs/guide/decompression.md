---
title: Decompression
description: Decompress data with zstd.zig and inspect frame metadata.
---

# Decompression

## Full Compressed-Block Support

The decoder implements the complete Zstandard entropy layer natively, following the Zstandard 1.6.0 specification:

| Feature | Status |
|---------|--------|
| `Raw_Block` / `RLE_Block` | ✅ |
| `Compressed_Block` - raw / RLE literals | ✅ |
| Huffman-coded literals (`set_compressed`) | ✅ single-stream & 4-stream, X1 flat tables |
| Treeless literals (`set_repeat`, reuses prior table) | ✅ carried per-frame |
| Sequence FSE modes: predefined / RLE / compressed / repeat | ✅ all four |
| Repeat offsets (`prevOffset[3]` incl. litLength==0 edge cases) | ✅ |
| Entropy + rep-offset carry-over across blocks in a frame | ✅ |
| XXH64 content checksum validation | ✅ |

Interoperability is verified bidirectionally against the official C `zstd` v1.6.0 CLI at levels 1 - 22 including `--ultra -22`.

## One-Shot Decompression

```zig
const zstd = @import("zstd");

const decompressed = try zstd.decompress(allocator, compressed);
defer allocator.free(decompressed);
```

Signature:

```zig
pub fn decompress(allocator: std.mem.Allocator, src: []const u8) anyerror![]u8
```

Decompress into a preallocated buffer:

```zig
pub fn decompressInto(allocator: std.mem.Allocator, dst: []u8, src: []const u8) ZstdError!usize
// usage
var out: [1 << 16]u8 = undefined;
const written = try zstd.decompressInto(allocator, &out, compressed);
```

Bounding / sizing helpers:

```zig
const bound = try zstd.decompressBound(allocator, compressed); // estimated decompressed size
const frame_size = try zstd.findFrameCompressedSize(allocator, compressed); // exact frame size
```

## DecompressionOptions

`DecompressionOptions` is defined:

```zig
pub const DecompressionOptions = struct {
    maxWindowSize: usize = 1 << 27,
    forceIgnoreChecksum: bool = false,
};
```

It is used by lower-level context configuration (currently `DecompressionContext` stores `maxWindowSize` directly). Top-level `zstd.decompress` does not take options - configure via context:

```zig
var dctx = zstd.DecompressionContext.init(allocator);
defer dctx.deinit();
dctx.setMaxWindowSize(1 << 27);
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `maxWindowSize` | `usize` | `1 << 27` (128 MB) | Maximum allowed window size for safety |
| `forceIgnoreChecksum` | `bool` | `false` | Skip checksum verification if set |


## Reusable DecompressionContext

Reuse for multiple buffers:

```zig
var dctx = zstd.DecompressionContext.init(allocator);
defer dctx.deinit();

const d1 = try dctx.decompressAlloc(c1);
defer allocator.free(d1);

const d2 = try dctx.decompressAlloc(c2);
defer allocator.free(d2);

// Into fixed buffer
var out: [4096]u8 = undefined;
const n = try dctx.decompress(&out, compressed);
```

### DecompressionContext Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `init` | `init(allocator: Allocator) DecompressionContext` | Create context |
| `deinit` | `deinit(self: *DecompressionContext) void` | Release resources |
| `decompress` | `decompress(self: *DecompressionContext, dst: []u8, src: []const u8) !usize` | Decompress into buffer |
| `decompressAlloc` | `decompressAlloc(self: *DecompressionContext, src: []const u8) anyerror![]u8` | Decompress with allocator |
| `setMaxWindowSize` | `setMaxWindowSize(self: *DecompressionContext, size: usize) void` | Set window size limit |
| `reset` | `reset(self: *DecompressionContext) void` | Reset internal stream state |


## Frame Inspection

Inspect zstd frame metadata without decompressing - top-level functions:

### Check if data is a zstd frame

```zig
if (zstd.isFrame(data)) {
    std.debug.print("Valid zstd frame\n", .{});
}
// Also skippable-frame aware:
if (zstd.isSkippableFrame(data)) {
    std.debug.print("Skippable frame\n", .{});
}
```

```zig
pub fn isFrame(src: []const u8) bool
pub fn isSkippableFrame(src: []const u8) bool
```

### Get original content size

```zig
const size = zstd.getFrameContentSize(compressed);
if (size == zstd.CONTENTSIZE_UNKNOWN) {
    std.debug.print("Content size unknown\n", .{});
} else if (size == zstd.CONTENTSIZE_ERROR) {
    std.debug.print("Invalid frame\n", .{});
} else {
    std.debug.print("Content size: {d}\n", .{size});
}
```

```zig
pub fn getFrameContentSize(src: []const u8) u64
// returns CONTENTSIZE_UNKNOWN or CONTENTSIZE_ERROR on error
```

### Get full frame header

```zig
const hdr = try zstd.getFrameHeader(compressed);
std.debug.print("windowSize={d} contentSize={d} dictId={d} checksum={} headerSize={d} blockSizeMax={d}\n",
    .{ hdr.windowSize, hdr.contentSize, hdr.dictId, hdr.checksumFlag, hdr.headerSize, hdr.blockSizeMax });
```

```zig
pub const FrameHeader = struct {
    frameType: FrameType, // .regular or .skippable
    headerSize: u32,
    windowSize: u64,
    blockSizeMax: u32,
    dictId: u32,
    checksumFlag: bool,
    contentSize: u64,
};
pub fn getFrameHeader(src: []const u8) ZstdError!FrameHeader
```

### Get compressed frame size

```zig
const size = try zstd.findFrameCompressedSize(allocator, compressed);
std.debug.print("Frame size: {d} bytes\n", .{size});
```

```zig
pub fn findFrameCompressedSize(allocator: std.mem.Allocator, src: []const u8) ZstdError!usize
```

### Get dictionary ID via header

```zig
const hdr = try zstd.getFrameHeader(compressed);
if (hdr.dictId != 0) {
    std.debug.print("Dictionary ID: {d}\n", .{hdr.dictId});
}
```

### Skippable frames

```zig
var buf: [32]u8 = undefined;
const n = zstd.writeSkippableFrame(&buf, "meta", 1);
std.debug.assert(zstd.isSkippableFrame(buf[0..n]));
var out: [16]u8 = undefined;
const m = try zstd.readSkippableFrame(&out, buf[0..n]);
```

```zig
pub fn writeSkippableFrame(dst: []u8, data: []const u8, magic_variant: u32) usize
pub fn readSkippableFrame(dst: []u8, src: []const u8) ZstdError!usize
```

## Error Handling

Decompression can fail with `ZstdError`:

```zig
const decompressed = zstd.decompress(allocator, data) catch |err| {
    switch (err) {
        error.PrefixUnknown => std.debug.print("Not a zstd frame\n", .{}),
        error.CorruptionDetected => std.debug.print("Data corrupted\n", .{}),
        error.SrcSizeWrong => std.debug.print("Source too short\n", .{}),
        error.DstSizeTooSmall => std.debug.print("Destination too small\n", .{}),
        error.ChecksumWrong => std.debug.print("Checksum mismatch\n", .{}),
        else => std.debug.print("Error: {}\n", .{err}),
    }
    return err;
};
```
