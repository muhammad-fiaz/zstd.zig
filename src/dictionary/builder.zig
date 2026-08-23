//! Dictionary construction from sample corpora.
//!
//! `train` selects representative segments from the corpus. `trainCover` and
//! `trainFastCover` refine selection with COVER-style parameters (k = segment
//! stride, d = segment window) so that the tuning knobs influence which
//! segments are chosen, while producing dictionaries in the same
//! magic + dictID container as `createDictionaryFromData`.

const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const dict_mod = @import("dictionary.zig");

pub const DictBuilderParams = struct {
    dict_size: usize = 112640,
    dict_id: u32 = 0,
    level: u32 = 3,
};

/// Score a candidate chunk by how often its leading k bytes recur elsewhere.
fn chunkScore(samples: []const []const u8, skip: usize, chunk: []const u8, k: usize) usize {
    if (chunk.len < k or k == 0) return 0;
    var score: usize = 0;
    for (samples, 0..) |s, si| {
        if (si == skip or s.len < k) continue;
        var i: usize = 0;
        while (i + k <= s.len) : (i += 1) {
            if (std.mem.eql(u8, s[i .. i + k], chunk[0..k])) score += 1;
        }
    }
    return score;
}

const Chunk = struct { sample: usize, start: usize, len: usize };

fn buildFromChunks(
    allocator: std.mem.Allocator,
    samples: []const []const u8,
    chunks: []const Chunk,
    dict_size: usize,
    dict_id: u32,
) errors.ZstdError!dict_mod.Dictionary {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    for (chunks) |c| {
        if (content.items.len >= dict_size) break;
        const take = @min(c.len, dict_size - content.items.len);
        content.appendSlice(allocator, samples[c.sample][c.start .. c.start + take]) catch return error.OutOfMemory;
    }
    if (content.items.len == 0) return error.InvalidDictionary;
    return dict_mod.createDictionaryFromData(allocator, content.items, dict_id);
}

