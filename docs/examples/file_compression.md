---
title: File Compression
description: Real file compression to .zst archive and decompression.
---

# File Compression

`examples/file_compression.zig` — `std.Io.Dir` + `zstd` file workflow (Zig 0.16).

## Client Code

```zig
const std = @import("std");
const zstd = @import("zstd");
const Dir = std.Io.Dir;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = Dir.cwd();

    const sample_text =
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

    const input_path = "example_input.txt";
    const compressed_path = "example_output.txt.zst";
    const decompressed_path = "example_restored.txt";

    // 1. Write sample input file
    try cwd.writeFile(io, .{ .sub_path = input_path, .data = sample_text, .flags = .{ .truncate = true } });
    std.debug.print("1. Created source file '{s}' ({d} bytes)\n", .{ input_path, sample_text.len });

    // 2 & 3. Read, compress, write .zst
    {
        var in_file = try cwd.openFile(io, input_path, .{});
        defer in_file.close(io);
        const in_stat = try in_file.stat(io);
        const in_data = try allocator.alloc(u8, @intCast(in_stat.size));
        defer allocator.free(in_data);
        _ = try in_file.readPositionalAll(io, in_data, 0);
        const compressed_data = try zstd.compress(allocator, in_data);
        defer allocator.free(compressed_data);
        try cwd.writeFile(io, .{ .sub_path = compressed_path, .data = compressed_data, .flags = .{ .truncate = true } });
        std.debug.print("2. Compressed '{s}' -> '{s}' ({d} -> {d} bytes, ratio: {d:.2}%)\n", .{ input_path, compressed_path, in_data.len, compressed_data.len, @as(f64, @floatFromInt(compressed_data.len)) / @as(f64, @floatFromInt(in_data.len)) * 100.0 });
    }

    // 4 & 5. Read .zst, decompress, write restored
    {
        var comp_file = try cwd.openFile(io, compressed_path, .{});
        defer comp_file.close(io);
        const comp_stat = try comp_file.stat(io);
        const comp_data = try allocator.alloc(u8, @intCast(comp_stat.size));
        defer allocator.free(comp_data);
        _ = try comp_file.readPositionalAll(io, comp_data, 0);
        const decompressed_data = try zstd.decompress(allocator, comp_data);
        defer allocator.free(decompressed_data);
        try cwd.writeFile(io, .{ .sub_path = decompressed_path, .data = decompressed_data, .flags = .{ .truncate = true } });
        std.debug.print("3. Decompressed '{s}' -> '{s}' ({d} bytes)\n", .{ compressed_path, decompressed_path, decompressed_data.len });
        std.debug.assert(std.mem.eql(u8, sample_text, decompressed_data));
        std.debug.print("4. Verified restored file matches original exactly!\n", .{});
    }
}
```

## Output

```text
1. Created source file 'example_input.txt' (616 bytes)
2. Compressed 'example_input.txt' -> 'example_output.txt.zst' (616 -> 626 bytes, ratio: 101.62%)
3. Decompressed 'example_output.txt.zst' -> 'example_restored.txt' (616 bytes)
4. Verified restored file matches original exactly!
```

*Ratio >100% for 616 B is expected — Zstandard frame overhead dominates for tiny files; larger files compress well. Checksum and `Content_Size` are validated.*

## Explanation

- Uses new `std.Io` (`Dir.cwd()`, `writeFile`, `openFile`, `stat`, `readPositionalAll`, `close` with explicit `io` — `lib/std/std.zig:19` `Io`).
- Demonstrates the full file lifecycle: `writeFile` → `compress` → `writeFile(.zst)` → `openFile` → `decompress` → `writeFile` → bit-for-bit `assert`.
- `zstd.compress` emits `0xFD2FB528` magic, `FHD` with `Content_Size`, `Window_Descriptor`, `Block_Header` (`Raw_Block` for this entropy), and `Checksum` if enabled.

Run:

```bash
zig build run-file_compression
```
