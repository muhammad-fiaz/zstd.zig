<div align="center">

# zstd.zig

<a href="https://muhammad-fiaz.github.io/zstd.zig/"><img src="https://img.shields.io/badge/docs-muhammad--fiaz.github.io-blue" alt="Documentation"></a>
<a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.17.0-orange.svg?logo=zig" alt="Zig Version"></a>
<a href="https://github.com/muhammad-fiaz/zstd.zig"><img src="https://img.shields.io/github/stars/muhammad-fiaz/zstd.zig" alt="GitHub stars"></a>
<a href="https://github.com/muhammad-fiaz/zstd.zig/issues"><img src="https://img.shields.io/github/issues/muhammad-fiaz/zstd.zig" alt="GitHub issues"></a>
<a href="https://github.com/muhammad-fiaz/zstd.zig/pulls"><img src="https://img.shields.io/github/issues-pr/muhammad-fiaz/zstd.zig" alt="GitHub pull requests"></a>
<a href="https://github.com/muhammad-fiaz/zstd.zig"><img src="https://img.shields.io/github/last-commit/muhammad-fiaz/zstd.zig" alt="GitHub last commit"></a>
<a href="https://github.com/muhammad-fiaz/zstd.zig/blob/dev/LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License"></a>
<a href="https://github.com/muhammad-fiaz/zstd.zig/actions/workflows/ci.yml"><img src="https://github.com/muhammad-fiaz/zstd.zig/actions/workflows/ci.yml/badge.svg?branch=dev" alt="CI"></a>
<img src="https://img.shields.io/badge/platforms-linux%20%7C%20windows%20%7C%20macos-blue" alt="Supported Platforms">
<a href="https://github.com/muhammad-fiaz/zstd.zig/releases/latest"><img src="https://img.shields.io/github/v/release/muhammad-fiaz/zstd.zig?label=Latest%20Release&style=flat-square" alt="Latest Release"></a>
<a href="https://pay.muhammadfiaz.com"><img src="https://img.shields.io/badge/Sponsor-pay.muhammadfiaz.com-ff69b4?style=flat&logo=heart" alt="Sponsor"></a>
<a href="https://github.com/sponsors/muhammad-fiaz"><img src="https://img.shields.io/badge/Sponsor-GitHub-pink?style=social&logo=github" alt="GitHub Sponsors"></a>
<a href="https://hits.sh/muhammad-fiaz/zstd.zig/"><img src="https://hits.sh/muhammad-fiaz/zstd.zig.svg?label=Visitors&extraCount=0&color=green" alt="Repo Visitors"></a>

<p><em>native Zig implementation of Facebook's Zstandard fast compression library.</em></p>

<b><a href="https://muhammad-fiaz.github.io/zstd.zig/">Documentation</a> |
<a href="https://muhammad-fiaz.github.io/zstd.zig/api/">API Reference</a> |
<a href="https://muhammad-fiaz.github.io/zstd.zig/guide/getting-started">Quick Start</a> |
<a href="CONTRIBUTING.md">Contributing</a></b>

</div>

A production-ready, native Zig implementation of the Zstandard compression format and codec, written from scratch in Zig with full compression, decompression, streaming, dictionary, frame, entropy-coding, and interoperability support. No C bindings, no external dependencies. Every byte is Zig.

> [!TIP]
> If you build with zstd.zig, make sure to give it a star.

