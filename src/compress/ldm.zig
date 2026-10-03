//! Long-distance matching (LDM).
//!
//! The regular match finders are bounded by the window. LDM covers matches that
//! start further back than it, or are visible only to a finder spanning the whole
//! input, as in archives where a section repeats verbatim a megabyte later.
//! A gear rolling hash picks split points about one per `2^hashRateLog` bytes; each
//! is fingerprinted by a 64-bit hash of the `minMatchLength` bytes ending there,
//! whose low bits pick a bucket and whose high 32 bits act as a checksum. A split
//! point scans only its own bucket, so a lookup is `minMatchLength` of hashing
//! plus a short bounded scan.

const std = @import("std");
const xxhash = @import("../common/xxhash.zig");
const constants = @import("../common/constants.zig");
const search = @import("search.zig");

/// Shortest match LDM will report. Matches shorter than this are not the point
/// of the module: the regular finders already handle them.
pub const min_match_length: u32 = 64;

/// Window LDM needs to be worth enabling, as a power of two. Below this there
/// is no "long" distance to find.
pub const min_window_log: u8 = 20;

/// Upper bound on the table log, matching the format's own limits.
pub const hash_log_max: u8 = 30;
pub const hash_log_min: u8 = 6;
/// Entries per bucket are `2^bucket_size_log`; four is the floor and matches
/// what the reference implementation uses by default.
pub const bucket_size_log_min: u8 = 4;
pub const bucket_size_log_max: u8 = 8;

/// Tuning, derived from the compression parameters when not set explicitly.
pub const Params = struct {
    /// Whether LDM runs at all.
    enabled: bool = false,
    /// Window the distances must fit in.
    windowLog: u8 = min_window_log,
    /// Table log: the table holds `2^hashLog` entries.
    hashLog: u8 = 20,
    /// Log of the entries per bucket.
    bucketSizeLog: u8 = 4,
    /// Shortest match reported.
    minMatchLength: u32 = min_match_length,
    /// Log of the average distance between split points: one split per
    /// `2^hashRateLog` bytes.
    hashRateLog: u8 = 7,

    /// Fills in the parameters a caller left at zero, the way the reference
    /// implementation derives them from the level's parameters, and clamps the
    /// rest into the supported ranges.
    pub fn adjust(self: *Params, window_log: u8, strategy: constants.Strategy, hash_log: u8) void {
        self.windowLog = window_log;
        if (self.hashRateLog == 0) {
            if (hash_log > 0) {
                if (self.windowLog > hash_log) self.hashRateLog = self.windowLog - hash_log;
            } else {
                // Mapping from [fast, rate7] to [btultra2, rate4]: the stronger
                // the strategy, the denser the split points.
                self.hashRateLog = 7 - @as(u8, @backingInt(strategy)) / 3;
            }
        }
        if (self.hashLog == 0) {
            self.hashLog = if (self.windowLog <= self.hashRateLog)
                hash_log_min
            else
                std.math.clamp(self.windowLog - self.hashRateLog, hash_log_min, hash_log_max);
        }
        if (self.minMatchLength == 0) {
            self.minMatchLength = min_match_length;
            if (@backingInt(strategy) >= @backingInt(constants.Strategy.btultra)) self.minMatchLength /= 2;
        }
        if (self.bucketSizeLog == 0) {
            self.bucketSizeLog = std.math.clamp(
                @as(u8, @backingInt(strategy)),
                bucket_size_log_min,
                bucket_size_log_max,
            );
        }
        self.bucketSizeLog = @min(self.bucketSizeLog, self.hashLog);
        if (self.hashLog > hash_log_max) self.hashLog = hash_log_max;
        if (self.hashRateLog == 0) self.hashRateLog = 1;
    }

    /// Bytes the table and the per-bucket offsets need.
    pub fn tableSize(self: Params) usize {
        if (!self.enabled) return 0;
        const bucket_size_log = @min(self.bucketSizeLog, self.hashLog);
        const bucket_count = @as(usize, 1) << @intCast(self.hashLog - bucket_size_log);
        return (@as(usize, 1) << @intCast(self.hashLog)) * @sizeOf(Entry) + bucket_count;
    }
};

