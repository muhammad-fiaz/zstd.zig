---
title: Dictionary Compression
description: Dictionary creation and header dict_id handling.
---

# Dictionary Compression

`examples/dictionary_compression.zig` — `createDictionaryFromData` and `dict_id`.

## Client Code

```zig
const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const dict_data = "common dictionary content for small message compression example";
    var dict = try zstd.createDictionaryFromData(allocator, dict_data, 12345);
    defer dict.deinit();
    std.debug.print("Dictionary ID: {d}, size: {d}\n", .{ dict.dictId(), dict.data.len });
    const samples = [_][]const u8{ "small message 1 with common prefix", "small message 2 with common prefix", "small message 3 with common prefix" };
    var builder = zstd.DictionaryBuilder.init(allocator, .{ .dict_size = 4096, .dict_id = 999 });
    var trained = try builder.train(&samples);
    defer trained.deinit();
    std.debug.print("Trained dictionary size: {d}\n", .{trained.data.len});
    std.debug.assert(trained.data.len > 0);
    const data = "small message 4 with common prefix and extra content";
    const opts = zstd.CompressionOptions{ .dict_id = dict.dictId() };
    const cs = try zstd.compressWithOptions(allocator, data, opts);
    defer allocator.free(cs);
    const dec = try zstd.decompress(allocator, cs);
    defer allocator.free(dec);
    std.debug.assert(std.mem.eql(u8, data, dec));
    std.debug.print("Dictionary example: {s} -> {d} bytes -> {s}\n", .{ data, cs.len, dec });
}
```

## Output

```text
Dictionary ID: 12345, size: 71
Trained dictionary size: 450
Dictionary example: small message 4 with common prefix and extra content -> 63 bytes -> small message 4 with common prefix and extra content
```

## Explanation

- `createDictionaryFromData(allocator, bytes, 12345)` writes `MAGIC_DICTIONARY (0xEC30A437)` + `dict_id` header.
- `DictionaryBuilder.train` / `loadDictionary` / `dict.content()` / `dictId()` expose dictionary handling.
- `CompressionOptions{ .dict_id }` sets `Dictionary_ID_flag` in `FHD`; `getFrameHeader` can verify `dict_id` on decompress.

Run:

```bash
zig build run-dictionary_compression
```
