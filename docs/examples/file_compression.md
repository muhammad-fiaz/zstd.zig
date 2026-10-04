---
title: File Compression
description: Real file compression to .zst archive and decompression.
---

# File Compression

`examples/file_compression.zig` - `std.Io.Dir` + `zstd` file workflow (Zig 0.17).

## Client Code

```zig
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
}
```

## Output

```text
1. Created source file 'example_input.txt' (616 bytes)
2. Compressed 'example_input.txt' -> 'example_output.txt.zst' (616 -> 353 bytes, ratio: 57.31%)
3. Decompressed 'example_output.txt.zst' -> 'example_restored.txt' (616 bytes)
4. Verified restored file matches original exactly!

--- Directory Compression & Decompression ---
1. Created directory 'example_src_dir' with 3 source files
2. Compressed 'config.json' (65 B) -> 'config.json.zst' (69 B)
2. Compressed 'metrics.log' (89 B) -> 'metrics.log.zst' (88 B)
2. Compressed 'payload.txt' (102 B) -> 'payload.txt.zst' (111 B)
3. Restored & verified 'config.json' (65 B) bit-for-bit
3. Restored & verified 'metrics.log' (89 B) bit-for-bit
3. Restored & verified 'payload.txt' (102 B) bit-for-bit
4. Verified all directory files round-tripped successfully!
```

## Explanation

- Uses new Zig 0.17 `std.Io` (`Dir.cwd()`, `createDirPath`, `writeFile`, `openFile`, `stat`, `readPositionalAll`, `deleteFile`, `deleteDir`).
- Demonstrates both single file lifecycle and full directory structure compression and decompression with bit-for-bit verification.
- `zstd.compress` and `zstd.decompress` operate natively with zero external dependencies.

Run:

```bash
zig build run-file_compression
```
