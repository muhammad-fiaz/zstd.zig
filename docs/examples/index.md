---
title: Examples
description: Code examples for zstd.zig compression library.
---

# Examples

Practical examples showing how to use zstd.zig. All 11 examples live in `examples/` with `_` names and are run via `zig build run-<name>`.

## All 11 Examples

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

Run all at once:

```bash
zig build run-all-examples
```

## Detailed Guides

| Guide | Description |
|---------|-------------|
| [Basic Compression](/examples/basic) | One-shot compress/decompress, levels, `CompressionContext`, `compressBound` |
| [Streaming](/examples/streaming) | `StreamingCompressor`/`StreamingDecompressor` chunk-based processing |
| [Dictionary](/examples/dictionary) | `Dictionary` / `DictionaryBuilder` APIs |
| [Frame Inspection](/examples/frame) | `isFrame`, `getFrameHeader`, `getFrameContentSize`, `findFrameCompressedSize`, `isSkippableFrame` |

## Validate

```bash
zig build test --summary all
zig build run-all-examples
zig build -Dtarget=aarch64-linux
zig build -Dtarget=x86_64-windows
zig build -Dtarget=aarch64-macos
zig build test -Dtarget=aarch64-linux --summary all -fqemu
```
