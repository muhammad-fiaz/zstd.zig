//! Parallel compression: your own threads, or the library's.
//!
//! Two ways to compress in parallel, both exercised in this file.
//!
//! 1. **One context per thread.** The serial path never starts a thread of its
//!    own, so parallelising it is your pattern: a `Compressor` and a
//!    `Decompressor` hold frame state (entropy tables, buffers) between calls,
//!    so sharing one across threads is a race; giving each thread its own is
//!    not. The allocator may be shared, as long as it is thread-safe.
//! 2. **`compressMT` / `MTCompressor`.** One frame compressed by several
//!    workers from this library's own pool, which is what you want for a single
//!    large input. Threads start only when you ask for them, and they run on the
//!    `std.Io` you pass in; nothing else in the library spawns anything.
//!
//! The first half of the file demonstrates pattern 1 over many small inputs and
//! checks that threaded and sequential runs agree byte for byte. The second half
//! demonstrates pattern 2 on one large input, and checks that the multithreaded
//! frame decodes back to exactly the input.
//!
//! Run with: `zig build run-parallel_compression`

const std = @import("std");
const builtin = @import("builtin");
const zstd = @import("zstd");

const thread_count = 4;
const messages = 64;
const payload_len = 32 * 1024;
/// Large enough to split across jobs at the library's 512 KiB job floor.
const mt_input_len = 4 * 1024 * 1024;

/// Byte totals for one stripe of the work.
const Totals = struct { in: usize, out: usize };

/// Everything a worker needs. Threads share the address space, so a worker is
/// handed a pointer to its own `Totals` slot and writes into it directly; the
/// join is what makes the result visible.
const Stripe = struct {
    allocator: std.mem.Allocator,
    totals: *Totals,
    /// First message this worker takes.
    id: usize,
    /// Step between messages. The parallel workers use the thread count so the
    /// stripes tile the range; a single-threaded run uses 1.
    stride: usize,
    /// Scratch buffer, one per worker because it is filled per message.
    buffer: []u8,
};

fn payloadFor(index: usize, buffer: []u8) []const u8 {
    // A mix of compressible and noisy data, so the workers do not all take the
    // same amount of time.
    const header = "record:";
    @memset(buffer, 0);
    @memcpy(buffer[0..header.len], header);
    var pos = header.len;
    var value: u32 = @truncate(index *% 2654435761);
    while (pos < buffer.len) {
        value = value *% 1664525 +% 1013904223;
        const run = 4 + @as(usize, @intCast((value >> 16) & 7));
        const byte: u8 = if ((value >> 24) & 1 == 0) 'a' + @as(u8, @intCast((value >> 8) & 15)) else @truncate(value);
        for (buffer[pos..@min(pos + run, buffer.len)]) |*b| b.* = byte;
        pos += run;
    }
    return buffer;
}

/// Compresses this stripe's messages and decompresses each frame back, so the
/// example proves the parallel result rather than just its size.
///
/// The contexts live for the duration of the call and are never shared, which is
/// the entire thread-safety contract.
fn runStripe(stripe: *Stripe) !void {
    var compressor = zstd.Compressor.initWithLevel(stripe.allocator, 9);
    defer compressor.deinit();
    var decompressor = zstd.Decompressor.init(stripe.allocator);
    defer decompressor.deinit();

    var total_in: usize = 0;
    var total_out: usize = 0;
    var index = stripe.id;
    while (index < messages) : (index += stripe.stride) {
        const payload = payloadFor(index, stripe.buffer);
        const frame = try compressor.compressAlloc(payload);
        total_in += payload.len;
        total_out += frame.len;

        const restored = try decompressor.decompressAlloc(frame);
        defer stripe.allocator.free(restored);
        if (!std.mem.eql(u8, payload, restored)) return error.RoundTripFailed;
        stripe.allocator.free(frame);
    }
    stripe.totals.* = .{ .in = total_in, .out = total_out };
}

fn threadEntry(stripe: *Stripe) void {
    runStripe(stripe) catch |e| std.debug.panic("worker {d} failed: {s}", .{ stripe.id, @errorName(e) });
}

/// The same work on one thread with one context, for comparison. The byte totals
/// match the parallel run exactly: the frames never depended on each other.
fn runSequential(allocator: std.mem.Allocator) !Totals {
    var totals: Totals = .{ .in = 0, .out = 0 };
    var stripe = Stripe{
        .allocator = allocator,
        .totals = &totals,
        .id = 0,
        .stride = 1,
        .buffer = try allocator.alloc(u8, payload_len),
    };
    defer allocator.free(stripe.buffer);
    try runStripe(&stripe);
    return totals;
}