> [!NOTE]
> This implementation follows the **Zstandard 1.6.0 specification**: the algorithms, formats, and logic are implemented natively in Zig to that specification.
>
> `zstd.zig` is a native Zig implementation of the Zstandard format and codec. The Zstandard project is used as a technical reference for format behavior, compatibility, and interoperability testing. All code in this repository is Zig; the reference implementation is not vendored, linked, or invoked, and is not required to build, test, or document this project.
>
> **Versioning:** `zstd.version` (or `zstd.versionString()`) tracks this library's release (0.0.4); `zstd.specVersionString()` tracks the Zstandard format specification it implements (1.6.0). The two move independently.
>
> **Pure Zig - zero C dependencies:** Unlike binding-based approaches, `zstd.zig` implements the Zstandard format directly in Zig, including:
> - **Frame format** with magic number validation, content size detection, and checksum verification
> - **Full compressed-block encoding and decoding** - raw, RLE, and compressed blocks; literals as raw, RLE, Huffman (1 and 4 streams) or treeless-Huffman; sequences with predefined, RLE, compressed, and repeat FSE tables
> - **Huffman coding** - optimal length-limited code construction, FSE-compressed or direct weight descriptions, X1-style flat decode tables, single-stream and 4-stream literal coding and decoding
> - **FSE (Finite State Entropy)** - compact table-header parsing and writing, normalized-count construction, decoding-table construction (`(next << nbBits) - size` transitions), predefined/RLE/compressed/repeat symbol modes
> - **Repeat-offset semantics** - full three-offset history including the `literalLength == 0` edge cases, carried across blocks within a frame
> - **Entropy carry-over** - the literals Huffman table and the three sequence FSE tables persist across blocks of a frame, so treeless literal blocks and repeat sequence tables work exactly as the format intends
> - **LZ77** back-reference matching with sliding-window history spanning prior blocks
> - **Per-strategy match finding** - a single-probe hash table (`fast`), the two-probe table (`dfast`), a bounded hash chain (`greedy`, `lazy`, `lazy2`), a binary tree of suffix-ordered positions (`btlazy2`), and a priced optimal parse on top of that tree (`btopt`, `btultra`, `btultra2`). Each level's strategy runs its own algorithm, not just different numbers.
> - **Long-distance matching** - a gear-hash split-point finder with a bucketed, checksum-validated table (`longDistanceMatching` plus the `ldm*` options), for matches further back than the window
> - **Client-side concurrency** - nothing here starts a thread unless you ask for one. Compress independent inputs in parallel by giving each thread its own `CompressionContext`; compress one large input in parallel with `compressMT()` / `MTCompressor`, which split the frame across a pool of workers over the `std.Io` you pass in
> - **Dictionary support**: a dictionary's content is real match history for the encoder, its ID is recorded in the frame, a mismatched dictionary is rejected rather than mis-decoded, and dictionaries can be trained from samples
> - **Streaming API** with `StreamingCompressor`/`StreamingDecompressor`: incremental in both directions, blocks emitted as input arrives, output accepted as small as one byte, and a sliding window instead of a whole-frame buffer
> - **Parameter API** for fine-tuning compression level, window size, hash tables, and search effort
> - **Frame inspection** for metadata extraction without full decompression
>
> **Interoperability verified:** frames produced by this library decode byte-for-byte with the reference Zstandard tooling, and reference-generated frames decode byte-for-byte here (see Interoperability Verification below).
>
> **Pre-1.0 historic frames: v0.1 through v0.5 decode, v0.6 and v0.7 are refused.** All seven historic magics (v01-v07) are recognised and versioned. v0.1 decodes: a real v0.1.1 frame regenerates byte for byte to the content it was made from, covering the four-stream literal layout, the Huffman table built from its FSE-compressed weights, the raw-mode sequence tables, and the sequence bitstream with its offset extra bits and repeat-offset resolution. v0.2, v0.3 and v0.4 each have their own reader, one per format change: v0.2 introduces the five-byte literals header and its own FSE table selection, v0.3 the two changes layered on it, and v0.4 the three it adds. v0.5 changes the literals header again into a scaled one that can also select a single-stream Huffman section, reads a sequence by peeking before it consumes bits, numbers raw before RLE, and starts its repeat offset at 1; each is verified by decoding that version's real frame byte for byte. v0.6 and v0.7 are refused from every entry point with `error.VersionUnsupported` rather than producing output that was not read from the body. A refused frame yields no bytes at all.

---

<details>
<summary><strong>Features</strong> (click to expand)</summary>

