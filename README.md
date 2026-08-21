<div align="center">

<a href="https://muhammad-fiaz.github.io/zstd.zig/"><img src="https://img.shields.io/badge/docs-muhammad--fiaz.github.io-blue" alt="Documentation"></a>
<a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.16.0-orange.svg?logo=zig" alt="Zig Version"></a>
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

`zstd.zig` is a complete native Zig implementation of Facebook's [Zstandard](https://github.com/facebook/zstd) fast compression library. No C bindings, no external dependencies. Every byte is Zig.

> [!TIP]
> If you build with zstd.zig, make sure to give it a star.

> [!NOTE]
> This implementation is based on **Zstandard 1.6.0** as reference, providing complete native Zig support for the latest Zstandard specifications as well as transparent backwards-compatibility for legacy frame versions (**v01 through v07**).
>
> **Pure Zig — zero C dependencies:** Unlike binding-based approaches, `zstd.zig` implements the Zstandard format directly in Zig, including:
> - **Frame format** with magic number validation, content size detection, and checksum verification
> - **Block structure** with raw, RLE, and compressed block types
> - **Huffman coding** for literal compression and decompression
> - **FSE (Finite State Entropy)** table construction and decoding for sequence compression
> - **LZ77** back-reference matching for sliding window compression
> - **Dictionary support** with Dictionary and DictionaryBuilder for trained dictionaries
> - **Streaming API** with StreamingCompressor/StreamingDecompressor for chunked data processing
> - **Parameter API** for fine-tuning compression level, window size, hash tables, and strategies
> - **Frame inspection** for metadata extraction without full decompression
> - **Legacy frames** transparent detection and decompression for legacy formats (v01, v02, v03, v04, v05, v06, v07)

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
| **Streaming Compression** | `StreamingCompressor` for chunked data with `compressStream()` and `EndDirective` |
| **Streaming Decompression** | `StreamingDecompressor` for chunked data with `decompressStream()` |
| **Dictionary Compression** | `Dictionary` and `DictionaryBuilder` for trained dictionaries |
| **Dictionary Training** | `DictionaryBuilder.train()`, `trainCover()`, `trainFastCover()` for creating custom dictionaries |
| **Frame Inspection** | `isFrame()`, `getFrameHeader()`, `getFrameContentSize()`, `findFrameCompressedSize()` for metadata extraction |
| **Parameter API** | `CompressionOptions` and `Strategy` for window_log, hash_log, chain_log, search_log, target_length |
| **Checksum Support** | Optional XXH64 checksum in frame headers for data integrity verification |
| **Content Size Validation** | Validates content size on decompression against expected size |
| **Window Size Limits** | Configurable `max_window_size` for decompression safety |
| **Multi-frame Decompression** | Decompress multiple concatenated zstd frames in sequence |
| **Skippable Frame Support** | Skip non-data frames during decompression via `isSkippableFrame()` |
| **Cross-platform** | Linux, Windows, macOS with x86_64, aarch64, x86 support |
| **Zero Dependencies** | Pure Zig implementation — no C libraries, no system dependencies |
| **Strategy Selection** | Fast, DFast, Greedy, Lazy, Lazy2, BTLazy2, BTOpt, BTUltra strategies |
| **Compression Bound** | `compressBound()` for pre-allocating output buffers |
| **Legacy Support** | Transparent handling of legacy frame versions v01-v07 |

</details>

---

<details>
<summary><strong>Prerequisites and Supported Platforms</strong> (click to expand)</summary>

<br>

## Prerequisites

Before using `zstd.zig`, ensure you have the following:

