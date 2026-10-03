---
title: Long-Distance Matching
description: The long-distance option, and an honest account of when it helps.
---

# Long-Distance Matching

`examples/long_distance_matching.zig`

Long-distance matching adds a second match finder for repeats that start further
back than the frame's window. A gear rolling hash picks candidate split points,
each is fingerprinted with a 64-bit hash of the bytes ending there, the low bits
choose a bucket in a checksummed table and the high 32 bits act as a checksum, so
a lookup is a short bounded scan rather than a walk of the whole input.

It is off by default because it costs a pass over the input and a table.

## Output

```text
input: 1572864 bytes, with the last 524288 a copy of the first 524288

without LDM: 1188040 bytes
with LDM:    1188040 bytes
expected LDM to be smaller on this input

LDM frame round tripped; window 8388608 bytes, dict id 0
same through a context: 1188040 bytes
```

## Read this before trusting the feature

**On this input LDM saves nothing, and the example says so rather than hiding
it.** That is not a rounding detail. Measured across window logs 17, 18, 20 and
23, the LDM output was never smaller than the baseline, and at small windows it
was marginally *larger*.

The reason is a constraint in the implementation, and it is worth stating plainly
because it bounds what the option can do:

- `ldm.zig` accepts a candidate only when `dist <= windowDistance()`, and
  `windowDistance()` is `1 << windowLog`.
- `compress.zig` raises the frame's declared window to at least
  `ldm.min_window_log` (20, i.e. 1 MiB) whenever the option is on.

Those two together mean the long-distance finder is only ever allowed to return
matches the window already covers - which is exactly the set the ordinary
window-bounded match finder already searches. The extra pass therefore costs time
without adding reach. In the reference implementation the two differ: its
long-distance table indexes the whole input while the window bounds only what the
decoder must retain, so a match beyond the window widens the window rather than
being discarded. That distinction is not present here.

So the option is plumbed, exercised, and round-trips correctly - every frame it
produces is an ordinary frame with no flag set and no decoder change - but on
this implementation it is not a compression win. Treat it as a no-op unless you
have measured otherwise on your own data.

## What is still verified here

- A frame produced with the option round trips byte for byte.
- The frame is an ordinary frame: `getFrameHeader` reports a normal window and no
  dictionary, and any conforming Zstandard decoder reads it.
- The same options through a reusable `Compressor` produce byte-identical output
  to the one-shot path, so the option does not introduce hidden per-call state.

## API used

| Option | Default | Meaning |
|---|---|---|
| `longDistanceMatching` | `false` | Enable the second finder |
| `ldmHashLog` | derived from level | `2^n` entries in the long-distance table |
| `ldmBucketSizeLog` | derived | `2^n` candidates per bucket |
| `ldmMinMatch` | derived | Minimum bytes for a long match |
| `ldmHashRateLog` | derived from level | Average gap between split points, `2^n` bytes |

`Compressor.setLongDistanceMatching(bool)` is the same switch on a reusable
context.

Run:

```bash
zig build run-long_distance_matching
```
