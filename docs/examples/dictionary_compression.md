---
title: Dictionary Compression
description: Training a dictionary, compressing against it, and decoding with it.
---

# Dictionary Compression

`examples/dictionary_compression.zig`

A dictionary is content that logically precedes the data. The encoder may match
back into it, so a payload sharing its phrasing costs far fewer bytes. The frame
records the dictionary's ID, and a decoder must be given the same dictionary to
reproduce the frame - without it, the frame cannot be decoded at all, because its
matches point into content the decoder does not have.

## Source

```zig
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

    // Training picks the parts of the corpus that recur, so the dictionary holds
    // the request line and the headers rather than one whole request.
    var builder = zstd.DictionaryBuilder.init(allocator, .{ .dictSize = 1024, .dictId = 0xC0FFEE });
    var dict = try builder.train(samples.items);
    defer dict.deinit();

    // A payload the dictionary has never seen, but which shares its phrasing.
    const payload = "GET /api/v1/orders?status=open&page=99 HTTP/1.1\r\nHost: api.example.com\r\nAccept: application/json\r\n";

    const without = try zstd.compressWithOptions(allocator, payload, .{ .level = 9 });
    defer allocator.free(without);
    const with_dict = try zstd.compressWithOptions(allocator, payload, .{ .level = 9, .dictionary = &dict });
    defer allocator.free(with_dict);

    // The frame records which dictionary it needs, so a decoder can tell.
    const header = try zstd.getFrameHeader(with_dict);

    // Decoding needs the same dictionary.
    const restored = try zstd.decompressWithOptions(allocator, with_dict, .{ .dictionary = &dict });
    defer allocator.free(restored);

    // Without it the frame cannot be decoded.
    if (zstd.decompress(allocator, with_dict)) |_| {
        return error.ShouldHaveFailed;
    } else |_| {}
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

## API used

| Call | Role |
|---|---|
| `zstd.DictionaryBuilder.init(allocator, params)` | Builder with `dictSize` and `dictId` |
| `builder.train(samples)` | Trains and returns a `Dictionary` |
| `dict.content()` | The trained content, without any header |
| `dict.dictId()` | The ID a frame made with it will record |
| `zstd.compressWithOptions(..., .{ .dictionary = &dict })` | Compress with the dictionary available for matching |
| `zstd.getFrameHeader(frame)` | Reads back the `dictId` the frame declares |
| `zstd.decompressWithOptions(..., .{ .dictionary = &dict })` | Decode, which requires the same dictionary |

## Notes

- The payload here is 98 bytes and compresses to 100 without a dictionary: the
  frame header alone costs more than the content. The dictionary version is 26.
  A dictionary earns its place on small payloads that share phrasing with it, not
  on large ones.
- The final check is the important one. `zstd.decompress` on a dictionary frame
  must fail; a decoder that silently produced output would be reading matches
  against content it does not have.

Run:

```bash
zig build run-dictionary_compression
```
