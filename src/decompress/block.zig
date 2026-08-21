const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const types = @import("../common/types.zig");
const block_header = @import("../frame/block.zig");
const literals_mod = @import("literals.zig");
const sequences_mod = @import("sequences.zig");

pub fn decompressBlock(dst: []u8, src: []const u8, window: []const u8) errors.ZstdError!usize {
    if (src.len < 3) return error.SrcSizeWrong;
    const props = try block_header.getBlockHeader(src);
    const csize = props.orig_size;
    if (3 + csize > src.len and props.block_type != .rle) return error.SrcSizeWrong;
    switch (props.block_type) {
        .raw => {
            if (csize > dst.len) return error.DstSizeTooSmall;
            if (src.len < 3 + csize) return error.SrcSizeWrong;
            @memcpy(dst[0..csize], src[3 .. 3 + csize]);
            return csize;
        },
        .rle => {
            if (src.len < 4) return error.SrcSizeWrong;
            const val = src[3];
            if (csize > dst.len) return error.DstSizeTooSmall;
            @memset(dst[0..csize], val);
            return csize;
        },
        .compressed => {
            const block_src = src[3 .. 3 + csize];
            return decompressCompressedBlock(dst, block_src, window);
        },
        .reserved => return error.InvalidBlock,
    }
}

fn decompressCompressedBlock(dst: []u8, src: []const u8, window: []const u8) errors.ZstdError!usize {
    var pos: usize = 0;
    if (src.len < 1) return error.SrcSizeWrong;

    const lit_result = try literals_mod.decodeLiterals(src);
    pos += lit_result.bytes_read;
    if (pos > src.len) return error.SrcSizeWrong;

    const literals = lit_result.literals;
    const lit_buffer = lit_result.lit_buffer;
    _ = lit_buffer;

    if (pos >= src.len) {
        if (literals.len > dst.len) return error.DstSizeTooSmall;
        @memcpy(dst[0..literals.len], literals);
        return literals.len;
    }

    const seq_result = try sequences_mod.decodeSequences(dst, literals, src[pos..], window);
    return seq_result;
}

pub fn decompressBlockStreaming(allocator: std.mem.Allocator, dst: []u8, src: []const u8, history: *std.ArrayList(u8)) errors.ZstdError!usize {
    const hist_slice = history.items;
    const decoded = try decompressBlock(dst, src, hist_slice);
    try history.appendSlice(allocator, dst[0..decoded]);
    if (history.items.len > 1 << 27) {
        const keep = 1 << 27;
        const excess = history.items.len - keep;
        std.mem.copyForwards(u8, history.items[0..keep], history.items[excess .. excess + keep]);
        history.shrinkRetainingCapacity(keep);
    }
    return decoded;
}
