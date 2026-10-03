//! Streaming decompression: input arrives in pieces, output leaves in pieces.
//!
//! The pattern is the one `ZSTD_decompressStream` uses. Feed whatever input you
//! have and let the decompressor write what it can into whatever output room
//! you give it; then ask again, with no new input, for as long as it keeps
//! producing bytes. Nothing here needs an output buffer as large as the frame.
//!
//! Run with: `zig build run-streaming_decompression`

const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var original: std.ArrayList(u8) = .empty;
    defer original.deinit(allocator);
    for (0..200) |_| try original.appendSlice(allocator, "Streaming decompression handles partial input and output buffers with backpressure. ");

    const compressed = try zstd.compress(allocator, original.items);
    defer allocator.free(compressed);

    var dstream = zstd.StreamingDecompressor.init(allocator);
    defer dstream.deinit();

    // A deliberately small output window: the decompressor decodes a block into
    // its own buffer and hands the bytes over in whatever pieces fit.
    var window: [1024]u8 = undefined;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    const chunkSize: usize = 64;
    var inPos: usize = 0;
    while (true) {
        const chunk = if (inPos < compressed.len) compressed[inPos..@min(inPos + chunkSize, compressed.len)] else compressed[compressed.len..];
        const res = try dstream.decompressStream(&window, chunk);
        inPos += res.inConsumed;
        try out.appendSlice(allocator, window[0..res.outProduced]);
        if (res.outProduced == 0 and inPos >= compressed.len) break;
    }

    std.debug.print("Stream decompressed {d} bytes from {d} bytes of input\n", .{ out.items.len, compressed.len });
    if (!std.mem.eql(u8, original.items, out.items)) {
        std.debug.print("FAILED: streamed output differs from the original\n", .{});
        return error.RoundTripFailed;
    }
    std.debug.print("Verified streaming decompression\n", .{});
}
