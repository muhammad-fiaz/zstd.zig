const errors = @import("../common/errors.zig");

pub fn decodeSequences(dst: []u8, literals: []const u8, src: []const u8, window: []const u8) errors.ZstdError!usize {
    if (src.len == 0) {
        if (literals.len > dst.len) return error.DstSizeTooSmall;
        @memcpy(dst[0..literals.len], literals);
        return literals.len;
    }
    var pos: usize = 0;
    const first = src[pos];
    pos += 1;
    var nb_seq: usize = 0;
    if (first < 128) {
        nb_seq = first;
    } else if (first < 255) {
        if (pos >= src.len) return error.SrcSizeWrong;
        nb_seq = ((@as(usize, first - 128) << 8) + @as(usize, src[pos]));
        pos += 1;
    } else {
        if (pos + 1 >= src.len) return error.SrcSizeWrong;
        nb_seq = @as(usize, src[pos]) + (@as(usize, src[pos + 1]) << 8) + 0x7F00;
        pos += 2;
    }
    if (nb_seq == 0) {
        if (literals.len > dst.len) return error.DstSizeTooSmall;
        @memcpy(dst[0..literals.len], literals);
        return literals.len;
    }
    if (pos >= src.len) return error.SrcSizeWrong;
    const sym_header = src[pos];
    pos += 1;
    const ll_type: u2 = @truncate((sym_header >> 6) & 0x3);
    const of_type: u2 = @truncate((sym_header >> 4) & 0x3);
    const ml_type: u2 = @truncate((sym_header >> 2) & 0x3);
    if (ll_type == 0 and of_type == 0 and ml_type == 0) {
        return error.Corruption;
    }
    if (ll_type == 1) {
        if (pos >= src.len) return error.SrcSizeWrong;
        pos += 1;
    } else if (ll_type == 2 or ll_type == 3) {
        return error.UnsupportedFeature;
    }
    if (of_type == 1) {
        if (pos >= src.len) return error.SrcSizeWrong;
        pos += 1;
    } else if (of_type == 2 or of_type == 3) {
        return error.UnsupportedFeature;
    }
    if (ml_type == 1) {
        if (pos >= src.len) return error.SrcSizeWrong;
        pos += 1;
    } else if (ml_type == 2 or ml_type == 3) {
        return error.UnsupportedFeature;
    }
    if (pos >= src.len) return error.SrcSizeWrong;
    pos += 1;
    var lit_pos: usize = 0;
    var out_pos: usize = 0;
    const rep = [3]u32{ 1, 4, 8 };
    _ = rep;
    var seq_idx: usize = 0;
    while (seq_idx < nb_seq) : (seq_idx += 1) {
        if (pos >= src.len) return error.SrcSizeWrong;
        const ll_code = src[pos];
        pos += 1;
        const lit_len = @as(usize, ll_code);
        if (lit_pos + lit_len > literals.len) return error.Corruption;
        if (out_pos + lit_len > dst.len) return error.DstSizeTooSmall;
        @memcpy(dst[out_pos .. out_pos + lit_len], literals[lit_pos .. lit_pos + lit_len]);
        out_pos += lit_len;
        lit_pos += lit_len;
        if (pos + 1 >= src.len) return error.SrcSizeWrong;
        const of_code = src[pos];
        const ml_code = src[pos + 1];
        pos += 2;
        const match_len: usize = @as(usize, ml_code) + 3;
        const offset: usize = @as(usize, of_code) + 1;
        if (offset > out_pos) {
            if (window.len > 0 and offset <= out_pos + window.len) {
                const from_window = offset - out_pos;
                const win_start = window.len - from_window;
                const copy_len = @min(match_len, from_window);
                if (out_pos + copy_len > dst.len) return error.DstSizeTooSmall;
                @memcpy(dst[out_pos .. out_pos + copy_len], window[win_start .. win_start + copy_len]);
                out_pos += copy_len;
                var remaining = match_len - copy_len;
                while (remaining > 0) {
                    const to_copy = @min(remaining, out_pos);
                    if (out_pos + to_copy > dst.len) return error.DstSizeTooSmall;
                    var i: usize = 0;
                    while (i < to_copy) : (i += 1) {
                        dst[out_pos + i] = dst[out_pos - offset + i];
                    }
                    out_pos += to_copy;
                    remaining -= to_copy;
                }
            } else {
                return error.InvalidOffset;
            }
        } else {
            if (out_pos + match_len > dst.len) return error.DstSizeTooSmall;
            var i: usize = 0;
            while (i < match_len) : (i += 1) {
                dst[out_pos + i] = dst[out_pos - offset + i];
            }
            out_pos += match_len;
        }
    }
    const remaining_lit = literals.len - lit_pos;
    if (out_pos + remaining_lit > dst.len) return error.DstSizeTooSmall;
    @memcpy(dst[out_pos .. out_pos + remaining_lit], literals[lit_pos..]);
    out_pos += remaining_lit;
    return out_pos;
}
