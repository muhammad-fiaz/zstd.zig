const std = @import("std");
const errors = @import("../common/errors.zig");
const bitstream_mod = @import("../common/bitstream.zig");
const fse_compress_mod = @import("../fse/compress.zig");
const common_mod = @import("common.zig");

pub const max_table_log: u8 = common_mod.maxTableLog;
pub const symbol_value_max: usize = 255;

pub const NodeElt = struct {
    count: u32 = 0,
    parent: u16 = 0,
    byte: u8 = 0,
    nb_bits: u8 = 0,
};

pub const HuffCElt = struct {
    nb_bits: u8 = 0,
    value: u32 = 0,
};

pub const HuffCTable = struct {
    table_log: u8 = 0,
    max_symbol_value: u8 = 0,
    elts: [256]HuffCElt = [_]HuffCElt{.{}} ** 256,
};

pub fn countFrequencies(counts: []u32, src: []const u8) usize {
    @memset(counts, 0);
    var max_symbol: usize = 0;
    for (src) |b| {
        counts[b] += 1;
        if (b > max_symbol) max_symbol = b;
    }
    return max_symbol;
}

// Builds a Huffman tree from sorted nodes (descending by count).
// Returns index of the last non-null node (smallest count).
// Matches the reference HUF_buildTree() logic including sentinel handling.
pub fn buildTree(nodes: []NodeElt, max_symbol: usize) usize {
    // Find the last non-null symbol
    var non_null_rank: usize = max_symbol;
    while (non_null_rank > 0 and nodes[non_null_rank].count == 0) : (non_null_rank -= 1) {}
    if (non_null_rank == 0 and nodes[0].count == 0) return 0;

    // Single-symbol edge case
    if (non_null_rank == 0) {
        nodes[0].nb_bits = 1;
        return 0;
    }

    const start_node = symbol_value_max + 1;
    var node_nb = start_node;
    // Use signed indices to handle the sentinel (like C's huffNode0[-1])
    var low_s: isize = @intCast(non_null_rank);
    const node_root: usize = node_nb + non_null_rank - 1;
    var low_n: isize = @intCast(node_nb);

    // Build first internal node from the two smallest leaves
    nodes[node_nb].count = nodes[@intCast(low_s)].count + nodes[@intCast(low_s - 1)].count;
    nodes[@intCast(low_s)].parent = @truncate(node_nb);
    nodes[@intCast(low_s - 1)].parent = @truncate(node_nb);
    node_nb += 1;
    low_s -= 2;

    // Initialize internal nodes with sentinel count (1<<30 as placeholder)
    for (node_nb..node_root + 1) |n_idx| {
        nodes[n_idx].count = @as(u32, 1) << 30;
    }

    // The C code uses huffNode[-1].count = 1<<31 as a strong barrier.
    // When low_s < 0, we treat it as having count (1<<31).
    while (node_nb <= node_root) {
        const n1: usize = blk: {
            const ls_count: u32 = if (low_s >= 0) nodes[@intCast(low_s)].count else (1 << 31);
            const ln_count: u32 = nodes[@intCast(low_n)].count;
            if (ls_count < ln_count) {
                const idx = low_s;
                low_s -= 1;
                break :blk @intCast(idx);
            } else {
                const idx = low_n;
                low_n += 1;
                break :blk @intCast(idx);
            }
        };

        const n2: usize = blk: {
            const ls_count: u32 = if (low_s >= 0) nodes[@intCast(low_s)].count else (1 << 31);
            const ln_count: u32 = nodes[@intCast(low_n)].count;
            if (ls_count < ln_count) {
                const idx = low_s;
                low_s -= 1;
                break :blk @intCast(idx);
            } else {
                const idx = low_n;
                low_n += 1;
                break :blk @intCast(idx);
            }
        };

        nodes[node_nb].count = nodes[n1].count + nodes[n2].count;
        nodes[n1].parent = @truncate(node_nb);
        nodes[n2].parent = @truncate(node_nb);
        node_nb += 1;
    }

    // Distribute nb_bits down from root
    nodes[node_root].nb_bits = 0;
    var n_walk = node_root;
    if (n_walk > start_node) {
        n_walk -= 1;
        while (n_walk >= start_node) : (n_walk -= 1) {
            nodes[n_walk].nb_bits = nodes[nodes[n_walk].parent].nb_bits + 1;
        }
    }
    for (0..non_null_rank + 1) |i| {
        nodes[i].nb_bits = nodes[nodes[i].parent].nb_bits + 1;
    }

    return non_null_rank;
}

