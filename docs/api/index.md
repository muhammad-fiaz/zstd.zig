---
title: API Reference
description: Complete API reference for zstd.zig compression library.
---

# API Reference

## Top-Level Functions

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

### `compressMT`

Compress one frame across a pool of workers. The frame is split into jobs, the
header is written once, and the result is an ordinary frame any decoder reads.
Threads start only for this call, on the `std.Io` passed in:

```zig
pub fn compressMT(allocator: std.mem.Allocator, io: std.Io, src: []const u8, options: CompressionOptions, threads: usize) anyerror![]u8
```

Keep the pool across many frames with `MTCompressor` instead:

```zig
pub const MTCompressor = struct {
    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: CompressionOptions, threads: usize) !MTCompressor;
    pub fn deinit(self: *MTCompressor) void;                    // joins the workers
    pub fn compressAlloc(self: *MTCompressor, src: []const u8) anyerror![]u8;
    pub fn compressInto(self: *MTCompressor, dst: []u8, src: []const u8) ZstdError!usize;
    minJobSize: usize = 512 * 1024;                             // job floor, lowerable for tests
};
```

A frame that fits in one job takes the serial path, so the result is exactly the
frame `compress` would have written. One compress call runs at a time per
compressor.

### `Pool`

The worker pool both of those are built on, exported as `zstd.pool`. Jobs are
plain `fn (?*anyopaque) void` plus one argument, so it fits work this library
does not know about:

```zig
pub const pool = @import("common/pool.zig");

var p = try zstd.pool.Pool.init(allocator, io, 4, 0);   // 4 workers, no queue
defer p.deinit();
p.add(work, arg);          // blocks until a worker takes it
if (p.tryAdd(work, arg)) {} // false instead of waiting; queue_size 0 means
                            // "a free worker or an empty queue"
p.joinJobs();              // wait for every queued job to finish
try p.resize(2);           // fewer (or more) workers
```

The allocator is the caller's; anything the jobs allocate is their business, so
a job that shares state across threads still needs whatever synchronisation that
state requires. The pool synchronises the queue, not the jobs.

### `Context`

One reusable context, one allocator, many operations (recommended for
repeated work):

```zig
var ctx = zstd.Context.init(allocator);
defer ctx.deinit();
const c = try ctx.compress(data);
defer allocator.free(c);
const d = try ctx.decompress(c);
defer allocator.free(d);
```

```zig
pub const Context = struct {
    pub fn init(allocator: std.mem.Allocator) Context;
    pub fn initWithLevel(allocator: std.mem.Allocator, level: i32) Context;
    pub fn deinit(self: *Context) void;
    pub fn setLevel(self: *Context, level: i32) void;
    pub fn setChecksum(self: *Context, flag: bool) void;
    pub fn reset(self: *Context) void;
    pub fn compress(self: *Context, src: []const u8) anyerror![]u8;
    pub fn decompress(self: *Context, src: []const u8) anyerror![]u8;
};
```

### `compressInto` / `decompressInto`

Preallocated-buffer variants:

```zig
pub fn compressInto(allocator: std.mem.Allocator, dst: []u8, src: []const u8, level: i32) ZstdError!usize
pub fn decompressInto(allocator: std.mem.Allocator, dst: []u8, src: []const u8) ZstdError!usize
```

### `compressBound` / `decompressBound` / `findFrameCompressedSize`

```zig
pub fn compressBound(srcSize: usize) usize
pub fn decompressBound(allocator: std.mem.Allocator, src: []const u8) ZstdError!usize
pub fn findFrameCompressedSize(allocator: std.mem.Allocator, src: []const u8) ZstdError!usize
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
pub fn createDictionaryFromData(allocator: std.mem.Allocator, data: []const u8, dictId: u32) ZstdError!Dictionary
pub fn getCompressionParameters(level: i32, srcSize: usize, windowLog: u8) CompressionOptions
```

### Version

```zig
pub fn versionString() []const u8 // "0.0.5"
pub fn versionNumber() u32 // 5
pub fn minCLevel() i32
pub fn maxCLevel() i32
pub fn defaultCLevel() i32
pub const version = "0.0.5";
pub fn specVersionString() []const u8 // "1.6.0"
pub fn specVersionNumber() u32 // 10600
```

## Types