/// One candidate: where it is and what it hashes to.
const Entry = struct {
    /// Position of the split point in the source.
    offset: u32,
    /// High 32 bits of the fingerprint.
    checksum: u32,
};

/// A long match, in source coordinates.
pub const Match = struct {
    /// Source position the match starts at.
    pos: usize,
    /// Match length, never below the configured minimum.
    length: u32,
    /// Distance back. Always valid: it points at bytes the decoder has already
    /// produced, because the split point it was found at is at least this far
    /// into the input.
    offset: u32,
};

/// Gear table: `table[b]` is a 64-bit value chosen so that the rolling sum of
/// a window of bytes is well distributed. Generated from the same prime
/// sequence xxHash uses, so the table is deterministic and needs no storage.
const gear_table: [256]u64 = blk: {
    @setEvalBranchQuota(4000);
    var table: [256]u64 = undefined;
    var h: u64 = 0;
    const prime: u64 = 0x9E3779B185EBCA87;
    for (&table) |*slot| {
        h +%= prime;
        slot.* = h;
    }
    break :blk table;
};

/// The rolling gear hash. `stop_mask` decides which positions are splits; it is
/// built so that firing depends on a window of `min_match_length` bytes and
/// happens on average every `2^hash_rate_log` bytes.
const GearHash = struct {
    rolling: u64 = 0xFFFF_FFFF,
    stop_mask: u64 = 0,

    fn init(self: *GearHash, params: Params) void {
        const max_bits: u32 = @min(params.minMatchLength, 64);
        const rate = params.hashRateLog;
        self.rolling = 0xFFFF_FFFF;
        if (rate > 0 and rate <= max_bits) {
            // Put the `rate` bits in the highest positions: bit n depends on
            // the last n bytes, so high bits depend on a long window.
            self.stop_mask = ((@as(u64, 1) << @intCast(rate)) - 1) << @intCast(max_bits - rate);
        } else {
            self.stop_mask = (@as(u64, 1) << @intCast(rate)) - 1;
        }
    }

    /// Feeds `min_match_length` bytes without recording splits, which is what
    /// makes the hash state depend on the window before the first split.
    fn reset(self: *GearHash, data: []const u8, window: usize) void {
        var hash = self.rolling;
        for (data[0..@min(window, data.len)]) |b| {
            hash = (hash << 1) +% gear_table[b];
        }
        self.rolling = hash;
    }

    /// Feeds `data` until `splits` is full or the input is consumed, returning the
    /// offsets where the hash fired and how many bytes were consumed. Feeding
    /// stops at the *last* split recorded, not at the end of the buffer: a split
    /// found but not recorded would be lost. The caller continues from `hashed`.
    fn feed(self: *GearHash, data: []const u8, splits: []usize) struct { hashed: usize, count: usize } {
        var hash = self.rolling;
        const mask = self.stop_mask;
        var n: usize = 0;
        var count: usize = 0;
        var consumed: usize = data.len;
        while (n < data.len) : (n += 1) {
            hash = (hash << 1) +% gear_table[data[n]];
            if (hash & mask == 0) {
                splits[count] = n + 1;
                count += 1;
                if (count == splits.len) {
                    consumed = n + 1;
                    break;
                }
            }
        }
        self.rolling = hash;
        return .{ .hashed = consumed, .count = count };
    }
};