// Enforces a maximum bit depth on the Huffman tree, redistributing cost.
// Matches HUF_setMaxHeight() from the reference implementation.
pub fn setMaxHeight(nodes: []NodeElt, last_non_null: usize, target_nb_bits: u8) u8 {
    const largest_bits = nodes[last_non_null].nb_bits;
    if (largest_bits <= target_nb_bits) return largest_bits;

    const no_symbol: u32 = 0xF0F0F0F0;

    // Phase 1: clamp all over-limit symbols to target, compute total cost
    var total_cost: i32 = 0;
    const base_cost: i32 = @as(i32, 1) << @as(std.math.Log2Int(i32), @intCast(largest_bits - target_nb_bits));
    var n: isize = @intCast(last_non_null);
    while (n >= 0 and nodes[@intCast(n)].nb_bits > target_nb_bits) : (n -= 1) {
        total_cost += base_cost - (@as(i32, 1) << @as(std.math.Log2Int(i32), @intCast(largest_bits - nodes[@intCast(n)].nb_bits)));
        nodes[@intCast(n)].nb_bits = target_nb_bits;
    }
    // n now points to first node with nb_bits <= target_nb_bits
    while (n >= 0 and nodes[@intCast(n)].nb_bits == target_nb_bits) : (n -= 1) {}

    // Renormalize total_cost from 2^largestBits to 2^targetNbBits
    total_cost >>= @intCast(largest_bits - target_nb_bits);

    // Phase 2: repay cost by promoting nodes from longer-bit ranks
    // Build rankLast[diff] = position of last symbol at (target_nb_bits - diff)
    var rank_last = [_]u32{no_symbol} ** (max_table_log + 2);
    {
        var current_nb_bits: u8 = target_nb_bits;
        var pos = n;
        while (pos >= 0) : (pos -= 1) {
            const p_bits = nodes[@intCast(pos)].nb_bits;
            if (p_bits >= current_nb_bits) continue;
            current_nb_bits = p_bits;
            rank_last[@intCast(target_nb_bits - current_nb_bits)] = @intCast(pos);
        }
    }

    while (total_cost > 0) {
        var nb_bits_to_decrease: u32 = (31 - @clz(@as(u32, @intCast(total_cost)))) + 1;
        while (nb_bits_to_decrease > 1) : (nb_bits_to_decrease -= 1) {
            const high_pos = rank_last[nb_bits_to_decrease];
            const low_pos = rank_last[nb_bits_to_decrease - 1];
            if (high_pos == no_symbol) continue;
            if (low_pos == no_symbol) break;
            const high_total = nodes[high_pos].count;
            const low_total = 2 * nodes[low_pos].count;
            if (high_total <= low_total) break;
        }
        // Find the actual position to decrease, handling no_symbol
        while (nb_bits_to_decrease <= max_table_log and rank_last[nb_bits_to_decrease] == no_symbol) : (nb_bits_to_decrease += 1) {}
        total_cost -= @as(i32, 1) << @intCast(nb_bits_to_decrease - 1);
        // Promote the node at rank_last[nb_bits_to_decrease]
        nodes[rank_last[nb_bits_to_decrease]].nb_bits += 1;

        // Update rank_last
        if (rank_last[nb_bits_to_decrease - 1] == no_symbol) {
            rank_last[nb_bits_to_decrease - 1] = rank_last[nb_bits_to_decrease];
        }
        if (rank_last[nb_bits_to_decrease] == 0) {
            rank_last[nb_bits_to_decrease] = no_symbol;
        } else {
            rank_last[nb_bits_to_decrease] -= 1;
            if (nodes[rank_last[nb_bits_to_decrease]].nb_bits != target_nb_bits - nb_bits_to_decrease) {
                rank_last[nb_bits_to_decrease] = no_symbol;
            }
        }
    }

    // Handle overshoot (total_cost < 0): promote from rank 0 to rank 1
    while (total_cost < 0) {
        if (rank_last[1] == no_symbol) {
            // Create a rank-1 symbol from the last rank-0 symbol
            while (nodes[@intCast(n)].nb_bits == target_nb_bits) : (n -= 1) {}
            nodes[@intCast(n + 1)].nb_bits -= 1;
            rank_last[1] = @intCast(n + 1);
            total_cost += 1;
        } else {
            nodes[rank_last[1] + 1].nb_bits -= 1;
            rank_last[1] += 1;
            total_cost += 1;
        }
    }

    var actual_max_bits: u8 = 0;
    for (0..last_non_null + 1) |i| {
        if (nodes[i].nb_bits > actual_max_bits) actual_max_bits = nodes[i].nb_bits;
    }
    return actual_max_bits;
}

