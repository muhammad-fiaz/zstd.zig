---
title: Dictionary Compression
description: Dictionary-based compression examples for better ratios on similar data.
---

# Dictionary Compression

Dictionary compression achieves much better ratios when compressing many similar small buffers.

## Basic Dictionary Usage

There is no `CDict`/`DDict` — use `Dictionary` with `loadDictionary` / `createDictionaryFromData` (`src/dictionary/dictionary.zig:5`, `src/zstd.zig:52`):

```zig
const std = @import("std");
const zstd = @import("zstd");

// Create a dictionary blob from raw bytes with explicit ID
var dict = try zstd.createDictionaryFromData(allocator, dict_data, 12345);
defer dict.deinit();
std.debug.print("dictId={d} size={d}\n", .{ dict.dictId(), dict.data.len });

// Load a stored dictionary blob (reads stored magic + dict_id)
var loaded = try zstd.loadDictionary(allocator, dict.data);
defer loaded.deinit();

// Access raw content without header
const content = dict.content();

// Compress with dictionary ID in frame header
const opts = zstd.CompressionOptions{ .dict_id = dict.dictId() };
const compressed = try zstd.compressWithOptions(allocator, data, opts);
defer allocator.free(compressed);

const decompressed = try zstd.decompress(allocator, compressed);
defer allocator.free(decompressed);
```

Full runnable example (`examples/dictionary_compression.zig`):

```zig
const dict_data = "common dictionary content for small message compression example";
var dict = try zstd.createDictionaryFromData(allocator, dict_data, 12345);
defer dict.deinit();

const samples = [_][]const u8{ "small message 1 with common prefix", "small message 2 with common prefix", "small message 3 with common prefix" };
var builder = zstd.DictionaryBuilder.init(allocator, .{ .dict_size = 4096, .dict_id = 999 });
var trained = try builder.train(&samples);
defer trained.deinit();

const data = "small message 4 with common prefix and extra content";
const opts = zstd.CompressionOptions{ .dict_id = dict.dictId() };
const cs = try zstd.compressWithOptions(allocator, data, opts);
defer allocator.free(cs);
const dec = try zstd.decompress(allocator, cs);
defer allocator.free(dec);
```

## Training a Dictionary

Use `DictionaryBuilder` (`src/dictionary/builder.zig:51`):

```zig
pub const DictBuilderParams = struct {
    dict_size: usize = 112640,
    dict_id: u32 = 0,
    level: u32 = 3,
};

pub const DictionaryBuilder = struct {
    pub fn init(allocator: std.mem.Allocator, params: DictBuilderParams) DictionaryBuilder
    pub fn train(self: *DictionaryBuilder, samples: []const []const u8) anyerror!Dictionary
    pub fn trainCover(self: *DictionaryBuilder, samples: []const []const u8, k: usize, d: usize) anyerror!Dictionary
    pub fn trainFastCover(self: *DictionaryBuilder, samples: []const []const u8, k: usize, d: usize, f: u32, accel: u32) anyerror!Dictionary
};
```

```zig
// Prepare samples as slice of slices
const sample1 = "The quick brown fox jumps over the lazy dog";
const sample2 = "A quick brown fox leaps over a lazy dog";
const sample3 = "The fast brown fox jumps above the lazy dog";
const samples = &[_][]const u8{ sample1, sample2, sample3 };

var builder = zstd.DictionaryBuilder.init(allocator, .{ .dict_size = 8192, .dict_id = 42 });
var dict = try builder.train(samples);
defer dict.deinit();

var cdict = try builder.trainCover(samples, 6, 8);
defer cdict.deinit();

var fdict = try builder.trainFastCover(samples, 6, 8, 6, 2);
defer fdict.deinit();
```

Runnable bulk example (`examples/dictionary_training.zig`):

```zig
var samples: std.ArrayList([]const u8) = .empty;
defer samples.deinit(allocator);
for (0..100) |i| {
    const s = try std.fmt.allocPrint(allocator, "sample {d}: common header and payload with id {d} and some repetitive text", .{ i, i % 10 });
    try samples.append(allocator, s);
}
defer for (samples.items) |s| allocator.free(s);

var builder = zstd.DictionaryBuilder.init(allocator, .{ .dict_size = 8192 });
var d = try builder.train(samples.items);
defer d.deinit();
var cd = try builder.trainCover(samples.items, 6, 8);
defer cd.deinit();
var fd = try builder.trainFastCover(samples.items, 6, 8, 6, 2);
defer fd.deinit();
```

## Dictionary ID from Frame

Check which dictionary a frame was written with via the header — not a separate helper:

```zig
const hdr = try zstd.getFrameHeader(compressed);
if (hdr.dict_id != 0) {
    std.debug.print("Frame uses dictionary ID: {d}\n", .{hdr.dict_id});
}
```

## Running

```bash
zig build run-dictionary_compression
zig build run-dictionary_training
```

> Removed names: old `zstd.CDict.init(dict, level)`, `zstd.DDict.init`, `compressUsingDict`, `decompressUsingDict`, `getDictIDFromDict`, `getDictIDFromFrame`, `trainFromSamples(buf, sizes, cap)`, `finalizeDictionary` no longer exist.