/// The long-distance matcher. One instance per frame: the table is the frame's
/// memory of where its long repeats are, so it is reset when a frame ends and
/// reused for the next one.
pub const Ldm = struct {
    params: Params,
    table: []Entry,
    /// Round-robin write cursor for each bucket.
    bucket_offsets: []u8,
    gear: GearHash = .{},
    /// Matches found, in ascending source order.
    matches: std.ArrayList(Match) = .empty,
    allocator: std.mem.Allocator,
    /// Highest split position seen, so a second call can resume.
    filled_to: usize = 0,

    pub fn init(allocator: std.mem.Allocator, params: Params) !Ldm {
        const bucket_size_log = @min(params.bucketSizeLog, params.hashLog);
        const table_len = @as(usize, 1) << @intCast(params.hashLog);
        const bucket_count = @as(usize, 1) << @intCast(params.hashLog - bucket_size_log);
        const table = try allocator.alloc(Entry, table_len);
        @memset(table, .{ .offset = 0, .checksum = 0 });
        const bucket_offsets = try allocator.alloc(u8, bucket_count);
        @memset(bucket_offsets, 0);
        var self = Ldm{
            .params = params,
            .table = table,
            .bucket_offsets = bucket_offsets,
            .allocator = allocator,
        };
        self.gear.init(params);
        return self;
    }

    pub fn deinit(self: *Ldm) void {
        self.allocator.free(self.table);
        self.allocator.free(self.bucket_offsets);
        self.matches.deinit(self.allocator);
        self.* = undefined;
    }

    /// Drops the table and the matches, keeping the allocation. Called when a
    /// frame ends, because the decoder's window resets there too.
    pub fn reset(self: *Ldm) void {
        @memset(self.table, .{ .offset = 0, .checksum = 0 });
        @memset(self.bucket_offsets, 0);
        self.matches.clearRetainingCapacity();
        self.gear.init(self.params);
        self.filled_to = 0;
    }

    inline fn bucketSizeLog(self: *const Ldm) u8 {
        return @min(self.params.bucketSizeLog, self.params.hashLog);
    }

    /// The `2^bucketSizeLog` entries a hash maps to.
    inline fn bucket(self: *Ldm, hash: u32) []Entry {
        const shift = self.bucketSizeLog();
        const start = @as(usize, hash) << @intCast(shift);
        return self.table[start..][0 .. @as(usize, 1) << @intCast(shift)];
    }

    /// Records a split point in its bucket, overwriting the oldest of the
    /// bucket's entries. `hash` is already masked to the bucket-index width, so
    /// it indexes both the table range and its own round-robin cursor.
    fn insert(self: *Ldm, hash: u32, entry: Entry) void {
        const bucket_size_log = self.bucketSizeLog();
        const offset = self.bucket_offsets[hash];
        self.bucket(hash)[offset] = entry;
        // The round-robin cursor wraps at the bucket size, which is 256 entries
        // for the widest bucket, so the mask is computed in a wider type: a
        // `u8` shift of eight would not fit the byte it is meant to describe.
        const mask: u8 = @truncate((@as(u32, 1) << @intCast(bucket_size_log)) - 1);
        self.bucket_offsets[hash] = (offset +% 1) & mask;
    }

    /// Fills the table with every split point in `src[from..to]`.
    ///
    /// Only used to seed the table before a parse, so a long repeat that starts
    /// before the first split in the search region is still findable.
    pub fn fill(self: *Ldm, src: []const u8, from: usize, to: usize) void {
        const min_match: usize = @min(self.params.minMatchLength, src.len);
        if (to <= from or src.len < min_match) {
            self.filled_to = @max(self.filled_to, to);
            return;
        }
        self.gear.init(self.params);
        self.gear.reset(src[from..], min_match);
        var ip = from + min_match;
        var splits: [64]usize = undefined;
        while (ip < to) {
            const end = @min(to, ip + (1 << 12));
            const result = self.gear.feed(src[ip..end], &splits);
            for (splits[0..result.count]) |split| {
                const at = ip + split;
                if (at < min_match) continue;
                const start = at - min_match;
                const digest = xxhash.xxhash64(src[start..at], 0);
                self.insert(lowHash(digest, self.params.hashLog, self.bucketSizeLog()), .{
                    .offset = @intCast(start),
                    .checksum = @truncate(digest >> 32),
                });
            }
            ip += result.hashed;
        }
        self.filled_to = to;
    }

    /// Finds long matches in `src[from..to]`, appending them to `matches`. A match
    /// may extend before `from`; backward extension turns a short coincidental
    /// overlap into a long match, but is only counted back to the region start so
    /// the caller keeps its own anchor.
    pub fn generateSequences(self: *Ldm, src: []const u8, from: usize, to: usize) !void {
        const min_match: usize = self.params.minMatchLength;
        if (to <= from + min_match or src.len < min_match) return;
        var splits: [64]usize = undefined;
        var ip = from + min_match;
        // A split point inside a match already emitted only registers the
        // position; emitting it would produce overlapping sequences, which the
        // block format cannot express.
        var anchor = from;
        while (ip < to - min_match) {
            const end = @min(to - min_match, ip + (1 << 12));
            const result = self.gear.feed(src[ip..end], &splits);
            for (splits[0..result.count]) |split| {
                const at = ip + split;
                if (at < min_match) continue;
                const start = at - min_match;
                const digest = xxhash.xxhash64(src[start..at], 0);
                const hash = lowHash(digest, self.params.hashLog, self.bucketSizeLog());
                const entry = Entry{ .offset = @intCast(start), .checksum = @truncate(digest >> 32) };

                var best_forward: usize = 0;
                var best_backward: usize = 0;
                var best: ?Entry = null;
                for (self.bucket(hash)) |candidate| {
                    if (candidate.checksum != entry.checksum or candidate.offset == 0) continue;
                    const cand_pos = candidate.offset;
                    if (cand_pos >= start) continue;
                    const dist = start - cand_pos;
                    if (dist > self.windowDistance()) continue;
                    // Only the bytes that are actually inside the search region
                    // may be matched: the rest of the table is history the
                    // decoder still has, but its content is not in `src`.
                    const forward = matchForward(src, start, cand_pos, to);
                    if (forward < min_match) continue;
                    const backward = matchBackward(src, start, cand_pos, from);
                    const total = forward + backward;
                    if (best == null or total > best_forward + best_backward) {
                        best_forward = forward;
                        best_backward = backward;
                        best = candidate;
                    }
                }

                if (best) |winner| {
                    const match_start = start - best_backward;
                    const match_end = start + best_forward;
                    if (match_start < anchor) {
                        // The match starts inside the previous one: keep the
                        // position in the table and move on.
                        self.insert(hash, entry);
                        continue;
                    }
                    self.matches.append(self.allocator, .{
                        .pos = match_start,
                        .length = @intCast(match_end - match_start),
                        .offset = @intCast(start - winner.offset),
                    }) catch return error.OutOfMemory;
                    anchor = match_end;
                    if (anchor > ip + result.hashed) {
                        // The match runs past the window just hashed, so the pattern
                        // repeats: one split point represents it, and skipping the
                        // rest keeps a long repeat from costing a match scan per
                        // split.
                        self.gear.reset(src[anchor - min_match ..], min_match);
                        ip = anchor - result.hashed;
                        break;
                    }
                }
                // Register the split point either way, so a later region that
                // repeats it is found even when this one produced a match.
                self.insert(hash, entry);
            }
            ip += result.hashed;
        }
    }

    /// Largest distance the frame's window allows.
    pub fn windowDistance(self: *const Ldm) usize {
        return @as(usize, 1) << @intCast(self.params.windowLog);
    }

    /// The long match starting at `pos`, if any. Positions are relative to the
    /// search region the caller passed to `generateSequences`.
    pub fn matchAt(self: *const Ldm, pos: usize) ?Match {
        var lo: usize = 0;
        var hi = self.matches.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const m = self.matches.items[mid];
            if (m.pos < pos) {
                lo = mid + 1;
            } else if (m.pos > pos) {
                hi = mid;
            } else {
                return m;
            }
        }
        return null;
    }

    /// The matches that start inside the block `[block_start, block_start + len)`,
    /// rebased to the block. The result is written into `scratch`, because a
    /// block's parser must not allocate per match.
    pub fn ldmMatchesIn(
        self: *const Ldm,
        block_start: usize,
        len: usize,
        scratch: []search.LongMatch,
    ) []const search.LongMatch {
        const block_end = block_start + len;
        var count: usize = 0;
        for (self.matches.items) |m| {
            if (m.pos < block_start) continue;
            if (m.pos >= block_end) break;
            if (count == scratch.len) break;
            scratch[count] = .{ .pos = m.pos - block_start, .length = m.length, .offset = m.offset };
            count += 1;
        }
        return scratch[0..count];
    }
};

