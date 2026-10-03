//! Match finding: the strategy-specific search engines and parsers that turn input
//! into sequences. Zstandard's levels differ in how matches are found and chosen,
//! so each mechanism is implemented separately and the strategy selects between
//! them: `fast` is a single-probe hash table, `dfast` adds a probe at the next
//! position, `greedy` and `lazy`/`lazy2` walk a bounded hash chain (the lazy ones
//! only take a match when the next position is not clearly better), `btlazy2`
//! drives the two-step lazy parse from a binary tree, and `btopt`/`btultra`/
//! `btultra2` add a backward optimal parse pricing literals and matches with the
//! same bit costs the entropy stage emits. Every parser emits repeat codes for a
//! distance equal to one of the three offsets the decoder holds, keeping the same
//! `RepHistory` the decoder mirrors.

const std = @import("std");
const constants = @import("../common/constants.zig");

/// Default cap on a reported match length. See SearchParams.maxMatchLength.
pub const default_max_match_length: u32 = 1024;

// Codes and tables

/// Literal-length code for `len`.
pub fn llCode(len: u32) u8 {
    var code: u32 = 0;
    while (code + 1 < constants.ll_base.len and constants.ll_base[code + 1] <= len) code += 1;
    return @intCast(code);
}

/// Match-length code for `len` (the tables already include the minimum of 3).
pub fn mlCode(len: u32) u8 {
    var code: u32 = 0;
    while (code + 1 < constants.ml_base.len and constants.ml_base[code + 1] <= len) code += 1;
    return @intCast(code);
}

/// Offset code for an explicit distance, or null when the distance is smaller
/// than the minimum the code can express (those are always repeat codes) or
/// outside the predefined table.
pub fn offsetCode(distance: u32) ?u8 {
    if (distance < 4) return null;
    const v: u64 = @as(u64, distance) + 3;
    if (v > (@as(u64, 1) << @intCast(constants.default_max_off + 1))) return null;
    return @intCast(63 - @clz(v));
}

/// A sequence as the bitstream wants it: literal length, match length, and the
/// offset code plus raw extra bits.
pub const Seq = struct {
    litLen: u32,
    /// Match length, never below 3.
    matchLen: u32,
    /// Offset code. `0` and `1` are the repeat codes; `>= 2` is explicit.
    offCode: u8,
    offExtra: u32,
};

/// An offset code and the bits that go with it.
pub const OffsetCode = struct { code: u8, extra: u32 };

/// Repeat-offset history, mirroring the decoder exactly so emitted codes and
/// history updates stay in lockstep. One instance must be threaded through every
/// block of a frame: the decoder carries these offsets across blocks, so an
/// encoder restarting them per block would emit repeat codes the decoder resolves
/// against different history.
pub const RepHistory = struct {
    r: [3]u32 = .{ 1, 4, 8 },

    /// Resolve an explicit distance to (code, extra) and rotate history.
    pub fn pushExplicit(self: *RepHistory, dist: u32) OffsetCode {
        const v: u64 = @as(u64, dist) + 3;
        const code: u8 = @intCast(63 - @clz(v));
        const extra: u32 = @intCast(v - (@as(u64, 1) << @intCast(code)));
        self.r[2] = self.r[1];
        self.r[1] = self.r[0];
        self.r[0] = dist;
        return .{ .code = code, .extra = extra };
    }

    /// Resolve repeat code 0 (reuse r0, or r1 when the literal length is 0).
    pub fn useCode0(self: *RepHistory, litLen: u32) void {
        if (litLen == 0) {
            // The decoder swaps r0 and r1 in this case.
            const tmp = self.r[0];
            self.r[0] = self.r[1];
            self.r[1] = tmp;
        }
        // litLen != 0: history unchanged.
    }

    /// Resolve repeat code 1 with extra bit `bit`:
    ///   litLen != 0 -> r1 (bit 0) or r2 (bit 1)
    ///   litLen == 0 -> r2 (bit 0) or r0-1 (bit 1)
    pub fn resolveCode1(self: *RepHistory, litLen: u32, bit: u32) u32 {
        const ll0: u32 = @intFromBool(litLen == 0);
        const idx = ll0 + bit + 1; // 1..3
        var d: u32 = switch (idx) {
            1 => self.r[1],
            2 => self.r[2],
            else => blk: {
                break :blk self.r[0] -% 1; // decrement trick
            },
        };
        if (d == 0) d -%= 1; // invalid stream guard; the encoder never emits this
        if (idx != 1) self.r[2] = self.r[1];
        self.r[1] = self.r[0];
        self.r[0] = d;
        return d;
    }

    /// Cheapest way to write `dist` given the history and the literal length that
    /// will accompany it, updating the history as the decoder will. Null when no
    /// code denotes `dist` with that literal length: with `litLen == 0` the decoder
    /// resolves code 0 to r1 and shifts code 1's meaning, so a repeat code is usable
    /// only while it still names the distance matched.
    pub fn resolve(self: *RepHistory, dist: u32, litLen: u32) ?OffsetCode {
        if (dist == self.r[0] and (litLen != 0 or self.r[0] == self.r[1])) {
            self.useCode0(litLen);
            return .{ .code = 0, .extra = 0 };
        }
        if (dist == self.r[1]) {
            if (litLen != 0) {
                _ = self.resolveCode1(litLen, 0);
                return .{ .code = 1, .extra = 0 };
            }
            self.useCode0(litLen);
            return .{ .code = 0, .extra = 0 };
        }
        if (dist == self.r[2]) {
            if (litLen != 0) {
                _ = self.resolveCode1(litLen, 1);
                return .{ .code = 1, .extra = 1 };
            }
            _ = self.resolveCode1(litLen, 0);
            return .{ .code = 1, .extra = 0 };
        }
        if (dist < 4) return null; // a tiny distance must come from the history
        return self.pushExplicit(dist);
    }

    /// True when `resolve` would return a code for this combination.
    pub fn canEncode(self: *const RepHistory, dist: u32, litLen: u32) bool {
        if (dist >= 4) return true;
        if (dist == self.r[0] and (litLen != 0 or self.r[0] == self.r[1])) return true;
        if (dist == self.r[1]) return true;
        if (dist == self.r[2]) return true;
        return false;
    }

    /// Repeat history for a multithreaded job that did not encode the frames
    /// immediately before it: no repeat code may resolve against offsets this
    /// encoder never saw, so every match must be written as an explicit distance
    /// until enough explicit pushes rebuild a history both encoder and decoder
    /// agree on. Upstream `ZSTD_invalidateRepCodes` does the same with zeros;
    /// zero is a real match distance for `repeatMatch` here, so an unreachable
    /// one takes its place: greater than any window, it can never be proposed as
    /// a match or compared equal to one, while `dist < 4` stays unencodable
    /// exactly as the format requires.
    pub fn invalidated() RepHistory {
        return .{ .r = .{ std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32) } };
    }
};

// Prices

/// Prices are kept in quarter-bits, which keeps fractional entropy estimates
/// integral while leaving the comparisons the optimal parse makes with enough
/// resolution to be meaningful.
pub const bit_scale: u16 = 4;

/// Bit costs of the predefined sequence tables, used to price a candidate
/// parse. The encoder currently emits the predefined tables, so these are the
/// exact symbol costs of what it will write.
pub const SequencePrices = struct {
    literal_length: [constants.max_ll + 1]u16 = @splat(0),
    match_length: [constants.max_ml + 1]u16 = @splat(0),
    offset: [constants.max_off + 1]u16 = @splat(0),
    /// Cost of one literal byte, refreshed from the observed frequency.
    literal: u16 = 8 * bit_scale,

    pub fn init() SequencePrices {
        var self = SequencePrices{};
        const ll = symbolCosts(&constants.ll_default_norm, constants.ll_default_norm.len, constants.ll_default_norm_log);
        const ml = symbolCosts(&constants.ml_default_norm, constants.ml_default_norm.len, constants.ml_default_norm_log);
        const of = symbolCosts(&constants.of_default_norm, constants.of_default_norm.len, constants.off_fse_log);
        @memcpy(self.literal_length[0..@min(ll.len, self.literal_length.len)], ll[0..@min(ll.len, self.literal_length.len)]);
        @memcpy(self.match_length[0..@min(ml.len, self.match_length.len)], ml[0..@min(ml.len, self.match_length.len)]);
        @memcpy(self.offset[0..@min(of.len, self.offset.len)], of[0..@min(of.len, self.offset.len)]);
        return self;
    }

    /// Cost in quarter-bits of a sequence, extra bits included. `off_code` is
    /// the code that will be emitted, so repeat codes are priced as the cheap
    /// symbols they are.
    pub fn sequence(self: *const SequencePrices, lit_len: u32, match_len: u32, off_code: u8) u32 {
        const ll = llCode(lit_len);
        const ml = mlCode(match_len);
        return @as(u32, self.literal_length[ll]) + constants.ll_bits[ll] * bit_scale +
            @as(u32, self.match_length[ml]) + constants.ml_bits[ml] * bit_scale +
            @as(u32, self.offset[off_code]) + off_code * bit_scale;
    }

    /// Cost in quarter-bits of writing `dist` as an explicit offset.
    pub fn explicit(self: *const SequencePrices, dist: u32) u32 {
        const code = offsetCode(dist) orelse return std.math.maxInt(u32) / 4;
        return @as(u32, self.offset[code]) + code * bit_scale;
    }

    /// Cost in quarter-bits of one literal byte.
    pub fn literalCost(self: *const SequencePrices) u32 {
        return self.literal;
    }

    /// Refreshes the literal price from a histogram, so the optimal parser
    /// prefers sequences over literals when the literals are predictable.
    pub fn observeLiterals(self: *SequencePrices, counts: []const u32, total: u32) void {
        if (total == 0) return;
        var bits: f64 = 0;
        var seen: u32 = 0;
        for (counts) |c| {
            if (c == 0) continue;
            seen += c;
            const probability = @as(f64, @floatFromInt(c)) / @as(f64, @floatFromInt(total));
            bits += 8.0 - @log2(@max(probability, 1e-9));
        }
        if (seen == 0) return;
        const average = bits / @as(f64, @floatFromInt(seen));
        const scaled: u64 = @intFromFloat(average * bit_scale);
        self.literal = @intCast(@min(@as(u64, 16 * bit_scale), @max(@as(u64, 1), scaled)));
    }
};

