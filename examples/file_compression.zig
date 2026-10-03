const std = @import("std");
const zstd = @import("zstd");
const Dir = std.Io.Dir;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = Dir.cwd();

    const sampleText =
        \\Zstandard (zstd) is a fast, lossless compression algorithm, targeting
        \\real-time compression scenarios at zlib-level and better compression ratios.
        \\It is backed by a very fast entropy stage, provided by Huff0 and FSE library.
        \\
        \\This file compression example demonstrates:
        \\1. Creating and writing a source text file
        \\2. Reading and compressing the file content with zstd
        \\3. Writing the compressed data to a .zst archive file (with overwrite support)
        \\4. Reading the .zst archive file and decompressing it
        \\5. Writing the decompressed data to a restored file
        \\6. Verifying the restored file matches the original bit-for-bit
        \\
    ;

    const inputPath = "example_input.txt";
    const compressedPath = "example_output.txt.zst";
    const decompressedPath = "example_restored.txt";

    // Step 1: Write sample input file
    try cwd.writeFile(io, .{
        .sub_path = inputPath,
        .data = sampleText,
        .flags = .{ .truncate = true },
    });
    std.debug.print("1. Created source file '{s}' ({d} bytes)\n", .{ inputPath, sampleText.len });

    // Step 2 & 3: Read input file, compress with zstd, write to .zst archive
    {
        var inFile = try cwd.openFile(io, inputPath, .{});
        defer inFile.close(io);

        const inStat = try inFile.stat(io);
        const inSize = @as(usize, @intCast(inStat.size));
        const inData = try allocator.alloc(u8, inSize);
        defer allocator.free(inData);

        _ = try inFile.readPositionalAll(io, inData, 0);

        const compressedData = try zstd.compress(allocator, inData);
        defer allocator.free(compressedData);

        try cwd.writeFile(io, .{
            .sub_path = compressedPath,
            .data = compressedData,
            .flags = .{ .truncate = true },
        });

        std.debug.print("2. Compressed '{s}' -> '{s}' ({d} -> {d} bytes, ratio: {d:.2}%)\n", .{
            inputPath,
            compressedPath,
            inData.len,
            compressedData.len,
            @as(f64, @floatFromInt(compressedData.len)) / @as(f64, @floatFromInt(inData.len)) * 100.0,
        });
    }

    // Step 4 & 5: Read .zst archive, decompress with zstd, write to restored file
    {
        var compFile = try cwd.openFile(io, compressedPath, .{});
        defer compFile.close(io);

        const compStat = try compFile.stat(io);
        const compSize = @as(usize, @intCast(compStat.size));
        const compData = try allocator.alloc(u8, compSize);
        defer allocator.free(compData);

        _ = try compFile.readPositionalAll(io, compData, 0);

        const decompressedData = try zstd.decompress(allocator, compData);
        defer allocator.free(decompressedData);

        try cwd.writeFile(io, .{
            .sub_path = decompressedPath,
            .data = decompressedData,
            .flags = .{ .truncate = true },
        });

        std.debug.print("3. Decompressed '{s}' -> '{s}' ({d} bytes)\n", .{
            compressedPath,
            decompressedPath,
            decompressedData.len,
        });

        // Step 6: Verify bit-for-bit match
        std.debug.assert(std.mem.eql(u8, sampleText, decompressedData));
        std.debug.print("4. Verified restored file matches original exactly!\n", .{});
    }

    // The three files above are scratch: the example removes them so running it
    // does not leave anything behind in whatever directory it was started from.
    for ([_][]const u8{ inputPath, compressedPath, decompressedPath }) |path| {
        cwd.deleteFile(io, path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }
}