| Feature | Description |
|---------|-------------|
| **One-shot Compression** | `zstd.compress()` for single-call compression with default options |
| **One-shot Decompression** | `zstd.decompress()` for single-call decompression with safety limits |
| **Compression Levels** | Numeric levels 1-22 via `zstd.compressWithLevel()` and `zstd.getCompressionParameters()` |
| **Reusable Compressor** | `CompressionContext` for efficient multi-call compression with state |
| **Reusable Decompressor** | `DecompressionContext` for efficient multi-call decompression with configurable limits |
| **Streaming Compression** | `StreamingCompressor` for chunked data with `compressStream()`, `EndDirective`, and an explicit `remaining` count |
| **Streaming Decompression** | `StreamingDecompressor` for chunked data with `decompressStream()`, which accepts output as small as one byte |
| **Dictionary Compression** | `CompressionOptions.dictionary` / `DecompressionOptions.dictionary`: dictionary content as match history, dictionary ID in the frame, mismatch rejected |
| **Dictionary Training** | `DictionaryBuilder.train()`, `trainCover()`, `trainFastCover()` for creating custom dictionaries from samples |
| **Dictionary Contexts** | `Compressor.setDictionary()` / `Decompressor.setDictionary()` for a reusable context |
| **Frame Inspection** | `isFrame()`, `getFrameHeader()`, `getFrameContentSize()`, `findFrameCompressedSize()` for metadata extraction |
| **Parameter API** | `CompressionOptions` and `Strategy` for windowLog, hashLog, chainLog, searchLog, targetLength |
| **Checksum Support** | Optional XXH64 checksum in frame headers for data integrity verification |
| **Content Size Validation** | Validates content size on decompression against expected size |
| **Window Size Limits** | Configurable `maxWindowSize` for decompression safety |
| **Multi-frame Decompression** | Decompress multiple concatenated zstd frames in sequence |
| **Skippable Frame Support** | Skip non-data frames during decompression via `isSkippableFrame()` |
| **Cross-platform** | Linux, Windows, macOS with x86_64, aarch64, x86 support |
| **Zero Dependencies** | Pure Zig implementation - no C libraries, no system dependencies |
| **Compression Bound** | `compressBound()` for pre-allocating output buffers |
| **Historic Formats** | v01-v05 frames decode to their exact content, each with its own reader; v06-v07 are detected, sized where possible, and refused with `error.VersionUnsupported` rather than guessed at |
| **Multithreaded Compression** | `compressMT()` and `MTCompressor` split one frame across a worker pool (`zstd.pool`), one `std.Io` supplied by the caller |
| **Worker Pool** | `Pool.init()` with worker count and queue depth, `add`/`tryAdd`/`joinJobs`/`resize`, for the caller's own jobs |
| **Differential Harness** | `zig build test` checks both directions against a reference `zstd`, found automatically; a missing reference fails the run rather than skipping |
| **Stress, Fuzz, Benchmarks** | `zig build stress`, `zig build fuzz`, `zig build bench` for concurrency stress, seeded fuzz targets, and throughput |

</details>

---

<details>
<summary><strong>Prerequisites and Supported Platforms</strong> (click to expand)</summary>

<br>

## Prerequisites

Before using `zstd.zig`, ensure you have the following:

