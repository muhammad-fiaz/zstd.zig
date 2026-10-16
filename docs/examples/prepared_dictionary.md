---
title: Prepared Dictionary
description: Preparing dictionary state once and reusing it across many operations.
---

# Prepared Dictionary

A prepared dictionary parses and pre-computes the entropy tables (Huffman literals and FSE sequence models) for a dictionary once. Successive compression contexts can attach the prepared dictionary to compress similar records with minimal setup overhead.

## Usage Example

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Shared content that recurring payloads share
    const shared = "the recurring phrase that every payload in this example shares";

    // Prepare dictionary once: builds pre-computed entropy tables
    var prepared = try zstd.prepareDictionary(allocator, shared);
    defer prepared.deinit();
    std.debug.print("prepared dictionary id {d}, {d} bytes of content\n", .{
        prepared.id,
        prepared.content().len,
    });

    var dict = try zstd.loadDictionary(allocator, prepared.data);
    defer dict.deinit();

    const inputs = [_][]const u8{
        shared,
        "a payload with no overlap at all, to show the dictionary is optional per frame",
        "the recurring phrase that every payload shares, plus a tail",
        "",
    };

    // Reuse a single compressor context across every input
    var comp = zstd.Compressor.init(allocator);
    defer comp.deinit();
    comp.setDictionary(&dict);

    var frames: [inputs.len][]u8 = undefined;
    for (inputs, 0..) |text, i| {
        frames[i] = try comp.compressAlloc(text);
        std.debug.print("compressed {d:>3} bytes into {d:>3}\n", .{ text.len, frames[i].len });
    }
    defer for (frames) |f| allocator.free(f);

    // Reuse a single decompressor context
    var dec = zstd.Decompressor.init(allocator);
    defer dec.deinit();
    dec.setDictionary(&dict);

    for (inputs, 0..) |text, i| {
        const back = try dec.decompressAlloc(frames[i]);
        defer allocator.free(back);
        if (!std.mem.eql(u8, back, text)) {
            return error.RoundTripFailed;
        }
        std.debug.print("frame {d} round tripped, {d} bytes\n", .{ i, back.len });
    }

    // Safety: mismatched dictionary is strictly refused
    var other = try zstd.createDictionaryFromData(allocator, "a completely different body", 999);
    defer other.deinit();
    if (zstd.decompressWithOptions(allocator, frames[0], .{
        .dictionary = &other,
        .requireDictionaryMatch = true,
    })) |wrong| {
        allocator.free(wrong);
        return error.WrongDictionaryAccepted;
    } else |e| {
        std.debug.print("mismatched dictionary refused as {s}\n", .{@errorName(e)});
    }

    // Missing required dictionary is also refused
    if (zstd.decompressWithOptions(allocator, frames[0], .{ .requireDictionaryMatch = true })) |wrong| {
        allocator.free(wrong);
        return error.MissingDictionaryAccepted;
    } else |e| {
        std.debug.print("missing dictionary refused as {s}\n", .{@errorName(e)});
    }
}
```

## Output

```text
prepared dictionary id 0, 62 bytes of content
compressed  62 bytes into  16
compressed  78 bytes into  71
compressed  59 bytes into  31
compressed   0 bytes into   9
frame 0 round tripped, 62 bytes
frame 1 round tripped, 78 bytes
frame 2 round tripped, 59 bytes
frame 3 round tripped, 0 bytes
mismatched dictionary refused as InvalidOffset
missing dictionary refused as DictionaryWrong
```

## Explanation

1. **`prepareDictionary`**: Compiles dictionary entropy structures ahead of time. This amortizes the cost of entropy analysis over thousands of messages.
2. **Context Reuse**: A single `Compressor` (`CompressionContext`) or `Decompressor` (`DecompressionContext`) retains the dictionary pointer and reuses it across multiple frames without resetting or reallocating memory.
3. **Safety Verification**: When `.requireDictionaryMatch = true` is supplied to `decompressWithOptions`, decoding a frame with the wrong dictionary or omitting the dictionary returns an error (`error.InvalidOffset` or `error.DictionaryWrong`).

## Run Command

```bash
zig build run-prepared_dictionary
```