| Requirement | Version | Notes |
|-------------|---------|-------|
| **Zig** | **0.16.0** (required) | Download from [ziglang.org](https://ziglang.org/download/) |
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

**Latest Release (v0.0.2)**

```bash
zig fetch --save https://github.com/muhammad-fiaz/zstd.zig/archive/refs/tags/0.0.2.tar.gz
```

### Method 2: Zig Fetch (Main Branch)

Use the latest development version from the `dev` branch.

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/zstd.zig.git#dev
```

### Method 3: Manual `build.zig.zon` Configuration

Add the dependency to your `build.zig.zon` file.

```zig
.dependencies = .{
    .zstd = .{
        .url = "https://github.com/muhammad-fiaz/zstd.zig/archive/refs/tags/0.0.2.tar.gz",
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

// Compress — simplest possible usage
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

    // Create reusable contexts
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
const size = try zstd.findFrameCompressedSize(data);
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

```zig
var cstream = try zstd.StreamingCompressor.init(allocator, 3);
defer cstream.deinit();
var out: [4096]u8 = undefined;
const r1 = try cstream.compressStream(&out, chunk1, .cont);
const r2 = try cstream.compressStream(&out[r1.out_produced..], chunk2, .flush);
const final = try cstream.compressStream(&out[r1.out_produced + r2.out_produced ..], &[_]u8{}, .end);

var dstream = zstd.StreamingDecompressor.init(allocator);
defer dstream.deinit();
var decoded: [4096]u8 = undefined;
const res = try dstream.decompressStream(&decoded, compressed);
```

### Frame Inspection

```zig
if (zstd.isFrame(data)) {
    const hdr = try zstd.getFrameHeader(data);
    std.debug.print("Content size: {d}\n", .{hdr.content_size});
    std.debug.print("Window size: {d}\n", .{hdr.window_size});
    std.debug.print("Checksum: {}\n", .{hdr.checksum_flag});
    std.debug.print("Dict ID: {d}\n", .{hdr.dict_id});
}
```

### Dictionary Compression

```zig
// Train dictionary from samples
var builder = zstd.DictionaryBuilder.init(allocator, .{ .dict_size = 8192 });
var dict = try builder.train(&[_][]const u8{ sample1, sample2, sample3 });
defer dict.deinit();

// Alternative: cover training
var cdict = try builder.trainCover(samples, 6, 8);
defer cdict.deinit();

// Compress with dictionary ID
const opts = zstd.CompressionOptions{ .dict_id = dict.dictId() };
const compressed = try zstd.compressWithOptions(allocator, data, opts);
defer allocator.free(compressed);

// Load existing dictionary
var loaded = try zstd.loadDictionary(allocator, dict_bytes);
defer loaded.deinit();
```

## API Reference

### Top-Level Functions

| Function | Description |
|---|---|
| `zstd.compress(alloc, src)` | One-shot compression with default level |
| `zstd.decompress(alloc, src)` | One-shot decompression |
| `zstd.compressWithLevel(alloc, src, level)` | Compress with numeric level 1-22 |
| `zstd.compressWithOptions(alloc, src, opts)` | Compress with `CompressionOptions` |
| `zstd.compressInto(dst, src, level)` | Compress into preallocated buffer |
| `zstd.decompressInto(dst, src)` | Decompress into preallocated buffer |
| `zstd.compressBound(src_size)` | Maximum compressed size for buffer allocation |
| `zstd.decompressBound(src)` | Estimated decompressed size |
| `zstd.findFrameCompressedSize(src)` | Exact compressed frame size |
| `zstd.getFrameContentSize(src)` | Content size from header or `CONTENTSIZE_UNKNOWN/ERROR` |
| `zstd.getFrameHeader(src)` | Parse `FrameHeader` with window, dict, checksum metadata |
| `zstd.isFrame(src)` | Check if data is a zstd frame |
| `zstd.isSkippableFrame(src)` | Check if data is a skippable frame |
| `zstd.writeSkippableFrame(dst, data, variant)` | Write skippable frame |
| `zstd.readSkippableFrame(dst, src)` | Read skippable frame payload |
| `zstd.loadDictionary(alloc, data)` | Load dictionary from bytes |
| `zstd.createDictionaryFromData(alloc, data, id)` | Create dictionary with ID |
| `zstd.getCompressionParameters(level, src_size, window_log)` | Get `CompressionOptions` for level |

### Types

| Type | Description |
|---|---|
| `CompressionContext` | Reusable compression context with `init(alloc)`, `initWithLevel(alloc, level)`, `compressAlloc(src)`, `compress(dst,src)`, `setLevel()`, `setChecksum()`, `setWindowLog()`, `deinit()` |
| `DecompressionContext` | Reusable decompression context with `init(alloc)`, `decompressAlloc(src)`, `decompress(dst,src)`, `setMaxWindowSize()`, `deinit()` |
| `StreamingCompressor` | Streaming compression with `init(alloc, level)`, `initWithOptions(alloc, opts)`, `compressStream(out,in,EndDirective)`, `reset()`, `deinit()` |
| `StreamingDecompressor` | Streaming decompression with `init(alloc)`, `decompressStream(out,in)`, `decompressAll(out,in)`, `reset()`, `deinit()` |
| `Dictionary` | Loaded dictionary with `dictId()`, `content()`, `deinit()` |
| `DictionaryBuilder` | Builder with `init(alloc, params)`, `train(samples)`, `trainCover(k,d)`, `trainFastCover(k,d,f,accel)` |
| `CompressionOptions` | Options struct with level, window_log, hash_log, chain_log, search_log, min_match, target_length, strategy, checksum, dict_id, content_size, enable_ldm |
| `DecompressionOptions` | Options with `max_window_size`, `force_ignore_checksum` |
| `Strategy` | Enum `fast, dfast, greedy, lazy, lazy2, btlazy2, btopt, btultra, btultra2` |
| `FrameHeader` | Frame metadata `frame_type, header_size, window_size, block_size_max, dict_id, checksum_flag, content_size` |
| `ZstdError` | Error set with `Corruption`, `ChecksumWrong`, `PrefixUnknown`, etc. |

### Namespaces

| Namespace | Description |
|---|---|
| `zstd.legacy` | Legacy frame support: `isLegacy()`, `legacyVersion()`, `findFrameSize()`, `decompressLegacy()` for v01-v07 |
| `zstd.version` | Version `version` string and `version_number` integer |
| `zstd.constants` | Constants via top-level aliases `MAGICNUMBER`, `MAGIC_DICTIONARY`, `BLOCKSIZE_MAX`, `MAX_INPUT_SIZE`, `CONTENTSIZE_UNKNOWN` |

## Examples

The `examples/` directory contains runnable examples demonstrating all features:

| Example | File | Description |
|---------|------|-------------|
| `basic_compression` | `examples/basic_compression.zig` | Basic compress/decompress round trip |
| `basic_decompression` | `examples/basic_decompression.zig` | Decompression with verification |
| `custom_level` | `examples/custom_level.zig` | Numeric compression levels 1-22 |
| `advanced_params` | `examples/advanced_params.zig` | Custom window, checksum, and strategy via `CompressionOptions` |
| `dictionary_compression` | `examples/dictionary_compression.zig` | Dictionary creation and header handling |
| `dictionary_training` | `examples/dictionary_training.zig` | Training via `train`, `trainCover`, `trainFastCover` |
| `streaming_compression` | `examples/streaming_compression.zig` | Streaming compression with `StreamingCompressor` |
| `streaming_decompression` | `examples/streaming_decompression.zig` | Streaming decompression with `StreamingDecompressor` |
| `custom_allocator` | `examples/custom_allocator.zig` | Custom allocator tracking |
| `error_handling` | `examples/error_handling.zig` | Corruption, truncation, and buffer error cases |
| `legacy_decompression` | `examples/legacy_decompression.zig` | Legacy frame detection for v01-v07 and skippable frames |
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

# Cross-target library compile validation
zig build -Dtarget=aarch64-linux
zig build -Dtarget=x86_64-windows
zig build -Dtarget=aarch64-macos

# Cross-target tests with emulation
zig build test -Dtarget=aarch64-linux --summary all -fqemu
zig build test -Dtarget=x86-windows --summary all
```

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

## License

MIT License - see [LICENSE](LICENSE) for details.

## Author

**Muhammad Fiaz** (https://github.com/muhammad-fiaz)