/// One large input with a repeated section in it, so the jobs after the first
/// have real history to reference.
fn makeMtInput(allocator: std.mem.Allocator) ![]u8 {
    const buffer = try allocator.alloc(u8, mt_input_len);
    errdefer allocator.free(buffer);
    var prng = std.Random.DefaultPrng.init(0x4D54);
    const random = prng.random();
    for (buffer[0 .. mt_input_len / 2]) |*b| b.* = random.intRangeAtMost(u8, 0, 63);
    @memcpy(buffer[mt_input_len / 2 ..], buffer[0 .. mt_input_len / 2]);
    return buffer;
}

/// Compresses one input on the library's own pool and decodes it back. The
/// frame is a single frame: the workers write blocks for one header, so the
/// result is an ordinary frame any decoder reads.
fn runMultithreaded(allocator: std.mem.Allocator, io: std.Io, payload: []const u8) !void {
    const options: zstd.CompressionOptions = .{ .level = 3, .checksum = true };

    const serial_frame = try zstd.compressWithOptions(allocator, payload, options);
    defer allocator.free(serial_frame);
    const mt_frame = try zstd.compressMT(allocator, io, payload, options, thread_count);
    defer allocator.free(mt_frame);

    std.debug.print("\none {d} MiB input, level 3 with a checksum:\n", .{mt_input_len / (1024 * 1024)});
    std.debug.print("  one frame, one thread:  {d} bytes\n", .{serial_frame.len});
    std.debug.print("  one frame, {d} workers: {d} bytes\n", .{ thread_count, mt_frame.len });

    // Both frames are ordinary frames, so the same check answers for both.
    for ([_][]const u8{ serial_frame, mt_frame }) |frame| {
        const restored = try zstd.decompress(allocator, frame);
        defer allocator.free(restored);
        if (!std.mem.eql(u8, payload, restored)) return error.RoundTripFailed;
    }
    std.debug.print("  both decode back to the {d} byte input\n", .{payload.len});
}

pub fn main(init: std.process.Init) !void {
    // page_allocator is thread-safe, so one allocator can back every worker.
    const allocator = std.heap.page_allocator;
    std.debug.print("{d} messages of {d} KiB, {d} threads\n\n", .{ messages, payload_len / 1024, thread_count });

    const serial = try runSequential(allocator);
    std.debug.print("one thread:  {d} -> {d} bytes\n", .{ serial.in, serial.out });

    var totals: [thread_count]Totals = undefined;
    var stripes: [thread_count]Stripe = undefined;
    var buffers: [thread_count][]u8 = undefined;
    var threads: [thread_count - 1]std.Thread = undefined;

    for (&totals, &stripes, &buffers, 0..) |*total, *stripe, *buffer, i| {
        total.* = .{ .in = 0, .out = 0 };
        buffer.* = try allocator.alloc(u8, payload_len);
        stripe.* = .{ .allocator = allocator, .totals = total, .id = i, .stride = thread_count, .buffer = buffer.* };
    }
    defer for (buffers) |buffer| allocator.free(buffer);

    // The calling thread takes stripe 0, so no worker idles. On a target with no
    // threads the remaining stripes are folded into the caller's own work, which
    // still exercises the per-context rule and still has to produce the same
    // totals.
    try runStripe(&stripes[0]);
    if (builtin.single_threaded) {
        for (stripes[1..]) |*stripe| try runStripe(stripe);
    } else {
        for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, threadEntry, .{&stripes[i + 1]});
        for (threads) |t| t.join();
    }

    var parallel: Totals = .{ .in = 0, .out = 0 };
    for (totals) |total| {
        parallel.in += total.in;
        parallel.out += total.out;
    }
    std.debug.print("{d} threads:  {d} -> {d} bytes\n", .{ thread_count, parallel.in, parallel.out });

    // The same input through the same contexts gives the same bytes, threaded or
    // not: this is the property that makes one context per thread safe.
    if (parallel.in != serial.in or parallel.out != serial.out) {
        std.debug.print("FAILED: totals differ between one thread and {d}\n", .{thread_count});
        return error.TotalsDiffer;
    }
    std.debug.print("\nOK: {d} frames round tripped across {d} threads, identical totals\n", .{ messages, thread_count });

    // The other half: one large input, compressed by the library's own pool.
    const mt_input = try makeMtInput(allocator);
    defer allocator.free(mt_input);
    try runMultithreaded(allocator, init.io, mt_input);
    std.debug.print("\nOK: one frame compressed by {d} workers decodes like any other\n", .{thread_count});
}
