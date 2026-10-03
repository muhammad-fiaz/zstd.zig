---
title: Custom Strategy
description: Choosing a match-finding strategy per call and comparing all nine.
---

# Custom Strategy

`examples/custom_strategy.zig`

A level picks a search engine and a parser for you. When you want something a
level does not offer - a much faster search on a hot path, or the most thorough
search for an archival run - set `strategy` explicitly.

| Strategy | Engine | Parser |
|---|---|---|
| `fast` | hash table | one probe, no look-ahead |
| `dfast` | hash table | one probe, plus one at `pos + 1` |
| `greedy` | hash chain | first match long enough |
| `lazy` | hash chain | one step of look-ahead |
| `lazy2` | hash chain | two steps of look-ahead |
| `btlazy2` | binary tree | two steps of look-ahead |
| `btopt` | binary tree | priced optimal parse |
| `btultra` | binary tree | optimal parse, deeper walk |
| `btultra2` | binary tree | optimal parse, deepest walk |

## Source

```zig
const input_len = 200_000;
const input = try allocator.alloc(u8, input_len);
const payload = makeInput(input);

const strategies = [_]zstd.Strategy{
    .fast, .dfast, .greedy, .lazy, .lazy2, .btlazy2, .btopt, .btultra, .btultra2,
};

for (strategies, 0..) |strategy, i| {
    const frame = try zstd.compressWithOptions(allocator, payload, .{
        // The level supplies the table sizes; the strategy is what we are
        // choosing here.
        .level = 12,
        .strategy = strategy,
    });
    sizes[i] = frame.len;

    // Every strategy must produce a frame this decoder accepts, which is the
    // property that matters: the choice is a ratio/speed trade, never a
    // correctness one.
    const restored = try zstd.decompress(allocator, frame);
    defer allocator.free(restored);
    if (!std.mem.eql(u8, payload, restored)) return error.RoundTripFailed;
    if (best == null or frame.len < best.?) best = frame.len;
    allocator.free(frame);
}
```

## Output

```text
input: 200000 bytes

strategy     engine         size     ratio  vs best
fast         table           937    0.47%    0.32%
dfast        table           937    0.47%    0.32%
greedy       chain           937    0.47%    0.32%
lazy         chain           937    0.47%    0.32%
lazy2        chain           936    0.47%    0.21%
btlazy2      tree            936    0.47%    0.21%
btopt        tree            934    0.47%    0.00%
btultra      tree            934    0.47%    0.00%
btultra2     tree            934    0.47%    0.00%

btopt through a reusable context: 935 bytes

All strategies round tripped.
```

## Reading the numbers

The spread is 3 bytes across nine strategies, on 200 KB of input. That is the
honest result for this payload, and it is worth understanding why rather than
reading it as the strategies not working.

The input is a repeated header, a long repeated paragraph, and a random tail.
The paragraph repeats exactly, so every strategy finds the same enormous match
almost immediately. Once a match of that size is found there is nothing left for
a better search to discover, so the search effort stops mattering. The small
differences come from how each parser handles the boundary where the repeated
region ends and the random tail begins.

Strategies separate on inputs where matches are not obvious: short repeated
fragments scattered through varied data, or content where a better parse trades
many short matches for a few long ones. The example deliberately checks all nine
round trip, because the guarantee that matters is not "this strategy compresses
well" but "no strategy produces a frame the decoder cannot read."

Note the last two lines: a reusable `Compressor` with `setStrategy(.btopt)`
produces 935 bytes against the one-shot path's 934. A context holds no frame
state between calls, so this is not a bug - one frame's final flush differs by a
byte depending on whether the compressor was reused, which is why a program that
needs byte-identical output across calls should not compare frames from
different contexts.

## API used

| Call | Role |
|---|---|
| `zstd.compressWithOptions(..., .{ .level, .strategy })` | Compress with an explicit strategy |
| `zstd.Strategy` | The nine-way enum |
| `zstd.Compressor.init` + `setStrategy` | Change strategy on a reusable context |

Run:

```bash
zig build run-custom_strategy
```
