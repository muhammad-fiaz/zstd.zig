p = 'src/compress/block.zig'
s = open(p).read()

# Replace the whole findSequences with a rep-aware version.
start = s.index('/// Find sequences greedily')
end = s.index('const ctable_mod = fse_ctable;')

new_fs = '''/// Repeat-offset history, mirroring the decoder exactly so that emitted
/// codes and history updates stay in lockstep.
const RepHistory = struct {
    r: [3]u32 = .{ 1, 4, 8 },

    /// Resolve an explicit distance to (code, extra) and rotate history.
    fn pushExplicit(self: *RepHistory, dist: u32) struct { code: u8, extra: u32 } {
        const v: u64 = @as(u64, dist) + 3;
        const code: u8 = @intCast(63 - @clz(v));
        const extra: u32 = @intCast(v - (@as(u64, 1) << @intCast(code)));
        self.r[2] = self.r[1];
        self.r[1] = self.r[0];
        self.r[0] = dist;
        return .{ .code = code, .extra = extra };
    }

    /// Resolve repeat code 0 (reuse r0 or r1 when lit_len == 0).
    fn useCode0(self: *RepHistory, lit_len: u32) void {
        if (lit_len == 0) {
            // Decoder swaps r0/r1 in this case.
            const tmp = self.r[0];
            self.r[0] = self.r[1];
            self.r[1] = tmp;
        }
        // lit_len != 0: history unchanged.
    }

    /// Resolve repeat code 1 with extra bit `bit`:
    ///   ll0==0 -> idx = 1+bit   (r1 / r2)
    ///   ll0==1 -> idx = 2+bit   (r2 / r0-1)
    fn resolveCode1(self: *RepHistory, lit_len: u32, bit: u32) u32 {
        const ll0: u32 = @intFromBool(lit_len == 0);
        const idx = ll0 + bit + 1; // 1..3
        var d: u32 = switch (idx) {
            1 => self.r[1],
            2 => self.r[2],
            else => blk: {
                break :blk self.r[0] -% 1; // decrement trick
            },
        };
        if (d == 0) d -%= 1; // invalid stream guard; encoder never emits this
        if (idx != 1) self.r[2] = self.r[1];
        self.r[1] = self.r[0];
        self.r[0] = d;
        return d;
    }
};

fn matchLengthAt(src: []const u8, pos: usize, dist: usize, max_len: usize) usize {
    if (dist > pos) return 0;
    var l: usize = 0;
    while (l < max_len and src[pos + l] == src[pos + l - dist]) : (l += 1) {}
    return l;
}

/// Find sequences greedily over `src` using a hash chain plus repeat-offset
/// candidates. Distances 1-3 are naturally covered by the initial rep
/// history {1,4,8} and its evolution.
fn findSequences(
    allocator: std.mem.Allocator,
    src: []const u8,
    min_match_in: usize,
    search_depth_in: usize,
) !struct { seqs: []Seq, literals: []u8 } {
    const min_match = @max(min_match_in, 4); // hash reads 4 bytes
    const search_depth = @max(search_depth_in, 1);

    var mf = try MatchFinder.init(allocator, 16);
    defer mf.deinit(allocator);

    const seqs = try allocator.alloc(Seq, 4096);
    errdefer allocator.free(seqs);
    const literals = try allocator.alloc(u8, src.len);
    errdefer allocator.free(literals);
    var n_lit: usize = 0;
    var n_seq: usize = 0;

    var reps = RepHistory{};
    var anchor: usize = 0;
    var pos: usize = 0;

    while (pos + min_match <= src.len) {
        const max_len = src.len - pos;

        // --- Repeat-offset candidates (cheapest codes). ---
        var rep_hit: ?usize = null; // index into reps
        var rep_len: usize = 0;
        inline for (0..3) |ri| {
            const d: usize = reps.r[ri];
            if (d <= pos) {
                const l = matchLengthAt(src, pos, d, max_len);
                if (l > rep_len) {
                    rep_len = l;
                    rep_hit = ri;
                }
            }
        }
        // Prefer rep[0] on ties (cheapest code).
        if (rep_hit != null and rep_len >= min_match) {
            const ri = rep_hit.?;
            const d: usize = reps.r[ri];
            const run = pos - anchor;
            @memcpy(literals[n_lit .. n_lit + run], src[anchor..pos]);
            n_lit += run;
            const lit_len: u32 = @intCast(run);
            const lit_len_zero: u32 = @intFromBool(run == 0);

            var code: u8 = undefined;
            var extra: u32 = 0;
            if (ri == 0) {
                // Distance equals most recent offset.
                if (run != 0) {
                    code = 0; // reuse r0, history unchanged
                    reps.useCode0(lit_len);
                } else {
                    code = 0; // ll0 path swaps r0/r1
                    reps.useCode0(lit_len);
                }
            } else if (ri == 1) {
                if (run != 0) {
                    code = 1;
                    extra = 0; // idx=1 -> r1
                    _ = reps.resolveCode1(lit_len, 0);
                } else {
                    code = 0; // ll0 swap brings r1 to front
                    reps.useCode0(lit_len);
                }
            } else { // ri == 2
                if (run != 0) {
                    code = 1;
                    extra = 1; // idx=2 -> r2
                    _ = reps.resolveCode1(lit_len | lit_len_zero, 1);
                } else {
                    code = 1;
                    extra = lit_len_zero; // ll0 shifts index by 1 -> still r2
                    _ = reps.resolveCode1(0, 1);
                }
            }
            seqs[n_seq] = .{
                .lit_len = lit_len,
                .match_len = @intCast(rep_len),
                .off_code = code,
                .off_extra = extra,
            };
            n_seq += 1;
            if (n_seq == seqs.len) break;
            var insert = pos;
            const end_insert = pos + rep_len;
            while (insert + 4 <= end_insert and insert + 4 <= src.len) : (insert += 1) {
                const hh = mf.hash4(src, insert);
                mf.prev[insert] = mf.head[hh];
                mf.head[hh] = @intCast(insert + 1);
            }
            pos += rep_len;
            anchor = pos;
            continue;
        }

        // --- Generic hash-chain search for an explicit distance. ---
        const h = mf.hash4(src, pos);
        var best_len: usize = 0;
        var best_dist: usize = 0;
        var cand = mf.head[h];
        var depth: usize = 0;
        while (cand != 0 and depth < search_depth) : (depth += 1) {
            const cand_pos = cand - 1;
            if (pos - cand_pos > constants.block_size_max) break;
            const l = matchLengthAt(src, pos, pos - cand_pos, max_len);
            if (l > best_len) {
                best_len = l;
                best_dist = pos - cand_pos;
                if (l == max_len) break;
            }
            cand = if (cand_pos < mf.prev.len) mf.prev[cand_pos] else 0;
        }

        const encodable = best_len >= min_match and best_dist >= 4 and
            (@as(u64, best_dist) + 3) <= (@as(u64, 1) << @intCast(constants.default_max_off + 1));
        if (encodable) {
            if (n_seq == seqs.len) break;
            const run = pos - anchor;
            @memcpy(literals[n_lit .. n_lit + run], src[anchor..pos]);
            n_lit += run;
            const res = reps.pushExplicit(@intCast(best_dist));
            seqs[n_seq] = .{
                .lit_len = @intCast(run),
                .match_len = @intCast(best_len),
                .off_code = res.code,
                .off_extra = res.extra,
            };
            n_seq += 1;
            var insert = pos;
            const end_insert = pos + best_len;
            while (insert + 4 <= end_insert and insert + 4 <= src.len) : (insert += 1) {
                const hh = mf.hash4(src, insert);
                mf.prev[insert] = mf.head[hh];
                mf.head[hh] = @intCast(insert + 1);
            }
            pos += best_len;
            anchor = pos;
        } else {
            const hh = mf.hash4(src, pos);
            mf.prev[pos] = mf.head[hh];
            mf.head[hh] = @intCast(pos + 1);
            pos += 1;
        }
    }

    // Trailing literals.
    const tail = src[anchor..];
    @memcpy(literals[n_lit .. n_lit + tail.len], tail);
    n_lit += tail.len;

    return .{ .seqs = seqs[0..n_seq], .literals = literals[0..n_lit] };
}

'''
s = s[:start] + new_fs + s[end:]
open(p, 'w').write(s)
print('findSequences rewritten with rep-offset support')
