---
title: Decompression
description: Decompress data with zstd.zig and inspect frame metadata.
---

# Decompression

## One-Shot Decompression

```zig
const zstd = @import("zstd");

const decompressed = try zstd.decompress(allocator, compressed);
defer allocator.free(decompressed);
```

Signature (`src/zstd.zig:59`):

```zig
pub fn decompress(allocator: std.mem.Allocator, src: []const u8) anyerror![]u8
```

Decompress into a preallocated buffer (`src/zstd.zig:77`):

```zig
pub fn decompressInto(dst: []u8, src: []const u8) ZstdError!usize
// usage
var out: [1 << 16]u8 = undefined;
const written = try zstd.decompressInto(&out, compressed);
```

Bounding / sizing helpers:

```zig
const bound = try zstd.decompressBound(compressed); // estimated decompressed size (src/zstd.zig:81)
const frame_size = try zstd.findFrameCompressedSize(compressed); // exact frame size
```

## DecompressionOptions

`DecompressionOptions` is defined in `src/decompress/context.zig:41`:

```zig
pub const DecompressionOptions = struct {
    max_window_size: usize = 1 << 27,
    force_ignore_checksum: bool = false,
};
```

It is used by lower-level context configuration (currently `DecompressionContext` stores `max_window_size` directly). Top-level `zstd.decompress` does not take options — configure via context:

```zig
var dctx = zstd.DecompressionContext.init(allocator);
defer dctx.deinit();
dctx.setMaxWindowSize(1 << 27);
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_window_size` | `usize` | `1 << 27` (128 MB) | Maximum allowed window size for safety |
| `force_ignore_checksum` | `bool` | `false` | Skip checksum verification if set |

> Removed: old `DecompressOptions { dict, max_output_size }` no longer exists. Dictionary handling uses `Dictionary` type and `loadDictionary` instead of raw `dict` bytes.

## Reusable DecompressionContext

Reuse for multiple buffers (`src/decompress/context.zig:6`):

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

> Removed names: old `Decompressor`, `Decompressor.init(allocator, opts)`, `decompress()` returning owned slice without `decompressAlloc` are replaced by `DecompressionContext` above.

## Frame Inspection

Inspect zstd frame metadata without decompressing — top-level functions in `src/zstd.zig:100-132`:

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
std.debug.print("window_size={d} content_size={d} dict_id={d} checksum={} header_size={d} block_size_max={d}\n",
    .{ hdr.window_size, hdr.content_size, hdr.dict_id, hdr.checksum_flag, hdr.header_size, hdr.block_size_max });
```

```zig
pub const FrameHeader = struct {
    frame_type: FrameType, // .regular or .skippable
    header_size: u32,
    window_size: u64,
    block_size_max: u32,
    dict_id: u32,
    checksum_flag: bool,
    content_size: u64,
};
pub fn getFrameHeader(src: []const u8) ZstdError!FrameHeader
```

### Get compressed frame size

```zig
const size = try zstd.findFrameCompressedSize(compressed);
std.debug.print("Frame size: {d} bytes\n", .{size});
```

```zig
pub fn findFrameCompressedSize(src: []const u8) ZstdError!usize
```

### Get dictionary ID via header

```zig
const hdr = try zstd.getFrameHeader(compressed);
if (hdr.dict_id != 0) {
    std.debug.print("Dictionary ID: {d}\n", .{hdr.dict_id});
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

> Removed names: old `zstd.Frame.isFrame`, `zstd.Frame.contentSize` returning `union(enum){known, unknown, error}`, `zstd.Frame.compressedSize`, `zstd.Frame.dictId`, `zstd.Frame.inspect` no longer exist — use the top-level functions above.

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
