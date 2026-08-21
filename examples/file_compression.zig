const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const sample_text =
        \\Zstandard (zstd) is a fast, lossless compression algorithm, targeting
        \\real-time compression scenarios at zlib-level and better compression ratios.
        \\It is backed by a very fast entropy stage, provided by Huff0 and FSE library.
        \\
        \\This file compression example demonstrates:
        \\1. Creating a source text file
        \\2. Reading and compressing the file content with zstd
        \\3. Writing the compressed data to a .zst archive file
        \\4. Reading the .zst archive file and decompressing it
        \\5. Verifying the decompressed file matches original bit-for-bit
        \\
    ;


    std.debug.print("1. Created source buffer ({d} bytes)\n", .{sample_text.len});

    // Step 2 & 3: Compress with zstd (simulating write to .zst archive)
    const compressed_data = try zstd.compress(allocator, sample_text);
    defer allocator.free(compressed_data);

    std.debug.print("2. Compressed buffer -> archive ({d} -> {d} bytes, ratio: {d:.2}%)\n", .{
        sample_text.len,
        compressed_data.len,
        @as(f64, @floatFromInt(compressed_data.len)) / @as(f64, @floatFromInt(sample_text.len)) * 100.0,
    });

    // Step 4: Decompress (simulating read from .zst archive)
    const decompressed_data = try zstd.decompress(allocator, compressed_data);
    defer allocator.free(decompressed_data);

    std.debug.print("3. Decompressed archive -> buffer ({d} bytes)\n", .{decompressed_data.len});

    // Step 5: Verify bit-for-bit match
    std.debug.assert(std.mem.eql(u8, sample_text, decompressed_data));
    std.debug.print("4. Verified restored buffer matches original exactly!\n", .{});
}