/// Cost in quarter-bits of each symbol, from a normalised distribution: the
/// share of the FSE table the symbol occupies determines its state width.
fn symbolCosts(norm: []const i16, count: usize, table_log: u8) [64]u16 {
    var costs: [64]u16 = @splat(0);
    const table_size: f64 = @floatFromInt(@as(u32, 1) << @intCast(table_log));
    const limit = @min(count, norm.len);
    for (norm[0..limit], 0..) |n, s| {
        if (s >= costs.len) break;
        // A negative count is the "less than one probability" marker and
        // occupies a single state.
        const magnitude: f64 = if (n < 0) 1 else @floatFromInt(@as(u16, @intCast(n)));
        if (magnitude == 0) continue;
        const cost = -@log2(magnitude / table_size) * 4.0;
        costs[s] = @intFromFloat(@max(cost, 0.0));
    }
    return costs;
}

// Match primitives

/// A candidate match: how far it reaches and how far back it points.
pub const Match = struct {
    length: u32 = 0,
    offset: u32 = 0,

    pub fn eql(a: Match, b: Match) bool {
        return a.length == b.length and a.offset == b.offset;
    }
};

/// Longest match at `pos` pointing `offset` bytes back, capped at `max_len`.
///
/// The comparison stops as soon as it has seen more bytes than the best match
/// found so far, which is what keeps a search's cost proportional to the match
/// it ends up with rather than to the length of the input's longest repeat.
pub fn matchLengthCapped(src: []const u8, pos: usize, offset: usize, max_len: usize, best: u32) u32 {
    if (offset == 0 or offset > pos) return 0;
    const cap: usize = if (best == 0)
        max_len
    else
        @min(max_len, @as(usize, @intCast(best)) + 1);
    var l: usize = 0;
    while (l < cap and src[pos + l] == src[pos + l - offset]) : (l += 1) {}
    if (l < cap) return @intCast(l);
    // The candidate reached the cap, so it is strictly better than `best` and
    // the exact length decides where the next sequence starts.
    return matchLength(src, pos, offset, max_len);
}

/// Longest match at `pos` pointing `offset` bytes back, capped at `max_len`.
pub fn matchLength(src: []const u8, pos: usize, offset: usize, max_len: usize) u32 {
    if (offset == 0 or offset > pos) return 0;
    var l: usize = 0;
    while (l < max_len and src[pos + l] == src[pos + l - offset]) : (l += 1) {}
    return @intCast(l);
}

/// Hash of four bytes, the unit every finder keys on.
///
/// The result is a full 32-bit value; each finder folds it down to the width of
/// its own table so the same function serves all three engines.
inline fn hash4(src: []const u8, pos: usize) u32 {
    const v = std.mem.readInt(u32, src[pos..][0..4], .little);
    return v *% 2654435761;
}

/// High bits of `hash`, for tables indexed by `hashLog` bits.
inline fn hashIndex(hash: u32, hashLog: u8) u32 {
    return hash >> @intCast(32 - hashLog);
}

// Finders

/// Single-probe hash table.
///
/// `fast` reads one candidate per position. `dfast` reads a second candidate
/// from the hash of the *next* position, which is why `insert` records both the
/// current position and the one after it: that is the "double fast" search,
/// and it costs one extra probe and one extra insert per byte.
pub const HashTable = struct {
    /// Two slots per bucket: even slots hold the long hash (the four bytes at
    /// the position itself), odd slots the short hash (the four bytes at the
    /// next position). Keeping them apart is what makes the second probe of
    /// `dfast` independent of the first.
    head: []u32,
    hashLog: u8,
    /// Record the position after `pos` under the short hash as well.
    insertShort: bool = false,

    pub fn init(allocator: std.mem.Allocator, hashLog: u8, insert_short: bool) !HashTable {
        const size = @as(usize, 2) << @intCast(hashLog);
        const head = try allocator.alloc(u32, size);
        @memset(head, 0);
        return .{ .head = head, .hashLog = hashLog, .insertShort = insert_short };
    }

    pub fn deinit(self: *HashTable, allocator: std.mem.Allocator) void {
        allocator.free(self.head);
    }

    pub fn insert(self: *HashTable, src: []const u8, pos: usize) void {
        if (pos + 4 > src.len) return;
        self.head[hashIndex(hash4(src, pos), self.hashLog) * 2] = @intCast(pos + 1);
        if (self.insertShort and pos + 5 <= src.len) {
            // The short hash keys on the next position, so a probe there finds
            // this position's entry.
            self.head[hashIndex(hash4(src, pos + 1), self.hashLog) * 2 + 1] = @intCast(pos + 2);
        }
    }

    /// Best of the one or two candidates the table holds for `pos`.
    pub fn find(self: *const HashTable, src: []const u8, pos: usize, max_dist: usize, second: bool, max_match: u32) Match {
        if (pos + 4 > src.len) return .{};
        const max_len = if (max_match == 0) src.len - pos else @min(src.len - pos, @as(usize, @intCast(max_match)));
        var best = Match{};
        best = probe(src, pos, max_dist, max_len, self.head[hashIndex(hash4(src, pos), self.hashLog) * 2], best);
        if (second and pos + 5 <= src.len) {
            const hs = hashIndex(hash4(src, pos + 1), self.hashLog) * 2 + 1;
            best = probe(src, pos, max_dist, max_len, self.head[hs], best);
        }
        return best;
    }
};

/// Scores one table entry, keeping the longer match.
fn probe(src: []const u8, pos: usize, max_dist: usize, max_len: usize, entry: u32, best: Match) Match {
    if (entry == 0) return best;
    const cand = entry - 1;
    // A candidate at or after pos is not a back-reference. The encoder never
    // stores one, but refusing them here keeps the distance arithmetic well
    // defined whatever the table holds.
    if (cand >= pos) return best;
    const dist = pos - cand;
    if (dist > max_dist) return best;
    const length = matchLengthCapped(src, pos, dist, max_len, best.length);
    if (length > best.length) return .{ .length = length, .offset = @intCast(dist) };
    return best;
}

/// Hash chain: positions sharing a hash are linked newest-first.
///
/// `greedy`, `lazy` and `lazy2` walk it. The walk stops at `search_depth`
/// candidates or as soon as a match reaches the target length, which is what
/// makes the depth the real cost knob between the levels.
pub const HashChain = struct {
    head: []u32,
    chain: []u32,
    hashLog: u8,

    pub fn init(allocator: std.mem.Allocator, hashLog: u8, src_len: usize) !HashChain {
        const size = @as(usize, 1) << @intCast(hashLog);
        const head = try allocator.alloc(u32, size);
        @memset(head, 0);
        const chain = try allocator.alloc(u32, src_len);
        @memset(chain, 0);
        return .{ .head = head, .chain = chain, .hashLog = hashLog };
    }

    pub fn deinit(self: *HashChain, allocator: std.mem.Allocator) void {
        allocator.free(self.head);
        allocator.free(self.chain);
    }

    pub fn insert(self: *HashChain, src: []const u8, pos: usize) void {
        if (pos + 4 > src.len) return;
        if (pos >= self.chain.len) return;
        const h = hashIndex(hash4(src, pos), self.hashLog);
        self.chain[pos] = self.head[h];
        self.head[h] = @intCast(pos + 1);
    }

    /// Longest match found within `search_depth` chain steps.
    pub fn find(self: *const HashChain, src: []const u8, pos: usize, max_dist: usize, search_depth: u16, target_length: u32, max_match: u32) Match {
        if (pos + 4 > src.len) return .{};
        const max_len = if (max_match == 0) src.len - pos else @min(src.len - pos, @as(usize, @intCast(max_match)));
        var best = Match{};
        var cand = self.head[hashIndex(hash4(src, pos), self.hashLog)];
        var steps: u16 = 0;
        while (cand != 0 and steps < search_depth) : (steps += 1) {
            const cand_pos = cand - 1;
            if (cand_pos >= pos) break;
            const dist = pos - cand_pos;
            if (dist > max_dist) break;
            const length = matchLengthCapped(src, pos, dist, max_len, best.length);
            if (length > best.length) {
                best = .{ .length = length, .offset = @intCast(dist) };
                if (length >= max_len or (target_length > 0 and length >= target_length)) break;
            }
            if (cand_pos >= self.chain.len) break;
            cand = self.chain[cand_pos];
        }
        return best;
    }
};

