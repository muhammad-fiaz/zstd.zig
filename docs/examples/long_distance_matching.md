---
title: Long-Distance Matching
description: Long-distance match finding with gear hashing and window bounding.
---

# Long-Distance Matching

Long-distance matching (LDM) enables the compressor to discover repeats across large distances that exceed standard block boundaries. A gear rolling hash identifies candidate split points, a checksummed bucketed table tracks historical occurrences, and candidate matches are evaluated by the block search engine within the declared window boundary.

## Usage Example

```zig
const std = @import("std");
const zstd = @import("zstd");

/// Three unrelated 512 KiB sections followed by a copy of the first one.
fn makeInput(buffer: []u8) []const u8 {
    const section = 512 * 1024;
    var prng = std.Random.DefaultPrng.init(0x4C44);
    const random = prng.random();
    for (buffer[0 .. section * 2]) |*b| b.* = random.intRangeAtMost(u8, 0, 63);
    @memcpy(buffer[section * 2 ..], buffer[0..section]);
    return buffer;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    _ = init.io;

    const input_len = 3 * 512 * 1024;
    const input = try allocator.alloc(u8, input_len);
    defer allocator.free(input);
    const payload = makeInput(input);

    std.debug.print("input: {d} bytes, with the last {d} a copy of the first {d}\n\n", .{
        payload.len,
        512 * 1024,
        512 * 1024,
    });

    // Baseline: standard window-bounded search without LDM
    const baseline = try zstd.compressWithOptions(allocator, payload, .{
        .level = 9,
        .windowLog = 23,
    });
    defer allocator.free(baseline);
    std.debug.print("without LDM: {d} bytes\n", .{baseline.len});

    // With long-distance matching enabled
    const with_ldm = try zstd.compressWithOptions(allocator, payload, .{
        .level = 9,
        .windowLog = 23,
        .longDistanceMatching = true,
        .ldmHashRateLog = 4,
    });
    defer allocator.free(with_ldm);
    std.debug.print("with LDM:    {d} bytes\n", .{with_ldm.len});
    if (with_ldm.len >= baseline.len) {
        std.debug.print("expected LDM to be smaller on this input\n", .{});
    } else {
        const saved = baseline.len - with_ldm.len;
        std.debug.print("LDM saved {d} bytes ({d:.1}% of the input)\n", .{
            saved,
            @as(f64, @floatFromInt(saved)) * 100.0 / @as(f64, @floatFromInt(payload.len)),
        });
    }

    // Verify round trip: frames produced with LDM are standard conforming Zstandard frames
    const restored = try zstd.decompress(allocator, with_ldm);
    defer allocator.free(restored);
    if (!std.mem.eql(u8, payload, restored)) {
        return error.RoundTripFailed;
    }
    const header = try zstd.getFrameHeader(with_ldm);
    std.debug.print("\nLDM frame round tripped; window {d} bytes, dict id {d}\n", .{
        header.windowSize,
        header.dictId,
    });

    // Verify through a reusable context
    const options = zstd.CompressionOptions{
        .level = 9,
        .windowLog = 23,
        .longDistanceMatching = true,
        .ldmHashRateLog = 4,
    };
    var compressor = zstd.Compressor.init(allocator);
    defer compressor.deinit();
    try compressor.setOptions(options);
    const from_context = try compressor.compressAlloc(payload);
    defer allocator.free(from_context);
    std.debug.print("same through a context: {d} bytes\n", .{from_context.len});
    if (!std.mem.eql(u8, with_ldm, from_context)) {
        return error.ContextMismatch;
    }
}
```

## Output

```text
input: 1572864 bytes, with the last 524288 a copy of the first 524288

without LDM: 788729 bytes
with LDM:    788729 bytes
expected LDM to be smaller on this input

LDM frame round tripped; window 8388608 bytes, dict id 0
same through a context: 788729 bytes
```

## Explanation

1. **Option Configuration**: Setting `.longDistanceMatching = true` in `CompressionOptions` enables the secondary long-distance match finder.
2. **Parameters**:
   - `ldmHashLog`: Log2 of the number of entries in the LDM hash table.
   - `ldmBucketSizeLog`: Log2 of candidates per bucket.
   - `ldmMinMatch`: Minimum match length considered by LDM.
   - `ldmHashRateLog`: Frequency of split points sampled across the payload.
3. **Format Conformance**: Frames generated with long-distance matching follow standard Zstandard frame formatting without requiring special flags or non-standard decoders. Any conforming decoder uncompresses the frame losslessly.
4. **Context Consistency**: Reusable `CompressionContext` and one-shot `compressWithOptions` generate identical compressed output for identical configurations.

## Run Command

```bash
zig build run-long_distance_matching
```
