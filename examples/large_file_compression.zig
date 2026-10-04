const std = @import("std");
const zstd = @import("zstd");
const Dir = std.Io.Dir;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = Dir.cwd();

    const inputPath = "large_input.txt";
    const compressedPath = "large_compressed.zst";
    const targetSize: usize = 4 * 1024 * 1024; // 4 MiB

    std.debug.print("==================================================\n", .{});
    std.debug.print("Zstandard Large File Compression Benchmark\n", .{});
    std.debug.print("==================================================\n", .{});

    // Step 1: Generate a realistic 4 MiB structured dataset (application logs)
    std.debug.print("1. Generating {d} bytes (4.00 MiB) of structured log data...\n", .{targetSize});
    var inputBuf = try allocator.alloc(u8, targetSize);
    defer allocator.free(inputBuf);

    const logTemplates = [_][]const u8{
        "2026-10-04T04:54:12.102Z [INFO] worker-01 service=api-gateway request_id=req-98124 status=200 duration_ms=14.2 path=/v1/compress bytes_sent=4096\n",
        "2026-10-04T04:54:12.105Z [DEBUG] worker-02 service=auth-service user_id=usr-55102 token_valid=true scope=read,write client_ip=192.168.1.42\n",
        "2026-10-04T04:54:12.110Z [WARN] worker-04 service=storage-cache cache_hit=false key=meta:doc:99120 eviction_policy=lru memory_used_mb=256\n",
        "2026-10-04T04:54:12.115Z [INFO] worker-03 service=stream-indexer batch_size=512 records_processed=512 latency_p99=18.4ms queue_depth=0\n",
        "2026-10-04T04:54:12.120Z [INFO] worker-01 service=metrics-collector cpu_percent=12.4 mem_percent=34.1 io_read_mb=1.2 io_write_mb=4.8\n",
    };

    var pos: usize = 0;
    var lineIdx: usize = 0;
    while (pos < targetSize) {
        const line = logTemplates[lineIdx % logTemplates.len];
        const copyLen = @min(line.len, targetSize - pos);
        @memcpy(inputBuf[pos .. pos + copyLen], line[0..copyLen]);
        pos += copyLen;
        lineIdx += 1;
    }

    // Step 2: Write uncompressed input file to disk
    try cwd.writeFile(io, .{
        .sub_path = inputPath,
        .data = inputBuf,
        .flags = .{ .truncate = true },
    });
    std.debug.print("2. Wrote source file '{s}' ({d} bytes)\n", .{ inputPath, inputBuf.len });

    // Step 3: Compress with Zstandard level 3 and checksum enabled
    std.debug.print("3. Compressing with native Zig Zstandard (level 3, checksum enabled)...\n", .{});
    const startTime = std.Io.Clock.awake.now(io);
    const compressed = try zstd.compressWithOptions(allocator, inputBuf, .{
        .level = 3,
        .checksum = true,
    });
    defer allocator.free(compressed);
    const endTime = std.Io.Clock.awake.now(io);
    const elapsedNs = endTime.nanoseconds - startTime.nanoseconds;
    const elapsedMs = @as(f64, @floatFromInt(elapsedNs)) / 1_000_000.0;

    // Step 4: Write compressed file to disk and keep it (do NOT delete)
    try cwd.writeFile(io, .{
        .sub_path = compressedPath,
        .data = compressed,
        .flags = .{ .truncate = true },
    });

    const origSize = inputBuf.len;
    const compSize = compressed.len;
    const ratio = (@as(f64, @floatFromInt(compSize)) / @as(f64, @floatFromInt(origSize))) * 100.0;
    const savings = 100.0 - ratio;
    const throughputMBps = (@as(f64, @floatFromInt(origSize)) / (1024.0 * 1024.0)) / (elapsedMs / 1000.0);

    std.debug.print("4. Saved compressed archive to '{s}' (preserved on disk for inspection)\n", .{compressedPath});
    std.debug.print("--------------------------------------------------\n", .{});
    std.debug.print("Original size:    {d} bytes ({d:.2} MiB)\n", .{ origSize, @as(f64, @floatFromInt(origSize)) / (1024.0 * 1024.0) });
    std.debug.print("Compressed size:  {d} bytes ({d:.2} KiB)\n", .{ compSize, @as(f64, @floatFromInt(compSize)) / 1024.0 });
    std.debug.print("Compression ratio:{d:.2}%\n", .{ratio});
    std.debug.print("Space savings:    {d:.2}%\n", .{savings});
    std.debug.print("Compression time: {d:.2} ms ({d:.1} MB/s throughput)\n", .{ elapsedMs, throughputMBps });
    std.debug.print("--------------------------------------------------\n", .{});

    // Step 5: Read back and decompress to verify integrity
    std.debug.print("5. Decompressing and verifying bit-for-bit round trip...\n", .{});
    const decompressed = try zstd.decompress(allocator, compressed);
    defer allocator.free(decompressed);

    std.debug.assert(decompressed.len == origSize);
    std.debug.assert(std.mem.eql(u8, inputBuf, decompressed));
    std.debug.print("6. Verified: Decompressed data matches original exactly bit-for-bit!\n", .{});
    std.debug.print("==================================================\n", .{});
}
