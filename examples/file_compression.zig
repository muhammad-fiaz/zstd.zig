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

    // Step 1: Single file compression & decompression
    // Step 1a: Write sample input file
    try cwd.writeFile(io, .{
        .sub_path = inputPath,
        .data = sampleText,
        .flags = .{ .truncate = true },
    });
    std.debug.print("1. Created source file '{s}' ({d} bytes)\n", .{ inputPath, sampleText.len });

    // Step 1b: Read input file, compress with zstd, write to .zst archive
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

    // Step 1c: Read .zst archive, decompress with zstd, write to restored file
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

        // Verify bit-for-bit match
        std.debug.assert(std.mem.eql(u8, sampleText, decompressedData));
        std.debug.print("4. Verified restored file matches original exactly!\n", .{});
    }

    // Clean up single files
    for ([_][]const u8{ inputPath, compressedPath, decompressedPath }) |path| {
        cwd.deleteFile(io, path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }

    // Step 2: Directory compression & decompression workflow
    std.debug.print("\n--- Directory Compression & Decompression ---\n", .{});

    const dirFiles = [_]struct { relPath: []const u8, content: []const u8 }{
        .{ .relPath = "config.json", .content = "{\n  \"service\": \"zstd-service\",\n  \"enabled\": true,\n  \"level\": 3\n}\n" },
        .{ .relPath = "metrics.log", .content = "2026-10-04T00:00:00Z INFO Server started successfully.\n2026-10-04T00:00:01Z DEBUG Ready.\n" },
        .{ .relPath = "payload.txt", .content = "Repeated block data: AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKKKLLLLMMMMNNNNOOOOPPPPQQQQRRRRSSSSTTTT\n" },
    };

    const srcDir = "example_src_dir";
    const compDir = "example_comp_dir";
    const restDir = "example_rest_dir";

    // Setup source directory
    try cwd.createDirPath(io, srcDir);
    try cwd.createDirPath(io, compDir);
    try cwd.createDirPath(io, restDir);

    for (dirFiles) |item| {
        const fullSrcPath = try std.fs.path.join(allocator, &.{ srcDir, item.relPath });
        defer allocator.free(fullSrcPath);
        try cwd.writeFile(io, .{ .sub_path = fullSrcPath, .data = item.content, .flags = .{ .truncate = true } });
    }
    std.debug.print("1. Created directory '{s}' with {d} source files\n", .{ srcDir, dirFiles.len });

    // Compress directory files
    for (dirFiles) |item| {
        const fullSrcPath = try std.fs.path.join(allocator, &.{ srcDir, item.relPath });
        defer allocator.free(fullSrcPath);

        const fullCompName = try std.fmt.allocPrint(allocator, "{s}.zst", .{item.relPath});
        defer allocator.free(fullCompName);
        const fullCompPath = try std.fs.path.join(allocator, &.{ compDir, fullCompName });
        defer allocator.free(fullCompPath);

        var inFile = try cwd.openFile(io, fullSrcPath, .{});
        defer inFile.close(io);
        const stat = try inFile.stat(io);
        const buf = try allocator.alloc(u8, @as(usize, @intCast(stat.size)));
        defer allocator.free(buf);
        _ = try inFile.readPositionalAll(io, buf, 0);

        const compBytes = try zstd.compress(allocator, buf);
        defer allocator.free(compBytes);

        try cwd.writeFile(io, .{ .sub_path = fullCompPath, .data = compBytes, .flags = .{ .truncate = true } });
        std.debug.print("2. Compressed '{s}' ({d} B) -> '{s}' ({d} B)\n", .{
            item.relPath,
            buf.len,
            fullCompName,
            compBytes.len,
        });
    }

    // Decompress directory files into restored directory
    for (dirFiles) |item| {
        const fullCompName = try std.fmt.allocPrint(allocator, "{s}.zst", .{item.relPath});
        defer allocator.free(fullCompName);
        const fullCompPath = try std.fs.path.join(allocator, &.{ compDir, fullCompName });
        defer allocator.free(fullCompPath);

        const fullRestPath = try std.fs.path.join(allocator, &.{ restDir, item.relPath });
        defer allocator.free(fullRestPath);

        var cFile = try cwd.openFile(io, fullCompPath, .{});
        defer cFile.close(io);
        const stat = try cFile.stat(io);
        const compBuf = try allocator.alloc(u8, @as(usize, @intCast(stat.size)));
        defer allocator.free(compBuf);
        _ = try cFile.readPositionalAll(io, compBuf, 0);

        const decompBytes = try zstd.decompress(allocator, compBuf);
        defer allocator.free(decompBytes);

        try cwd.writeFile(io, .{ .sub_path = fullRestPath, .data = decompBytes, .flags = .{ .truncate = true } });
        std.debug.assert(std.mem.eql(u8, item.content, decompBytes));
        std.debug.print("3. Restored & verified '{s}' ({d} B) bit-for-bit\n", .{ item.relPath, decompBytes.len });
    }
    std.debug.print("4. Verified all directory files round-tripped successfully!\n", .{});

    // Cleanup scratch directory files
    for (dirFiles) |item| {
        const p1 = try std.fs.path.join(allocator, &.{ srcDir, item.relPath });
        defer allocator.free(p1);
        cwd.deleteFile(io, p1) catch {};

        const fullCompName = try std.fmt.allocPrint(allocator, "{s}.zst", .{item.relPath});
        defer allocator.free(fullCompName);
        const p2 = try std.fs.path.join(allocator, &.{ compDir, fullCompName });
        defer allocator.free(p2);
        cwd.deleteFile(io, p2) catch {};

        const p3 = try std.fs.path.join(allocator, &.{ restDir, item.relPath });
        defer allocator.free(p3);
        cwd.deleteFile(io, p3) catch {};
    }
    cwd.deleteDir(io, srcDir) catch {};
    cwd.deleteDir(io, compDir) catch {};
    cwd.deleteDir(io, restDir) catch {};
}
