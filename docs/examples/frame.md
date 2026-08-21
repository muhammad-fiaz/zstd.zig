---
title: Frame Inspection
description: Inspect zstd frame metadata without decompressing.
---

# Frame Inspection

All helpers are top-level in `zstd` (`src/zstd.zig:89-132`) returning `FrameHeader` or `u64` sentinels — there is no `zstd.Frame` namespace.

## Check if Data is a Zstd Frame

```zig
const zstd = @import("zstd");

if (zstd.isFrame(data)) {
    std.debug.print("Valid zstd frame\n", .{});
} else {
    std.debug.print("Not a zstd frame\n", .{});
}

if (zstd.isSkippableFrame(data)) {
    std.debug.print("Skippable frame\n", .{});
}
```

```zig
pub fn isFrame(src: []const u8) bool
pub fn isSkippableFrame(src: []const u8) bool
```

## Get Content Size

`getFrameContentSize` returns a `u64` sentinel, not a tagged union:

```zig
const size = zstd.getFrameContentSize(compressed);
if (size == zstd.CONTENTSIZE_UNKNOWN) {
    std.debug.print("Content size not specified in frame\n", .{});
} else if (size == zstd.CONTENTSIZE_ERROR) {
    std.debug.print("Invalid frame header\n", .{});
} else {
    std.debug.print("Original size: {d} bytes\n", .{size});
}
```

```zig
pub const CONTENTSIZE_UNKNOWN: u64 = 0xFFFFFFFFFFFFFFFF - 1;
pub const CONTENTSIZE_ERROR:   u64 = 0xFFFFFFFFFFFFFFFF - 2;
pub fn getFrameContentSize(src: []const u8) u64
```

## Get Compressed Size

```zig
const size = try zstd.findFrameCompressedSize(compressed);
std.debug.print("Compressed frame: {d} bytes\n", .{size});
```

```zig
pub fn findFrameCompressedSize(src: []const u8) ZstdError!usize
```

## Get Dictionary ID & Header Fields

Dictionary ID and all metadata come from `getFrameHeader`:

```zig
const hdr = try zstd.getFrameHeader(compressed);
if (hdr.dict_id != 0) {
    std.debug.print("Dictionary ID: {d}\n", .{hdr.dict_id});
}
std.debug.print("window_size={d} content_size={d} checksum={} header_size={d}\n",
    .{ hdr.window_size, hdr.content_size, hdr.checksum_flag, hdr.header_size });
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

## Skippable Frames

```zig
var buf: [32]u8 = undefined;
const n = zstd.writeSkippableFrame(&buf, "meta", 1);
std.debug.assert(zstd.isSkippableFrame(buf[0..n]));
var out: [16]u8 = undefined;
const m = try zstd.readSkippableFrame(&out, buf[0..n]);
std.debug.print("read {d} bytes from skippable frame\n", .{m});
```

```zig
pub fn writeSkippableFrame(dst: []u8, data: []const u8, magic_variant: u32) usize
pub fn readSkippableFrame(dst: []u8, src: []const u8) ZstdError!usize
```

## Complete Frame Inspection

```zig
fn inspectFrame(data: []const u8) !void {
    if (!zstd.isFrame(data)) {
        std.debug.print("Not a zstd frame\n", .{});
        return;
    }
    std.debug.print("Valid zstd frame\n", .{});

    const size = zstd.getFrameContentSize(data);
    if (size == zstd.CONTENTSIZE_UNKNOWN) std.debug.print("  Content size: unknown\n", .{})
    else if (size == zstd.CONTENTSIZE_ERROR) std.debug.print("  Content size: error\n", .{})
    else std.debug.print("  Content size: {d} bytes\n", .{size});

    const compressed_size = try zstd.findFrameCompressedSize(data);
    std.debug.print("  Compressed size: {d} bytes\n", .{compressed_size});

    const hdr = try zstd.getFrameHeader(data);
    std.debug.print("  Window size: {d}\n", .{hdr.window_size});
    std.debug.print("  Checksum: {}\n", .{hdr.checksum_flag});
    if (hdr.dict_id != 0) std.debug.print("  Dictionary ID: {d}\n", .{hdr.dict_id});
    std.debug.print("  Header size: {d}\n", .{hdr.header_size});
    std.debug.print("  Block max: {d}\n", .{hdr.block_size_max});
}
```

> Removed names: old `zstd.Frame.isFrame`, `zstd.Frame.contentSize` (union), `zstd.Frame.compressedSize`, `zstd.Frame.dictId`, `zstd.Frame.inspect` / `FrameInfo` no longer exist — use `zstd.isFrame`, `zstd.getFrameContentSize`, `zstd.findFrameCompressedSize`, `zstd.getFrameHeader`, `zstd.isSkippableFrame`, `zstd.writeSkippableFrame`, `zstd.readSkippableFrame`.