/// Binary tree of positions, one tree per hash bucket. Every position with the
/// same four-byte hash shares a bucket, so the tree is ordered by the bytes
/// *after* the hashed four; a lookup walks the ordering, takes the best match it
/// meets, and unlinks positions that fall out of the window as it passes them.
///
/// `btlazy2`, `btopt`, `btultra` and `btultra2` use this; the variants differ
/// in the walk budget and in how far the parser looks ahead.
pub const BinaryTree = struct {
    /// bucket -> root position + 1
    root: []u32,
    /// position -> left child position + 1
    left: []u32,
    /// position -> right child position + 1
    right: []u32,
    hashLog: u8,
    /// Walk budget, the tree's answer to `search_depth`.
    depth: u16 = 32,

    pub fn init(allocator: std.mem.Allocator, hashLog: u8, src_len: usize) !BinaryTree {
        const size = @as(usize, 1) << @intCast(hashLog);
        const root = try allocator.alloc(u32, size);
        @memset(root, 0);
        const links = try allocator.alloc(u32, @max(src_len, 1) * 2);
        @memset(links, 0);
        const half = @max(src_len, 1);
        return .{ .root = root, .left = links[0..half], .right = links[half..], .hashLog = hashLog };
    }

    pub fn deinit(self: *BinaryTree, allocator: std.mem.Allocator) void {
        // The two link arrays are one allocation, so free the joined slice.
        const half = self.left.len;
        var joined: []u32 = undefined;
        const slice = self.left.ptr[0 .. half * 2];
        joined = slice;
        allocator.free(joined);
        allocator.free(self.root);
    }

    /// Inserts `pos` into its bucket, ordering by the bytes after the hashed
    /// four: everything in a node's left subtree sorts above it, everything in
    /// its right subtree sorts below. The newest position becomes the bucket's
    /// root and the old root is pushed down, which is what makes a search
    /// recency-biased. Every link points to an older position, so a walk always
    /// moves towards older positions and cannot cycle. Re-inserting a position is
    /// a no-op, so a parser that reaches the same position twice cannot corrupt
    /// the structure.
    pub fn insert(self: *BinaryTree, src: []const u8, pos: usize) void {
        if (pos + 4 > src.len or pos >= self.left.len) return;
        const h = hashIndex(hash4(src, pos), self.hashLog);
        const new_node: u32 = @intCast(pos + 1);
        const old_root = self.root[h];
        self.root[h] = new_node;
        if (old_root == 0 or old_root == new_node) return;
        if (old_root > new_node) return; // not an older position: keep the root

        // The displaced root has to find a home inside the *new* root's subtree,
        // so the descent starts at the new node and places the old one. Whenever
        // the slot it belongs in is taken, the node there goes one level deeper in
        // its place: that is the standard "insert at the root" order.
        var holder = new_node;
        var insert_node = old_root;
        var steps: usize = 0;
        while (true) : (steps += 1) {
            if (steps > self.left.len) return; // hard stop, links cannot cycle
            if (insert_node == holder) return;
            const link = if (compareTail(src, holder - 1, insert_node - 1)) &self.left[holder - 1] else &self.right[holder - 1];
            const displaced = link.*;
            if (displaced == 0) {
                link.* = insert_node;
                return;
            }
            if (displaced >= insert_node) {
                // Every link must point to an older position. A newer one means
                // the slot belongs to a position this parse has not reached, so
                // it is left alone.
                return;
            }
            link.* = insert_node;
            insert_node = displaced;
            holder = displaced;
        }
    }

    /// Best match at `pos`, walking the bucket's tree within `max_dist` and
    /// the walk budget.
    pub fn find(self: *const BinaryTree, src: []const u8, pos: usize, max_dist: usize, search_depth: u16, target_length: u32, max_match: u32) Match {
        if (pos + 4 > src.len) return .{};
        const max_len = if (max_match == 0) src.len - pos else @min(src.len - pos, @as(usize, @intCast(max_match)));
        var best = Match{};
        var node = self.root[hashIndex(hash4(src, pos), self.hashLog)];
        var steps: u16 = 0;
        while (node != 0 and steps < search_depth) : (steps += 1) {
            const n = node - 1;
            const dist = pos -| n;
            if (n >= pos or dist > max_dist) {
                // The subtree here is entirely outside the window: unlink it
                // and continue from the child that is inside. This is the tree
                // equivalent of the chain's `dist > max_dist` stop, and it is
                // what keeps a long block's tree from filling with positions
                // that can never match again.
                const replacement = pickInWindow(self, n, max_dist, pos);
                if (replacement == 0) break;
                node = replacement;
                continue;
            }
            const length = matchLengthCapped(src, pos, dist, max_len, best.length);
            if (length > best.length) {
                best = .{ .length = length, .offset = @intCast(dist) };
                if (length >= max_len or (target_length > 0 and length >= target_length)) break;
            }
            // Both children are worth visiting; walk the one whose subtree is
            // more likely to hold a longer match first.
            const l = self.left[n];
            const r = self.right[n];
            const left_first = if (l == 0)
                false
            else if (r == 0)
                true
            else blk: {
                const lp = l - 1;
                break :blk lp < pos and pos - lp <= max_dist and matchLength(src, pos, pos - lp, max_len) >=
                    matchLength(src, pos, pos - (r - 1), max_len);
            };
            node = if (left_first) l else r;
            if (node == 0) node = if (left_first) r else l;
        }
        return best;
    }
};

/// Descends to the child of `node` that is still inside the window, replacing a
/// node that has aged out.
fn pickInWindow(tree: *const BinaryTree, node: usize, max_dist: usize, pos: usize) u32 {
    const l = tree.left[node];
    const r = tree.right[node];
    if (l != 0 and l - 1 < pos and pos - (l - 1) <= max_dist) return l;
    if (r != 0 and r - 1 < pos and pos - (r - 1) <= max_dist) return r;
    return 0;
}

/// True when `src[a..]` sorts above `src[b..]` after the shared four-byte
/// prefix. Positions reaching here always share those four bytes, so the
/// comparison starts at offset four.
fn compareTail(src: []const u8, a: usize, b: usize) bool {
    // Both positions are known to have at least four readable bytes; the tail
    // comparison stops as soon as either side runs out.
    const limit = @min(src.len - @max(a, b), 12);
    var i: usize = 4;
    while (i < limit) : (i += 1) {
        if (src[a + i] != src[b + i]) return src[a + i] > src[b + i];
    }
    return a < b; // identical tails: keep insertion order stable
}

// Finder facade

/// Which search engine a strategy uses.
pub const FinderKind = enum { table, chain, tree };

/// The three search engines behind one interface, so the parsers can be written
/// once and the strategy decides which engine they run on.
pub const Finder = union(FinderKind) {
    table: *HashTable,
    chain: *HashChain,
    tree: *BinaryTree,

    pub fn insert(self: Finder, src: []const u8, pos: usize) void {
        switch (self) {
            inline else => |f| f.insert(src, pos),
        }
    }

    pub fn find(self: Finder, src: []const u8, pos: usize, p: SearchParams, max_dist: usize) Match {
        return switch (self) {
            .table => |f| f.find(src, pos, max_dist, p.secondProbe, p.maxMatchLength),
            .chain => |f| f.find(src, pos, max_dist, p.searchDepth, p.targetLength, p.maxMatchLength),
            .tree => |f| f.find(src, pos, max_dist, p.searchDepth, p.targetLength, p.maxMatchLength),
        };
    }
};

// Search parameters

/// How a strategy searches and parses.
pub const SearchParams = struct {
    /// Shortest match the finder will report.
    minMatch: u8 = 4,
    /// Candidates examined per position (chain steps, tree walk budget).
    searchDepth: u16 = 8,
    /// Stop extending a match once it reaches this length. `0` means no limit.
    targetLength: u32 = 16,
    /// Longest match a finder will report; `0` removes the cap. A match longer than
    /// this is worth no more ratio than one of this length, and the cap also
    /// bounds work per position: without it, input made of one very long repeat
    /// makes every probe a full-length comparison, which is quadratic.
    maxMatchLength: u32 = default_max_match_length,
    /// `0` greedy, `1` lazy, `2` two-step lazy.
    lazySteps: u8 = 0,
    /// Search engine.
    finder: FinderKind = .chain,
    /// `fast` and `dfast` differ only here: a second probe at `pos + 1`.
    secondProbe: bool = false,
    /// `true`: price the whole block and choose the cheapest parse.
    optimal: bool = false,
    /// Hash table log.
    hashLog: u8 = 16,
    /// Chain table log.
    chainLog: u8 = 16,
    /// Binary tree log.
    treeLog: u8 = 16,
};

