//! Walking the frames in a buffer with `FrameIterator`.
//!
//! A Zstandard stream is a sequence of frames, and each may be a regular frame or
//! a skippable frame holding opaque bytes. This example builds a stream with both
//! kinds in it, then walks it reporting each frame's boundaries - which is what a
//! caller needs to split a file into frames, report per-frame metadata, or skip
//! the parts that are not compressed data.

const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Build a stream: skippable, regular, skippable, regular.
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);

    try appendSkippable(allocator, &stream, "metadata written by some tool");

    const first = "the first frame, with enough text to be worth compressing at all";
    const first_frame = try zstd.compress(allocator, first);
    defer allocator.free(first_frame);
    try stream.appendSlice(allocator, first_frame);

    try appendSkippable(allocator, &stream, "");

    const second = "the second frame, also compressible, and a different length entirely";
    const second_frame = try zstd.compress(allocator, second);
    defer allocator.free(second_frame);
    try stream.appendSlice(allocator, second_frame);

    // Walk it. The iterator borrows the buffer and copies nothing, so the views
    // it hands back are valid as long as `stream` is.
    var it = zstd.FrameIterator.init(stream.items);
    var frame_index: usize = 0;
    while (try it.next()) |frame| {
        if (frame.isSkippable()) {
            std.debug.print(
                "frame {d}: skippable at offset {d}, {d} bytes total, payload {d} bytes\n",
                .{ frame_index, frame.offset, frame.totalSize, frame.payloadBytes.len },
            );
        } else {
            const text = try zstd.decompress(allocator, frame.bytes());
            defer allocator.free(text);
            std.debug.print(
                "frame {d}: regular at offset {d}, {d} bytes total, header {d}, window {d}, content {d} bytes\n",
                .{
                    frame_index,
                    frame.offset,
                    frame.totalSize,
                    frame.headerSize,
                    frame.windowSize,
                    text.len,
                },
            );
            std.debug.print("         {s}\n", .{text});
        }
        frame_index += 1;
    }

    std.debug.print("{d} frames, {d} bytes consumed of {d}\n", .{ frame_index, it.offset(), stream.items.len });

    // A truncated tail is reported rather than yielded, because a caller would
    // otherwise start decoding at the wrong offset.
    const truncated = stream.items[0 .. stream.items.len - 5];
    var partial = zstd.FrameIterator.init(truncated);
    var walked: usize = 0;
    while (true) {
        const step = partial.next() catch null;
        if (step == null) break;
        walked += 1;
    }
    std.debug.print("truncated input: {d} complete frames before the error\n", .{walked});
}

fn appendSkippable(allocator: std.mem.Allocator, stream: *std.ArrayList(u8), payload: []const u8) !void {
    var header: [8]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], 0x184D2A50, .little);
    std.mem.writeInt(u32, header[4..8], @intCast(payload.len), .little);
    try stream.appendSlice(allocator, &header);
    try stream.appendSlice(allocator, payload);
}