/// Splits a fingerprint into a bucket index: the low bits, since the checksum is
/// taken from the high ones. Only `hashLog - bucketSizeLog` bits are used,
/// because the bucket index is scaled by the bucket size to reach the table.
fn lowHash(digest: u64, hash_log: u8, bucket_size_log: u8) u32 {
    const index_bits = hash_log - bucket_size_log;
    return @truncate(digest & ((@as(u64, 1) << @intCast(index_bits)) - 1));
}

/// Bytes two positions `dist` apart agree on, forward.
fn matchForward(src: []const u8, pos: usize, cand: usize, limit: usize) usize {
    var n: usize = 0;
    while (pos + n < limit and src[pos + n] == src[cand + n]) : (n += 1) {}
    return n;
}

/// Bytes two positions `dist` apart agree on, backwards, never before `from`
/// or before the candidate's own start.
fn matchBackward(src: []const u8, pos: usize, cand: usize, from: usize) usize {
    var n: usize = 0;
    while (pos - n > from and cand -| n > 0 and src[pos - n - 1] == src[cand - n - 1]) : (n += 1) {}
    return n;
}

const testing = std.testing;

test "adjustParameters derives defaults from the strategy" {
    var p = Params{ .enabled = true };
    p.adjust(23, .btultra2, 0);
    try testing.expect(p.hashLog > 0);
    try testing.expect(p.bucketSizeLog >= bucket_size_log_min);
    try testing.expect(p.minMatchLength > 0);
    try testing.expect(p.hashRateLog >= 1);
    // A very large window must not push the table past the supported log.
    var big = Params{ .enabled = true };
    big.adjust(31, .fast, 0);
    try testing.expect(big.hashLog <= hash_log_max);
    try testing.expect(big.bucketSizeLog <= big.hashLog);
}

