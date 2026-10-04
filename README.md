<div align="center">

# zstd.zig

<a href="https://muhammad-fiaz.github.io/zstd.zig/"><img src="https://img.shields.io/badge/docs-muhammad--fiaz.github.io-blue" alt="Documentation"></a>
<a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.17.0-orange.svg?logo=zig" alt="Zig Version"></a>
<a href="https://github.com/muhammad-fiaz/zstd.zig"><img src="https://img.shields.io/github/stars/muhammad-fiaz/zstd.zig" alt="GitHub stars"></a>
<a href="https://github.com/muhammad-fiaz/zstd.zig/issues"><img src="https://img.shields.io/github/issues/muhammad-fiaz/zstd.zig" alt="GitHub issues"></a>
<a href="https://github.com/muhammad-fiaz/zstd.zig/pulls"><img src="https://img.shields.io/github/issues-pr/muhammad-fiaz/zstd.zig" alt="GitHub pull requests"></a>
<a href="https://github.com/muhammad-fiaz/zstd.zig"><img src="https://img.shields.io/github/last-commit/muhammad-fiaz/zstd.zig" alt="GitHub last commit"></a>
<a href="https://github.com/muhammad-fiaz/zstd.zig/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License"></a>
<img src="https://img.shields.io/badge/platforms-linux%20%7C%20windows%20%7C%20macos-blue" alt="Supported Platforms">
<a href="https://github.com/muhammad-fiaz/zstd.zig/releases/latest"><img src="https://img.shields.io/github/v/release/muhammad-fiaz/zstd.zig?label=Latest%20Release&style=flat-square" alt="Latest Release"></a>
<a href="https://pay.muhammadfiaz.com"><img src="https://img.shields.io/badge/Sponsor-pay.muhammadfiaz.com-ff69b4?style=flat&logo=heart" alt="Sponsor"></a>
<a href="https://github.com/sponsors/muhammad-fiaz"><img src="https://img.shields.io/badge/Sponsor-GitHub-pink?style=social&logo=github" alt="GitHub Sponsors"></a>

<p><em>Fast, native Zstandard compression for Zig.</em></p>

<b><a href="https://muhammad-fiaz.github.io/zstd.zig/">Documentation</a> |
<a href="https://muhammad-fiaz.github.io/zstd.zig/api/">API Reference</a> |
<a href="https://muhammad-fiaz.github.io/zstd.zig/guide/getting-started">Quick Start</a> |
<a href="CONTRIBUTING.md">Contributing</a></b>

</div>