| Requirement | Version | Notes |
|-------------|---------|-------|
| **Zig** | **0.17.0** (required) | Download from [ziglang.org](https://ziglang.org/download/) |
| **Operating System** | Windows 10+, Linux, macOS | Cross-platform support |

---

## Supported Platforms

`zstd.zig` is validated on these architectures:

| Platform | x86_64 (64-bit) | aarch64 (ARM64) | x86 (32-bit) |
|----------|-----------------|-----------------|--------------|
| **Linux** | Yes | Yes (via QEMU) | Yes |
| **Windows** | Yes | Yes | Yes |
| **macOS** | Yes (via aarch64 runner) | Yes (Apple Silicon) | No |

### Cross-Compilation

Zig makes cross-compilation easy. Build for any target from any host:

```bash
# Build for Linux ARM64 from Windows
zig build -Dtarget=aarch64-linux

# Build for Windows from Linux
zig build -Dtarget=x86_64-windows

# Build for macOS Apple Silicon from Linux
zig build -Dtarget=aarch64-macos

# Build for 32-bit Windows
zig build -Dtarget=x86-windows

# Run tests with emulation for cross targets
zig build test -Dtarget=aarch64-linux --summary all -fqemu
```

</details>

---

## Installation

### Method 1: Zig Fetch (Recommended)

**Latest Release (v0.0.4)** - requires Zig 0.17.0.

```bash
zig fetch --save https://github.com/muhammad-fiaz/zstd.zig/archive/refs/tags/0.0.4.tar.gz
```

> **Still on Zig 0.16?** Use the previous stable release **v0.0.3**, which is
> the last version supporting Zig 0.16.x:
>
> ```bash
> zig fetch --save https://github.com/muhammad-fiaz/zstd.zig/archive/refs/tags/0.0.3.tar.gz
> ```

### Method 2: Zig Fetch (Dev Branch - Latest Updates)

Use the latest development version from the `dev` branch. This tracks the
newest features and fixes ahead of the next release.

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/zstd.zig.git
```

### Method 3: Manual `build.zig.zon` Configuration

Add the dependency to your `build.zig.zon` file.

```zig
.dependencies = .{
    .zstd = .{
        .url = "https://github.com/muhammad-fiaz/zstd.zig/archive/refs/tags/0.0.4.tar.gz",
        .hash = "...", // Run `zig fetch --save <url>` to generate the hash.
    },
},
```

### Method 4: Local Source Checkout

Clone the repository locally.

```bash
git clone https://github.com/muhammad-fiaz/zstd.zig.git
cd zstd.zig
zig build
```

To use a local checkout from another project, add a path dependency to your `build.zig.zon`:

```zig
.dependencies = .{
    .zstd = .{
        .path = "../zstd.zig",
    },
},
```

### Wire into `build.zig`

After adding the dependency, import the module in your `build.zig`:

```zig
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});

