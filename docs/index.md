---
layout: home
title: zstd.zig
titleTemplate: Native Zig Compression Library

hero:
  name: zstd.zig
  text: Native Zig Compression Library
  tagline: "A complete native Zig implementation of Zstandard compression. No C bindings, no dependencies. Supports compression, decompression, streaming, and dictionary-based operations for Zig 0.16.0+."
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: API Reference
      link: /api/
    - theme: alt
      text: GitHub
      link: https://github.com/muhammad-fiaz/zstd.zig

features:
  - title: Pure Zig Implementation
    details: "Complete native Zig reimplementation of Zstandard. No C bindings, no external dependencies. Every byte is Zig."
  - title: One-Shot Compression
    details: "Simple compress and decompress functions. Use compressWithLevel for numeric levels 1-22 or compressWithOptions for fine control."
  - title: Reusable Contexts
    details: "CompressionContext and DecompressionContext types that can be initialized once and reused across multiple operations. Set parameters, reset, and compress again."
  - title: Streaming Support
    details: "StreamingCompressor and StreamingDecompressor for chunk-based processing. Handle data that doesn't fit in memory with incremental compression via EndDirective."
  - title: Dictionary Compression
    details: "Dictionary and DictionaryBuilder types for dictionary-based compression. Train dictionaries from samples via train, trainCover, trainFastCover."
  - title: Frame Inspection
    details: "Frame inspection via isFrame, getFrameHeader, getFrameContentSize, findFrameCompressedSize and isSkippableFrame without decompressing."
  - title: Cross-Platform
    details: "Works on Linux, Windows, macOS, and FreeBSD. Supports both 32-bit and 64-bit architectures including aarch64."
  - title: Idiomatic Zig API
    details: "Options structs, enums, and comptime features. The API feels natural in Zig with named parameters and clean error handling."
---

> zstd.zig follows the Zstandard 1.6.0 specification natively in Zig.