`zstd.zig` is a complete, native Zig implementation of the [Zstandard](https://facebook.github.io/zstd/) compressed-data format (RFC 8878) targeting **Zig 0.17.0**, built entirely from scratch in pure Zig. No C bindings, no libc, and no external dependencies.

> [!TIP]
> If you build with zstd.zig, make sure to give it a star!

> [!NOTE]
> `zstd.zig` implements the RFC 8878 format specification. The upstream [Zstandard project](https://github.com/facebook/zstd) is used as a reference for format behavior, compatibility requirements, and interoperability testing.
>
> - **Streaming state machine** with sliding window history and fine-grained flushing directives (`.cont`, `.flush`, `.end`).
> - **Finite State Entropy (FSE) & Huffman coding** - canonical tables, normalized frequency distributions, multi-stream decoding, and repeat table persistence.
> - **All 9 match-finding strategies** - `fast`, `dfast`, `greedy`, `lazy`, `lazy2`, `btlazy2`, `btopt`, `btultra`, and `btultra2`.
> - **Long-distance matching (LDM)** - gear hash split-point finder with bucketed match candidate tables.
> - **LZ77 match finder** with 3-offset history registers and zero-literal repetitions.
> - **Static and trained dictionaries** - load, create, train (`trainCover`, `trainFastCover`), and prepare dictionaries for state reuse.
> - **Client-side concurrency** - thread-safe isolated contexts, zero implicit background threads, and worker pool integration.
> - **Historic frame decoding** - complete support for legacy frames (v0.1 to v0.5) and skippable frames.
> - **Reusable contexts** - initialize once, compress/decompress multiple streams via `reset()`, eliminating allocation churn.

---

<details>
<summary><strong>Features</strong> (click to expand)</summary>

| Feature | Description |
|---|---|
| **One-shot Compression** | `zstd.compress(allocator, data)` for single-call compression |
| **One-shot Decompression** | `zstd.decompress(allocator, data)` for single-call decompression |
| **Compression Levels** | Numeric levels 1-22 via `compressWithLevel()` and `compressWithOptions()` |
| **Reusable Compressor** | `zstd.Compressor` (`init`, `compress`, `reset`, `deinit`) |
| **Reusable Decompressor** | `zstd.Decompressor` (`init`, `decompress`, `reset`, `deinit`) |
| **Streaming Compressor** | `StreamingCompressor` with `compressStream()` and `EndDirective` |
| **Streaming Decompressor** | `StreamingDecompressor` with `decompressStream()` supporting 1-byte output buffers |
| **Dictionary Compression** | Custom dictionary support via `dictionary` options on compressor and decompressor |
| **Dictionary Training** | Built-in dictionary training with `DictionaryBuilder.train()`, `trainCover()`, `trainFastCover()` |
| **Prepared Dictionaries** | Pre-parsed dictionary tables with `prepareDictionary()` for repeated low-latency compression |
| **All 9 Strategies** | Complete implementation of all match strategies from `fast` to `btultra2` |
| **Long-Distance Matching** | Gear hash LDM match finder for finding matches across large windows |
| **Frame Inspection** | `isFrame()`, `getFrameHeader()`, `getFrameContentSize()`, `findFrameCompressedSize()` |
| **Legacy Format Support** | Full decoding of v0.1 to v0.5 frames; clean detection and refusal of v0.6 and v0.7 |
| **Skippable Frames** | RFC 8878 skippable frame generation, detection, and skipping |
| **Checksum Verification** | xxHash-64 content checksum verification |
| **Window Size Limits** | Configurable `maxWindowSize` for decompression protection |
| **Zero Dependencies** | Pure native Zig targeting Zig 0.17.0 |

</details>

---

<details>
<summary><strong>Prerequisites and Supported Platforms</strong> (click to expand)</summary>

<br>

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| **Zig** | **0.17.0** (required) | Download from [ziglang.org](https://ziglang.org/download/). Zig 0.16.0 is not supported in v0.0.4+; use v0.0.3 for Zig 0.16.x. |
| **Operating System** | Windows 10+, Linux, macOS | Cross-platform support |

---

## Supported Platforms

`zstd.zig` targets these architectures:

| Platform | x86_64 (64-bit) | aarch64 (ARM64) | x86 (32-bit) |
|---|---|---|---|
| **Linux** | Yes | Yes | Yes |
| **Windows** | Yes | Yes | Yes |
| **macOS** | Yes | Yes (Apple Silicon) | Yes |

### Cross-Compilation

Zig makes cross-compilation easy:

```bash
# Build for Linux ARM64
zig build -Dtarget=aarch64-linux

# Build for Windows x86_64
zig build -Dtarget=x86_64-windows

# Build for macOS Apple Silicon
zig build -Dtarget=aarch64-macos

# Build for 32-bit Windows
zig build -Dtarget=x86-windows
```

</details>

---

## Installation

### Method 1: Zig Fetch (Recommended) - Latest Release (Zig 0.17.0)

```bash
zig fetch --save https://github.com/muhammad-fiaz/zstd.zig/archive/refs/tags/v0.0.4.tar.gz
```

> [!NOTE]
> `zstd.zig` v0.0.4+ exclusively targets **Zig 0.17.0** (using new `std.Io` APIs and language builtins). **Zig 0.16.0 is not supported** in this release. If your project is on Zig 0.16.0, use the previous stable release `v0.0.3`:
>
> ```bash
> zig fetch --save https://github.com/muhammad-fiaz/zstd.zig/archive/refs/tags/v0.0.3.tar.gz
> ```

### Method 2: Zig Fetch (Main Branch)

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/zstd.zig.git
```

### Wire into `build.zig`

```zig
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});

const zstd_dep = b.dependency("zstd", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zstd", zstd_dep.module("zstd"));
```

---

## Quick Start

### One-Shot Compression & Decompression

```zig
const zstd = @import("zstd");

// Compress
const compressed = try zstd.compress(allocator, data);
defer allocator.free(compressed);

// Decompress
const decompressed = try zstd.decompress(allocator, compressed);
defer allocator.free(decompressed);
```

### Advanced Options

```zig
const compressed = try zstd.compressWithOptions(allocator, data, .{
    .level = 9,
    .strategy = .btlazy2,
    .checksum = true,
    .windowLog = 20,
});
defer allocator.free(compressed);

const decompressed = try zstd.decompressWithOptions(allocator, compressed, .{
    .maxWindowSize = 10 * 1024 * 1024,
});
defer allocator.free(decompressed);
```

### Reusable Contexts (Zero Allocation Churn)

Initialize the context once with your allocator, reuse across multiple streams via `reset()`, and deinitialize when done:

```zig
var compressor = zstd.Compressor.initWithLevel(allocator, 6);
defer compressor.deinit();

var decompressor = zstd.Decompressor.init(allocator);
defer decompressor.deinit();

// First stream
const comp1 = try compressor.compressAlloc(input1);
defer allocator.free(comp1);
const out1 = try decompressor.decompressAlloc(comp1);
defer allocator.free(out1);

// Second stream
const comp2 = try compressor.compressAlloc(input2);
defer allocator.free(comp2);
const out2 = try decompressor.decompressAlloc(comp2);
defer allocator.free(out2);
```

### Streaming Compression & Decompression

```zig
// Incremental streaming compression
var sc = try zstd.StreamingCompressor.init(allocator, 3);
defer sc.deinit();

var out_buf: [131072]u8 = undefined;
const r1 = try sc.compressStream(&out_buf, chunk1, .cont);
// write out_buf[0..r1.outProduced]

const r2 = try sc.compressStream(&out_buf, chunk2, .end);
// write out_buf[0..r2.outProduced]

// Incremental streaming decompression
var sd = zstd.StreamingDecompressor.init(allocator);
defer sd.deinit();

var decomp_buf: [4096]u8 = undefined;
const r3 = try sd.decompressStream(&decomp_buf, compressed_chunk);
// process decomp_buf[0..r3.outProduced]
```

### Custom & Trained Dictionaries

```zig
// Train a dictionary from sample records
var builder = zstd.DictionaryBuilder.init(allocator, .{ .dictSize = 8192, .dictId = 0xC0FFEE });
var dict = try builder.train(samples);
defer dict.deinit();

// Compress with dictionary
const comp = try zstd.compressWithOptions(allocator, payload, .{
    .level = 9,
    .dictionary = &dict,
});
defer allocator.free(comp);

// Decompress with dictionary
const restored = try zstd.decompressWithOptions(allocator, comp, .{ .dictionary = &dict });
defer allocator.free(restored);
```

### Frame Inspection

```zig
if (zstd.isFrame(data)) {
    const hdr = try zstd.getFrameHeader(data);
    std.debug.print("Content size: {d}\n", .{hdr.contentSize});
    std.debug.print("Window size:  {d}\n", .{hdr.windowSize});
    std.debug.print("Checksum:     {}\n", .{hdr.checksumFlag});
    std.debug.print("Dict ID:      {d}\n", .{hdr.dictId});
}
```

---

## Examples

The `examples/` directory contains complete, runnable examples:

| Example | File | Description |
|---|---|---|
| `basic_compression` | `examples/basic_compression.zig` | Basic compress/decompress round trip |
| `custom_level` | `examples/custom_level.zig` | Numeric compression levels 1-22 via `compressWithLevel` |
| `advanced_params` | `examples/advanced_params.zig` | Custom window, checksum, and strategy via `CompressionOptions` |
| `custom_strategy` | `examples/custom_strategy.zig` | All nine match-finding strategies compared |
| `compression_bound` | `examples/compression_bound.zig` | Sizing an output buffer with `compressBound` |
| `window_limit` | `examples/window_limit.zig` | Bounding the declared window a decoder accepts |
| `frame_iteration` | `examples/frame_iteration.zig` | Walking frames in a buffer with `FrameIterator` |
| `long_distance_matching` | `examples/long_distance_matching.zig` | Long-distance matching evaluation |
| `parallel_compression` | `examples/parallel_compression.zig` | Application-managed threads, one context per worker |
| `dictionary_compression` | `examples/dictionary_compression.zig` | Train a dictionary, compress against it, decode with it |
| `dictionary_training` | `examples/dictionary_training.zig` | Training via `train`, `trainCover`, `trainFastCover` |
| `prepared_dictionary` | `examples/prepared_dictionary.zig` | Preparing dictionary state once and reusing it |
| `streaming_compression` | `examples/streaming_compression.zig` | Streaming compression with `StreamingCompressor` |
| `streaming_decompression` | `examples/streaming_decompression.zig` | Streaming decompression with `StreamingDecompressor` |
| `custom_allocator` | `examples/custom_allocator.zig` | Custom memory tracking allocator |
| `error_handling` | `examples/error_handling.zig` | Corruption, truncation, and buffer error cases |
| `legacy_decompression` | `examples/legacy_decompression.zig` | Historic frame detection for v01-v07 and skippable frames |
| `file_compression` | `examples/file_compression.zig` | Real file compression, write to .zst archive, and decompression |
| `explicit_io_streaming` | `examples/explicit_io_streaming.zig` | Chunked streaming file compression, decompression, and Encoder/Decoder contexts |
| `large_file_compression` | `examples/large_file_compression.zig` | Multi-megabyte (4 MiB) compression, ratio inspection, and disk preservation |

Run any example:

```bash
zig build run-basic_compression
zig build run-streaming_compression
zig build run-explicit_io_streaming
zig build run-large_file_compression
zig build run-all-examples   # Run all 20 examples
```

---

## Building & Testing

```bash
zig build                    # Build native Zstandard library
zig build test               # Run all unit and interoperability tests
zig build test --summary all # Detailed test execution summary
zig build run-all-examples   # Run all 20 example executables
zig build check              # Compile tests and examples without running
zig build docs               # Generate documentation in zig-out/docs/
```

---

## Contributing

Contributions are welcome! Please ensure all tests pass:

```bash
zig fmt .
zig build test --summary all
zig build run-all-examples
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

## Security

For vulnerability reporting and security guarantees, please see [SECURITY.md](SECURITY.md).

## Acknowledgements

`zstd.zig` is a native Zig implementation of the Zstandard format and codec, built entirely from scratch in Zig.

The [Zstandard project](https://github.com/facebook/zstd) is used as a reference for the Zstandard format, codec behavior, compatibility, and interoperability verification.

This project does not depend on the upstream implementation.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Author

**Muhammad Fiaz** (https://github.com/muhammad-fiaz)
