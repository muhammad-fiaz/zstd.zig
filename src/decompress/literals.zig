const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");

pub const LiteralsResult = struct {
    literals: []const u8,
    lit_buffer: []u8,
    bytes_read: usize,
    huffman_used: bool,
};

pub fn decodeLiterals(src: []const u8) errors.ZstdError!LiteralsResult {
    if (src.len < 1) return error.SrcSizeWrong;
    const header = src[0];
    const lit_type: u2 = @truncate(header & 0x3);
    switch (lit_type) {
        0 => {
            var size: usize = 0;
            var header_size: usize = 0;
            const size_format = (header >> 2) & 0x3;
            switch (size_format) {
                0, 2 => {
                    size = header >> 3;
                    header_size = 1;
                },
                1 => {
                    if (src.len < 2) return error.SrcSizeWrong;
                    size = (@as(usize, header >> 4) << 8) | @as(usize, src[1]);
                    header_size = 2;
                },
                3 => {
                    if (src.len < 3) return error.SrcSizeWrong;
                    size = (@as(usize, header >> 4) << 16) | (@as(usize, src[1]) << 8) | @as(usize, src[2]);
                    header_size = 3;
                },
                else => unreachable,
            }
            if (src.len < header_size + size) return error.SrcSizeWrong;
            return LiteralsResult{
                .literals = src[header_size .. header_size + size],
                .lit_buffer = &[_]u8{},
                .bytes_read = header_size + size,
                .huffman_used = false,
            };
        },
        1 => {
            return error.UnsupportedFeature;
        },
        2, 3 => {
            return error.UnsupportedFeature;
        },
    }
}

pub fn decodeRawLiterals(src: []const u8, dst: []u8) errors.ZstdError!usize {
    const r = try decodeLiterals(src);
    if (r.literals.len > dst.len) return error.DstSizeTooSmall;
    @memcpy(dst[0..r.literals.len], r.literals);
    return r.bytes_read;
}
