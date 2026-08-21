pub fn compressFast(dst: []u8, src: []const u8) usize {
    if (dst.len < src.len + 3) return 0;
    @memcpy(dst[3 .. 3 + src.len], src);
    return 3 + src.len;
}
