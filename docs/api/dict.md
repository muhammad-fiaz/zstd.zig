---
title: Dictionary / DictionaryBuilder
description: Dictionary compression and decompression types.
---

> **Spec conformance:** zstd.zig implements the [Zstandard 1.6.0 specification](https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md) natively in Zig - every algorithm, frame element, and default table in this document follows that version.


# Dictionary / DictionaryBuilder

The dictionary's content is the encoder's prefix history and the decoder's initial window for the frame, and the frame header records the dictionary ID so a mismatched dictionary is rejected. Re-exported as `zstd.Dictionary`, `zstd.DictionaryBuilder`, `zstd.DictBuilderParams`.

## Dictionary

Loaded dictionary with raw `data` (including 8-byte header `MAGIC_DICTIONARY + dictId`) and helpers.

### Definition

```zig
pub const Dictionary = struct {
    data: []u8,
    dictId: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Dictionary) void
    pub fn dictId(self: *const Dictionary) u32
    pub fn content(self: *const Dictionary) []const u8 // without 8-byte header if present
};
```

### Top-Level Functions

```zig
pub fn loadDictionary(allocator: std.mem.Allocator, data: []const u8) ZstdError!Dictionary
pub fn createDictionaryFromData(allocator: std.mem.Allocator, data: []const u8, dictId: u32) ZstdError!Dictionary
```

### Usage

```zig
// Create from raw content with explicit ID
var dict = try zstd.createDictionaryFromData(allocator, raw_bytes, 12345);
defer dict.deinit();
std.debug.print("dictId={d}\n", .{ dict.dictId() });

// Load stored blob (reads header magic + id)
var loaded = try zstd.loadDictionary(allocator, dict.data);
defer loaded.deinit();

// Access content without header
const c = dict.content();

// Use dictId in frame header
const compressed = try zstd.compressWithOptions(allocator, data, .{ .dictId = dict.dictId() });
defer allocator.free(compressed);
const hdr = try zstd.getFrameHeader(compressed);
std.debug.assert(hdr.dictId == dict.dictId());
```

## DictionaryBuilder

Builder for training dictionaries from samples. Defined:

### Definition

```zig
pub const DictBuilderParams = struct {
    dictSize: usize = 112640,
    dictId: u32 = 0,
    level: u32 = 3,
};

pub const DictionaryBuilder = struct {
    allocator: std.mem.Allocator,
    params: DictBuilderParams,

    pub fn init(allocator: std.mem.Allocator, params: DictBuilderParams) DictionaryBuilder
    pub fn train(self: *DictionaryBuilder, samples: []const []const u8) anyerror!Dictionary
    pub fn trainCover(self: *DictionaryBuilder, samples: []const []const u8, k: usize, d: usize) anyerror!Dictionary
    pub fn trainFastCover(self: *DictionaryBuilder, samples: []const []const u8, k: usize, d: usize, f: u32, accel: u32) anyerror!Dictionary
};

// Free functions also available:
pub fn trainFromSamples(allocator, samples, params) !Dictionary
pub fn trainCoverImpl(allocator, samples, params, k, d) !Dictionary
pub fn trainFastCoverImpl(allocator, samples, params, k, d, f, accel) !Dictionary
```

### Usage

```zig
var builder = zstd.DictionaryBuilder.init(allocator, .{ .dictSize = 8192, .dictId = 999 });

const samples = &[_][]const u8{ s1, s2, s3 };
var dict = try builder.train(samples);
defer dict.deinit();

var cdict = try builder.trainCover(samples, 6, 8);
defer cdict.deinit();

var fdict = try builder.trainFastCover(samples, 6, 8, 6, 2);
defer fdict.deinit();
```

### Full Example (`examples/dictionary_training.zig`)

```zig
var samples: std.ArrayList([]const u8) = .empty;
defer samples.deinit(allocator);
for (0..100) |i| {
    const s = try std.fmt.allocPrint(allocator, "sample {d}: common header and payload with id {d} and some repetitive text", .{ i, i % 10 });
    try samples.append(allocator, s);
}
defer for (samples.items) |s| allocator.free(s);

var builder = zstd.DictionaryBuilder.init(allocator, .{ .dictSize = 8192 });
var d = try builder.train(samples.items);
defer d.deinit();
var cd = try builder.trainCover(samples.items, 6, 8);
defer cd.deinit();
var fd = try builder.trainFastCover(samples.items, 6, 8, 6, 2);
defer fd.deinit();
```

## DictBuilderParams

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `dictSize` | `usize` | `112640` | Desired dictionary size |
| `dictId` | `u32` | `0` | Dictionary ID to embed |
| `level` | `u32` | `3` | Compression level hint |

## Removed Old API

| Old (removed) | New |
|---------------|-----|
| `CDict.init(dict_buffer, level)` / `CDict.compress` | `Dictionary` + `createDictionaryFromData` / `compressWithOptions(.dictionary)` |
| `DDict.init(dict_buffer)` / `DDict.decompress` | `Dictionary` + `loadDictionary` / `decompress` |
| `compressUsingDict(alloc, src, dict, level)` | `compressWithOptions(alloc, src, .{ .dictionary = &dict })` |
| `decompressUsingDict(alloc, src, dict)` | `decompressWithOptions(alloc, src, .{ .dictionary = &dict })` |
| `getDictIDFromDict` / `getDictIDFromFrame` | `dict.dictId()` / `(try getFrameHeader(src)).dictId` |
| `trainFromSamples(buf, sizes, cap)` / `finalizeDictionary` | `DictionaryBuilder.train*` / `DictBuilderParams` |
| `DictParams { compression_level, dictId }` | `DictBuilderParams { dictSize, dictId, level }` |
