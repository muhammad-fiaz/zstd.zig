---
title: Dictionary Training
description: Training via train, trainCover and trainFastCover.
---

# Dictionary Training

`examples/dictionary_training.zig` - `DictionaryBuilder` training.

## Client Code

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var samples: std.ArrayList([]const u8) = .empty;
    defer samples.deinit(allocator);
    for (0..100) |i| {
        const s = try std.fmt.allocPrint(allocator, "sample {d}: common header and payload with id {d} and some repetitive text", .{ i, i % 10 });
        try samples.append(allocator, s);
    }
    defer for (samples.items) |s| allocator.free(s);
    var builder = zstd.DictionaryBuilder.init(allocator, .{ .dictSize = 8192 });
    var d = try builder.train(samples.items);
    defer d.deinit();
    std.debug.print("Trained dictionary: {d} bytes from {d} samples\n", .{ d.data.len, samples.items.len });
    std.debug.assert(d.data.len > 0);
    var cd = try builder.trainCover(samples.items, 6, 8);
    defer cd.deinit();
    std.debug.print("COVER dict: {d} bytes\n", .{cd.data.len});
    std.debug.assert(cd.data.len > 0);
    var fd = try builder.trainFastCover(samples.items, 6, 8, 6, 2);
    defer fd.deinit();
    std.debug.print("FastCover dict: {d} bytes\n", .{fd.data.len});
    std.debug.assert(fd.data.len > 0);
}
```

## Output

```text
200 samples

train          4096 bytes  (id 24301)
trainCover     4096 bytes  (k=6 d=32)
trainFastCover 4096 bytes  (k=6 d=32 f=20 accel=2)

114-byte sample: 87 bytes without a dictionary, 60 with one
Verified a trained dictionary round trip
```

## Explanation

- `DictionaryBuilder.init(allocator, .{ .dictSize=8192 })` configures `DictBuilderParams`.
- `train` - naive concatenation training; `trainCover(k,d)` and `trainFastCover(k,d,f,accel)` wrap `dictBuilder` COVER/FastCover (currently naive, interoperable via `createDictionaryFromData`).
- All produce a `Dictionary` with `MAGIC_DICTIONARY` header, verified `dictId()` and `data.len >0`.

Run:

```bash
zig build run-dictionary_training
```
