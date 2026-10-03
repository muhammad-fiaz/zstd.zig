//! Bounding how much window a decoder will accept.
//!
//! Every Zstandard frame header states the window its compressor used. Honouring
//! that blindly would let a hostile header demand an enormous buffer, so a decoder
//! takes a limit and refuses anything above it. This example shows the limit being
//! applied per frame, so a stream cannot smuggle an oversized frame in behind a
//! small one.

const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Two frames with genuinely different windows. The content is sized so the
    // encoder has to use a large window for the second one.
    const small = try zstd.compressWithOptions(allocator, "a small frame", .{ .windowLog = 10 });
    defer allocator.free(small);

    var payload: [200_000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(4242);
    for (&payload) |*b| b.* = if (prng.random().boolean()) 'a' else 'b';
    const large = try zstd.compressWithOptions(allocator, &payload, .{ .windowLog = 18 });
    defer allocator.free(large);

    // A frame header reports its window as a 64-bit field, while the limit is
    // given in the target's own integer type, so the value is narrowed here.
    const small_window: usize = @intCast((try zstd.inspectFrame(allocator, small)).header.windowSize);
    const large_window: usize = @intCast((try zstd.inspectFrame(allocator, large)).header.windowSize);
    std.debug.print("small frame declares a {d} byte window\n", .{small_window});
    std.debug.print("large frame declares a {d} byte window\n", .{large_window});

    // The limit is a ceiling, so the frame's own window and anything above it are
    // fine.
    try tryLimit(allocator, small, small_window, true);
    try tryLimit(allocator, small, small_window + 1, true);
    // One byte below what the frame needs is refused: there is no slack.
    try tryLimit(allocator, small, small_window - 1, false);
    try tryLimit(allocator, small, 0, false);

    // Concatenated frames are checked one at a time, so a large frame after a
    // small one is still refused.
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);
    try joined.appendSlice(allocator, small);
    try joined.appendSlice(allocator, large);
    try tryLimit(allocator, joined.items, small_window + 1, false);
    try tryLimit(allocator, joined.items, large_window, true);

    // Streaming enforces the same rule through the same mechanism.
    var sd = zstd.StreamingDecompressor.init(allocator);
    defer sd.deinit();
    sd.setMaxWindowSize(large_window);
    var out_buf2: [8192]u8 = undefined;
    const r = try sd.decompressStream(&out_buf2, large);
    std.debug.print("streaming with a matching limit accepted {d} bytes\n", .{r.outProduced});

    var tight = zstd.StreamingDecompressor.init(allocator);
    defer tight.deinit();
    tight.setMaxWindowSize(small_window);
    if (tight.decompressStream(&out_buf2, large)) |_| {
        std.debug.print("streaming should have refused the oversized frame\n", .{});
        return error.LimitNotEnforced;
    } else |e| {
        std.debug.print("streaming refused it as {s}\n", .{@errorName(e)});
    }
}

fn tryLimit(
    allocator: std.mem.Allocator,
    src: []const u8,
    limit: usize,
    expect_ok: bool,
) !void {
    const outcome = zstd.decompressWithOptions(allocator, src, .{ .maxWindowSize = limit });
    if (outcome) |out| {
        defer allocator.free(out);
        if (!expect_ok) {
            std.debug.print("limit {d}: accepted {d} bytes, expected a refusal\n", .{ limit, out.len });
            return error.LimitNotEnforced;
        }
        std.debug.print("limit {d}: accepted, {d} bytes\n", .{ limit, out.len });
    } else |e| {
        if (expect_ok) return e;
        std.debug.print("limit {d}: refused as {s}\n", .{ limit, @errorName(e) });
    }
}
