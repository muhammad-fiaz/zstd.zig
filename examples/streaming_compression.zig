//! Streaming compression: blocks leave as the input arrives, and the frame is
//! finished with `.end`.
//!
//! Two rules make it work. First, a `.flush` or `.end` call needs output room
//! for at least one block (a block is at most 128 KiB), and if it does not get
//! it the frame stays open: the call reports `remaining` and the caller repeats
//! it with a bigger buffer. Second, a `.cont` call never stalls - whatever does
//! not fit stays buffered and goes out on a later call.
//!
//! Run with: `zig build run-streaming_compression`

const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const line = "Streaming compression processes data incrementally, without buffering all of it at once. ";
    var cstream = try zstd.StreamingCompressor.init(allocator, 5);
    defer cstream.deinit();

    // Room for a couple of blocks, not the whole stream: the loop below has to
    // come back for the rest.
    var outBuf: [1 << 17]u8 = undefined;
    var frame = std.ArrayList(u8).empty;
    defer frame.deinit(allocator);

    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(allocator);

    var produced_early = false;
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        try expected.appendSlice(allocator, line);
        const res = try cstream.compressStream(&outBuf, line, .cont);
        try frame.appendSlice(allocator, outBuf[0..res.outProduced]);
        if (i == 100) {
            std.debug.print("after {d} lines: {d} compressed bytes, {d} still buffered\n", .{ i + 1, frame.items.len, res.remaining });
            produced_early = frame.items.len > 0;
        }
    }
    if (!produced_early) {
        std.debug.print("FAILED: nothing was emitted while the stream was open\n", .{});
        return error.NotIncremental;
    }

    // Finish the frame. Each call emits what fits; a non-zero `remaining` means
    // call again.
    var calls: usize = 0;
    while (true) : (calls += 1) {
        const res = try cstream.compressStream(&outBuf, "", .end);
        try frame.appendSlice(allocator, outBuf[0..res.outProduced]);
        if (res.remaining == 0) break;
        if (calls > 1000) return error.TooManyCalls;
    }
    std.debug.print("frame finished across {d} final calls: {d} -> {d} bytes\n", .{ calls + 1, expected.items.len, frame.items.len });

    const restored = try zstd.decompress(allocator, frame.items);
    defer allocator.free(restored);
    if (!std.mem.eql(u8, expected.items, restored)) {
        std.debug.print("FAILED: round trip differs\n", .{});
        return error.RoundTripFailed;
    }
    std.debug.print("Verified streaming compression\n", .{});
}
