---
title: Examples
description: Code examples for zstd.zig compression library.
---

# Examples

Practical examples showing how to use zstd.zig. All 20 examples live in `examples/` with `_` names and are run via `zig build run-<name>`.

## All 20 Examples

| Example | File | Description | Run Command |
|---------|------|-------------|-------------|
| `basic_compression` | `examples/basic_compression.zig` | Basic compress/decompress round trip | `zig build run-basic_compression` |
| `custom_level` | `examples/custom_level.zig` | Numeric compression levels 1-22 via `compressWithLevel` | `zig build run-custom_level` |
| `advanced_params` | `examples/advanced_params.zig` | Custom window, checksum, strategy via `CompressionOptions` | `zig build run-advanced_params` |
| `custom_strategy` | `examples/custom_strategy.zig` | All nine match-finding strategies compared | `zig build run-custom_strategy` |
| `compression_bound` | `examples/compression_bound.zig` | Sizing an output buffer with `compressBound` | `zig build run-compression_bound` |
| `window_limit` | `examples/window_limit.zig` | Bounding the declared window a decoder accepts | `zig build run-window_limit` |
| `frame_iteration` | `examples/frame_iteration.zig` | Walking frames in a buffer with `FrameIterator` | `zig build run-frame_iteration` |
| `long_distance_matching` | `examples/long_distance_matching.zig` | Long-distance matching, and when it does not help | `zig build run-long_distance_matching` |
| `parallel_compression` | `examples/parallel_compression.zig` | Application-managed threads, one context per worker | `zig build run-parallel_compression` |
| `dictionary_compression` | `examples/dictionary_compression.zig` | Train a dictionary, compress against it, decode with it | `zig build run-dictionary_compression` |
| `dictionary_training` | `examples/dictionary_training.zig` | Training via `DictionaryBuilder.train`, `trainCover`, `trainFastCover` | `zig build run-dictionary_training` |
| `prepared_dictionary` | `examples/prepared_dictionary.zig` | Preparing dictionary state once and reusing it | `zig build run-prepared_dictionary` |
| `streaming_compression` | `examples/streaming_compression.zig` | Streaming compression with `StreamingCompressor` + `EndDirective` | `zig build run-streaming_compression` |
| `streaming_decompression` | `examples/streaming_decompression.zig` | Streaming decompression with `StreamingDecompressor` | `zig build run-streaming_decompression` |
| `custom_allocator` | `examples/custom_allocator.zig` | Custom `TrackingAllocator` tracking | `zig build run-custom_allocator` |
| `error_handling` | `examples/error_handling.zig` | Corruption, truncation, and buffer error cases | `zig build run-error_handling` |
| `legacy_decompression` | `examples/legacy_decompression.zig` | Historic frame detection for v01-v07 and skippable frames | `zig build run-legacy_decompression` |
| `file_compression` | `examples/file_compression.zig` | Real file compression, write to .zst archive, and decompression | `zig build run-file_compression` |
| `explicit_io_streaming` | `examples/explicit_io_streaming.zig` | Chunked streaming file compression, decompression, and Encoder/Decoder contexts | `zig build run-explicit_io_streaming` |
| `large_file_compression` | `examples/large_file_compression.zig` | Multi-megabyte (4 MiB) compression, ratio inspection, and disk preservation | `zig build run-large_file_compression` |

Run all at once:

```bash
zig build run-all-examples
```

## Per-Example Guides

Every example above has a page here with its source, its real captured output,
and what the output means.

| Guide | Example File | Focus |
|---------|--------------|-------|
| [Basic Compression](/examples/basic_compression) | `basic_compression.zig` | `compress`/`decompress` round-trip, ratio |
| [Custom Level](/examples/custom_level) | `custom_level.zig` | `compressWithLevel`, and why every level ties here |
| [Advanced Params](/examples/advanced_params) | `advanced_params.zig` | `getCompressionParameters`, `checksum`, `windowLog`, `strategy` |
| [Custom Strategy](/examples/custom_strategy) | `custom_strategy.zig` | All nine `Strategy` values, round-tripped |
| [Compression Bound](/examples/compression_bound) | `compression_bound.zig` | `compressBound` as an upper bound, `compressInto` |
| [Window Limit](/examples/window_limit) | `window_limit.zig` | `maxWindowSize` boundary, one-shot and streaming |
| [Frame Iteration](/examples/frame_iteration) | `frame_iteration.zig` | `FrameIterator`, skippable frames, truncation |
| [Long-Distance Matching](/examples/long_distance_matching) | `long_distance_matching.zig` | LDM options, and why it currently saves nothing |
| [Parallel Compression](/examples/parallel_compression) | `parallel_compression.zig` | One context per thread, and one frame across a worker pool |
| [Dictionary Compression](/examples/dictionary_compression) | `dictionary_compression.zig` | Train, compress against, decode with |
| [Dictionary Training](/examples/dictionary_training) | `dictionary_training.zig` | `train`, `trainCover`, `trainFastCover` |
| [Prepared Dictionary](/examples/prepared_dictionary) | `prepared_dictionary.zig` | `prepareDictionary`, reuse, wrong-dictionary refusal |
| [Streaming Compression](/examples/streaming_compression) | `streaming_compression.zig` | `StreamingCompressor`, `EndDirective`, `remaining` |
| [Streaming Decompression](/examples/streaming_decompression) | `streaming_decompression.zig` | `StreamingDecompressor`, `needsMore` |
| [Custom Allocator](/examples/custom_allocator) | `custom_allocator.zig` | A caller-supplied counting allocator |
| [Error Handling](/examples/error_handling) | `error_handling.zig` | `PrefixUnknown`, `SrcSizeWrong`, `DstSizeTooSmall` |
| [Legacy Decompression](/examples/legacy_decompression) | `legacy_decompression.zig` | Historic detection, v0.1-v0.5 decode, v0.6-v0.7 refusal |
| [File & Directory Compression](/examples/file_compression) | `file_compression.zig` | File and directory tree to `.zst` and back, with `std.Io.Dir` |
| [Explicit IO Streaming](/examples/explicit_io_streaming) | `explicit_io_streaming.zig` | std.Io chunk streaming, StreamingCompressor, StreamingDecompressor, Encoder, Decoder |
| [Large File Compression](/examples/large_file_compression) | `large_file_compression.zig` | 4 MiB buffer compression, ratio, throughput, and disk preservation |

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
