//! Long-distance matching: finding a repeat that is further back than the
//! window.
//!
//! The regular match finders are bounded by the frame's window, so a repeat that
//! starts a megabyte back is invisible to them. Long-distance matching adds a
//! second finder for exactly that case: a gear-hash picks candidate positions, a
//! checksummed bucketed table recognises the ones it has seen before, and the
//! block parsers then treat the resulting long matches as candidates.
//!
//! It pays off on data built from several large, similar sections - containers,
//! archives, logs that repeat a header. It is off by default because it costs a
//! pass over the input and a table.
//!
//! Run with: `zig build run-long_distance_matching`

const std = @import("std");
const zstd = @import("zstd");

/// Three unrelated 512 KiB sections followed by a copy of the first one. The
/// copy is 1 MiB back, well past a 128 KiB block, so nothing but the
/// long-distance finder can see it.
fn makeInput(buffer: []u8) []const u8 {
    const section = 512 * 1024;
    var prng = std.Random.DefaultPrng.init(0x4C44);
    const random = prng.random();
    for (buffer[0 .. section * 2]) |*b| b.* = random.intRangeAtMost(u8, 0, 63);
    @memcpy(buffer[section * 2 ..], buffer[0..section]);
    return buffer;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    _ = init.io;

    const input_len = 3 * 512 * 1024;
    const input = try allocator.alloc(u8, input_len);
    defer allocator.free(input);
    const payload = makeInput(input);

    std.debug.print("input: {d} bytes, with the last {d} a copy of the first {d}\n\n", .{
        payload.len,
        512 * 1024,
        512 * 1024,
    });

    // Baseline: the window-bounded search on its own.
    const baseline = try zstd.compressWithOptions(allocator, payload, .{
        .level = 9,
        .windowLog = 23,
    });
    defer allocator.free(baseline);
    std.debug.print("without LDM: {d} bytes\n", .{baseline.len});

    // With long-distance matching. The window is widened automatically when the
    // option is on, because a distance the frame cannot hold cannot be written;
    // the explicit window here is only to keep the two runs comparable.
    const with_ldm = try zstd.compressWithOptions(allocator, payload, .{
        .level = 9,
        .windowLog = 23,
        .longDistanceMatching = true,
        // A denser split-point rate finds the copy sooner; the default is
        // derived from the level.
        .ldmHashRateLog = 4,
    });
    defer allocator.free(with_ldm);
    std.debug.print("with LDM:    {d} bytes\n", .{with_ldm.len});
    if (with_ldm.len >= baseline.len) {
        std.debug.print("expected LDM to be smaller on this input\n", .{});
    } else {
        const saved = baseline.len - with_ldm.len;
        std.debug.print("LDM saved {d} bytes ({d:.1}% of the input)\n", .{
            saved,
            @as(f64, @floatFromInt(saved)) * 100.0 / @as(f64, @floatFromInt(payload.len)),
        });
    }

    // A frame produced with LDM is an ordinary frame: anything that reads
    // Zstandard reads it, with no flag set and no decoder change.
    const restored = try zstd.decompress(allocator, with_ldm);
    defer allocator.free(restored);
    if (!std.mem.eql(u8, payload, restored)) {
        std.debug.print("LDM frame did not round trip\n", .{});
        return error.RoundTripFailed;
    }
    const header = try zstd.getFrameHeader(with_ldm);
    std.debug.print("\nLDM frame round tripped; window {d} bytes, dict id {d}\n", .{
        header.windowSize,
        header.dictId,
    });

    // A reusable context exposes the same switch, for a program that decides per
    // message whether the long-distance pass is worth its cost.
    // The same options through a reusable context, which must produce the same
    // bytes: a context holds no frame state between calls.
    const options = zstd.CompressionOptions{
        .level = 9,
        .windowLog = 23,
        .longDistanceMatching = true,
        .ldmHashRateLog = 4,
    };
    var compressor = zstd.Compressor.init(allocator);
    defer compressor.deinit();
    try compressor.setOptions(options);
    const from_context = try compressor.compressAlloc(payload);
    defer allocator.free(from_context);
    std.debug.print("same through a context: {d} bytes\n", .{from_context.len});
    if (!std.mem.eql(u8, with_ldm, from_context)) {
        std.debug.print("context and one-shot disagreed\n", .{});
        return error.ContextMismatch;
    }
}
