---
title: Dictionaries
description: Use dictionary compression for better ratios on similar data.
---

# Dictionaries

Dictionary compression achieves significantly better compression ratios when compressing many similar small buffers (e.g., database records, JSON objects, log entries).

## Dictionary Type

`Dictionary` is defined in `src/dictionary/dictionary.zig:5`:

```zig
pub const Dictionary = struct {
    data: []u8, // includes 8-byte header (magic + dict_id)
    dict_id: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Dictionary) void
    pub fn dictId(self: *const Dictionary) u32
    pub fn content(self: *const Dictionary) []const u8 // raw content without header
};
```

Top-level helpers in `src/zstd.zig:52-53`:

```zig
pub fn loadDictionary(allocator: std.mem.Allocator, data: []const u8) ZstdError!Dictionary
pub fn createDictionaryFromData(allocator: std.mem.Allocator, data: []const u8, dict_id: u32) ZstdError!Dictionary
```

```zig
const zstd = @import("zstd");

// Create a dictionary from raw bytes with an explicit ID
var dict = try zstd.createDictionaryFromData(allocator, raw_bytes, 12345);
defer dict.deinit();
std.debug.print("ID={d} size={d}\n", .{ dict.dictId(), dict.data.len });
std.debug.print("content len={d}\n", .{ dict.content().len });

// Load an existing dictionary blob (preserves its stored dict_id)
var loaded = try zstd.loadDictionary(allocator, dict.data);
defer loaded.deinit();
std.debug.assert(loaded.dictId() == dict.dictId());
```

### Compressing with a Dictionary ID

Dictionary-aware compression currently stores the `dict_id` in the frame header via `CompressionOptions`:

```zig
const opts = zstd.CompressionOptions{ .dict_id = dict.dictId() };
const compressed = try zstd.compressWithOptions(allocator, data, opts);
defer allocator.free(compressed);

// Verify via header
const hdr = try zstd.getFrameHeader(compressed);
std.debug.assert(hdr.dict_id == dict.dictId());

const decompressed = try zstd.decompress(allocator, compressed);
defer allocator.free(decompressed);
```

> Removed names: old `CDict`/`DDict`, `compressUsingDict`, `decompressUsingDict`, `getDictIDFromDict`, `getDictIDFromFrame`, `compressUsingCDict` no longer exist — use `Dictionary`, `loadDictionary`, `createDictionaryFromData`, and `CompressionOptions.dict_id` instead.

## DictionaryBuilder

`DictionaryBuilder` is defined in `src/dictionary/builder.zig:51`:

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

Helper functions (same file):

```zig
pub fn trainFromSamples(allocator, samples, params) !Dictionary
pub fn trainCoverImpl(allocator, samples, params, k, d) !Dictionary
pub fn trainFastCoverImpl(allocator, samples, params, k, d, f, accel) !Dictionary
```

### Training a Dictionary

```zig
const samples = &[_][]const u8{
    sample1, sample2, sample3, sample4, sample5,
};

var builder = zstd.DictionaryBuilder.init(allocator, .{ .dict_size = 8192, .dict_id = 42 });
var dict = try builder.train(samples);
defer dict.deinit();

// Cover variants (k = capacity, d = dict bits)
var cdict = try builder.trainCover(samples, 6, 8);
defer cdict.deinit();

var fdict = try builder.trainFastCover(samples, 6, 8, 6, 2);
defer fdict.deinit();
```

Training requires at least one non-empty sample; content is synthesized from the samples in the current implementation.

### Full Example (mirrors `examples/dictionary_training.zig`)

```zig
var samples: std.ArrayList([]const u8) = .empty;
defer samples.deinit(allocator);
for (0..100) |i| {
    const s = try std.fmt.allocPrint(allocator, "sample {d}: common header payload {d}", .{ i, i % 10 });
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

## Running the Dictionary Examples

```bash
zig build run-dictionary_compression
zig build run-dictionary_training
```