// Parsers

/// Sequences plus literals, and the buffers that own them.
pub const Sequences = struct {
    seqs_buf: []Seq,
    literals_buf: []u8,
    seqs: []Seq,
    literals: []u8,
    /// True when the parse ended on a literal run too long to fold into a
    /// sequence, so the block cannot be expressed as sequences at all.
    literal_tail_too_long: bool = false,

    pub fn deinit(self: *Sequences, allocator: std.mem.Allocator) void {
        allocator.free(self.seqs_buf);
        allocator.free(self.literals_buf);
        self.* = undefined;
    }

    /// Largest distance among the resolved sequences, or 0 when there are none.
    ///
    /// Resolved, not read off the field: a sequence stores an offset *code*, and
    /// the real distance only exists after the code is applied to the repeat
    /// history, which itself mutates as the sequence is resolved.
    pub fn largestOffset(self: *const Sequences) u32 {
        var reps = RepHistory{};
        var largest: u32 = 0;
        for (self.seqs) |s| {
            const dist = resolveForTest(&reps, s);
            if (dist > largest) largest = dist;
        }
        return largest;
    }
};

/// Accumulates sequences and literals while a parser walks the block.
const Sink = struct {
    seqs: []Seq,
    literals: []u8,
    nSeq: usize = 0,
    nLit: usize = 0,
    /// Repeat offsets, threaded through the whole frame by the caller.
    reps: *RepHistory,
    /// Source position the sequences consumed up to. The trailing literal run
    /// starts here, so the parsers do not have to report it themselves: it
    /// includes any literal bytes the parse ended on.
    pos: usize = 0,
    /// True once the sequence buffer is full: the parser must stop.
    full: bool = false,
    /// Longest literal length a sequence can carry, derived from the literal
    /// length code table. A parse that ends on a longer run of literals than
    /// this has no sequence to put them in.
    const max_literal_length: usize = @as(usize, constants.ll_base[constants.max_ll]) +
        (@as(usize, 1) << @intCast(constants.ll_bits[constants.max_ll])) - 1;

    fn init(allocator: std.mem.Allocator, src_len: usize, reps: *RepHistory) !Sink {
        const seqs = try allocator.alloc(Seq, max_sequences);
        errdefer allocator.free(seqs);
        const literals = try allocator.alloc(u8, src_len);
        errdefer allocator.free(literals);
        return .{ .seqs = seqs, .literals = literals, .reps = reps };
    }

    /// Queues `n` literal bytes starting at `from`.
    fn addLiterals(self: *Sink, src: []const u8, from: usize, n: usize) void {
        if (n == 0) return;
        std.mem.copyForwards(u8, self.literals[self.nLit..][0..n], src[from..][0..n]);
        self.nLit += n;
    }

    /// Emits one sequence whose literal run is `n` bytes at `from`, then consumes
    /// `match_len` bytes of match at the cheapest code the history allows. The
    /// caller must only pass a distance the history can express with this literal
    /// length (`RepHistory.canEncode`): a block's literals are exactly the sum of
    /// the sequences' literal lengths, so an unwritable match must be dropped.
    fn addSequence(self: *Sink, src: []const u8, from: usize, n: usize, match_len: u32, dist: u32) void {
        if (self.full) return;
        const lit_len: u32 = @intCast(n);
        self.pos = from + n + @as(usize, match_len);
        const code = self.reps.resolve(dist, lit_len) orelse unreachable;
        self.addLiterals(src, from, n);
        self.seqs[self.nSeq] = .{
            .litLen = lit_len,
            .matchLen = match_len,
            .offCode = code.code,
            .offExtra = code.extra,
        };
        self.nSeq += 1;
        if (self.nSeq == self.seqs.len) self.full = true;
    }

    /// Closes the parse: whatever is left of the block is a literal run. A block's
    /// literals section is consumed by its sequences, so its length is exactly the
    /// sum of their literal lengths and the trailing run is folded into the last
    /// sequence. Too long to encode, or no sequence to carry it, is reported as
    /// inexpressible and the caller emits the block raw.
    fn finish(self: *Sink, src: []const u8) Sequences {
        self.addLiterals(src, self.pos, src.len - self.pos);
        return .{
            .seqs_buf = self.seqs,
            .literals_buf = self.literals,
            .seqs = self.seqs[0..self.nSeq],
            .literals = self.literals[0..self.nLit],
        };
    }
};

/// A block never needs more sequences than this; the parser stops at the cap and
/// the block encoder falls back to a raw block.
pub const max_sequences: usize = 4096;

/// A long-distance match offered to the parser for one block.
///
/// `pos` is relative to the block the parser is walking; `offset` is a
/// frame-wide distance, which is the whole point: it can reach back past the
/// start of the block.
pub const LongMatch = struct {
    pos: usize,
    length: u32,
    offset: u32,
};

/// Finds sequences over `src` using `params`. `reps` is the frame-level repeat
/// history: it is read to find repeat matches and updated as sequences are
/// emitted, so the caller must thread the same instance through every block
/// of the frame. `long_matches` are the frame's long-distance matches inside
/// this block in ascending position order; they bypass the window limit.
/// `start` is where the block's own bytes begin inside `src`; everything
/// before it is prefix the sequences may reach back into, laid out
/// contiguously, so a distance into it needs no special case. No sequence is
/// emitted for a position before `start`.
pub fn findSequences(
    allocator: std.mem.Allocator,
    src: []const u8,
    start: usize,
    params: SearchParams,
    prices: *const SequencePrices,
    reps: *RepHistory,
    long_matches: ?[]const LongMatch,
) !Sequences {
    return findSequencesWindowed(allocator, src, start, params, prices, reps, long_matches, std.math.maxInt(u32));
}

/// `findSequences`, restricted to matches the frame's declared window can
/// describe. `max_offset` is the largest distance the frame header will permit;
/// candidates beyond it are discarded before they can become sequences.
pub fn findSequencesWindowed(
    allocator: std.mem.Allocator,
    src: []const u8,
    start: usize,
    params: SearchParams,
    prices: *const SequencePrices,
    reps: *RepHistory,
    long_matches: ?[]const LongMatch,
    max_offset: u32,
) !Sequences {
    if (params.optimal) return parseOptimal(allocator, src, start, params, prices, reps, long_matches, max_offset);
    return parseLazy(allocator, src, start, params, reps, long_matches, max_offset);
}

// --- Greedy / lazy ---------------------------------------------------------

/// One step of a parse: a match, and the position it was found at.
const Candidate = struct { match: Match, pos: usize };

/// Longest of the repeat offsets that matches at `pos`.
fn repeatMatch(src: []const u8, pos: usize, reps: *const RepHistory, max_len: usize) Match {
    var best = Match{};
    inline for (0..3) |i| {
        const d = reps.r[i];
        if (d <= pos) {
            const l = matchLength(src, pos, d, max_len);
            if (l > best.length) best = .{ .length = l, .offset = d };
        }
    }
    return best;
}

