const std = @import("std");
const zstd = @import("zstd");
const Dir = std.Io.Dir;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = Dir.cwd();

    std.debug.print("==================================================\n", .{});
    std.debug.print("Explicit std.Io Streaming File Compression & Decompression\n", .{});
    std.debug.print("==================================================\n", .{});

    const srcPath = "explicit_io_input.txt";
    const zstPath = "explicit_io_output.txt.zst";
    const dstPath = "explicit_io_restored.txt";

    // 1. Create a multi-chunk source file using explicit std.Io
    {
        var file = try cwd.createFile(io, srcPath, .{ .truncate = true });
        defer file.close(io);

        var offset: u64 = 0;
        const line = "Explicit std.Io chunk stream: high performance native Zig 0.17 Zstandard pipeline.\n";
        for (0..500) |_| {
            try file.writePositionalAll(io, line, offset);
            offset += line.len;
        }
    }

    // 2. Stream-compress the input file to .zst archive in 4 KiB chunks
    {
        var inFile = try cwd.openFile(io, srcPath, .{});
        defer inFile.close(io);

        var outFile = try cwd.createFile(io, zstPath, .{ .truncate = true });
        defer outFile.close(io);

        var compressor = try zstd.StreamingCompressor.init(allocator, 7);
        defer compressor.deinit();
        compressor.setChecksumFlag(true);

        var inBuf: [4096]u8 = undefined;
        var outBuf: [131072]u8 = undefined;
        var inOffset: u64 = 0;
        var outOffset: u64 = 0;

        while (true) {
            const bytesRead = try inFile.readPositionalAll(io, &inBuf, inOffset);
            if (bytesRead == 0) break;
            inOffset += bytesRead;

            const res = try compressor.compressStream(&outBuf, inBuf[0..bytesRead], .cont);
            if (res.outProduced > 0) {
                try outFile.writePositionalAll(io, outBuf[0..res.outProduced], outOffset);
                outOffset += res.outProduced;
            }
        }

        // Finish the frame with .end directive
        while (true) {
            const res = try compressor.compressStream(&outBuf, "", .end);
            if (res.outProduced > 0) {
                try outFile.writePositionalAll(io, outBuf[0..res.outProduced], outOffset);
                outOffset += res.outProduced;
            }
            if (res.remaining == 0) break;
        }

        std.debug.print("1. Stream-compressed '{s}' ({d} B) -> '{s}' ({d} B, ratio: {d:.2}%)\n", .{
            srcPath,
            inOffset,
            zstPath,
            outOffset,
            @as(f64, @floatFromInt(outOffset)) / @as(f64, @floatFromInt(inOffset)) * 100.0,
        });
    }

    // 3. Stream-decompress the .zst archive back to uncompressed file in 4 KiB chunks
    {
        var compFile = try cwd.openFile(io, zstPath, .{});
        defer compFile.close(io);

        var outFile = try cwd.createFile(io, dstPath, .{ .truncate = true });
        defer outFile.close(io);

        var decompressor = zstd.StreamingDecompressor.init(allocator);
        defer decompressor.deinit();

        var inBuf: [4096]u8 = undefined;
        var outBuf: [16384]u8 = undefined;
        var inOffset: u64 = 0;
        var outOffset: u64 = 0;

        var inValid: usize = 0;
        var inConsumedTotal: usize = 0;
        var fileDone = false;

        while (true) {
            if (inValid == 0 and !fileDone) {
                const n = try compFile.readPositionalAll(io, &inBuf, inOffset);
                inOffset += n;
                inValid = n;
                if (n == 0) fileDone = true;
            }

            const inSlice = inBuf[inConsumedTotal .. inConsumedTotal + inValid];
            const res = try decompressor.decompressStream(&outBuf, inSlice);
            if (res.outProduced > 0) {
                try outFile.writePositionalAll(io, outBuf[0..res.outProduced], outOffset);
                outOffset += res.outProduced;
            }
            inConsumedTotal += res.inConsumed;
            inValid -= res.inConsumed;
            if (inValid == 0) inConsumedTotal = 0;

            if (fileDone and res.outProduced == 0 and inValid == 0) break;
        }

        std.debug.print("2. Stream-decompressed '{s}' ({d} B) -> '{s}' ({d} B)\n", .{
            zstPath,
            inOffset,
            dstPath,
            outOffset,
        });
    }

    // 4. Verify bit-for-bit equality
    {
        var f1 = try cwd.openFile(io, srcPath, .{});
        defer f1.close(io);
        var f2 = try cwd.openFile(io, dstPath, .{});
        defer f2.close(io);

        const s1 = try f1.stat(io);
        const s2 = try f2.stat(io);
        std.debug.assert(s1.size == s2.size);

        var b1: [4096]u8 = undefined;
        var b2: [4096]u8 = undefined;
        var off: u64 = 0;
        while (off < s1.size) {
            const toRead = @min(b1.len, s1.size - off);
            _ = try f1.readPositionalAll(io, b1[0..toRead], off);
            _ = try f2.readPositionalAll(io, b2[0..toRead], off);
            std.debug.assert(std.mem.eql(u8, b1[0..toRead], b2[0..toRead]));
            off += toRead;
        }
        std.debug.print("3. Verified restored file matches original exactly bit-for-bit!\n", .{});
    }

    // 5. Client-Side Explicit Encoder & Decoder Reusable Contexts
    {
        std.debug.print("\n--- Client-Side Explicit Encoder & Decoder Contexts ---\n", .{});
        var encoder = try zstd.Encoder.init(allocator, .{ .level = 5, .checksum = true });
        defer encoder.deinit();

        var decoder = zstd.Decoder.init(allocator, .{});
        defer decoder.deinit();

        const msg1 = "Payload stream 1: explicit encoder compression with checksum enabled.\n";
        const msg2 = "Payload stream 2: second stream reusing the same encoder and decoder contexts without reallocation.\n";

        // First pass
        const comp1 = try encoder.compress(msg1);
        defer allocator.free(comp1);
        const decomp1 = try decoder.decompressAlloc(comp1);
        defer allocator.free(decomp1);
        std.debug.assert(std.mem.eql(u8, msg1, decomp1));
        std.debug.print("Stream 1: {d} -> {d} bytes (verified bit-for-bit)\n", .{ msg1.len, comp1.len });

        // Second pass reusing contexts
        encoder.reset();
        decoder.reset();
        const comp2 = try encoder.compress(msg2);
        defer allocator.free(comp2);
        const decomp2 = try decoder.decompressAlloc(comp2);
        defer allocator.free(decomp2);
        std.debug.assert(std.mem.eql(u8, msg2, decomp2));
        std.debug.print("Stream 2: {d} -> {d} bytes (verified bit-for-bit, 0 context re-init)\n", .{ msg2.len, comp2.len });
    }

    // 6. Cleanup scratch files
    for ([_][]const u8{ srcPath, zstPath, dstPath }) |path| {
        cwd.deleteFile(io, path) catch {};
    }
    std.debug.print("4. Cleaned up temporary files.\n", .{});
    std.debug.print("==================================================\n", .{});
}
