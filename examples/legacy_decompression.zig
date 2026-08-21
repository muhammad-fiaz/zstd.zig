const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Demonstrate legacy frame detection (v01-v07) and transparent decompression
    const legacy_magics = [_]struct { version: u8, magic: u32 }{
        .{ .version = 1, .magic = 0xFD2FB521 },
        .{ .version = 2, .magic = 0xFD2FB522 },
        .{ .version = 3, .magic = 0xFD2FB523 },
        .{ .version = 4, .magic = 0xFD2FB524 },
        .{ .version = 5, .magic = 0xFD2FB525 },
        .{ .version = 6, .magic = 0xFD2FB526 },
        .{ .version = 7, .magic = 0xFD2FB527 },
    };

    for (legacy_magics) |lm| {
        var frame: [4]u8 = undefined;
        frame[0] = @truncate(lm.magic);
        frame[1] = @truncate(lm.magic >> 8);
        frame[2] = @truncate(lm.magic >> 16);
        frame[3] = @truncate(lm.magic >> 24);
        std.debug.print("Legacy v{d:0>2} magic 0x{X:0>8} isLegacy={} version={?d}\n", .{ lm.version, lm.magic, zstd.legacy.isLegacy(&frame), zstd.legacy_detect.legacyVersion(&frame) });
        std.debug.assert(zstd.legacy.isLegacy(&frame));
        std.debug.assert(zstd.legacy_detect.legacyVersion(&frame).? == lm.version);
    }

    // Modern frame should not be legacy
    const modern_data = "modern frame test";
    const modern_compressed = try zstd.compress(allocator, modern_data);
    defer allocator.free(modern_compressed);
    std.debug.assert(!zstd.legacy.isLegacy(modern_compressed));
    std.debug.assert(zstd.isFrame(modern_compressed));
    std.debug.print("Modern frame correctly not detected as legacy\n", .{});

    // Transparently decompress modern via legacy path also works (decompress handles both)
    const decompressed = try zstd.decompress(allocator, modern_compressed);
    defer allocator.free(decompressed);
    std.debug.assert(std.mem.eql(u8, modern_data, decompressed));
    std.debug.print("Legacy decoder transparently handles modern frames\n", .{});

    // Demonstrate skippable frame handling (not legacy, but related)
    var skip_buf: [32]u8 = undefined;
    const skip_len = zstd.writeSkippableFrame(&skip_buf, "legacy meta", 4);
    std.debug.assert(zstd.isSkippableFrame(skip_buf[0..skip_len]));
    std.debug.print("Skippable frame written {d} bytes\n", .{skip_len});
}