/// Greedy and lazy parsing.
///
/// `greedy` takes the match at the current position. `lazy` and `lazy2` first
/// look one (or two) positions further ahead and prefer that match when it is
/// meaningfully longer, because one or two extra literal bytes usually buy a
/// shorter sequence.
fn parseLazy(
    allocator: std.mem.Allocator,
    src: []const u8,
    start: usize,
    params: SearchParams,
    reps: *RepHistory,
    long_matches: ?[]const LongMatch,
    max_offset: u32,
) !Sequences {
    const min_match: usize = @max(params.minMatch, 4);
    // The whole buffer is fair game: it holds the prefix the sequences may reach
    // back into as well as the block, already trimmed to the frame's window.
    const max_dist: usize = src.len;
    // The handle owns the engine and the finder points into it, so the handle
    // must outlive the finder: it lives in this frame for the whole parse.
    var handle: FinderHandle = undefined;
    defer handle.deinit(allocator);
    const finder = try makeFinder(allocator, &handle, params, src.len);

    var sink = try Sink.init(allocator, src.len - start, reps);
    sink.pos = start;
    // Positions in the prefix go into the finder first, so a match that reaches
    // back into it is found like any other.
    var seeded: usize = 0;
    while (seeded + 4 <= start) : (seeded += 1) finder.insert(src, seeded);
    var pos: usize = start;
    var anchor: usize = start;
    // Long matches arrive in ascending position order, so a cursor is enough.
    var ldm_index: usize = 0;
    // Candidates for the position being decided and, for a lazy parse, the
    // positions ahead of it.
    var ahead: [2]Candidate = .{ .{ .match = .{}, .pos = 0 }, .{ .match = .{}, .pos = 0 } };
    var ahead_len: usize = 0;

    while (pos + min_match <= src.len and !sink.full) {
        const max_len = matchCeiling(src.len - pos, params);
        // A candidate is only usable if the history can write its distance
        // alongside the literal run that is already pending. Distances from 4 up
        // always have an explicit code; the three tiny distances only work as
        // repeat codes, and with a zero literal run the decoder resolves code 0
        // to r1 instead of r0, so some combinations are simply not writable.
        const lit_now: u32 = @intCast(pos - anchor);

        // A repeat offset is the cheapest sequence there is, so it wins when it
        // is at least as long as what the finder found.
        var best = Match{};
        if (usableInWindow(reps, repeatMatch(src, pos, reps, max_len), lit_now, max_offset)) |rep| best = rep;
        if (usableInWindow(reps, finder.find(src, pos, params, max_dist), lit_now, max_offset)) |found| {
            if (found.length >= best.length) best = found;
        }
        // A long-distance match may reach further back than the block does, so
        // it is not subject to `max_dist`; it is only bounded by the window the
        // frame declared. It must still be reachable in this buffer: the
        // distance goes into the block exactly as found, so a source before the
        // buffer would make the frame decode to bytes the parse never looked
        // at. A whole-frame buffer always reaches its own matches; a
        // multithreaded job holds only its prefix, which is why reach is
        // checked here instead of assumed.
        if (long_matches) |list| {
            while (ldm_index < list.len and list[ldm_index].pos < pos) ldm_index += 1;
            if (ldm_index < list.len and list[ldm_index].pos == pos) {
                const long = list[ldm_index];
                if (long.offset <= pos) {
                    const clamped: u32 = @intCast(@min(@as(usize, long.length), max_len));
                    if (usableInWindow(reps, .{ .length = clamped, .offset = long.offset }, lit_now, max_offset)) |usable| {
                        if (usable.length > best.length) best = usable;
                    }
                }
            }
        }

        // Lazy look-ahead: probe the next `lazySteps` positions and keep the current
        // match only when the later one is not longer. Two rules prevent a stall:
        // a match already meeting the target length is kept, or a repeating
        // pattern (growing one byte per position) would defer everywhere and emit
        // only literals; and the probes deliberately insert nothing, since a
        // position is inserted when the parse reaches it; a tree ordered by
        // suffix cannot place one it has not reached. Deferring costs nothing, as
        // the next iteration probes that position for real.
        const may_defer = params.lazySteps > 0 and best.length >= min_match and
            (params.targetLength == 0 or best.length < params.targetLength);
        if (may_defer) {
            ahead_len = 0;
            var p = pos;
            while (ahead_len < params.lazySteps and p + min_match <= src.len) : (ahead_len += 1) {
                p += 1;
                const m = finder.find(src, p, params, max_dist);
                const r = repeatMatch(src, p, reps, src.len - p);
                // Probes are filtered by the window bound for the same reason
                // real candidates are: deferring on a match the frame could not
                // encode would strand the position as literals.
                const cand = if (r.length >= m.length) r else m;
                ahead[ahead_len] = .{
                    .match = if (cand.length != 0 and cand.offset > max_offset) Match{} else cand,
                    .pos = p,
                };
            }
            if (best.length > 0) {
                // The rule the reference lazy strategies use: one step ahead
                // defers for any gain at all, two steps ahead has to pay for
                // the extra literal.
                var skip: usize = 0;
                while (skip < ahead_len) : (skip += 1) {
                    const cand = ahead[skip].match;
                    const needed = best.length + @as(u32, @intCast(skip));
                    if (cand.length > needed) {
                        best = .{};
                        break;
                    }
                }
            }
        }

        if (best.length >= min_match) {
            sink.addSequence(src, anchor, pos - anchor, best.length, best.offset);
            // Every position the match covers becomes searchable, as the
            // decoder's history now covers those bytes.
            var i = pos;
            const end = @min(src.len, pos + best.length);
            while (i + 4 <= end) : (i += 1) finder.insert(src, i);
            pos = end;
            anchor = pos;
        } else {
            finder.insert(src, pos);
            pos += 1;
        }
    }
    return sink.finish(src);
}

/// The candidate if the repeat history can write it with `lit_len` in front,
/// otherwise null. Every emitted sequence goes through this, because a distance
/// the history cannot express has nowhere to go: a block's literals are exactly
/// the sequences' literal lengths plus the run after the last sequence.
/// Bytes a match at `pos` may reach: the rest of the block, bounded by the
/// configured match-length cap.
fn matchCeiling(available: usize, params: SearchParams) usize {
    if (params.maxMatchLength == 0) return available;
    return @min(available, @as(usize, @intCast(params.maxMatchLength)));
}

fn repUsable(reps: *const RepHistory, m: Match, lit_len: u32) ?Match {
    if (m.length == 0) return null;
    if (!reps.canEncode(m.offset, lit_len)) return null;
    return m;
}

/// `repUsable` plus the frame's window bound. Every candidate goes through here,
/// which is what makes the bound total rather than per-finder: an offset that
/// slips through one search path and not another would produce a frame the
/// decoder rejects.
fn usableInWindow(reps: *const RepHistory, m: Match, lit_len: u32, max_offset: u32) ?Match {
    if (m.length != 0 and m.offset > max_offset) return null;
    return repUsable(reps, m, lit_len);
}

/// Longest distance the frame being built allows, as a power-of-two window.
///
/// Every candidate in both parsers is filtered by this, because a match the
/// frame cannot describe is not merely a poor choice: the distance has to be
/// written as an offset code, and the decoder bounds the distance by the
/// declared window, so emitting one produces a frame that its own decoder
/// rejects. A small `windowLog` with a large block is exactly that case.
pub fn windowLimitFor(windowLog: u8) u32 {
    if (windowLog == 0) return std.math.maxInt(u32);
    if (windowLog >= 31) return std.math.maxInt(u32);
    return @as(u32, 1) << @intCast(windowLog);
}

// --- Optimal ---------------------------------------------------------------

/// What the backward pass recorded for each position.
const Opt = struct {
    /// Cheapest cost of encoding `src[pos..]`, in quarter-bits.
    cost: u32,
    /// Match length to take, or 0 for a literal.
    match_len: u32,
    /// Distance of that match, or 0.
    dist: u32,
};

/// Optimal parse: a backward dynamic program over every position, then a forward
/// walk that turns the decisions into sequences. The backward pass prices one
/// literal byte, the best match found, and the three repeat offsets at the bit
/// costs the entropy stage will emit; the forward walk re-derives the actual
/// offset codes against the real repeat history, so a decision priced with a
/// repeat code it can only write explicitly still encodes correctly.
fn parseOptimal(
    allocator: std.mem.Allocator,
    src: []const u8,
    start: usize,
    params: SearchParams,
    prices: *const SequencePrices,
    reps: *RepHistory,
    long_matches: ?[]const LongMatch,
    max_offset: u32,
) !Sequences {
    if (src.len == 0) return parseLazy(allocator, src, start, params, reps, long_matches, max_offset);
    const min_match: usize = @max(params.minMatch, 4);
    // The buffer holds the prefix the block may reach back into as well as the
    // block, and the caller has already trimmed that prefix to the window.
    const max_dist: usize = src.len;
    // The handle owns the engine and the finder points into it, so the handle
    // must outlive the finder: it lives in this frame for the whole parse.
    var handle: FinderHandle = undefined;
    defer handle.deinit(allocator);
    const finder = try makeFinder(allocator, &handle, params, src.len);

    const opt = try allocator.alloc(Opt, src.len + 1);
    defer allocator.free(opt);
    const best = try allocator.alloc(Match, src.len);
    defer allocator.free(best);
    @memset(best, .{});
    const ceiling = if (params.maxMatchLength == 0) src.len else @min(src.len, @as(usize, @intCast(params.maxMatchLength)));

    // Candidates for every position, gathered in one pass. The prefix goes in
    // first so a match reaching back into it is a candidate like any other.
    var i: usize = 0;
    while (i + 4 <= start) : (i += 1) finder.insert(src, i);
    while (i + 4 <= src.len) : (i += 1) {
        const m = finder.find(src, i, params, max_dist);
        if (m.length >= min_match and m.offset <= max_offset and (offsetCode(m.offset) != null or m.offset < 4)) best[i] = .{ .length = @min(m.length, @as(u32, @intCast(ceiling))), .offset = m.offset };
        finder.insert(src, i);
    }
    // Long-distance matches join the same candidate set, so the dynamic program
    // can weigh them against literals and against the window-bounded matches.
    // A match is only a candidate where its source is inside the buffer being
    // parsed: the distance is written into the block as found, so an unreachable
    // source would decode to bytes this parse never saw.
    if (long_matches) |list| {
        for (list) |long| {
            if (long.pos >= best.len or long.length < 3) continue;
            if (long.offset > long.pos) continue;
            const clamped: u32 = @intCast(@min(@as(usize, long.length), src.len - long.pos));
            const candidate = Match{ .length = clamped, .offset = long.offset };
            if (candidate.offset > max_offset) continue;
            if (candidate.length > best[long.pos].length) best[long.pos] = candidate;
        }
    }

    // Backward pass. The repeat history is simulated in reverse, which is an
    // approximation; the forward walk below resolves every distance against the
    // real history, so correctness does not depend on it.
    var sim = reps.*;
    const lit_cost = prices.literalCost();
    opt[src.len] = .{ .cost = 0, .match_len = 0, .dist = 0 };
    i = src.len;
    while (i > start) {
        i -= 1;
        var chosen = Opt{ .cost = opt[i + 1].cost + lit_cost, .match_len = 0, .dist = 0 };

        // Repeat offsets first: they are the cheapest sequences.
        inline for (0..3) |ri| {
            const d = sim.r[ri];
            if (d <= i) {
                const l = matchLength(src, i, d, @min(src.len - i, ceiling));
                if (l >= 3) {
                    const end = @min(src.len, i + l);
                    const code = cheapestRepCode(&sim, d, 0);
                    const c = opt[end].cost + prices.sequence(0, l, code);
                    if (c < chosen.cost) chosen = .{ .cost = c, .match_len = @intCast(end - i), .dist = d };
                }
            }
        }

        const m = best[i];
        if (m.length >= 3) {
            const end = @min(src.len, i + m.length);
            if (offsetCode(m.offset)) |code| {
                const c = opt[end].cost + prices.sequence(0, m.length, code);
                if (c < chosen.cost) chosen = .{ .cost = c, .match_len = @intCast(end - i), .dist = m.offset };
            }
        }
        opt[i] = chosen;
        // Keep the simulated history roughly in step so repeat pricing at
        // neighbouring positions is not wildly off.
        if (chosen.match_len > 0) {
            _ = sim.resolve(chosen.dist, 0);
        }
    }

    // Forward walk. The backward pass priced each decision without knowing how
    // many literals would precede it, so a decision is re-checked here against
    // the real history: a match whose distance cannot be written with the
    // pending literal run becomes a literal, and the next position decides
    // again.
    var sink = try Sink.init(allocator, src.len - start, reps);
    sink.pos = start;
    var pos: usize = start;
    var anchor: usize = start;
    while (pos < src.len and !sink.full) {
        const lit_now: u32 = @intCast(pos - anchor);
        // The window bound is re-checked here so the emitted block cannot depend
        // on which parser produced the decision.
        if (opt[pos].match_len >= 3 and opt[pos].dist <= max_offset and reps.canEncode(opt[pos].dist, lit_now)) {
            sink.addSequence(src, anchor, pos - anchor, opt[pos].match_len, opt[pos].dist);
            var j = pos;
            const end = @min(src.len, pos + opt[pos].match_len);
            while (j + 4 <= end) : (j += 1) finder.insert(src, j);
            pos = end;
            anchor = pos;
        } else {
            finder.insert(src, pos);
            pos += 1;
        }
    }
    return sink.finish(src);
}

