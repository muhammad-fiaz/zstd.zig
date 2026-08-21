pub fn compressLiterals(dst: []u8, src: []const u8) usize {
    if (src.len < 32) {
        if (dst.len < src.len + 1) return 0;
        dst[0] = @truncate(src.len << 3);
        if (src.len > 0) @memcpy(dst[1 .. 1 + src.len], src);
        return 1 + src.len;
    } else if (src.len < 4096) {
        if (dst.len < src.len + 2) return 0;
        dst[0] = @truncate((1 << 2) | ((src.len >> 8) << 4));
        dst[1] = @truncate(src.len);
        @memcpy(dst[2 .. 2 + src.len], src);
        return 2 + src.len;
    } else {
        if (dst.len < src.len + 3) return 0;
        dst[0] = @truncate((3 << 2) | ((src.len >> 16) << 4));
        dst[1] = @truncate(src.len >> 8);
        dst[2] = @truncate(src.len);
        @memcpy(dst[3 .. 3 + src.len], src);
        return 3 + src.len;
    }
}
