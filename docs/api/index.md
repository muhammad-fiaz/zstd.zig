---
title: API Reference
description: Complete API reference for zstd.zig compression library.
---

# API Reference

## Top-Level Functions (`src/zstd.zig`)

### `compress`

One-shot compression with default level (`3`).

```zig
pub fn compress(allocator: std.mem.Allocator, src: []const u8) anyerror![]u8
```

### `decompress`

One-shot decompression.

```zig
pub fn decompress(allocator: std.mem.Allocator, src: []const u8) anyerror![]u8
```

### `compressWithLevel`

Compress with numeric `i32` level.

```zig
pub fn compressWithLevel(allocator: std.mem.Allocator, src: []const u8, level: i32) anyerror![]u8
```

### `compressWithOptions`

Compress with `CompressionOptions`:

```zig
pub fn compressWithOptions(allocator: std.mem.Allocator, src: []const u8, options: CompressionOptions) anyerror![]u8
```

### `compressInto` / `decompressInto`

Preallocated-buffer variants:

```zig
pub fn compressInto(dst: []u8, src: []const u8, level: i32) ZstdError!usize
pub fn decompressInto(dst: []u8, src: []const u8) ZstdError!usize
```

### `compressBound` / `decompressBound` / `findFrameCompressedSize`

```zig
pub fn compressBound(src_size: usize) usize
pub fn decompressBound(src: []const u8) ZstdError!usize
pub fn findFrameCompressedSize(src: []const u8) ZstdError!usize
```

### `getFrameContentSize` / `getFrameHeader` / `isFrame` / `isSkippableFrame`

```zig
pub fn getFrameContentSize(src: []const u8) u64 // CONTENTSIZE_UNKNOWN / CONTENTSIZE_ERROR sentinels
pub fn getFrameHeader(src: []const u8) ZstdError!FrameHeader
pub fn isFrame(src: []const u8) bool
pub fn isSkippableFrame(src: []const u8) bool
pub fn writeSkippableFrame(dst: []u8, data: []const u8, magic_variant: u32) usize
pub fn readSkippableFrame(dst: []u8, src: []const u8) ZstdError!usize
```

### Dictionary

```zig
pub fn loadDictionary(allocator: std.mem.Allocator, data: []const u8) ZstdError!Dictionary
pub fn createDictionaryFromData(allocator: std.mem.Allocator, data: []const u8, dict_id: u32) ZstdError!Dictionary
pub fn getCompressionParameters(level: i32, src_size: usize, window_log: u8) CompressionOptions
```

### Version

```zig
pub fn versionString() []const u8
pub fn versionNumber() u32
pub fn minCLevel() i32
pub fn maxCLevel() i32
pub fn defaultCLevel() i32
pub const version: []const u8 = "1.6.0";
pub const version_number: u32 = 10600;
```

## Types

| Type | Source | Description |
|------|--------|-------------|
| [CompressionOptions](/api/compress-options) | `src/compress/compress.zig:8` | `level: i32, window_log/hash_log/chain_log/search_log/min_match/target_length/strategy/checksum/dict_id/content_size/enable_ldm` |
| [DecompressionOptions](/api/decompress-options) | `src/decompress/context.zig:41` | `max_window_size: usize, force_ignore_checksum: bool` |
| [CompressionContext](/api/compressor) | `src/compress/context.zig:6` | `init(allocator)`, `initWithLevel(allocator,i32)`, `compressAlloc`, `compress(dst,src)`, `setLevel`, `setChecksum`, `setWindowLog`, `setPledgedSrcSize`, `reset`, `deinit` |
| [DecompressionContext](/api/decompressor) | `src/decompress/context.zig:6` | `init(allocator)`, `decompressAlloc`, `decompress(dst,src)`, `setMaxWindowSize`, `reset`, `deinit` |
| [StreamingCompressor (CStream)](/api/stream-compressor) | `src/streaming/compress.zig:11` | `init(allocator,i32)!`, `initWithOptions(allocator,CompressionOptions)`, `compressStream(out,in,EndDirective)->{in_consumed,out_produced,remaining}`, `setPledgedSrcSize`, `setChecksumFlag`, `reset`, `deinit`; `EndDirective {cont,flush,end}` |
| [StreamingDecompressor (DStream)](/api/stream-decompressor) | `src/streaming/decompress.zig:11` | `init(allocator)`, `decompressStream(out,in)->{in_consumed,out_produced,needs_more}`, `decompressAll`, `reset`, `deinit` |
| [Dictionary / DictionaryBuilder](/api/dict) | `src/dictionary/dictionary.zig:5`, `src/dictionary/builder.zig:51` | `Dictionary {data, dictId(), content(), deinit}`, `DictionaryBuilder{init(allocator,DictBuilderParams), train, trainCover(k,d), trainFastCover(k,d,f,accel)}` |
| [FrameHeader](/api/frame) | `src/common/types.zig:3` | `frame_type, header_size, window_size, block_size_max, dict_id, checksum_flag, content_size` |
| [Strategy](/api/clevel) | `src/common/constants.zig:98` | `fast, dfast, greedy, lazy, lazy2, btlazy2, btopt, btultra, btultra2` |
| [Constants](/api/constants) | `src/common/constants.zig` | `MAGICNUMBER`, `MAGIC_DICTIONARY`, `BLOCKSIZE_MAX`, `MAX_INPUT_SIZE`, `CONTENTSIZE_UNKNOWN/ERROR`, etc. |
| [Errors](/api/errors) | `src/common/errors.zig` | `ZstdError` set |

## Namespaces

```zig
zstd.legacy        // legacy frame support: isLegacy(), legacyVersion(), findFrameSize(), decompressLegacy() for v01-v07
zstd.legacy_detect // legacyVersion()
```

## Removed Old Names

The following names appeared in outdated docs and do not exist in `src/zstd.zig`:

`Compressor` → `CompressionContext`, `Decompressor` → `DecompressionContext`, `StreamCompressor`/`StreamDecompressor` → `StreamingCompressor`/`StreamingDecompressor`, `CDict`/`DDict` → `Dictionary`, `Frame.isFrame`/`Frame.contentSize`/`Frame.compressedSize`/`Frame.dictId`/`Frame.inspect` → `isFrame`/`getFrameContentSize`/`findFrameCompressedSize`/`getFrameHeader`, `CLevel` enum → `i32`, `CompressOptions`/`DecompressOptions{dict}` → `CompressionOptions`/`DecompressionOptions{max_window_size,force_ignore_checksum}`, `trainFromSamples(buf,sizes,cap)`/`finalizeDictionary` → `DictionaryBuilder.train*`, `zstd.version.number/string` → `zstd.versionString/Number`, `zstd.constants` → top-level `zstd.MAGICNUMBER` etc.