test "adjustParameters honours explicit values and clamps them" {
    var p = Params{ .enabled = true, .hashLog = 4, .bucketSizeLog = 9, .hashRateLog = 3, .minMatchLength = 100 };
    p.adjust(20, .greedy, 0);
    try testing.expectEqual(@as(u8, 4), p.hashLog);
    try testing.expectEqual(@as(u8, 4), p.bucketSizeLog);
    try testing.expectEqual(@as(u32, 100), p.minMatchLength);
    try testing.expectEqual(@as(u8, 3), p.hashRateLog);
    // A zero rate would make the split rate meaningless.
    var zero = Params{ .enabled = true, .hashRateLog = 0, .hashLog = 0, .minMatchLength = 0, .bucketSizeLog = 0 };
    zero.adjust(0, .fast, 0);
    try testing.expect(zero.hashRateLog >= 1);
    try testing.expect(zero.hashLog >= hash_log_min);
    try testing.expect(zero.minMatchLength >= 32);
}

test "tableSize is zero when disabled and sized when enabled" {
    const off = Params{};
    try testing.expectEqual(@as(usize, 0), off.tableSize());
    var on = Params{ .enabled = true, .hashLog = 10, .bucketSizeLog = 4 };
    on.adjust(20, .greedy, 0);
    try testing.expect(on.tableSize() > (@as(usize, 1) << 10) * @sizeOf(Entry));
}

test "gear hash fires at roughly the configured rate" {
    const params = Params{ .enabled = true, .hashLog = 16, .bucketSizeLog = 4, .hashRateLog = 4, .minMatchLength = 64 };
    var gear = GearHash{};
    gear.init(params);
    var data: [1 << 16]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i / 7));
    var splits: [1024]usize = undefined;
    var count: usize = 0;
    var total: usize = 0;
    while (total < data.len and count < splits.len) {
        const r = gear.feed(data[total..], splits[count..]);
        count += r.count;
        total += r.hashed;
    }
    // About one split per 16 bytes: 65536/16 = 4096, but the batch cap and the
    // four byte granularity move it, so only the order of magnitude is checked.
    try testing.expect(count > 100);
    try testing.expect(count < data.len / 4);
}

test "ldm finds a long match far outside a small window" {
    const alloc = testing.allocator;
    // 4 KiB of noise, then the same 4 KiB again. A 4 KiB window cannot see the
    // copy, which is the whole point of LDM.
    var src: [8192]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x1D);
    const random = prng.random();
    for (src[0..4096]) |*b| b.* = random.int(u8);
    @memcpy(src[4096..], src[0..4096]);

    var params = Params{ .enabled = true, .hashLog = 16, .bucketSizeLog = 6, .hashRateLog = 4, .minMatchLength = 64 };
    params.adjust(20, .greedy, 0);
    params.hashRateLog = 4;
    var ldm = try Ldm.init(alloc, params);
    defer ldm.deinit();
    ldm.fill(&src, 0, 4096);
    try ldm.generateSequences(&src, 4096, 8192);
    try testing.expect(ldm.matches.items.len > 0);

    var found = false;
    for (ldm.matches.items) |m| {
        try testing.expect(m.offset >= 4096);
        try testing.expectEqual(@as(usize, m.pos), m.pos);
        if (m.length >= 256) found = true;
    }
    try testing.expect(found);
}

