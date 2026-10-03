---
title: Errors
description: Error types and error handling for zstd.zig.
---

> **Spec conformance:** zstd.zig implements the [Zstandard 1.6.0 specification](https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md) natively in Zig - every algorithm, frame element, and default table in this document follows that version.


# Errors

## ZstdError

The main error set for zstd operations, re-exported as `zstd.ZstdError`:

```zig
pub const ZstdError = error{
    Corruption,
    ChecksumWrong,
    DictionaryCorrupted,
    DictionaryWrong,
    ParameterOutOfBound,
    TableLogTooLarge,
    MaxSymbolValueTooLarge,
    MaxSymbolValueTooSmall,
    StageWrong,
    InitMissing,
    MemoryAllocation,
    WorkspaceTooSmall,
    DstSizeTooSmall,
    SrcSizeWrong,
    DstBufferNull,
    NoForwardProgressDestFull,
    NoForwardProgressInputEmpty,
    FrameIndexTooLarge,
    PrefixUnknown,
    VersionUnsupported,
    FrameParameterUnsupported,
    WindowTooLarge,
    UnsupportedFeature,
    InvalidMagic,
    InvalidFrameHeader,
    InvalidBlock,
    InvalidBlockSize,
    InvalidDictionary,
    InvalidFseTable,
    InvalidHuffmanTable,
    InvalidSequence,
    InvalidOffset,
    ContentSizeMismatch,
    AllocationFailure,
    GenericError,
    OutOfMemory,
};
```

Helper:

```zig
pub fn errorToString(err: ZstdError) []const u8
// e.g. error.ChecksumWrong -> "checksum_wrong"
```

Exposed as `zstd.errorToString`. It is a free function rather than a member of
`ZstdError`, which is an error set and cannot carry methods. Use it when the name
goes into a log or a message that crosses a boundary; use `@errorName` for
Zig-idiomatic output inside your own code.

## Common Errors

| Error | Cause |
|-------|-------|
| `PrefixUnknown` | Data doesn't start with zstd magic (`0xFD2FB528`) |
| `Corruption` | Data is corrupted |
| `SrcSizeWrong` | Source buffer too short / truncated |
| `DstSizeTooSmall` | Destination buffer too small |
| `OutOfMemory` | Memory allocation failed |
| `ChecksumWrong` | Frame XXH64 checksum mismatch |
| `InvalidDictionary` | Dictionary bytes invalid |
| `ContentSizeMismatch` | Decoded size differs from header `contentSize` |
| `WindowTooLarge` | Window log exceeds limit |

## Handling Example (`examples/error_handling.zig`)

```zig
const good = try zstd.compress(allocator, "valid data");
defer allocator.free(good);

var bad = try allocator.dupe(u8, good);
defer allocator.free(bad);
bad[0] ^= 0xFF;

const result = zstd.decompress(allocator, bad);
if (result) |data| {
    defer allocator.free(data);
    return error.TestFailed;
} else |err| {
      std.debug.print("Correctly caught: {s} ({s})\n", .{ @errorName(err), zstd.errorToString(err) });
}

const truncated = good[0 .. good.len / 2];
const r2 = zstd.decompress(allocator, truncated); // -> error.SrcSizeWrong

var small: [2]u8 = undefined;
const r3 = zstd.decompressInto(allocator, &small, good); // -> error.DstSizeTooSmall
```
