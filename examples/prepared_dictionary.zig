//! Preparing a dictionary once and reusing it.
//!
//! A prepared dictionary carries the entropy tables describing how its own
//! content compresses, so a frame compressed against it can inherit them instead
//! of re-deriving them. Preparing costs work proportional to the dictionary, so
//! the shape to aim for is: prepare once, then reuse across many inputs.
//!
//! The same value serves any number of contexts, and because preparation produces
//! no mutable state, holding one in several contexts at once is safe.

const std = @import("std");
const zstd = @import("zstd");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // The content the payloads share. A dictionary earns its keep when the
    // payloads repeat material it already contains.
    const shared = "the recurring phrase that every payload in this example shares";

    // Prepare once. `prepare` accepts raw content or a prepared dictionary; raw
    // content yields no tables, which a frame then describes for itself.
    var prepared = try zstd.prepareDictionary(allocator, shared);
    defer prepared.deinit();
    std.debug.print("prepared dictionary id {d}, {d} bytes of content\n", .{
        prepared.id,
        prepared.content().len,
    });

    // A frame compressor needs a dictionary view, which `loadDictionary` builds
    // from the prepared bytes.
    var dict = try zstd.loadDictionary(allocator, prepared.data);
    defer dict.deinit();

    const inputs = [_][]const u8{
        shared,
        "a payload with no overlap at all, to show the dictionary is optional per frame",
        "the recurring phrase that every payload shares, plus a tail",
        "",
    };

    // Reuse one compressor across every input. Frames must come out
    // independently: the dictionary is shared, but no state is.
    var comp = zstd.Compressor.init(allocator);
    defer comp.deinit();
    comp.setDictionary(&dict);

    var frames: [inputs.len][]u8 = undefined;
    for (inputs, 0..) |text, i| {
        frames[i] = try comp.compressAlloc(text);
        std.debug.print("compressed {d:>3} bytes into {d:>3}\n", .{ text.len, frames[i].len });
    }
    defer for (frames) |f| allocator.free(f);

    // Reuse one decompressor the same way.
    var dec = zstd.Decompressor.init(allocator);
    defer dec.deinit();
    dec.setDictionary(&dict);

    for (inputs, 0..) |text, i| {
        const back = try dec.decompressAlloc(frames[i]);
        defer allocator.free(back);
        if (!std.mem.eql(u8, back, text)) {
            std.debug.print("frame {d} did not round trip\n", .{i});
            return error.RoundTripFailed;
        }
        std.debug.print("frame {d} round tripped, {d} bytes\n", .{ i, back.len });
    }

    // The dictionary's identity is enforced. A frame compressed for one
    // dictionary is refused by another rather than decoded to plausible rubbish.
    var other = try zstd.createDictionaryFromData(allocator, "a completely different body", 999);
    defer other.deinit();
    if (zstd.decompressWithOptions(allocator, frames[0], .{
        .dictionary = &other,
        .requireDictionaryMatch = true,
    })) |wrong| {
        allocator.free(wrong);
        std.debug.print("a mismatched dictionary should not have decoded\n", .{});
        return error.WrongDictionaryAccepted;
    } else |e| {
        std.debug.print("mismatched dictionary refused as {s}\n", .{@errorName(e)});
    }

    // A frame that names a dictionary cannot be decoded without one.
    if (zstd.decompressWithOptions(allocator, frames[0], .{ .requireDictionaryMatch = true })) |wrong| {
        allocator.free(wrong);
        std.debug.print("a dictionary frame should not have decoded without one\n", .{});
        return error.MissingDictionaryAccepted;
    } else |e| {
        std.debug.print("missing dictionary refused as {s}\n", .{@errorName(e)});
    }
}
