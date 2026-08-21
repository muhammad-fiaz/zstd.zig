const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const frame_block = @import("../frame/block.zig");
const types = @import("../common/types.zig");

pub const BlockType = types.BlockType;

pub fn compressBlock(dst: []u8, src: []const u8, is_last: bool) errors.ZstdError!usize {
    if (src.len == 0) {
        if (dst.len < 3) return error.DstSizeTooSmall;
        frame_block.writeBlockHeader(dst[0..3], is_last, .raw, 0);
        return 3;
    }
    if (isRle(src)) {
        if (dst.len < 4) return error.DstSizeTooSmall;
        frame_block.writeBlockHeader(dst[0..3], is_last, .rle, @intCast(src.len));
        dst[3] = src[0];
        return 4;
    }
    if (dst.len >= 3) {
        if (tryCompress(dst[3..], src)) |c_len| {
            if (c_len < src.len) {
                frame_block.writeBlockHeader(dst[0..3], is_last, .compressed, @intCast(c_len));
                return 3 + c_len;
            }
        }
    }
    const bound = src.len + 3;
    if (dst.len < bound) return error.DstSizeTooSmall;
    frame_block.writeBlockHeader(dst[0..3], is_last, .raw, @intCast(src.len));
    @memcpy(dst[3 .. 3 + src.len], src);
    return 3 + src.len;
}

fn isRle(src: []const u8) bool {
    if (src.len < 8) return false;
    const first = src[0];
    for (src[1..]) |b| if (b != first) return false;
    return true;
}

pub fn compressBlockWithStrategy(dst: []u8, src: []const u8, is_last: bool, strategy: constants.Strategy, level: i32) errors.ZstdError!usize {
    _ = strategy;
    _ = level;
    return compressBlock(dst, src, is_last);
}

fn tryCompress(dst: []u8, src: []const u8) ?usize {
    return tryCompressLevel(dst, src, 256, 4);
}

fn tryCompressLevel(dst: []u8, src: []const u8, window: usize, min_match: usize) ?usize {
    // Toy LZ77 + raw literals + toy sequences (compatible with decompress/sequences.zig)
    // Limits: lit_len up to 255, offset 1..256, match_len 3..258, nb_seq <128 for simplicity
    const Sequence = struct { lit_len: usize, offset: usize, match_len: usize };
    var seqs: [1024]Sequence = undefined;
    var seq_count: usize = 0;
    var literals_buf: [131072]u8 = undefined;
    var literals_len: usize = 0;

    var pos: usize = 0;
    var anchor: usize = 0;

    while (pos < src.len and seq_count < 1024) {
        var best_len: usize = 0;
        var best_off: usize = 0;
        if (pos + min_match <= src.len) {
            const win_start: usize = if (pos > window) pos - window else 0;
            var ref: usize = win_start;
            while (ref < pos) : (ref += 1) {
                if (src[ref] != src[pos]) continue;
                // quick 4-byte check when possible
                if (pos + 4 <= src.len and ref + 4 <= src.len) {
                    if (src[ref + 0] != src[pos + 0] or src[ref + 1] != src[pos + 1] or src[ref + 2] != src[pos + 2] or src[ref + 3] != src[pos + 3]) continue;
                }
                const max_len = @min(src.len - pos, 258);
                const max_ref = src.len - ref;
                const limit = @min(max_len, max_ref);
                var len: usize = 0;
                while (len < limit and src[ref + len] == src[pos + len]) : (len += 1) {}
                if (len >= min_match and len > best_len) {
                    best_len = len;
                    best_off = pos - ref;
                    if (len == 258) break;
                }
            }
        }
        if (best_len >= min_match) {
            const lit_len = pos - anchor;
            if (lit_len > 255) {
                return null;
            }
            if (best_off == 0 or best_off > window or best_off > 256) return null;
            // Clamp match len to 258 max, already.
            if (seq_count >= seqs.len) return null;
            // Append literals for this sequence
            if (literals_len + lit_len > literals_buf.len) return null;
            if (lit_len > 0) {
                @memcpy(literals_buf[literals_len .. literals_len + lit_len], src[anchor..pos]);
                literals_len += lit_len;
            }
            seqs[seq_count] = .{ .lit_len = lit_len, .offset = best_off, .match_len = best_len };
            seq_count += 1;
            pos += best_len;
            anchor = pos;
        } else {
            pos += 1;
        }
    }
    // trailing literals
    const trailing = src.len - anchor;
    if (literals_len + trailing > literals_buf.len) return null;
    if (trailing > 0) {
        @memcpy(literals_buf[literals_len .. literals_len + trailing], src[anchor .. anchor + trailing]);
        literals_len += trailing;
    }

    if (seq_count == 0) return null;
    if (seq_count >= 128) return null; // need 1-byte nb_seq

    // Estimate sizes
    const lit_header: usize = if (literals_len < 32) 1 else if (literals_len < 4096) 2 else 3;
    const lit_section = lit_header + literals_len;
    // sequences section: nb_seq 1 + sym 1 + 3 RLE +1 dummy + per-seq (3 each)
    const seq_section: usize = 1 + 1 + 4 + seq_count * 3;
    const total = lit_section + seq_section;
    if (total >= src.len) return null;
    if (dst.len < total) return null;

    // Encode literals section (raw type 0)
    var out_pos: usize = 0;
    if (literals_len < 32) {
        dst[out_pos] = @truncate(literals_len << 3);
        out_pos += 1;
    } else if (literals_len < 4096) {
        dst[out_pos] = @truncate((1 << 2) | ((literals_len >> 8) << 4));
        dst[out_pos + 1] = @truncate(literals_len);
        out_pos += 2;
    } else {
        dst[out_pos] = @truncate((3 << 2) | ((literals_len >> 16) << 4));
        dst[out_pos + 1] = @truncate(literals_len >> 8);
        dst[out_pos + 2] = @truncate(literals_len);
        out_pos += 3;
    }
    if (literals_len > 0) {
        @memcpy(dst[out_pos .. out_pos + literals_len], literals_buf[0..literals_len]);
        out_pos += literals_len;
    }

    // Encode sequences section
    dst[out_pos] = @truncate(seq_count);
    out_pos += 1;
    dst[out_pos] = 0x54; // ll=1, of=1, ml=1
    out_pos += 1;
    // RLE values + dummy (ignored by decompressor but required)
    dst[out_pos] = 0;
    dst[out_pos + 1] = 0;
    dst[out_pos + 2] = 0;
    dst[out_pos + 3] = 0;
    out_pos += 4;

    for (0..seq_count) |i| {
        const s = seqs[i];
        dst[out_pos] = @truncate(s.lit_len);
        out_pos += 1;
        dst[out_pos] = @truncate(s.offset - 1);
        dst[out_pos + 1] = @truncate(s.match_len - 3);
        out_pos += 2;
    }

    return out_pos;
}