pub fn buildCTable(ctable: *HuffCTable, counts: []const u32, max_symbol: usize, max_nb_bits_in: u8) errors.ZstdError!u8 {
    var nodes = [_]NodeElt{.{}} ** (2 * (symbol_value_max + 1));
    for (0..max_symbol + 1) |s| {
        nodes[s].count = counts[s];
        nodes[s].byte = @truncate(s);
    }

    // Insertion sort descending by count (matches HUF_sort in C reference)
    for (1..max_symbol + 1) |i| {
        const key = nodes[i];
        var j: isize = @as(isize, @intCast(i)) - 1;
        while (j >= 0 and nodes[@intCast(j)].count < key.count) : (j -= 1) {
            nodes[@intCast(j + 1)] = nodes[@intCast(j)];
        }
        nodes[@intCast(j + 1)] = key;
    }

    const non_null = buildTree(&nodes, max_symbol);
    var max_nb_bits: u8 = if (max_nb_bits_in == 0) max_table_log else max_nb_bits_in;
    max_nb_bits = setMaxHeight(&nodes, non_null, max_nb_bits);

    // Compute nb_per_rank: count of symbols per bit-depth
    var nb_per_rank = [_]u16{0} ** 16;
    var val_per_rank = [_]u16{0} ** 16;
    for (0..non_null + 1) |i| {
        nb_per_rank[nodes[i].nb_bits] += 1;
    }

    // Compute canonical starting code value per bit-depth
    var min_val: u16 = 0;
    var r = @as(isize, @intCast(max_nb_bits));
    while (r > 0) : (r -= 1) {
        val_per_rank[@intCast(r)] = min_val;
        min_val += nb_per_rank[@intCast(r)];
        min_val >>= 1;
    }

    // Set nb_bits for each symbol (from sorted node array)
    for (0..max_symbol + 1) |s| {
        ctable.elts[nodes[s].byte].nb_bits = nodes[s].nb_bits;
    }
    // Assign canonical code values in symbol order (0, 1, 2, ...)
    for (0..max_symbol + 1) |s| {
        const bits = ctable.elts[s].nb_bits;
        if (bits > 0) {
            ctable.elts[s].value = val_per_rank[bits];
            val_per_rank[bits] += 1;
        } else {
            ctable.elts[s].value = 0;
        }
    }

    ctable.table_log = max_nb_bits;
    ctable.max_symbol_value = @truncate(max_symbol);
    return max_nb_bits;
}

pub fn writeCTable(dst: []u8, ctable: *const HuffCTable, allocator: std.mem.Allocator) errors.ZstdError!usize {
    if (dst.len == 0) return error.DstSizeTooSmall;
    var weights: [256]u8 = undefined;
    const huff_log = ctable.table_log;
    for (0..ctable.max_symbol_value + 1) |s| {
        const nb_bits = ctable.elts[s].nb_bits;
        weights[s] = if (nb_bits == 0) 0 else (huff_log + 1 - nb_bits);
    }

    // Try FSE compression of weights (for symbols 0..max_symbol_value-1; last weight is implicit)
    if (ctable.max_symbol_value >= 2) {
        var w_counts = [_]u32{0} ** 16;
        var max_w: usize = 0;
        for (0..ctable.max_symbol_value) |s| {
            const w = weights[s];
            w_counts[w] += 1;
            if (w > max_w) max_w = w;
        }

        const wt_size = ctable.max_symbol_value;
        const opt_log = fse_compress_mod.optimalTableLog(6, wt_size, max_w);
        var norm = [_]i16{0} ** 16;
        if (fse_compress_mod.normalizeCountsExt(&norm, w_counts[0 .. max_w + 1], opt_log, wt_size, false)) |tlog| {
            if (dst.len > 2) {
                const header_len = try fse_compress_mod.writeNCount(dst[1..], &norm, max_w, tlog);
                var fse_ctable = try fse_compress_mod.buildCTable(allocator, &norm, max_w, tlog);
                defer fse_ctable.deinit();

                const bs_space = dst[1 + header_len ..];
                if (bs_space.len > 8) {
                    var bitstream = try bitstream_mod.BIT_CStream.init(bs_space);
                    var cstate1 = fse_compress_mod.FseCState.init(&fse_ctable, weights[wt_size - 1]);
                    var i = @as(isize, @intCast(wt_size - 1));
                    while (i > 0) {
                        i -= 1;
                        cstate1.encodeSymbol(&bitstream, &fse_ctable, weights[@intCast(i)]);
                        bitstream.flushBits();
                    }
                    cstate1.flush(&bitstream);
                    const csize = try bitstream.close();
                    const total_fse = header_len + csize;
                    if (total_fse < (ctable.max_symbol_value / 2) and total_fse + 1 < dst.len) {
                        dst[0] = @truncate(total_fse);
                        return total_fse + 1;
                    }
                }
            }
        } else |_| {}
    }

    // Fallback: raw 4-bit weights encoding
    // Header byte = 128 + num_symbols - 1. num_symbols = max_symbol_value (last weight implicit).
    // We encode weights[0..max_symbol_value-1] (max_symbol_value weights), 2 per byte.
    const num_weights = ctable.max_symbol_value; // last symbol weight is implicit
    const osize = (num_weights + 1) / 2;
    if (dst.len < 1 + osize) return error.DstSizeTooSmall;
    dst[0] = @truncate(128 + (num_weights - 1));
    for (0..osize) |i| {
        const w1 = weights[2 * i];
        const w2 = if (2 * i + 1 < num_weights) weights[2 * i + 1] else 0;
        dst[1 + i] = (w1 << 4) | (w2 & 0x0F);
    }
    return 1 + osize;
}