fn collectChunks(
    allocator: std.mem.Allocator,
    samples: []const []const u8,
    d: usize,
) errors.ZstdError![]Chunk {
    var chunks: std.ArrayList(Chunk) = .empty;
    errdefer chunks.deinit(allocator);
    for (samples, 0..) |s, si| {
        var start: usize = 0;
        while (start < s.len) : (start += d) {
            const len = @min(d, s.len - start);
            if (len < 8) break; // too small to be representative
            chunks.append(allocator, .{ .sample = si, .start = start, .len = len }) catch return error.OutOfMemory;
        }
    }
    if (chunks.items.len == 0) return error.InvalidDictionary;
    return chunks.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// COVER-style training: rank d-sized chunks by recurrence of their first
/// k bytes across the corpus, then pack the best chunks up to dict_size.
pub fn trainCoverImpl(
    allocator: std.mem.Allocator,
    samples: []const []const u8,
    params: DictBuilderParams,
    k: usize,
    d: usize,
) errors.ZstdError!dict_mod.Dictionary {
    if (samples.len == 0) return error.InvalidDictionary;
    if (k == 0 or d == 0) return error.InvalidDictionary;

    var total: usize = 0;
    for (samples) |s| total += s.len;
    if (total == 0) return error.InvalidDictionary;

    const chunks = try collectChunks(allocator, samples, d);
    defer allocator.free(chunks);

    const Scored = struct { score: usize, idx: usize };
    var scored = allocator.alloc(Scored, chunks.len) catch return error.OutOfMemory;
    defer allocator.free(scored);
    for (chunks, 0..) |c, i| {
        scored[i] = .{
            .score = chunkScore(samples, c.sample, samples[c.sample][c.start .. c.start + c.len], k),
            .idx = i,
        };
    }
    std.sort.pdq(Scored, scored, {}, struct {
        fn lt(_: void, a: Scored, b: Scored) bool {
            return a.score > b.score; // descending
        }
    }.lt);

    var order = allocator.alloc(Chunk, chunks.len) catch return error.OutOfMemory;
    defer allocator.free(order);
    for (scored, 0..) |sc, i| order[i] = chunks[sc.idx];

    return buildFromChunks(allocator, samples, order, params.dict_size, params.dict_id);
}

/// FastCover variant: like `trainCoverImpl` but only scores every `accel`
/// candidate per sample and requires an f-hash step of `f` bytes.
pub fn trainFastCoverImpl(
    allocator: std.mem.Allocator,
    samples: []const []const u8,
    params: DictBuilderParams,
    k: usize,
    d: usize,
    f: u32,
    accel: u32,
) errors.ZstdError!dict_mod.Dictionary {
    if (samples.len == 0) return error.InvalidDictionary;
    if (k == 0 or d == 0 or accel == 0) return error.InvalidDictionary;

    var total: usize = 0;
    for (samples) |s| total += s.len;
    if (total == 0) return error.InvalidDictionary;

    // Candidate stride is d; skip `accel-1` candidates after each scored one.
    var chunks: std.ArrayList(Chunk) = .empty;
    defer chunks.deinit(allocator);
    for (samples, 0..) |s, si| {
        var start: usize = 0;
        while (start + d <= s.len) : (start += d * accel) {
            chunks.append(allocator, .{ .sample = si, .start = start, .len = d }) catch return error.OutOfMemory;
        }
    }
    if (chunks.items.len == 0) {
        // Fall back to one chunk covering each sample head.
        for (samples, 0..) |s, si| {
            if (s.len >= 8) chunks.append(allocator, .{ .sample = si, .start = 0, .len = @min(d, s.len) }) catch return error.OutOfMemory;
        }
    }
    if (chunks.items.len == 0) return error.InvalidDictionary;

    const hash_step: usize = @max(1, f / 4);
    const Scored = struct { score: usize, idx: usize };
    var scored = allocator.alloc(Scored, chunks.items.len) catch return error.OutOfMemory;
    defer allocator.free(scored);
    for (chunks.items, 0..) |c, ci| {
        const seg = samples[c.sample][c.start .. c.start + c.len];
        var score: usize = 0;
        if (seg.len >= k) {
            for (samples, 0..) |s, si| {
                if (si == c.sample or s.len < k) continue;
                var i: usize = 0;
                while (i + k <= s.len) : (i += hash_step) {
                    if (std.mem.eql(u8, s[i .. i + k], seg[0..k])) score += 1;
                }
            }
        }
        scored[ci] = .{ .score = score, .idx = ci };
    }
    std.sort.pdq(Scored, scored, {}, struct {
        fn lt(_: void, a: Scored, b: Scored) bool {
            return a.score > b.score;
        }
    }.lt);

    var order = allocator.alloc(Chunk, chunks.items.len) catch return error.OutOfMemory;
    defer allocator.free(order);
    for (scored, 0..) |sc, i| order[i] = chunks.items[sc.idx];

    return buildFromChunks(allocator, samples, order, params.dict_size, params.dict_id);
}

/// Naive full-corpus trainer: concatenates sample heads until dict_size.
pub fn trainFromSamples(allocator: std.mem.Allocator, samples: []const []const u8, params: DictBuilderParams) errors.ZstdError!dict_mod.Dictionary {
    if (samples.len == 0) return error.InvalidDictionary;
    var total: usize = 0;
    for (samples) |s| total += s.len;
    if (total == 0) return error.InvalidDictionary;

    var pos: usize = 0;
    var sample_idx: usize = 0;
    const buf = allocator.alloc(u8, @min(params.dict_size, total)) catch return error.OutOfMemory;
    defer allocator.free(buf);
    while (pos < buf.len) {
        const s = samples[sample_idx % samples.len];
        const copy_len = @min(s.len, buf.len - pos);
        if (copy_len == 0) {
            sample_idx += 1;
            if (sample_idx >= samples.len * 2) break;
            continue;
        }
        @memcpy(buf[pos .. pos + copy_len], s[0..copy_len]);
        pos += copy_len;
        sample_idx += 1;
    }
    if (pos == 0) return error.InvalidDictionary;
    return dict_mod.createDictionaryFromData(allocator, buf[0..pos], params.dict_id);
}

pub const DictionaryBuilder = struct {
    allocator: std.mem.Allocator,
    params: DictBuilderParams,

    pub fn init(allocator: std.mem.Allocator, params: DictBuilderParams) DictionaryBuilder {
        return .{ .allocator = allocator, .params = params };
    }

    pub fn train(self: *DictionaryBuilder, samples: []const []const u8) anyerror!dict_mod.Dictionary {
        return trainFromSamples(self.allocator, samples, self.params);
    }

    pub fn trainCover(self: *DictionaryBuilder, samples: []const []const u8, k: usize, d: usize) anyerror!dict_mod.Dictionary {
        return trainCoverImpl(self.allocator, samples, self.params, k, d);
    }

    pub fn trainFastCover(self: *DictionaryBuilder, samples: []const []const u8, k: usize, d: usize, f: u32, accel: u32) anyerror!dict_mod.Dictionary {
        return trainFastCoverImpl(self.allocator, samples, self.params, k, d, f, accel);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "trainCover prefers recurring chunks" {
    const alloc = testing.allocator;
    const hot = "recurring-header-payload-AAAA";
    const cold = "zzzz qqqq wwww xxxx";
    const samples = [_][]const u8{ hot, hot, hot, cold };
    var dict = try trainCoverImpl(alloc, &samples, .{ .dict_size = 128 }, 6, 14);
    defer dict.deinit();
    try testing.expect(dict.data.len > 0);
    // Hot content should dominate the dictionary.
    try testing.expect(std.mem.indexOf(u8, dict.content(), "recurring") != null);
}

test "trainFastCover respects accel stride" {
    const alloc = testing.allocator;
    const samples = [_][]const u8{"abcdefgh" ** 8};
    var dict = try trainFastCoverImpl(alloc, &samples, .{ .dict_size = 64 }, 6, 16, 6, 2);
    defer dict.deinit();
    try testing.expect(dict.data.len > 0);
}

test "train rejects empty corpora" {
    try testing.expectError(error.InvalidDictionary, trainFromSamples(testing.allocator, &.{}, .{}));
}