| Type | Description |
|------|-------------|
| [CompressionOptions](/api/compress-options) | `level: i32, windowLog/hashLog/chainLog/searchLog/minMatch/targetLength/strategy/checksum/dictId/contentSize` |
| [DecompressionOptions](/api/decompress-options) | `maxWindowSize: usize, forceIgnoreChecksum: bool` |
| [Encoder](/api/compressor#encoder) | High-level client compression encoder with explicit multithreading and options |
| [Decoder](/api/decompressor#decoder) | High-level client decompression decoder with window limit and dictionary control |
| [Context](/api/index#context) | Unified reusable `compress`/`decompress` context (recommended) |
| [Compressor / Decompressor](/api/compressor) | Convenient aliases for CompressionContext and DecompressionContext |
| [CompressionContext](/api/compressor) | `init(allocator)`, `initWithLevel(allocator,i32)`, `compressAlloc`, `compress(dst,src)`, `setLevel`, `setChecksum`, `setWindowLog`, `setLongDistanceMatching`, `setPledgedSrcSize`, `setStrategy`, `setOptions`, `setDictionary`, `reset`, `deinit` |
| [DecompressionContext](/api/decompressor) | `init(allocator)`, `decompressAlloc`, `decompress(dst,src)`, `setMaxWindowSize`, `setDictionary`, `reset`, `deinit` |
| [StreamingCompressor](/api/stream-compressor) | `init(allocator,i32)!`, `initWithOptions(allocator,CompressionOptions)`, `compressStream(out,in,EndDirective)->{inConsumed,outProduced,remaining}`, `setPledgedSrcSize`, `setChecksumFlag`, `setDictionary`, `reset`, `deinit`; `EndDirective {cont,flush,end}` |
| [StreamingDecompressor](/api/stream-decompressor) | `init(allocator)`, `decompressStream(out,in)->{inConsumed,outProduced,needsMore}`, `setMaxWindowSize`, `reset`, `deinit` |
| [MTCompressor / compressMT](/api/index#compressmt) | `compressMT(allocator,io,src,options,threads)`, `MTCompressor.init(allocator,io,options,threads)`, `compressAlloc`, `compressInto`, `deinit` |
| [Pool](/api/index#pool) | `Pool.init(allocator,io,threads,queue_depth)`, `add`, `tryAdd`, `joinJobs`, `resize`, `count`, `deinit` |
| [Dictionary / DictionaryBuilder](/api/dict) | `Dictionary {dictId(), content(), deinit}`; `DictionaryBuilder{init(allocator,DictBuilderParams), train, trainCover(k,d), trainFastCover(k,d,f,accel)}` |
| [PreparedDictionary](/api/dict) | `prepare`, `fromContent`, `content`, `entropyTables`, `repeats`, `deinit` |
| [FrameHeader](/api/frame) | `frameType, headerSize, windowSize, blockSizeMax, dictId, checksumFlag, contentSize` |
| [Frame / FrameIterator](/api/frame) | Walk the frames in a buffer: `FrameIterator.init`, `next`, `offset`; `Frame {kind, offset, totalSize, frameBytes, headerBytes, payloadBytes, header, contentSize, windowSize, headerSize, isSkippable(), bytes()}` |
| [Strategy](/api/clevel) | `fast, dfast, greedy, lazy, lazy2, btlazy2, btopt, btultra, btultra2` |
| [Constants](/api/constants) | `MAGICNUMBER`, `MAGIC_DICTIONARY`, `MAGIC_SKIPPABLE_START`, `MAGIC_SKIPPABLE_MASK`, `BLOCKSIZE_MAX`, `MAX_INPUT_SIZE`, `CONTENTSIZE_UNKNOWN`, `CONTENTSIZE_ERROR`, `CLEVEL_DEFAULT` |
| [Errors](/api/errors) | `ZstdError` set, plus `zstd.errorToString` |

## Namespaces (Idiomatic Zig 0.17 Architecture)

zstd.zig exposes modular, cohesive namespaces grouping functionality by responsibility:

### `zstd.compression`
- `alloc(allocator, src, options) ![]u8` — one-shot allocator-backed compression.
- `into(allocator, dst, src, options) ZstdError!usize` — zero-allocation compression into caller-provided buffer.
- `default(allocator, src) ![]u8` — one-shot compression with default level 3.
- `withLevel(allocator, src, level) ![]u8` — compression with numeric level 1-22.
- `multithreaded(allocator, io, src, options, workers) ![]u8` — parallel multithreaded chunk compression.
- `bound(src_size) usize` — worst-case output buffer size calculation.

### `zstd.decompression`
- `alloc(allocator, src, options) ![]u8` — one-shot allocator-backed decompression.
- `into(allocator, dst, src, options) ZstdError!usize` — zero-allocation decompression into caller-provided buffer.
- `default(allocator, src) ![]u8` — decompression with default parameters.
- `frame(allocator, dst, src) ZstdError!FrameResult` — decompress exactly one frame.
- `bound(allocator, src) ZstdError!usize` — upper bound on decompressed size.

### `zstd.streaming`
- `Compressor` / `StreamingCompressor` — incremental streaming compressor with buffer recycling and `.cont`/`.flush`/`.end` directives.
- `Decompressor` / `StreamingDecompressor` — incremental streaming decompressor handling arbitrary chunk boundaries.
- `EndDirective` — enum with `.cont`, `.flush`, and `.end`.

### `zstd.io`
- `compressPipeline(allocator, *std.Io.Reader, *std.Io.Writer, level) !void` — streaming compression reading from reader into writer.
- `decompressPipeline(allocator, *std.Io.Reader, *std.Io.Writer) !void` — streaming decompression reading from reader into writer.

### `zstd.frames`
- `Header` — parsed frame header struct.
- `Iterator` — zero-copy iterator over concatenated frames in a buffer.
- `isZstd(src) bool` — detect regular Zstandard frame magic (`0xFD2FB528`).
- `isSkippable(src) bool` — detect skippable frame magic (`0x184D2A50` - `0x184D2A5F`).
- `getHeader(src) ZstdError!FrameHeader` — parse first frame header without decompressing.
- `inspect(allocator, src) ZstdError!FrameInfo` — inspect header and exact compressed size.

### `zstd.dictionary`
- `Dictionary` — dictionary state, `dictId()`, `content()`, and `deinit()`.
- `load(allocator, data) ZstdError!Dictionary` — parse raw dictionary bytes.
- `createFromData(allocator, data, dictId) ZstdError!Dictionary` — create dictionary with custom ID.
- `prepare(allocator, *Dictionary) ZstdError!PreparedDictionary` — pre-parse tables for high-throughput reuse.
- `trainCover(...)`, `trainFastCover(...)` — train dictionary models from sample corpora.

### `zstd.legacy`
- `isLegacy(src) bool` — true for any historical Zstandard format (v0.1 through v0.7).
- `detect(src) Format` — returns specific detected legacy format.
- `legacyVersion(src) ?u8` — returns numeric version (1-7) or null.
- `supportsDecode(version) bool` — true for supported historic decoders.
- `decompress(allocator, dst, src) ZstdError!Result` — decompress any recognized historic frame.
- `v01` through `v07` — per-version module declarations.