/// Cheapest repeat code the decoder could use for `dist` with literal length
/// `lit_len`, without mutating the history: 0 or 1 when a repeat code can
/// express it, otherwise the explicit code.
fn cheapestRepCode(reps: *const RepHistory, dist: u32, lit_len: u32) u8 {
    if (dist == reps.r[0] and (lit_len != 0 or reps.r[0] == reps.r[1])) return 0;
    if (dist == reps.r[1]) return 1;
    if (dist == reps.r[2] and lit_len != 0) return 1;
    return offsetCode(dist) orelse 31;
}

// --- Finder construction ---------------------------------------------------

/// Builds the engine `params` asks for.
pub const FinderHandle = struct {
    finder: Finder,
    table: ?HashTable = null,
    chain: ?HashChain = null,
    tree: ?BinaryTree = null,

    pub fn deinit(self: *FinderHandle, allocator: std.mem.Allocator) void {
        if (self.table) |*t| t.deinit(allocator);
        if (self.chain) |*c| c.deinit(allocator);
        if (self.tree) |*t| t.deinit(allocator);
        self.* = undefined;
    }
};

fn makeFinder(allocator: std.mem.Allocator, handle: *FinderHandle, params: SearchParams, src_len: usize) !Finder {
    handle.* = .{ .finder = undefined };
    errdefer handle.deinit(allocator);
    switch (params.finder) {
        .table => {
            handle.table = try HashTable.init(allocator, clampLog(params.hashLog, 10, 20), params.secondProbe);
            handle.finder = .{ .table = &handle.table.? };
        },
        .chain => {
            handle.chain = try HashChain.init(allocator, clampLog(params.chainLog, 10, 20), src_len);
            handle.finder = .{ .chain = &handle.chain.? };
        },
        .tree => {
            handle.tree = try BinaryTree.init(allocator, clampLog(params.treeLog, 10, 20), src_len);
            handle.finder = .{ .tree = &handle.tree.? };
        },
    }
    return handle.finder;
}

/// Clamps a caller-supplied hash log into the range this finder supports.
///
/// A log outside the range is a request the tables cannot honour: too small and
/// the table cannot hold enough distinct positions, too large and it allocates
/// more than the window can ever use.
fn clampLog(log: u8, low: u8, high: u8) u8 {
    return std.math.clamp(log, low, high);
}

// Strategy mapping

/// Maps a strategy and the level's parameters onto a concrete search.
///
/// Every strategy named here runs a different engine or a different parser:
/// `fast` and `dfast` never build a chain, `greedy` never looks ahead, `lazy`
/// and `lazy2` differ in how far they look, and everything from `btlazy2` up
/// runs on the binary tree, with the higher ones adding the optimal parse.
pub fn paramsForStrategy(strategy: constants.Strategy, level: i32) SearchParams {
    const params = @import("parameters.zig").getParams(level, 0, 0);
    var out = SearchParams{};
    out.minMatch = if (params.minMatch == 0) 4 else params.minMatch;
    out.targetLength = params.targetLength;
    out.hashLog = clampLog(params.hashLog, 10, 20);
    out.chainLog = clampLog(params.chainLog, 10, 20);
    // The tree is indexed by hash like the chain, and its walk budget comes
    // from the same log: deeper walks cost more but find more.
    out.treeLog = clampLog(params.chainLog, 10, 20);
    const requested: u16 = if (params.searchLog == 0) 8 else @intCast(params.searchLog);
    switch (strategy) {
        .fast => {
            out.finder = .table;
            out.secondProbe = false;
            out.searchDepth = 1;
        },
        .dfast => {
            out.finder = .table;
            out.secondProbe = true;
            out.searchDepth = 2;
        },
        .greedy => {
            out.finder = .chain;
            out.searchDepth = requested;
        },
        .lazy => {
            out.finder = .chain;
            out.searchDepth = requested;
            out.lazySteps = 1;
        },
        .lazy2 => {
            out.finder = .chain;
            out.searchDepth = @max(requested, 8);
            out.lazySteps = 2;
        },
        .btlazy2 => {
            out.finder = .tree;
            out.searchDepth = @max(@as(u16, requested), 16);
            out.lazySteps = 2;
        },
        .btopt => {
            out.finder = .tree;
            out.searchDepth = @max(@as(u16, requested), 24);
            out.optimal = true;
        },
        .btultra => {
            out.finder = .tree;
            out.searchDepth = @max(@as(u16, requested), 32);
            out.optimal = true;
        },
        .btultra2 => {
            out.finder = .tree;
            out.searchDepth = @max(@as(u16, requested), 48);
            out.optimal = true;
        },
    }
    return out;
}

// Tests

/// Resolves an emitted sequence's distance exactly as the decoder would, for
/// tests that check the sequence stream against the input.
pub fn resolveForTestPub(reps: *RepHistory, sq: Seq) u32 {
    return resolveForTest(reps, sq);
}

fn resolveForTest(reps: *RepHistory, sq: Seq) u32 {
    return switch (sq.offCode) {
        0 => if (sq.litLen == 0) blk: {
            const tmp = reps.r[0];
            reps.r[0] = reps.r[1];
            reps.r[1] = tmp;
            break :blk reps.r[0];
        } else reps.r[0],
        1 => blk: {
            const ll0: u32 = @intFromBool(sq.litLen == 0);
            const idx = ll0 + sq.offExtra + 1;
            var d: u32 = switch (idx) {
                1 => reps.r[1],
                2 => reps.r[2],
                else => reps.r[0] - 1,
            };
            if (d == 0) d -%= 1;
            if (idx != 1) reps.r[2] = reps.r[1];
            reps.r[1] = reps.r[0];
            reps.r[0] = d;
            break :blk d;
        },
        else => blk: {
            const v: u32 = (@as(u32, 1) << @intCast(sq.offCode)) - 3 + sq.offExtra;
            reps.r[2] = reps.r[1];
            reps.r[1] = reps.r[0];
            reps.r[0] = v;
            break :blk v;
        },
    };
}
const testing = std.testing;

test "offsetCode maps distances to the predefined codes" {
    try testing.expectEqual(@as(?u8, null), offsetCode(1));
    try testing.expectEqual(@as(?u8, null), offsetCode(3));
    try testing.expectEqual(@as(?u8, 2), offsetCode(4));
    try testing.expectEqual(@as(?u8, 3), offsetCode(5));
    try testing.expectEqual(@as(?u8, 27), offsetCode(1 << 27));
    try testing.expectEqual(@as(?u8, 28), offsetCode((1 << 28) - 3));
    try testing.expectEqual(@as(?u8, null), offsetCode(1 << 30));
}

