---
title: Compression Bound
description: Sizing an output buffer with compressBound and filling it exactly.
---

# Compression Bound

`examples/compression_bound.zig`

`zstd.compressBound(src_size)` returns the largest number of bytes
`compressWithOptions` can produce for an input of that size, for any level and
any options. Sizing a buffer with it means allocating once and never retrying.

The guarantee is an upper bound, not an estimate. Incompressible input can grow:
frame and block headers are fixed overhead, so a few bytes of input still produce
a frame of some tens of bytes.

## Output

```text
size        0: bound       64, wrote        9
size        1: bound       64, wrote       10
size     1024: bound     1091, wrote     1034
size    65536: bound    65824, wrote    65546
size  1048576: bound  1052672, wrote  1048610
short buffer rejected as DstSizeTooSmall, as documented
```

## Reading the numbers

`bound` minus `wrote` is the headroom. For 1 MiB of input the bound is
1,052,672 and the actual frame is 1,048,610 - about 0.4% more than the input, and
4 KB under the bound. The `wrote` column crossing above `size` at 0 and 1 bytes is
the fixed frame overhead, not a measurement error: an empty input is still a
valid frame of 9 bytes.

The last line is the guarantee being enforced rather than assumed. A buffer one
byte shorter than the bound is rejected with `DstSizeTooSmall` instead of
overrunning.

## API used

| Call | Role |
|---|---|
| `zstd.compressBound(src_size)` | Largest output for that input size; errors with `SrcSizeTooLarge` at or above the format's maximum |
| `zstd.compressInto(allocator, dst, src, level)` | Compress into a buffer you sized, returning bytes written |
| `zstd.decompressInto(allocator, dst, src)` | Decompress into a caller buffer, returning bytes written |

`compressBound` can fail: an input size at or above `MAX_INPUT_SIZE` is not
representable in the format, and reporting that is better than returning a
wrapped value that would then look like a real bound.

Run:

```bash
zig build run-compression_bound
```
