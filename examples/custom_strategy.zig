//! Choosing a match-finding strategy per call.
//!
//! A Zstandard level picks a search engine and a parser for you. When you want
//! something a level does not offer - a much faster search for a hot path, or the
//! most thorough search for an archival run - set `strategy` explicitly. Every
//! strategy is implemented natively here, and each one behaves differently:
//!
//! | Strategy    | Engine        | Parser                     |
//! |-------------|---------------|----------------------------|
//! | `fast`      | hash table    | one probe, no look-ahead   |
//! | `dfast`     | hash table    | one probe, plus one at `pos + 1` |
//! | `greedy`    | hash chain    | first match long enough    |
//! | `lazy`      | hash chain    | one step of look-ahead     |
//! | `lazy2`     | hash chain    | two steps of look-ahead    |
//! | `btlazy2`   | binary tree   | two steps of look-ahead    |
//! | `btopt`     | binary tree   | priced optimal parse       |
//! | `btultra`   | binary tree   | optimal parse, deeper walk |
//! | `btultra2`  | binary tree   | optimal parse, deepest walk|
//!
//! Run with: `zig build run-custom_strategy`

const std = @import("std");
const zstd = @import("zstd");

/// Input with several kinds of structure: a repeated header, a text-like middle,
/// and a random tail. That is what makes the strategies' differences visible.
fn makeInput(buffer: []u8) []const u8 {
    const header = "HEADER:zstd-sample-payload;version=1;kind=demo\n";
    const body = "the quick brown fox jumps over the lazy dog while the compressor " ++
        "decides between a match now and a longer one a byte later, which is the " ++
        "only decision a lazy parse actually makes. ";
    @memset(buffer, 'x');
    @memcpy(buffer[0..header.len], header);
    var pos = header.len;
    while (pos + body.len < buffer.len - 64) {
        @memcpy(buffer[pos..][0..body.len], body);
        pos += body.len;
    }
    var prng = std.Random.DefaultPrng.init(0x5A7);
    const random = prng.random();
    for (buffer[pos..]) |*b| b.* = random.intRangeAtMost(u8, 0, 255);
    return buffer;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    _ = io;

    const input_len = 200_000;
    const input = try allocator.alloc(u8, input_len);
    defer allocator.free(input);
    const payload = makeInput(input);

    std.debug.print("input: {d} bytes\n\n", .{payload.len});
    std.debug.print("{s: <12} {s: <10} {s: >8} {s: >9} {s: >8}\n", .{ "strategy", "engine", "size", "ratio", "vs best" });

    const strategies = [_]zstd.Strategy{
        .fast,
        .dfast,
        .greedy,
        .lazy,
        .lazy2,
        .btlazy2,
        .btopt,
        .btultra,
        .btultra2,
    };

    var best: ?usize = null;
    var sizes: [strategies.len]usize = @splat(0);

    for (strategies, 0..) |strategy, i| {
        const frame = try zstd.compressWithOptions(allocator, payload, .{
            // The level supplies the table sizes; the strategy is what we are
            // choosing here.
            .level = 12,
            .strategy = strategy,
        });
        sizes[i] = frame.len;

        // Every strategy must produce a frame this decoder accepts, which is the
        // property that matters: the choice is a ratio/speed trade, never a
        // correctness one.
        const restored = try zstd.decompress(allocator, frame);
        defer allocator.free(restored);
        if (!std.mem.eql(u8, payload, restored)) {
            std.debug.print("round trip FAILED for {s}\n", .{@tagName(strategy)});
            return error.RoundTripFailed;
        }
        if (best == null or frame.len < best.?) best = frame.len;
        allocator.free(frame);
    }

    for (strategies, 0..) |strategy, i| {
        std.debug.print("{s: <12} {s: <10} {d: >8} {d: >7.2}% {d: >7.2}%\n", .{
            @tagName(strategy),
            switch (strategy) {
                .fast, .dfast => "table",
                .greedy, .lazy, .lazy2 => "chain",
                else => "tree",
            },
            sizes[i],
            @as(f64, @floatFromInt(sizes[i])) * 100.0 / @as(f64, @floatFromInt(payload.len)),
            (@as(f64, @floatFromInt(sizes[i])) - @as(f64, @floatFromInt(best.?))) * 100.0 / @as(f64, @floatFromInt(best.?)),
        });
    }

    // A context keeps its options, so a program that changes strategy per
    // message uses one context and sets the strategy on it.
    var compressor = zstd.Compressor.init(allocator);
    defer compressor.deinit();
    compressor.setStrategy(.btopt);
    const archival = try compressor.compressAlloc(payload);
    defer allocator.free(archival);
    std.debug.print("\nbtopt through a reusable context: {d} bytes\n", .{archival.len});

    std.debug.print("\nAll strategies round tripped.\n", .{});
}
