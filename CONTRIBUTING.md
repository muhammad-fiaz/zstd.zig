# Contributing to zstd.zig

Thank you for your interest in contributing to zstd.zig!

## Getting Started

1. Fork the repository
2. Clone your fork
3. Create a feature branch
4. Make your changes
5. Submit a pull request

## Development Setup

### Prerequisites

* Zig 0.17.0 or later
* Git

### Installing Zig 0.17.0

Download from [ziglang.org](https://ziglang.org/download/) or use a package manager:

```bash
# Using Scoop (Windows)
scoop install zig

# Or download directly from https://ziglang.org/download/
```

### Building

```bash
zig build            # Build the library
zig build test       # Run all tests
zig build check      # Compile tests and examples for another target without running
zig build fmt        # Format
zig build docs       # Build the documentation site
```

Concurrency, fuzzing, and throughput have their own steps, each scaled by
environment variables so a CI run stays short:

```bash
STRESS_ROUNDS=1 STRESS_CLIENTS=2 zig build stress   # pool waves, concurrent compressors
FUZZ_ITERS=60 zig build fuzz                        # seeded mutations, round trips, legacy frames
zig build bench -- --quick                          # small throughput matrix; no flag for the full one
```

`FUZZ_DEEP=1` lifts the payload-size pairing between the round-trip target and
the expensive levels, so every level meets every size at the cost of a much
longer run.

The differential tests need a reference `zstd` binary, and they never skip: a run that
cannot find one fails. It is located through `ZSTD_REFERENCE_PATH` first, then the
first `zstd` on `PATH`, then the usual install locations, so on a machine with zstd
installed `zig build test` is already the full run and nothing needs configuring.

### Running Examples

```bash
zig build run-basic_compression
zig build run-custom_level
zig build run-advanced_params
zig build run-custom_strategy
zig build run-custom_allocator
zig build run-error_handling
zig build run-file_compression
zig build run-parallel_compression
zig build run-window_limit
zig build run-compression_bound
zig build run-frame_iteration
zig build run-long_distance_matching
zig build run-streaming_compression
zig build run-streaming_decompression
zig build run-dictionary_compression
zig build run-dictionary_training
zig build run-prepared_dictionary
zig build run-legacy_decompression
```

Each example's step is named `run-<example file name>`. `zig build run-all-examples`
runs all of them, and `zig build check` compiles them for another target without
running, which is what CI uses for cross-compilation.

## Code Style

* Follow idiomatic Zig conventions
* Use the existing code style as reference
* All public APIs must have doc comments
* Keep functions focused and small
* Use `ZstdError` for error handling

## Architecture

This is a **pure Zig implementation** - no C dependencies or bindings.

### Source Structure

```
src/
  zstd.zig          public API facade; the only module a caller imports
  common/           bits, bitstream, constants, cpu, errors, memory, types, xxhash
  frame/            frame header, block header, checksum, detect, iterator, skippable
  compress/         block encoding, one-shot entry points, context, ldm, search, parameters
  decompress/       block decoding, entropy decoding, one-shot entry points, context, frame
  dictionary/       dictionary type, trainer, prepared dictionaries
  fse/              FSE tables, normalized counts, encode and decode
  huffman/          Huffman table construction, encode and decode
  streaming/        streaming compressor and decompressor
  legacy/           pre-1.0 frame detection, v0.1 decoding, refusal for v0.2-v0.7
```

Each subsystem is a directory rather than a flat set of files, because the split is
along the format's own layers: a frame contains blocks, a block contains a
literals section and a sequences section, and the entropy stages that decode those
sections are shared between the current format and the historic one.

Tests live at the bottom of the file they test, not in a separate directory. A
module that nothing imports would have its tests silently skipped, so `zstd.zig`
carries a comptime block that references every module; that is what keeps the
reported test count equal to the tests that actually run.

### Key Design Principles

1. **Zero C Dependencies** - Pure Zig, builds from source
2. **The application owns the allocator and the I/O** - every entry point takes an
   allocator, nothing here opens a file or starts a thread
3. **One context per concurrent operation** - contexts hold frame state and are not
   safe to share; threading is the caller's to arrange
4. **Safety first** - window limits, output bounds, reserved-bit checks, and
   checked arithmetic on lengths read from untrusted input
5. **Refuse rather than guess** - an unrecognised or unreadable frame returns an
   error instead of producing output that was not read from the body

## Adding New Features

### Adding New API Functions

1. Add the function to the appropriate module file
2. Create idiomatic Zig interface with proper error handling
3. Add doc comments explaining the function
4. Add unit tests
5. Re-export at the root level in `src/zstd.zig` if it's a convenience function
6. Update the README API reference

### Example Structure

```zig
// examples/my-example.zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    // Your example code here
}
```

## Testing

All changes must pass the test suite:

```bash
zig build test
```

Anything touching the pool, the multithreaded compressor, or the frame writers
also needs the concurrency and fuzz steps, which CI runs on native targets:

```bash
STRESS_ROUNDS=1 STRESS_CLIENTS=2 zig build stress
FUZZ_ITERS=60 zig build fuzz
```

Tests should:
* Cover the new functionality
* Test error cases
* Use `std.testing.allocator` for memory leak detection
* Be placed in the relevant source file as `test` blocks

## Documentation

### Building Docs Locally

```bash
cd docs
npm install
npm run dev
```

### Writing Doc Pages

* Place API reference pages in `docs/api/`
* Place guide pages in `docs/guide/`
* Place example pages in `docs/examples/`
* Use Markdown with optional Vue components

## Pull Request Process

1. Update documentation if needed
2. Ensure CI passes (`zig build test`, `zig fmt src/`)
3. Request review from maintainers

## Reporting Issues

* Use the GitHub issue tracker
* Include Zig version and OS
* Provide a minimal reproduction case
* Include error messages and stack traces

## License

By contributing, you agree that your contributions will be licensed under the same license as the project (MIT).
