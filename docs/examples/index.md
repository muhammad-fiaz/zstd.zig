---
title: Examples
description: Code examples for zstd.zig compression library.
---

# Examples

Practical examples showing how to use zstd.zig. All 21 examples live in `examples/` with `_` names and are run via `zig build run-<name>`.

## All 21 Examples

| Example Guide | Source File | Description & Focus | Run Command |
|---|---|---|---|
| [Basic Compression](/examples/basic_compression) | [`examples/basic_compression.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/basic_compression.zig) | Basic `compress`/`decompress` round-trip and ratio calculation | `zig build run-basic_compression` |
| [Custom Level](/examples/custom_level) | [`examples/custom_level.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/custom_level.zig) | Numeric compression levels 1-22 via `compressWithLevel` | `zig build run-custom_level` |
| [Advanced Params](/examples/advanced_params) | [`examples/advanced_params.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/advanced_params.zig) | Custom window, checksum, strategy via `CompressionOptions` | `zig build run-advanced_params` |
| [Custom Strategy](/examples/custom_strategy) | [`examples/custom_strategy.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/custom_strategy.zig) | All nine match-finding strategies compared and round-tripped | `zig build run-custom_strategy` |
| [Compression Bound](/examples/compression_bound) | [`examples/compression_bound.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/compression_bound.zig) | Sizing an output buffer with `compressBound` and `compressInto` | `zig build run-compression_bound` |
| [Window Limit](/examples/window_limit) | [`examples/window_limit.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/window_limit.zig) | Bounding the declared window a decoder accepts | `zig build run-window_limit` |
| [Frame Iteration](/examples/frame_iteration) | [`examples/frame_iteration.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/frame_iteration.zig) | Walking frames in a buffer with zero-copy `FrameIterator` | `zig build run-frame_iteration` |
| [Long-Distance Matching](/examples/long_distance_matching) | [`examples/long_distance_matching.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/long_distance_matching.zig) | Long-distance match finding with gear hashing and window bounding | `zig build run-long_distance_matching` |
| [Parallel Compression](/examples/parallel_compression) | [`examples/parallel_compression.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/parallel_compression.zig) | Application-managed threads, one context per worker pool | `zig build run-parallel_compression` |
| [Dictionary Compression](/examples/dictionary_compression) | [`examples/dictionary_compression.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/dictionary_compression.zig) | Train a dictionary, compress against it, and decode with it | `zig build run-dictionary_compression` |
| [Dictionary Training](/examples/dictionary_training) | [`examples/dictionary_training.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/dictionary_training.zig) | Training via `DictionaryBuilder.train`, `trainCover`, and `trainFastCover` | `zig build run-dictionary_training` |
| [Prepared Dictionary](/examples/prepared_dictionary) | [`examples/prepared_dictionary.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/prepared_dictionary.zig) | Preparing dictionary state once and reusing it with table caching | `zig build run-prepared_dictionary` |
| [Streaming Compression](/examples/streaming_compression) | [`examples/streaming_compression.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/streaming_compression.zig) | Chunk streaming with `StreamingCompressor` and `EndDirective` | `zig build run-streaming_compression` |
| [Streaming Decompression](/examples/streaming_decompression) | [`examples/streaming_decompression.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/streaming_decompression.zig) | Streaming decompression with `StreamingDecompressor` and `needsMore` | `zig build run-streaming_decompression` |
| [Custom Allocator](/examples/custom_allocator) | [`examples/custom_allocator.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/custom_allocator.zig) | Custom `TrackingAllocator` tracking memory allocations | `zig build run-custom_allocator` |
| [Error Handling](/examples/error_handling) | [`examples/error_handling.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/error_handling.zig) | Corruption, truncation, and buffer error cases handling | `zig build run-error_handling` |
| [Legacy Decompression](/examples/legacy_decompression) | [`examples/legacy_decompression.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/legacy_decompression.zig) | Historic frame detection and native v0.1-v0.7 frame decode | `zig build run-legacy_decompression` |
| [File Compression](/examples/file_compression) | [`examples/file_compression.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/file_compression.zig) | Real file compression, write to .zst archive, and decompression | `zig build run-file_compression` |
| [Explicit IO Streaming](/examples/explicit_io_streaming) | [`examples/explicit_io_streaming.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/explicit_io_streaming.zig) | Chunked streaming file compression, decompression, and Encoder/Decoder contexts | `zig build run-explicit_io_streaming` |
| [Explicit IO Pipeline](/examples/explicit_io_pipeline) | [`examples/explicit_io_pipeline.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/explicit_io_pipeline.zig) | One-shot / short explicit std.Io Reader & Writer pipeline streaming | `zig build run-explicit_io_pipeline` |
| [Large File Compression](/examples/large_file_compression) | [`examples/large_file_compression.zig`](https://github.com/muhammad-fiaz/zstd.zig/blob/main/examples/large_file_compression.zig) | Multi-megabyte (4 MiB) compression, ratio inspection, and disk preservation | `zig build run-large_file_compression` |

Every guide above provides full copy-paste runnable Zig code, captured console output, and in-depth explanation.

Run all at once:

```bash
zig build run-all-examples
```

## Validate

```bash
zig build test --summary all
zig build run-all-examples
zig build check
zig build -Dtarget=aarch64-linux
zig build -Dtarget=x86_64-windows
zig build -Dtarget=aarch64-macos
zig build -Dtarget=x86-windows
```