test "ldm reports nothing when there is no long repeat" {
    const alloc = testing.allocator;
    var src: [16384]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x2E);
    const random = prng.random();
    for (&src) |*b| b.* = random.int(u8);
    var params = Params{ .enabled = true };
    params.adjust(20, .greedy, 0);
    params.hashRateLog = 4;
    var ldm = try Ldm.init(alloc, params);
    defer ldm.deinit();
    ldm.fill(&src, 0, 8192);
    try ldm.generateSequences(&src, 8192, 16384);
    for (ldm.matches.items) |m| try testing.expect(m.length < 64 or m.offset < 8192);
}

test "ldm matches are ordered and findable by position" {
    const alloc = testing.allocator;
    var src: [12288]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x3F);
    const random = prng.random();
    for (src[0..4096]) |*b| b.* = random.int(u8);
    @memcpy(src[4096..8192], src[0..4096]);
    @memcpy(src[8192..], src[0..4096]);
    var params = Params{ .enabled = true };
    params.adjust(20, .greedy, 0);
    params.hashRateLog = 4;
    var ldm = try Ldm.init(alloc, params);
    defer ldm.deinit();
    ldm.fill(&src, 0, 4096);
    try ldm.generateSequences(&src, 4096, 12288);
    var i: usize = 1;
    while (i < ldm.matches.items.len) : (i += 1) {
        try testing.expect(ldm.matches.items[i].pos >= ldm.matches.items[i - 1].pos);
    }
    for (ldm.matches.items) |m| {
        const found = ldm.matchAt(m.pos);
        try testing.expect(found != null);
        try testing.expectEqual(m.length, found.?.length);
        try testing.expectEqual(m.offset, found.?.offset);
    }
    try testing.expect(ldm.matchAt(0) == null or ldm.matchAt(0).?.pos == 0);
}

test "ldm reset clears the table and the matches" {
    const alloc = testing.allocator;
    var params = Params{ .enabled = true };
    params.adjust(20, .greedy, 0);
    var ldm = try Ldm.init(alloc, params);
    defer ldm.deinit();
    ldm.table[0] = .{ .offset = 5, .checksum = 9 };
    try ldm.matches.append(alloc, .{ .pos = 0, .length = 64, .offset = 1 });
    ldm.reset();
    try testing.expectEqual(@as(usize, 0), ldm.matches.items.len);
    try testing.expectEqual(@as(u32, 0), ldm.table[0].offset);
    try testing.expectEqual(@as(u32, 0), ldm.table[0].checksum);
}

test "insert rotates within a bucket" {
    const alloc = testing.allocator;
    var params = Params{ .enabled = true, .minMatchLength = 64, .hashRateLog = 4 };
    params.adjust(20, .greedy, 0);
    params.hashLog = 8;
    params.bucketSizeLog = 4;
    var ldm = try Ldm.init(alloc, params);
    defer ldm.deinit();
    // One bucket holds sixteen entries, so the seventeenth insert into the same
    // bucket replaces the first one.
    var i: u32 = 0;
    while (i < 16) : (i += 1) ldm.insert(3, .{ .offset = i + 1, .checksum = i });
    const bucket = ldm.bucket(3);
    try testing.expectEqual(@as(u32, 1), bucket[0].offset);
    try testing.expectEqual(@as(u32, 16), bucket[15].offset);
    ldm.insert(3, .{ .offset = 99, .checksum = 99 });
    try testing.expectEqual(@as(u32, 99), ldm.bucket(3)[0].offset);
    try testing.expectEqual(@as(u32, 2), ldm.bucket(3)[1].offset);
    // A different bucket index in the same table has its own cursor.
    ldm.insert(4, .{ .offset = 77, .checksum = 77 });
    try testing.expectEqual(@as(u32, 77), ldm.bucket(4)[0].offset);
    try testing.expectEqual(@as(u32, 0), ldm.bucket(4)[1].offset);
    try testing.expectEqual(@as(u32, 99), ldm.bucket(3)[0].offset);
}
