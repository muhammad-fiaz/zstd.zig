---
title: Examples
description: Code examples for zstd.zig compression library.
---

# Examples

Practical examples showing how to use zstd.zig. All 12 examples live in `examples/` with `_` names and are run via `zig build run-<name>`.

## All 12 Examples

| Example | File | Description | Run Command |
|---------|------|-------------|-------------|
| `basic_compression` | `examples/basic_compression.zig` | Basic compress/decompress round trip | `zig build run-basic_compression` |
| `basic_decompression` | `examples/basic_decompression.zig` | Decompression with verification | `zig build run-basic_decompression` |
| `custom_level` | `examples/custom_level.zig` | Numeric compression levels 1-22 via `compressWithLevel` | `zig build run-custom_level` |
| `advanced_params` | `examples/advanced_params.zig` | Custom window, checksum, strategy via `CompressionOptions` | `zig build run-advanced_params` |
| `dictionary_compression` | `examples/dictionary_compression.zig` | Dictionary creation (`createDictionaryFromData`) and header `dict_id` handling | `zig build run-dictionary_compression` |
| `dictionary_training` | `examples/dictionary_training.zig` | Training via `DictionaryBuilder.train`, `trainCover`, `trainFastCover` | `zig build run-dictionary_training` |
| `streaming_compression` | `examples/streaming_compression.zig` | Streaming compression with `StreamingCompressor` + `EndDirective` | `zig build run-streaming_compression` |
| `streaming_decompression` | `examples/streaming_decompression.zig` | Streaming decompression with `StreamingDecompressor` | `zig build run-streaming_decompression` |
| `custom_allocator` | `examples/custom_allocator.zig` | Custom `TrackingAllocator` tracking | `zig build run-custom_allocator` |
| `error_handling` | `examples/error_handling.zig` | Corruption, truncation, and buffer error cases | `zig build run-error_handling` |
| `legacy_decompression` | `examples/legacy_decompression.zig` | Legacy frame detection for v01-v07 (`zstd.legacy`) and skippable frames | `zig build run-legacy_decompression` |
| `file_compression` | `examples/file_compression.zig` | Real file compression, write to .zst archive, and decompression | `zig build run-file_compression` |

Run all at once:

```bash
zig build run-all-examples
```

## Per-Example Client-Side Guides (code + output + explanation)

| Guide | Example File | Client-Side Focus |
|---------|--------------|-------------------|
| [Basic Compression](/examples/basic_compression) | `basic_compression.zig` | `compress`/`decompress` round-trip, ratio, `std.debug.print` |
| [Basic Decompression](/examples/basic_decompression) | `basic_decompression.zig` | `decompress` verification, `std.mem.eql` |
| [Custom Level](/examples/custom_level) | `custom_level.zig` | `compressWithLevel` 1-22, `minCLevel`/`maxCLevel` |
| [Advanced Params](/examples/advanced_params) | `advanced_params.zig` | `getCompressionParameters`, `checksum`, `window_log`, `strategy` |
| [Dictionary Compression](/examples/dictionary_compression) | `dictionary_compression.zig` | `createDictionaryFromData`, `dictId`, `CompressionOptions.dict_id` |
| [Dictionary Training](/examples/dictionary_training) | `dictionary_training.zig` | `DictionaryBuilder.train`/`trainCover`/`trainFastCover` |
| [Streaming Compression](/examples/streaming_compression) | `streaming_compression.zig` | `StreamingCompressor`, `EndDirective`, `remaining` |
| [Streaming Decompression](/examples/streaming_decompression) | `streaming_decompression.zig` | `StreamingDecompressor`, `needs_more`, chunked `64B` |
| [Custom Allocator](/examples/custom_allocator) | `custom_allocator.zig` | `TrackingAllocator`, `allocated`/`allocs`/`frees` |
| [Error Handling](/examples/error_handling) | `error_handling.zig` | `PrefixUnknown`, `SrcSizeWrong`, `DstSizeTooSmall` |
| [Legacy Decompression](/examples/legacy_decompression) | `legacy_decompression.zig` | `legacy.isLegacy`, `legacyVersion`, `isFrame`, skippable |
| [File Compression](/examples/file_compression) | `file_compression.zig` | `std.Io.Dir` file → `.zst` → restore, `writeFile`/`openFile`/`stat` |

## Validate

```bash
zig build test --summary all
zig build run-all-examples
zig build -Dtarget=aarch64-linux
zig build -Dtarget=x86_64-windows
zig build -Dtarget=aarch64-macos
zig build test -Dtarget=aarch64-linux --summary all -fqemu
```