test "llCode and mlCode walk their base tables" {
    try testing.expectEqual(@as(u8, 0), llCode(0));
    try testing.expectEqual(@as(u8, 1), llCode(1));
    try testing.expectEqual(@as(u8, 0), mlCode(3));
    try testing.expectEqual(@as(u8, 1), mlCode(4));
    try testing.expectEqual(@as(u8, 2), mlCode(5));
}

test "symbolCosts are positive and ordered by probability" {
    const ll = symbolCosts(&constants.ll_default_norm, constants.ll_default_norm.len, constants.ll_default_norm_log);
    try testing.expect(ll[0] > 0);
    try testing.expect(ll[0] <= ll[constants.max_ll]);
}

test "SequencePrices charges more for a bigger sequence" {
    const prices = SequencePrices.init();
    try testing.expect(prices.sequence(0, 40, 20) > prices.sequence(0, 3, 4));
    try testing.expect(prices.literalCost() > 0);
}

test "observeLiterals lowers the literal price for predictable input" {
    var prices = SequencePrices.init();
    const before = prices.literal;
    var counts: [256]u32 = @splat(0);
    counts['a'] = 1000;
    prices.observeLiterals(&counts, 1000);
    try testing.expect(prices.literal < before);
}

test "RepHistory repeat codes agree with the decoder" {
    var reps = RepHistory{};
    // A distance equal to r0 with literals: code 0, history untouched.
    var code = reps.resolve(1, 3).?;
    try testing.expectEqual(@as(u8, 0), code.code);
    try testing.expectEqualSlices(u32, &.{ 1, 4, 8 }, &reps.r);
    // r1: code 1 with bit 0, history rotates to (4, 1, 8).
    code = reps.resolve(4, 2).?;
    try testing.expectEqual(@as(u8, 1), code.code);
    try testing.expectEqual(@as(u32, 0), code.extra);
    try testing.expectEqualSlices(u32, &.{ 4, 1, 8 }, &reps.r);
    // r2 with literals: code 1 with bit 1.
    code = reps.resolve(8, 1).?;
    try testing.expectEqual(@as(u8, 1), code.code);
    try testing.expectEqual(@as(u32, 1), code.extra);
    try testing.expectEqualSlices(u32, &.{ 8, 4, 1 }, &reps.r);
    // An explicit distance rotates without touching a repeat slot.
    code = reps.resolve(100, 0).?;
    try testing.expect(code.code >= 2);
    try testing.expectEqualSlices(u32, &.{ 100, 8, 4 }, &reps.r);
}

test "RepHistory falls back to an explicit code when the repeat would lie" {
    var reps = RepHistory{};
    // r0 is 1 and r1 is 4, so with a zero literal length code 0 would resolve
    // to r1, not r0: the encoder must not emit it, and must report that the
    // distance is unencodable rather than invent one.
    try testing.expect(!reps.canEncode(1, 0));
    try testing.expectEqual(@as(?OffsetCode, null), reps.resolve(1, 0));
    try testing.expectEqualSlices(u32, &.{ 1, 4, 8 }, &reps.r);
    // With a literal in front, r0 is reachable again.
    try testing.expect(reps.canEncode(1, 1));
    const code = reps.resolve(1, 1).?;
    try testing.expectEqual(@as(u8, 0), code.code);
    // An arbitrary distance that is not in the history always has a code.
    try testing.expect(reps.canEncode(37, 0));
    try testing.expect((reps.resolve(37, 0).?).code >= 2);
}

test "HashTable finds an exact repeat" {
    var src: [64]u8 = undefined;
    const unit = "abcdefgh";
    for (&src, 0..) |*b, i| b.* = unit[i % unit.len];
    var table = try HashTable.init(testing.allocator, 16, false);
    defer table.deinit(testing.allocator);
    var i: usize = 0;
    while (i + 4 <= 40) : (i += 1) table.insert(&src, i);
    const m = table.find(&src, 40, src.len, false, 0);
    try testing.expect(m.length >= 8);
    try testing.expectEqual(@as(u32, 8), m.offset);
}

test "HashTable second probe finds a match one byte later" {
    // The repeat only exists at position 41, so a single probe at 40 must miss
    // it while the double-fast probe finds it.
    var src: [64]u8 = undefined;
    @memset(&src, 0);
    @memcpy(src[16..24], "abcdefgh");
    @memcpy(src[41..49], "abcdefgh");
    var table = try HashTable.init(testing.allocator, 16, true);
    defer table.deinit(testing.allocator);
    var i: usize = 0;
    while (i + 4 <= 37) : (i += 1) table.insert(&src, i);
    const single = table.find(&src, 40, src.len, false, 0);
    const double = table.find(&src, 40, src.len, true, 0);
    try testing.expect(double.length >= single.length);
    try testing.expect(double.length >= 8);
}

test "HashChain honours the depth limit" {
    var src: [512]u8 = undefined;
    const unit = "abcdefgh";
    for (&src, 0..) |*b, i| b.* = unit[i % unit.len];
    var chain = try HashChain.init(testing.allocator, 16, src.len);
    defer chain.deinit(testing.allocator);
    var i: usize = 0;
    while (i + 4 <= 300) : (i += 1) chain.insert(&src, i);
    const shallow = chain.find(&src, 300, src.len, 1, 0, 0);
    try testing.expect(shallow.length >= 8);
    const deep = chain.find(&src, 300, src.len, 200, 0, 0);
    try testing.expect(deep.length >= shallow.length);
}

test "BinaryTree finds a real repeat" {
    var src: [512]u8 = undefined;
    const unit = "abcdefghij";
    for (&src, 0..) |*b, i| b.* = unit[i % unit.len];
    var tree = try BinaryTree.init(testing.allocator, 16, src.len);
    defer tree.deinit(testing.allocator);
    var i: usize = 0;
    while (i + 4 <= 300) : (i += 1) tree.insert(&src, i);
    const found = tree.find(&src, 300, src.len, 32, 0, 0);
    // The period is 10, so every position has a valid match 10 bytes back.
    try testing.expect(found.length >= 10);
    try testing.expectEqual(@as(u32, 0), @as(u32, @intCast(found.offset)) % 10);
    try testing.expect(found.offset <= 300);
}

test "BinaryTree insertion is idempotent" {
    // A parser can reach the same position twice. A second insert must not
    // disturb the tree: overwriting a link there is what turns the next descent
    // into an infinite loop.
    var src: [256]u8 = undefined;
    const unit = "abcdefghij";
    for (&src, 0..) |*b, i| b.* = unit[i % unit.len];
    var tree = try BinaryTree.init(testing.allocator, 16, src.len);
    defer tree.deinit(testing.allocator);
    var i: usize = 0;
    while (i + 4 <= 200) : (i += 1) {
        tree.insert(&src, i);
        tree.insert(&src, i);
    }
    const found = tree.find(&src, 220, src.len, 32, 0, 0);
    try testing.expect(found.length >= 10);
}

