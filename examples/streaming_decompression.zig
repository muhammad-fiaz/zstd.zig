const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const original = "Streaming decompression handles partial input and output buffers with backpressure. " ** 10;
    const compressed = try zstd.compress(allocator, original);
    defer allocator.free(compressed);
    var dstream = zstd.StreamingDecompressor.init(allocator);
    defer dstream.deinit();
    var out: [1 << 16]u8 = undefined;
    var out_pos: usize = 0;
    var in_pos: usize = 0;
    const chunk_size: usize = 64;
    while (in_pos < compressed.len) {
        const chunk = compressed[in_pos..@min(in_pos + chunk_size, compressed.len)];
        const res = try dstream.decompressStream(out[out_pos..], chunk);
        in_pos += res.in_consumed;
        out_pos += res.out_produced;
        if (res.needs_more and in_pos >= compressed.len) break;
    }
    std.debug.print("Stream decompressed {d} bytes\n", .{out_pos});
    std.debug.assert(std.mem.eql(u8, original, out[0..out_pos]));
    std.debug.print("Verified streaming decompression\n", .{});
}