const zstd_dep = b.dependency("zstd", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zstd", zstd_dep.module("zstd"));
```

## Quick Start

### One-Liner Compression

```zig
const zstd = @import("zstd");

// Compress - simplest possible usage
const compressed = try zstd.compress(allocator, data);
defer allocator.free(compressed);

// Decompress
const decompressed = try zstd.decompress(allocator, compressed);
defer allocator.free(decompressed);
```

### Client Usage

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // One reusable context, one allocator, many operations.
    var ctx = zstd.Context.init(allocator);
    defer ctx.deinit();

    const compressed = try ctx.compress("Hello, zstd.zig!");
    defer allocator.free(compressed);

    const decompressed = try ctx.decompress(compressed);
    defer allocator.free(decompressed);

    std.debug.print("Decompressed: {s}\n", .{decompressed});
}
```

Separate compression/decompression contexts are also available when only one
direction is needed:

```zig
    var cctx = zstd.CompressionContext.init(allocator);
    defer cctx.deinit();
    var dctx = zstd.DecompressionContext.init(allocator);
    defer dctx.deinit();

    // Compress with context
    const compressed = try cctx.compressAlloc("Hello, zstd.zig!");
    defer allocator.free(compressed);

    // Decompress with context
    const decompressed = try dctx.decompressAlloc(compressed);
    defer allocator.free(decompressed);

    std.debug.print("Decompressed: {s}\n", .{decompressed});
}
```

### Simplified API Aliases

Every method is available as a top-level function for convenience.

```zig
// Compression
const compressed = try zstd.compress(allocator, data);
const withLevel = try zstd.compressWithLevel(allocator, data, 3);
const withOpts = try zstd.compressWithOptions(allocator, data, .{ .level = 9, .checksum = true });
const bound = zstd.compressBound(data.len);

// Decompression
const decompressed = try zstd.decompress(allocator, compressed);

// Frame detection
const is_valid = zstd.isFrame(data);
const content = zstd.getFrameContentSize(data);
const size = try zstd.findFrameCompressedSize(allocator, data);
const header = try zstd.getFrameHeader(data);

// Skippable frame
const is_skip = zstd.isSkippableFrame(data);
const n = zstd.writeSkippableFrame(&buf, "meta", 1);

// Version
const ver = zstd.versionNumber();
const str = zstd.versionString();
const min = zstd.minCLevel();
const max = zstd.maxCLevel();
const def = zstd.defaultCLevel();
```

### Streaming

Both streaming types keep real cross-call state: the frame header is written once, entropy tables and repeat offsets are threaded from block to block, the checksum covers input as it arrives, and the decoder keeps a sliding window of history rather than the whole frame. Nothing waits for the end of the stream except the tail a `.flush` or `.end` emits as a partial block.

`compressStream(out, in, directive)` accepts every input byte, emits as much as `out` holds, and reports what is still buffered in `remaining`:

```zig
var cstream = try zstd.StreamingCompressor.init(allocator, 3);
defer cstream.deinit();
var out: [1 << 17]u8 = undefined;           // room for a block or two
var frame: std.ArrayList(u8) = .empty;
defer frame.deinit(allocator);

var produced: usize = 0;
for (chunks) |chunk| {                      // `.cont` never stalls: a partial block waits
    const r = try cstream.compressStream(&out, chunk, .cont);
    try frame.appendSlice(allocator, out[0..r.outProduced]);
}
while (true) {                              // `.end` repeats until the frame is closed
    const r = try cstream.compressStream(&out, "", .end);
    try frame.appendSlice(allocator, out[0..r.outProduced]);
    if (r.remaining == 0) break;
}
```

A `.flush` or `.end` call needs output room for at least one block (a block is at most 128 KiB). Given less, it either makes the progress it can - leaving `remaining` non-zero - or, if it cannot emit anything at all, returns `error.DstSizeTooSmall`. `decompressStream` never needs a large output: a block is decoded into an internal buffer and handed over in whatever pieces the output allows, so `out` may be a single byte.

```zig
var dstream = zstd.StreamingDecompressor.init(allocator);
defer dstream.deinit();
var window: [1024]u8 = undefined;
var decoded: std.ArrayList(u8) = .empty;
defer decoded.deinit(allocator);

var in_pos: usize = 0;
while (true) {
    const chunk = if (in_pos < frame.items.len) frame.items[in_pos..] else frame.items[0..0];
    const r = try dstream.decompressStream(&window, chunk);
    in_pos += r.inConsumed;
    try decoded.appendSlice(allocator, window[0..r.outProduced]);
    if (r.outProduced == 0 and in_pos >= frame.items.len) break;
}
```

### Frame Inspection

```zig
if (zstd.isFrame(data)) {
    const hdr = try zstd.getFrameHeader(data);
    std.debug.print("Content size: {d}\n", .{hdr.contentSize});
    std.debug.print("Window size: {d}\n", .{hdr.windowSize});
    std.debug.print("Checksum: {}\n", .{hdr.checksumFlag});
    std.debug.print("Dict ID: {d}\n", .{hdr.dictId});
}
```

### Dictionary Compression

A dictionary is content that logically precedes the data. The encoder may match back into it, so a payload that shares its phrasing with the dictionary costs far fewer bytes; the frame records the dictionary's ID, and a decoder given a different one is rejected instead of being fed the wrong bytes.

```zig
// Train a dictionary from a corpus. `train` keeps representative segments,
// `trainCover` and `trainFastCover` rank them by how often they recur.
var builder = zstd.DictionaryBuilder.init(allocator, .{ .dictSize = 8192, .dictId = 0xC0FFEE });
var dict = try builder.train(samples);          // or .trainCover(samples, 6, 32)
defer dict.deinit();

// Compress with it. The frame header declares the dictionary ID.
const frame = try zstd.compressWithOptions(allocator, payload, .{
    .level = 9,
    .dictionary = &dict,
});
defer allocator.free(frame);

// Decoding needs the same dictionary.
const restored = try zstd.decompressWithOptions(allocator, frame, .{ .dictionary = &dict });
defer allocator.free(restored);

// A frame that names a different dictionary is rejected, not mis-decoded.
try zstd.decompress(allocator, frame);          // error.DictionaryWrong

// A reusable context borrows the dictionary too, for as long as it holds it.
var dctx = zstd.Decompressor.init(allocator);
defer dctx.deinit();
dctx.setDictionary(&dict);

// An existing dictionary, from bytes on disk.
var loaded = try zstd.loadDictionary(allocator, dict_bytes);
defer loaded.deinit();
```

The dictionary's entropy tables are not required: a frame is free to write its own, and this encoder always does, so any implementation that has the same dictionary *content* decodes the frame. Frames produced this way are verified against the reference decoder with `zstd -d -D`.

## API Reference

### Top-Level Functions

| Function | Description |
|---|---|
| `zstd.compress(alloc, src)` | One-shot compression with default level |
| `zstd.decompress(alloc, src)` | One-shot decompression |
| `zstd.compressWithLevel(alloc, src, level)` | Compress with numeric level 1-22 |
| `zstd.compressWithOptions(alloc, src, opts)` | Compress with `CompressionOptions` |
| `zstd.compressInto(alloc, dst, src, level)` | Compress into preallocated buffer |
| `zstd.decompressInto(alloc, dst, src)` | Decompress into preallocated buffer |
| `zstd.compressBound(srcSize)` | Maximum compressed size for buffer allocation |
| `zstd.decompressBound(alloc, src)` | Estimated decompressed size |
| `zstd.findFrameCompressedSize(alloc, src)` | Exact compressed frame size |
| `zstd.getFrameContentSize(src)` | Content size from header or `CONTENTSIZE_UNKNOWN/ERROR` |
| `zstd.decompressWithDict(alloc, dst, src, dict)` | Decompress with dictionary content as prefix history |
| `zstd.getFrameHeader(src)` | Parse `FrameHeader` with window, dict, checksum metadata |
| `zstd.isFrame(src)` | Check if data is a zstd frame |
| `zstd.isSkippableFrame(src)` | Check if data is a skippable frame |
| `zstd.writeSkippableFrame(dst, data, variant)` | Write skippable frame |
| `zstd.readSkippableFrame(dst, src)` | Read skippable frame payload |
| `zstd.loadDictionary(alloc, data)` | Load dictionary from bytes |
| `zstd.createDictionaryFromData(alloc, data, id)` | Create dictionary with ID |
| `zstd.getCompressionParameters(level, srcSize, windowLog)` | Get `CompressionOptions` for level |

### Types

| Type | Description |
|---|---|
| `Context` | Unified reusable context with `init(alloc)`, `initWithLevel(alloc, level)`, `compress(src)`, `decompress(src)`, `setLevel()`, `setChecksum()`, `reset()`, `deinit()` - one allocator for everything |
| `CompressionContext` | Reusable compression context with `init(alloc)`, `initWithLevel(alloc, level)`, `compressAlloc(src)`, `compress(dst,src)`, `setLevel()`, `setChecksum()`, `setWindowLog()`, `deinit()` |
| `DecompressionContext` | Reusable decompression context with `init(alloc)`, `decompressAlloc(src)`, `decompress(dst,src)`, `setMaxWindowSize()`, `deinit()` |
| `StreamingCompressor` | Streaming compression with `init(alloc, level)`, `initWithOptions(alloc, opts)`, `compressStream(out,in,EndDirective)`, `reset()`, `deinit()` |
| `StreamingDecompressor` | Streaming decompression with `init(alloc)`, `decompressStream(out,in)`, `setMaxWindowSize(size)`, `reset()`, `deinit()` |
| `Dictionary` | Loaded dictionary with `dictId()`, `content()`, `deinit()` |
| `DictionaryBuilder` | Builder with `init(alloc, params)`, `train(samples)`, `trainCover(k,d)`, `trainFastCover(k,d,f,accel)` |
| `CompressionOptions` | Options struct with level, windowLog, hashLog, chainLog, searchLog, minMatch, targetLength, strategy, checksum, dictId, contentSize |
| `DecompressionOptions` | Options with `maxWindowSize`, `forceIgnoreChecksum` |
| `Strategy` | Enum `fast, dfast, greedy, lazy, lazy2, btlazy2, btopt, btultra, btultra2` |
| `FrameHeader` | Frame metadata `frameType, headerSize, windowSize, blockSizeMax, dictId, checksumFlag, contentSize` |
| `ZstdError` | Error set with `Corruption`, `ChecksumWrong`, `PrefixUnknown`, etc. |

### Namespaces

| Namespace | Description |
|---|---|
| `zstd.legacy` | Historic frames: `isLegacy()`, `findFrameSize()`, `decompressLegacy()` for v01 - v07 |
| `zstd.legacyDetect` | Historic frame identification: `legacyVersion()`, `isLegacy()`, `supportsDecode()` |
| `zstd.version` / `versionString()` / `versionNumber()` | This library's version, as a comptime string, a function, and a packed number |
| Constants | Top-level aliases, not a namespace: `MAGICNUMBER`, `MAGIC_DICTIONARY`, `MAGIC_SKIPPABLE_START`, `MAGIC_SKIPPABLE_MASK`, `BLOCKSIZE_MAX`, `MAX_INPUT_SIZE`, `CONTENTSIZE_UNKNOWN`, `CONTENTSIZE_ERROR`, `CLEVEL_DEFAULT` |

## Examples

The `examples/` directory contains runnable examples demonstrating all features:

| Example | File | Description |
|---------|------|-------------|
| `basic_compression` | `examples/basic_compression.zig` | Basic compress/decompress round trip |
| `custom_level` | `examples/custom_level.zig` | Numeric compression levels 1-22 |
| `advanced_params` | `examples/advanced_params.zig` | Custom window, checksum, and strategy via `CompressionOptions` |
| `custom_strategy` | `examples/custom_strategy.zig` | All nine match-finding strategies compared |
| `compression_bound` | `examples/compression_bound.zig` | Sizing an output buffer with `compressBound` |
| `window_limit` | `examples/window_limit.zig` | Bounding the declared window a decoder accepts |
| `frame_iteration` | `examples/frame_iteration.zig` | Walking frames in a buffer with `FrameIterator` |
| `long_distance_matching` | `examples/long_distance_matching.zig` | Long-distance matching, and when it does not help |
| `parallel_compression` | `examples/parallel_compression.zig` | Application-managed threads, one context per worker |
| `dictionary_compression` | `examples/dictionary_compression.zig` | Train a dictionary, compress against it, decode with it |
| `dictionary_training` | `examples/dictionary_training.zig` | Training via `train`, `trainCover`, `trainFastCover` |
| `prepared_dictionary` | `examples/prepared_dictionary.zig` | Preparing dictionary state once and reusing it |
| `streaming_compression` | `examples/streaming_compression.zig` | Streaming compression with `StreamingCompressor` |
| `streaming_decompression` | `examples/streaming_decompression.zig` | Streaming decompression with `StreamingDecompressor` |
| `custom_allocator` | `examples/custom_allocator.zig` | Custom allocator tracking |
| `error_handling` | `examples/error_handling.zig` | Corruption, truncation, and buffer error cases |
| `legacy_decompression` | `examples/legacy_decompression.zig` | Historic frame detection for v01-v07 and skippable frames |
| `file_compression` | `examples/file_compression.zig` | Real file compression, write to .zst archive, and decompression |

To run any example:

```bash
zig build run-basic_compression
zig build run-streaming_compression
zig build run-custom_level
zig build run-dictionary_training
zig build run-legacy_decompression
zig build run-advanced_params
zig build run-custom_allocator
zig build run-error_handling
```

## Validation Matrix

Validate host functionality and cross-target compatibility with these commands:

```bash
# Host runtime validation
zig build test --summary all
zig build run-all-examples
zig build stress          # concurrency: pool waves, concurrent compressors, a non-thread-safe allocator
zig build fuzz            # seeded fuzz targets: mutations, round trips, legacy frames
zig build bench           # throughput and ratio; -- --quick for a smaller matrix

# Cross-target library compile validation
zig build -Dtarget=aarch64-linux
zig build -Dtarget=x86_64-windows
zig build -Dtarget=aarch64-macos

# Cross-target tests with emulation
zig build test -Dtarget=aarch64-linux --summary all -fqemu
zig build test -Dtarget=x86-windows --summary all
```

### Interoperability Verification

Compatibility is checked in both directions against a reference binary, comparing the regenerated bytes exactly. The harness lives in the test root, in the `interop:` tests, so `zig build test` is the whole procedure:

```bash
zig build test                  # self round trips and both reference directions
```

A generated corpus (constant, low-alphabet, random, textual, mixed-run and repeating payloads, at sizes from 0 to 131073 bytes) is pushed through every level and every strategy, and separately through a reference binary in each direction. Dictionary-compressed frames are checked with the reference's own `-D` flag. Compressed bytes are never compared: the format allows several valid encodings of the same input.

The reference binary is found automatically: `ZSTD_REFERENCE_PATH` if set, otherwise the first `zstd` on `PATH`, otherwise one of the usual install locations. **The differential tests never skip.** A run that cannot find a reference fails and says which variable to set, because a run without the comparison is not the run this README describes. Scratch files live in the system temporary directory, so a run leaves nothing in the project tree. Last run against reference `zstd` v1.5.7: no failures. The counts each run prints are the record of what was covered - the suite asserts them, so a matrix that silently shrinks fails rather than reporting a smaller number.

The in-suite tests additionally decode a set of frames generated by the reference implementation (empty block, RLE first block, zero-sequence literal, invalid offset, truncated Huffman state, extraneous sequence data) and assert both that valid ones decode and that the malformed ones are rejected.

For explicit cross-target test compilation:

```bash
zig build test -Dtarget=x86-windows --summary all
zig build test -Dtarget=aarch64-macos --summary all
```

## Building & Testing

```bash
zig build                    # Build library
zig build test --summary all # Run all tests
zig build run-all-examples   # Run all examples
zig build stress            # Concurrency stress test (STRESS_ROUNDS, STRESS_CLIENTS)
zig build fuzz              # Fuzz targets (FUZZ_ITERS, FUZZ_SEED)
zig build bench             # Benchmarks (zig build bench -- --quick for a smaller matrix)
zig build check              # Compile tests and examples without running
ZSTD_REFERENCE_PATH=<reference binary> zig build test
zig build docs               # Generate documentation site
```

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass: `zig build test --summary all`
5. Ensure formatting passes: `zig fmt --check src/`
6. Submit a pull request

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

## Security

Found a security vulnerability? Please do **not** open a public issue. See [SECURITY.md](SECURITY.md) for responsible disclosure and supported versions.

## License

MIT License - see [LICENSE](LICENSE) for details.

### Acknowledgements

`zstd.zig` is a native Zig implementation of the Zstandard format and codec, built entirely from scratch in Zig.

The [Zstandard project](https://github.com/Facebook/zstd) is used as a reference for the Zstandard format, codec behavior, compatibility, and interoperability verification.

This project does not depend on the upstream implementation.

## Author

**Muhammad Fiaz** (https://github.com/muhammad-fiaz)
