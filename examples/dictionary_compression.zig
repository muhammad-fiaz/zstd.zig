//! Compressing with a dictionary: train one, use it, and see the difference.
//!
//! A dictionary is content that logically precedes the data. The encoder may
//! match back into it, so a payload that shares its phrasing with the dictionary
//! costs far fewer bytes; the frame records the dictionary's ID, and a decoder
//! has to be given the same dictionary to reproduce it.
//!
//! Run with: `zig build run-dictionary_compression`

const std = @import("std");
const zstd = @import("zstd");

/// A corpus with a lot of shared phrasing, which is what a dictionary is for.
fn corpus(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var samples: std.ArrayList([]const u8) = .empty;
    errdefer samples.deinit(allocator);
    const statuses = [_][]const u8{ "open", "closed", "pending", "cancelled" };
    for (0..64) |i| {
        const s = try std.fmt.allocPrint(allocator, "GET /api/v1/orders?status={s}&page={d} HTTP/1.1\r\nHost: api.example.com\r\nAccept: application/json\r\n", .{ statuses[i % statuses.len], i / 4 });
        try samples.append(allocator, s);
    }
    return samples;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var samples = try corpus(allocator);
    defer {
        for (samples.items) |s| allocator.free(s);
        samples.deinit(allocator);
    }

    // Training picks the parts of the corpus that recur, so the dictionary holds
    // the request line and the headers rather than one whole request.
    var builder = zstd.DictionaryBuilder.init(allocator, .{ .dictSize = 1024, .dictId = 0xC0FFEE });
    var dict = try builder.train(samples.items);
    defer dict.deinit();
    std.debug.print("dictionary: {d} bytes, id {d}, from {d} samples\n\n", .{ dict.content().len, dict.dictId(), samples.items.len });

    // A payload the dictionary has never seen, but which shares its phrasing.
    const payload = "GET /api/v1/orders?status=open&page=99 HTTP/1.1\r\nHost: api.example.com\r\nAccept: application/json\r\n";

    const without = try zstd.compressWithOptions(allocator, payload, .{ .level = 9 });
    defer allocator.free(without);
    const with_dict = try zstd.compressWithOptions(allocator, payload, .{ .level = 9, .dictionary = &dict });
    defer allocator.free(with_dict);

    std.debug.print("{d} bytes of request text\n", .{payload.len});
    std.debug.print("  without a dictionary: {d} bytes\n", .{without.len});
    std.debug.print("  with    a dictionary: {d} bytes\n", .{with_dict.len});

    // The frame records which dictionary it needs, so a decoder can tell.
    const header = try zstd.getFrameHeader(with_dict);
    std.debug.print("  frame dictionary id:  {d}\n\n", .{header.dictId});

    // Decoding needs the same dictionary.
    const restored = try zstd.decompressWithOptions(allocator, with_dict, .{ .dictionary = &dict });
    defer allocator.free(restored);
    if (!std.mem.eql(u8, payload, restored)) {
        std.debug.print("FAILED: dictionary round trip differs\n", .{});
        return error.RoundTripFailed;
    }

    // Without it the frame cannot be decoded, because its matches point into
    // content the decoder does not have.
    if (zstd.decompress(allocator, with_dict)) |_| {
        std.debug.print("FAILED: a dictionary frame decoded without its dictionary\n", .{});
        return error.ShouldHaveFailed;
    } else |_| {}

    std.debug.print("Verified dictionary round trip\n", .{});
}
