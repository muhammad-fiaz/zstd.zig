---
title: Dictionary Training
description: Training custom compression dictionaries via train, trainCover, and trainFastCover.
---

# Dictionary Training

`DictionaryBuilder` constructs custom Zstandard dictionaries from representative samples using three distinct selection algorithms:

1. **`train`**: Selects representative segments from the corpus in order of appearance.
2. **`trainCover`**: The COVER algorithm ranks segment candidates by frequency and coverage score, maximizing shared substring reach.
3. **`trainFastCover`**: Accelerates COVER by subsampling split points, providing near-identical dictionary quality with substantially lower training time.

## Usage Example

```zig
const std = @import("std");
const zstd = @import("zstd");

/// Generate a sample corpus of repeating transactional database queries
fn corpus(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var samples: std.ArrayList([]const u8) = .empty;
    errdefer samples.deinit(allocator);
    const verbs = [_][]const u8{ "insert", "update", "delete", "select" };
    const tables = [_][]const u8{ "orders", "customers", "invoices", "shipments" };
    for (0..200) |i| {
        const s = try std.fmt.allocPrint(allocator, "begin transaction on table {s}: {s} row {d} of 1000; commit transaction on table {s}; end transaction\n", .{
            tables[i % tables.len],
            verbs[i % verbs.len],
            i,
            tables[(i + 1) % tables.len],
        });
        try samples.append(allocator, s);
    }
    return samples;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var samples = try corpus(allocator);
    defer {
        for (samples.items) |s| allocator.free(s);
        samples.deinit(allocator);
    }

    var builder = zstd.DictionaryBuilder.init(allocator, .{ .dictSize = 4096, .dictId = 0x5EED });
    std.debug.print("{d} samples\n\n", .{samples.items.len});

    // 1. Train via standard segmentation
    var plain = try builder.train(samples.items);
    defer plain.deinit();
    std.debug.print("train          {d} bytes  (id {d})\n", .{ plain.content().len, plain.dictId() });

    // 2. Train via COVER algorithm (k = key size, d = candidate size)
    var cover = try builder.trainCover(samples.items, 6, 32);
    defer cover.deinit();
    std.debug.print("trainCover     {d} bytes  (k=6 d=32)\n", .{cover.content().len});

    // 3. Train via FastCOVER algorithm
    var fast = try builder.trainFastCover(samples.items, 6, 32, 20, 2);
    defer fast.deinit();
    std.debug.print("trainFastCover {d} bytes  (k=6 d=32 f=20 accel=2)\n", .{fast.content().len});

    // Compare compression with and without dictionary
    const payload = samples.items[samples.items.len - 1];
    const without = try zstd.compressWithOptions(allocator, payload, .{ .level = 9 });
    defer allocator.free(without);
    const with_dict = try zstd.compressWithOptions(allocator, payload, .{ .level = 9, .dictionary = &cover });
    defer allocator.free(with_dict);
    std.debug.print("\n{d}-byte sample: {d} bytes without a dictionary, {d} with one\n", .{
        payload.len,
        without.len,
        with_dict.len,
    });

    // Verify round-trip decompression
    const restored = try zstd.decompressWithOptions(allocator, with_dict, .{ .dictionary = &cover });
    defer allocator.free(restored);
    if (!std.mem.eql(u8, payload, restored)) {
        return error.RoundTripFailed;
    }
    std.debug.print("Verified a trained dictionary round trip\n", .{});
}
```

## Output

```text
200 samples

train          4096 bytes  (id 24301)
trainCover     4096 bytes  (k=6 d=32)
trainFastCover 4096 bytes  (k=6 d=32 f=20 accel=2)

114-byte sample: 87 bytes without a dictionary, 61 with one
Verified a trained dictionary round trip
```

## Explanation

1. **`DictionaryBuilder.init(allocator, .{ .dictSize, .dictId })`**: Sets target dictionary byte capacity and dictionary ID.
2. **Algorithm Parameters**:
   - `k`: Segment key size (e.g. 6 bytes).
   - `d`: Candidate dictionary entry length (e.g. 32 bytes).
   - `f`: Log2 of the hash frequency filter.
   - `accel`: Subsampling stride for accelerated training.
3. **Usage**: Trained dictionaries conform to the standard Zstandard dictionary format (`MAGIC_DICTIONARY = 0xEC30A437`) and can be attached to both one-shot and streaming operations.

## Run Command

```bash
zig build run-dictionary_training
```
