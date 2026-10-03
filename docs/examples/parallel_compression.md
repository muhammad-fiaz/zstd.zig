---
title: Parallel Compression
description: One context per thread for many inputs, or the library's own worker pool for one large input.
---

# Parallel Compression

`examples/parallel_compression.zig`

There are two ways to compress in parallel, and the example does both.

1. **One context per thread.** The serial path (`Compressor`, `Decompressor`)
   never starts a thread of its own, so parallelising it is your pattern. A
   `Compressor` and a `Decompressor` hold frame state (entropy tables, buffers)
   between calls, so sharing one across threads is a race; giving each thread
   its own is not. The allocator may be shared, as long as it is thread-safe  - 
   `std.heap.page_allocator` is used here for exactly that reason.

2. **`compressMT` / `MTCompressor`.** One frame compressed by several workers
   from the library's own pool (`zstd.pool`). This is the one you want for a
   single large input. The frame is split into jobs, each job encodes a segment
   seeded with the frame content just before it, and the finished result is one
   ordinary frame with one header. Threads start only when you ask for them, and
   they use the `std.Io` you pass in.

## Output

```text
64 messages of 32 KiB, 4 threads

one thread:  2097152 -> 1389519 bytes
4 threads:  2097152 -> 1389519 bytes

OK: 64 frames round tripped across 4 threads, identical totals

one 4 MiB input, level 3 with a checksum:
  one frame, one thread:  3149446 bytes
  one frame, 4 workers:  3149677 bytes
  both decode back to the 4194304 byte input

OK: one frame compressed by 4 workers decodes like any other
```

## Source shape

One context per thread, many inputs:

```zig
const thread_count = 4;
var totals: [thread_count]Totals = undefined;
var stripes: [thread_count]Stripe = undefined;
var threads: [thread_count - 1]std.Thread = undefined;

for (&totals, &stripes, 0..) |*total, *stripe, i| {
    total.* = .{ .in = 0, .out = 0 };
    // Each worker gets its own contexts. Sharing one would be the race.
    stripe.* = .{ .allocator = allocator, .totals = total, .id = i, .stride = thread_count };
}

// The calling thread takes stripe 0, so no worker idles.
try runStripe(&stripes[0]);
for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, threadEntry, .{&stripes[i + 1]});
for (threads) |t| t.join();
```

One input, the library's workers:

```zig
// A single call: the pool starts the workers, splits the frame, and is joined
// again before this returns.
const frame = try zstd.compressMT(allocator, init.io, payload, .{ .level = 3 }, thread_count);
defer allocator.free(frame);

// Or keep the compressor for many frames: its pool is created once and reused.
var mt = try zstd.MTCompressor.init(allocator, init.io, .{ .level = 3 }, thread_count);
defer mt.deinit();
const again = try mt.compressAlloc(payload);
defer allocator.free(again);
```

## Notes

- **The identical totals are the point.** One thread and four produce the same
  1,389,519 bytes. Partitioning the work must not change the output, and the
  equality check at the end enforces that rather than assuming it.
- **The calling thread does one stripe itself**, so `thread_count` workers cost
  `thread_count - 1` spawned threads.
- **`stride` makes the stripes tile the range.** Worker `i` takes messages `i`,
  `i + 4`, `i + 8`… so every message is compressed exactly once, and each worker's
  totals accumulate into its own slot. Threads share the address space, so a
  worker writes directly into its own `Totals`; the join is what makes the result
  visible.
- **Each worker decompresses what it compressed** and compares against the
  original, so a context shared by mistake would show up as a mismatch or a
  failure rather than passing silently.
- **The multithreaded frame is a normal frame.** Nothing about it needs a
  multithreaded decoder: one header, a checksum over the whole input, and blocks
  in order. The example decodes both frames with the ordinary `decompress` and
  compares against the input.
- **The two frame sizes differ slightly** (3,149,446 against 3,149,677 bytes).
  Jobs start with no repeat history of their own, so a job cannot reuse the
  cheapest kind of match against a block another job encoded; that is a few
  dozen bytes on a 4 MiB input and is the price of splitting the frame.
- On a target with no threads (`builtin.single_threaded`), the remaining stripes
  are folded into the caller's own work. The per-context rule still holds and the
  totals are unchanged.

Run:

```bash
zig build run-parallel_compression
```
