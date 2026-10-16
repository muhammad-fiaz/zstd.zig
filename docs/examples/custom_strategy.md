---
title: Custom Strategy
description: Choosing match-finding strategies and comparing all nine native search engines.
---

# Custom Strategy

While standard compression levels automatically select a search engine and parsing strategy, you can explicitly configure any of the nine native Zstandard strategies via `CompressionOptions.strategy` or `CompressionContext.setStrategy()`.

| Strategy | Engine | Parser | Characteristics |
|---|---|---|---|
| `.fast` | Hash table | One probe, no look-ahead | Maximum throughput |
| `.dfast` | Hash table | Dual probe (`pos` and `pos + 1`) | Fast matching with improved coverage |
| `.greedy` | Hash chain | First match above threshold | Balanced linear search |
| `.lazy` | Hash chain | 1-step look-ahead | Evaluates next position for longer match |
| `.lazy2` | Hash chain | 2-step look-ahead | Better match selection on text |
| `.btlazy2` | Binary tree | 2-step look-ahead with tree search | Deeper dictionary search |
| `.btopt` | Binary tree | Priced optimal parsing | Cost-modeled sequence selection |
| `.btultra` | Binary tree | Deep optimal parse | Archival compression |
| `.btultra2` | Binary tree | Full depth optimal parse | Maximum ratio compression |

## Usage Example

```zig
const std = @import("std");
const zstd = @import("zstd");

/// Input with repeated headers, text-like middle, and a random tail
fn makeInput(buffer: []u8) []const u8 {
    const header = "HEADER:zstd-sample-payload;version=1;kind=demo\n";
    const body = "the quick brown fox jumps over the lazy dog while the compressor " ++
        "decides between a match now and a longer one a byte later, which is the " ++
        "only decision a lazy parse actually makes. ";
    @memset(buffer, 'x');
    @memcpy(buffer[0..header.len], header);
    var pos = header.len;
    while (pos + body.len < buffer.len - 64) {
        @memcpy(buffer[pos..][0..body.len], body);
        pos += body.len;
    }
    var prng = std.Random.DefaultPrng.init(0x5A7);
    const random = prng.random();
    for (buffer[pos..]) |*b| b.* = random.intRangeAtMost(u8, 0, 255);
    return buffer;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    _ = init.io;

    const input_len = 200_000;
    const input = try allocator.alloc(u8, input_len);
    defer allocator.free(input);
    const payload = makeInput(input);

    std.debug.print("input: {d} bytes\n\n", .{payload.len});
    std.debug.print("{s: <12} {s: <10} {s: >8} {s: >9} {s: >8}\n", .{ "strategy", "engine", "size", "ratio", "vs best" });

    const strategies = [_]zstd.Strategy{
        .fast,
        .dfast,
        .greedy,
        .lazy,
        .lazy2,
        .btlazy2,
        .btopt,
        .btultra,
        .btultra2,
    };

    var best: ?usize = null;
    var sizes: [strategies.len]usize = @splat(0);

    for (strategies, 0..) |strategy, i| {
        const frame = try zstd.compressWithOptions(allocator, payload, .{
            .level = 12,
            .strategy = strategy,
        });
        defer allocator.free(frame);
        sizes[i] = frame.len;

        // Verify round-trip decompression
        const restored = try zstd.decompress(allocator, frame);
        defer allocator.free(restored);
        if (!std.mem.eql(u8, payload, restored)) {
            return error.RoundTripFailed;
        }
        if (best == null or frame.len < best.?) best = frame.len;
    }

    for (strategies, 0..) |strategy, i| {
        std.debug.print("{s: <12} {s: <10} {d: >8} {d: >7.2}% {d: >7.2}%\n", .{
            @tagName(strategy),
            switch (strategy) {
                .fast, .dfast => "table",
                .greedy, .lazy, .lazy2 => "chain",
                else => "tree",
            },
            sizes[i],
            @as(f64, @floatFromInt(sizes[i])) * 100.0 / @as(f64, @floatFromInt(payload.len)),
            (@as(f64, @floatFromInt(sizes[i])) - @as(f64, @floatFromInt(best.?))) * 100.0 / @as(f64, @floatFromInt(best.?)),
        });
    }

    // Context reuse with custom strategy
    var compressor = zstd.Compressor.init(allocator);
    defer compressor.deinit();
    compressor.setStrategy(.btopt);
    const archival = try compressor.compressAlloc(payload);
    defer allocator.free(archival);
    std.debug.print("\nbtopt through a reusable context: {d} bytes\n", .{archival.len});

    std.debug.print("\nAll strategies round tripped.\n", .{});
}
```

## Output

```text
input: 200000 bytes

strategy     engine         size     ratio  vs best
fast         table           935    0.47%    0.21%
dfast        table           935    0.47%    0.21%
greedy       chain           935    0.47%    0.21%
lazy         chain           933    0.47%    0.00%
lazy2        chain           933    0.47%    0.00%
btlazy2      tree            933    0.47%    0.00%
btopt        tree            933    0.47%    0.00%
btultra      tree            933    0.47%    0.00%
btultra2     tree            933    0.47%    0.00%

btopt through a reusable context: 933 bytes

All strategies round tripped.
```

## Explanation

1. **Independent Verification**: Every strategy produces bitstream-conforming frames verified by `zstd.decompress`.
2. **Strategy vs Level**: While `level` sets defaults for window, hash, chain, and search logs, explicitly setting `strategy` overrides the match finder algorithm while retaining tuned log table sizes.
3. **Context Reuse**: `compressor.setStrategy(.btopt)` configures the reusable context for subsequent operations.

## Run Command

```bash
zig build run-custom_strategy
```
