---
title: Dictionary Compression
description: Training a dictionary, compressing small records against it, and decoding with it.
---

# Dictionary Compression

Dictionary compression dramatically improves compression ratios on small, repetitive records (such as HTTP requests, JSON documents, or database tuples). The dictionary acts as shared history that precedes each payload, allowing matches to reference shared strings directly.

## Usage Example

```zig
const std = @import("std");
const zstd = @import("zstd");

/// Generate a sample corpus of HTTP requests with repetitive structure
fn corpus(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var samples: std.ArrayList([]const u8) = .empty;
    errdefer samples.deinit(allocator);
    const statuses = [_][]const u8{ "open", "closed", "pending", "cancelled" };
    for (0..64) |i| {
        const s = try std.fmt.allocPrint(allocator, "GET /api/v1/orders?status={s}&page={d} HTTP/1.1\r\nHost: api.example.com\r\nAccept: application/json\r\n", .{ statuses[i % statuses.len], i / 4 });
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

    // Train a dictionary from the sample corpus
    var builder = zstd.DictionaryBuilder.init(allocator, .{ .dictSize = 1024, .dictId = 0xC0FFEE });
    var dict = try builder.train(samples.items);
    defer dict.deinit();
    std.debug.print("dictionary: {d} bytes, id {d}, from {d} samples\n\n", .{ dict.content().len, dict.dictId(), samples.items.len });

    // A payload that shares phrasing with the corpus
    const payload = "GET /api/v1/orders?status=open&page=99 HTTP/1.1\r\nHost: api.example.com\r\nAccept: application/json\r\n";

    const without = try zstd.compressWithOptions(allocator, payload, .{ .level = 9 });
    defer allocator.free(without);
    const with_dict = try zstd.compressWithOptions(allocator, payload, .{ .level = 9, .dictionary = &dict });
    defer allocator.free(with_dict);

    std.debug.print("{d} bytes of request text\n", .{payload.len});
    std.debug.print("  without a dictionary: {d} bytes\n", .{without.len});
    std.debug.print("  with    a dictionary: {d} bytes\n", .{with_dict.len});

    // The frame header records the dictionary ID required to decode it
    const header = try zstd.getFrameHeader(with_dict);
    std.debug.print("  frame dictionary id:  {d}\n\n", .{header.dictId});

    // Decompress with dictionary attached
    const restored = try zstd.decompressWithOptions(allocator, with_dict, .{ .dictionary = &dict });
    defer allocator.free(restored);
    if (!std.mem.eql(u8, payload, restored)) {
        return error.RoundTripFailed;
    }

    // Decoding without dictionary correctly fails
    if (zstd.decompress(allocator, with_dict)) |_| {
        return error.ShouldHaveFailed;
    } else |_| {}

    std.debug.print("Verified dictionary round trip\n", .{});
}
```

## Output

```text
dictionary: 1024 bytes, id 12648430, from 64 samples

98 bytes of request text
  without a dictionary: 100 bytes
  with    a dictionary: 26 bytes
  frame dictionary id:  12648430

Verified dictionary round trip
```

## Explanation

1. **Dramatic Size Savings**: For a 98-byte payload, compressing without a dictionary produces a 100-byte frame due to header overhead. With the trained dictionary, the size drops to 26 bytes (nearly a 4x reduction).
2. **`dictId` Header Tracking**: The frame header records the dictionary ID (e.g. `12648430`), allowing decoders to verify they have the appropriate dictionary loaded.
3. **Integrity Enforcement**: Attempting to decompress a dictionary-encoded frame without providing the dictionary is safely rejected.

## Run Command

```bash
zig build run-dictionary_compression
```