pub fn compress1X(dst: []u8, src: []const u8, ctable: *const HuffCTable) errors.ZstdError!usize {
    if (src.len == 0) return 0;
    if (dst.len <= 8) return error.DstSizeTooSmall;

    var bitstream = try bitstream_mod.BIT_CStream.init(dst);
    var ip = src.len;
    while (ip > 0) {
        ip -= 1;
        const b = src[ip];
        const elt = ctable.elts[b];
        if (elt.nb_bits == 0) return error.Corruption;
        bitstream.addBits(elt.value, elt.nb_bits);
        bitstream.flushBits();
    }
    return try bitstream.close();
}

pub fn compress4X(dst: []u8, src: []const u8, ctable: *const HuffCTable) errors.ZstdError!usize {
    if (src.len < 4) return error.SrcSizeWrong;
    if (dst.len < 12) return error.DstSizeTooSmall;

    const segment_size = (src.len + 3) / 4;
    const s1 = src[0..segment_size];
    const s2 = src[segment_size .. 2 * segment_size];
    const s3 = src[2 * segment_size .. 3 * segment_size];
    const s4 = src[3 * segment_size ..];

    // Jump table: 3 x LE16 sizes of first 3 streams (6 bytes)
    var out_pos: usize = 6;

    const c1 = try compress1X(dst[out_pos..], s1, ctable);
    if (c1 > 0xFFFF) return error.DstSizeTooSmall;
    out_pos += c1;

    const c2 = try compress1X(dst[out_pos..], s2, ctable);
    if (c2 > 0xFFFF) return error.DstSizeTooSmall;
    out_pos += c2;

    const c3 = try compress1X(dst[out_pos..], s3, ctable);
    if (c3 > 0xFFFF) return error.DstSizeTooSmall;
    out_pos += c3;

    const c4 = try compress1X(dst[out_pos..], s4, ctable);
    out_pos += c4;

    dst[0] = @truncate(c1);
    dst[1] = @truncate(c1 >> 8);
    dst[2] = @truncate(c2);
    dst[3] = @truncate(c2 >> 8);
    dst[4] = @truncate(c3);
    dst[5] = @truncate(c3 >> 8);

    return out_pos;
}

pub fn compressHuffman(dst: []u8, src: []const u8) errors.ZstdError!usize {
    if (src.len == 0) return 0;
    var counts = [_]u32{0} ** 256;
    const max_sym = countFrequencies(&counts, src);
    var ctable: HuffCTable = .{};
    _ = try buildCTable(&ctable, &counts, max_sym, max_table_log);
    var allocator_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_buf);
    const h_size = try writeCTable(dst, &ctable, fba.allocator());
    const c_size = if (src.len < 256)
        try compress1X(dst[h_size..], src, &ctable)
    else
        try compress4X(dst[h_size..], src, &ctable);
    return h_size + c_size;
}

pub fn buildWeights(weights: []u8, counts: []const u32, max_symbol: usize) errors.ZstdError!u8 {
    var ctable: HuffCTable = .{};
    const log = try buildCTable(&ctable, counts, max_symbol, max_table_log);
    for (0..max_symbol + 1) |s| {
        const bits = ctable.elts[s].nb_bits;
        weights[s] = if (bits == 0) 0 else (log + 1 - bits);
    }
    return log;
}
