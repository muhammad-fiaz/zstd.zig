//! Sizing a compression buffer with `compressBound`.
//!
//! `compressBound` is a worst-case guarantee rather than an estimate: a buffer of
//! exactly the reported size holds the frame for any input of that length, at any
//! level. That is what makes it safe to allocate once and reuse.
//!
//! Run with: `zig build run-frame-iterator` style targets; see build.zig for the
//! per-example step names.

const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // The bound is a function of the input size alone, so it can be computed
    // before any data exists - which is the point when sizing a fixed buffer.
    const sizes = [_]usize{ 0, 1, 1024, 64 * 1024, 1024 * 1024 };

    for (sizes) |size| {
        const payload = try allocator.alloc(u8, size);
        defer allocator.free(payload);
        // Content that resists compression, since that is the worst case the
        // bound has to cover.
        var prng = std.Random.DefaultPrng.init(@intCast(size +% 1));
        prng.random().bytes(payload);

        const bound = try zstd.compressBound(size);
        const buf = try allocator.alloc(u8, bound);
        defer allocator.free(buf);

        const written = try zstd.compressInto(allocator, buf, payload, 19);
        std.debug.print("size {d:>8}: bound {d:>8}, wrote {d:>8}\n", .{ size, bound, written });

        // The bound is a guarantee, so a decode into the original size must
        // return exactly the input.
        const back = try zstd.decompressInto(allocator, payload, buf[0..written]);
        if (back != size) {
            std.debug.print("  round trip returned {d} bytes, expected {d}\n", .{ back, size });
            return error.RoundTripFailed;
        }
    }

    // A bound is not a suggestion: a buffer one byte short is reported rather than
    // silently producing a partial frame.
    const bound = try zstd.compressBound(4096);
    const short_buf = try allocator.alloc(u8, bound - 1);
    defer allocator.free(short_buf);
    const small = try allocator.alloc(u8, 4096);
    defer allocator.free(small);
    @memset(small, 'a');

    if (zstd.compressInto(allocator, short_buf, small, 3)) |_| {
        std.debug.print("a short buffer should not have been accepted\n", .{});
        return error.ShortBufferAccepted;
    } else |e| {
        std.debug.print("short buffer rejected as {s}, as documented\n", .{@errorName(e)});
    }
}