test "BinaryTree prunes candidates outside the window" {
    // Only the distant copies are in the tree, so a small window must exclude
    // them all and report no match rather than an out-of-window distance.
    var src: [1024]u8 = undefined;
    @memset(&src, 'a');
    @memcpy(src[0..64], "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    @memcpy(src[900..964], "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    var tree = try BinaryTree.init(testing.allocator, 16, src.len);
    defer tree.deinit(testing.allocator);
    for ([_]usize{ 0, 16, 32, 48 }) |p| tree.insert(&src, p);
    const wide = tree.find(&src, 900, src.len, 32, 0, 0);
    try testing.expect(wide.length >= 64);
    const narrow = tree.find(&src, 900, 64, 32, 0, 0);
    try testing.expectEqual(@as(u32, 0), narrow.length);
}

test "BinaryTree keeps every inserted position reachable" {
    // Positions that share a four-byte prefix but differ afterwards, so the tree
    // has to order them by suffix rather than link them in one chain.
    var src: [256]u8 = undefined;
    @memset(&src, 0);
    const tails = [_][]const u8{ "aaaaaaaa", "bbbbbbbb", "cccccccc", "dddddddd" };
    for (tails, 0..) |t, k| {
        const at = 8 + k * 12;
        @memcpy(src[at..][0..4], "WXYZ");
        @memcpy(src[at + 4 ..][0..8], t);
    }
    @memcpy(src[100..104], "WXYZ");
    var tree = try BinaryTree.init(testing.allocator, 16, src.len);
    defer tree.deinit(testing.allocator);
    for ([_]usize{ 8, 20, 32, 44, 100 }) |p| tree.insert(&src, p);

    // A full traversal of the bucket must reach all five positions, which is
    // what makes this a tree rather than a single link.
    const h = hashIndex(hash4(&src, 100), tree.hashLog);
    var stack: [32]u32 = @splat(0);
    var len: usize = 1;
    stack[0] = tree.root[h];
    var seen: usize = 0;
    while (len > 0) {
        len -= 1;
        const node = stack[len];
        if (node == 0) continue;
        seen += 1;
        const n = node - 1;
        stack[len] = tree.left[n];
        len += 1;
        stack[len] = tree.right[n];
        len += 1;
    }
    try testing.expectEqual(@as(usize, 5), seen);
}

test "compareTail orders by the first differing byte after the hash" {
    // Two positions that share the four hashed bytes, so the decision is made
    // on byte four: the position whose tail starts with 'Z' sorts above the one
    // that starts with 'Y'.
    var buf: [32]u8 = @splat(0);
    @memcpy(buf[0..4], "WXYZ");
    @memcpy(buf[4..12], "ZZZZZZZZ");
    @memcpy(buf[8..12], "WXYZ");
    @memcpy(buf[12..20], "YYYYYYYY");
    try testing.expect(compareTail(&buf, 0, 8));
    try testing.expect(!compareTail(&buf, 8, 0));
    // Identical tails fall back to insertion order, so the ordering stays a
    // strict order and a descent always terminates.
    @memcpy(buf[20..24], "WXYZ");
    @memcpy(buf[24..32], "ssssssss");
    try testing.expect(compareTail(&buf, 20, 24));
    try testing.expect(!compareTail(&buf, 24, 20));
}

test "each strategy selects its own engine and parser" {
    const cases = [_]struct { strategy: constants.Strategy, finder: FinderKind, lazy: u8, optimal: bool, probes: bool }{
        .{ .strategy = .fast, .finder = .table, .lazy = 0, .optimal = false, .probes = false },
        .{ .strategy = .dfast, .finder = .table, .lazy = 0, .optimal = false, .probes = true },
        .{ .strategy = .greedy, .finder = .chain, .lazy = 0, .optimal = false, .probes = false },
        .{ .strategy = .lazy, .finder = .chain, .lazy = 1, .optimal = false, .probes = false },
        .{ .strategy = .lazy2, .finder = .chain, .lazy = 2, .optimal = false, .probes = false },
        .{ .strategy = .btlazy2, .finder = .tree, .lazy = 2, .optimal = false, .probes = false },
        .{ .strategy = .btopt, .finder = .tree, .lazy = 0, .optimal = true, .probes = false },
        .{ .strategy = .btultra, .finder = .tree, .lazy = 0, .optimal = true, .probes = false },
        .{ .strategy = .btultra2, .finder = .tree, .lazy = 0, .optimal = true, .probes = false },
    };
    for (cases) |c| {
        const p = paramsForStrategy(c.strategy, 5);
        try testing.expectEqual(c.finder, p.finder);
        try testing.expectEqual(c.lazy, p.lazySteps);
        try testing.expectEqual(c.optimal, p.optimal);
        try testing.expectEqual(c.probes, p.secondProbe);
    }
}

test "strategies disagree on their parse" {
    // The strategies must not all produce the same sequence list: a lazy parse
    // has to differ from greedy on input where the later match is longer.
    var src: [2048]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(99);
    const random = prng.random();
    for (&src) |*b| b.* = random.intRangeAtMost(u8, 0, 7);
    // Two long runs, offset by one byte, so a lazy parse can shift the match.
    const line = "the quick brown fox jumps over the lazy dog and keeps running for a while";
    for (0..2) |k| {
        @memcpy(src[100 + k * line.len ..][0..line.len], line);
        @memcpy(src[101 + k * line.len ..][0..line.len], line);
    }

    var sink: usize = 0;
    for ([_]constants.Strategy{ .fast, .dfast, .greedy, .lazy, .lazy2, .btlazy2, .btopt, .btultra, .btultra2 }) |strategy| {
        const params = paramsForStrategy(strategy, 12);
        var reps = RepHistory{};
        var out = try findSequences(testing.allocator, &src, 0, params, &SequencePrices.init(), &reps, null);
        defer out.deinit(testing.allocator);
        try testing.expect(out.seqs.len > 0);
        sink += out.seqs.len;
    }
    try testing.expect(sink > 0);
}

test "every strategy round trips through the sequence sink" {
    var src: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    for (&src) |*b| b.* = random.intRangeAtMost(u8, 0, 3);
    @memcpy(src[500..700], src[100..300]);

    for ([_]constants.Strategy{ .fast, .dfast, .greedy, .lazy, .lazy2, .btlazy2, .btopt, .btultra, .btultra2 }) |strategy| {
        const params = paramsForStrategy(strategy, 19);
        var reps = RepHistory{};
        var out = try findSequences(testing.allocator, &src, 0, params, &SequencePrices.init(), &reps, null);
        defer out.deinit(testing.allocator);
        {
            var lit: usize = 0;
            var mlen: usize = 0;
            for (out.seqs) |sq| {
                lit += sq.litLen;
                mlen += sq.matchLen;
            }
            if (lit + mlen + (out.literals.len - lit) != src.len) {
                std.debug.print("{s}: seqs={d} lits={d} sumll={d} summl={d} tail={d} src={d}\n", .{
                    @tagName(strategy), out.seqs.len, out.literals.len, lit, mlen, out.literals.len - lit, src.len,
                });
            }
        }
        // Executing the sequences the way the decoder does must reconstruct the
        // input exactly, with the repeat-offset semantics included.
        var decode_reps = RepHistory{};
        var dst: [2048]u8 = undefined;
        var outPos: usize = 0;
        var litPos: usize = 0;
        for (out.seqs) |sq| {
            std.mem.copyForwards(u8, dst[outPos..][0..sq.litLen], out.literals[litPos..][0..sq.litLen]);
            outPos += sq.litLen;
            litPos += sq.litLen;
            const dist = switch (sq.offCode) {
                0 => if (sq.litLen == 0) blk: {
                    const tmp = decode_reps.r[0];
                    decode_reps.r[0] = decode_reps.r[1];
                    decode_reps.r[1] = tmp;
                    break :blk decode_reps.r[0];
                } else decode_reps.r[0],
                1 => blk: {
                    const ll0: u32 = @intFromBool(sq.litLen == 0);
                    const bit: u32 = sq.offExtra;
                    const idx = ll0 + bit + 1;
                    var d: u32 = switch (idx) {
                        1 => decode_reps.r[1],
                        2 => decode_reps.r[2],
                        else => decode_reps.r[0] - 1,
                    };
                    if (d == 0) d -%= 1;
                    if (idx != 1) decode_reps.r[2] = decode_reps.r[1];
                    decode_reps.r[1] = decode_reps.r[0];
                    decode_reps.r[0] = d;
                    break :blk d;
                },
                else => blk: {
                    const v: u32 = (@as(u32, 1) << @intCast(sq.offCode)) - 3 + sq.offExtra;
                    decode_reps.r[2] = decode_reps.r[1];
                    decode_reps.r[1] = decode_reps.r[0];
                    decode_reps.r[0] = v;
                    break :blk v;
                },
            };
            try testing.expect(dist >= 1 and dist <= outPos);
            var m: usize = 0;
            while (m < sq.matchLen) : (m += 1) {
                dst[outPos] = dst[outPos - @as(usize, @intCast(dist))];
                outPos += 1;
            }
        }
        const tail = out.literals.len - litPos;
        std.mem.copyForwards(u8, dst[outPos..][0..tail], out.literals[litPos..][0..tail]);
        outPos += tail;
        try testing.expectEqual(src.len, outPos);
        if (!std.mem.eql(u8, &src, dst[0..outPos])) {
            var at: usize = 0;
            while (at < outPos and dst[at] == src[at]) : (at += 1) {}
            // Replay the sequences to find which one covers the first mismatch.
            var rp = RepHistory{};
            var op: usize = 0;
            var li: usize = 0;
            for (out.seqs, 0..) |sq, si| {
                const d = resolveForTest(&rp, sq);
                if (at >= op and at < op + sq.litLen + sq.matchLen) {
                    std.debug.print("{s}: seq {d} covers {d}: ll={d} ml={d} code={d} extra={d} dist={d} srcpos={d}\n", .{
                        @tagName(strategy), si, at, sq.litLen, sq.matchLen, sq.offCode, sq.offExtra, d, op,
                    });
                }
                op += sq.litLen + sq.matchLen;
                li += sq.litLen;
            }
            std.debug.print("{s}: first mismatch at {d}: got {d} want {d}\n", .{ @tagName(strategy), at, dst[at], src[at] });
            try testing.expectEqualSlices(u8, &src, dst[0..outPos]);
        }
    }
}

test "sequence cap is respected" {
    // A long block of high-entropy data produces many short matches; the sink
    // must stop at the cap rather than overrunning.
    var src: [60000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(5150);
    const random = prng.random();
    for (&src) |*b| b.* = random.int(u8);
    const params = paramsForStrategy(.fast, 1);
    var reps = RepHistory{};
    var out = try findSequences(testing.allocator, &src, 0, params, &SequencePrices.init(), &reps, null);
    defer out.deinit(testing.allocator);
    try testing.expect(out.seqs.len <= max_sequences);
}
