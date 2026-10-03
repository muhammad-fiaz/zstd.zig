//! Training a dictionary from samples.
//!
//! Three selection strategies are available, and they differ in how they choose
//! what goes into the dictionary:
//!
//!   * `train` keeps representative segments of the corpus, in order;
//!   * `trainCover` ranks `d`-byte segments by how often their first `k` bytes
//!     recur, which favours the phrasing that repeats across samples;
//!   * `trainFastCover` does the same but only scores every `accel`-th candidate,
//!     trading a little quality for a lot less work on a large corpus.
//!
//! The result is an ordinary dictionary: the same type a caller loads from disk
//! and hands to `compressWithOptions` or `decompressWithOptions`.
//!
//! Run with: `zig build run-dictionary_training`

const std = @import("std");
const zstd = @import("zstd");

/// A corpus that repeats its structure but varies its values, which is what a
/// dictionary can exploit.
fn corpus(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var samples: std.ArrayList([]const u8) = .empty;
    errdefer samples.deinit(allocator);
    const verbs = [_][]const u8{ "insert", "update", "delete", "select" };
    const tables = [_][]const u8{ "orders", "customers", "invoices", "shipments" };
    for (0..200) |i| {
        const s = try std.fmt.allocPrint(allocator, "begin transaction on table {s}: {s} row {d} of 1000; commit transaction on table {s}; end transaction\n", .{ tables[i % tables.len], verbs[i % verbs.len], i, tables[(i + 1) % tables.len] });
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

    var builder = zstd.DictionaryBuilder.init(allocator, .{ .dictSize = 4096, .dictId = 0x5EED });
    std.debug.print("{d} samples\n\n", .{samples.items.len});

    var plain = try builder.train(samples.items);
    defer plain.deinit();
    std.debug.print("train          {d} bytes  (id {d})\n", .{ plain.content().len, plain.dictId() });

    var cover = try builder.trainCover(samples.items, 6, 32);
    defer cover.deinit();
    std.debug.print("trainCover     {d} bytes  (k=6 d=32)\n", .{cover.content().len});

    var fast = try builder.trainFastCover(samples.items, 6, 32, 20, 2);
    defer fast.deinit();
    std.debug.print("trainFastCover {d} bytes  (k=6 d=32 f=20 accel=2)\n", .{fast.content().len});

    // A trained dictionary is a dictionary: measure what it does for a sample
    // from the corpus it was built from.
    const payload = samples.items[samples.items.len - 1];
    const without = try zstd.compressWithOptions(allocator, payload, .{ .level = 9 });
    defer allocator.free(without);
    const with_dict = try zstd.compressWithOptions(allocator, payload, .{ .level = 9, .dictionary = &cover });
    defer allocator.free(with_dict);
    std.debug.print("\n{d}-byte sample: {d} bytes without a dictionary, {d} with one\n", .{ payload.len, without.len, with_dict.len });

    const restored = try zstd.decompressWithOptions(allocator, with_dict, .{ .dictionary = &cover });
    defer allocator.free(restored);
    if (!std.mem.eql(u8, payload, restored)) {
        std.debug.print("FAILED: trained dictionary round trip differs\n", .{});
        return error.RoundTripFailed;
    }
    std.debug.print("Verified a trained dictionary round trip\n", .{});
}
