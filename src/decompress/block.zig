const std = @import("std");
const errors = @import("../common/errors.zig");
const types = @import("../common/types.zig");
const block_header = @import("../frame/block.zig");
const entropy_mod = @import("entropy.zig");

pub fn decompressBlock(
    state: *entropy_mod.State,
    dst: []u8,
    src: []const u8,
    window: []const u8,
) errors.ZstdError!usize {
    if (src.len < 3) return error.SrcSizeWrong; // EDBG1
    const props = try block_header.getBlockHeader(src);
    const csize = props.orig_size;
    if (3 + csize > src.len and props.block_type != .rle) return error.SrcSizeWrong; // EDBG2
    switch (props.block_type) {
        .raw => {
            if (csize > dst.len) return error.DstSizeTooSmall; // EDBG3
            if (src.len < 3 + csize) return error.SrcSizeWrong; // EDBG4
            @memcpy(dst[0..csize], src[3 .. 3 + csize]);
            return csize;
        },
        .rle => {
            if (src.len < 4) return error.SrcSizeWrong; // EDBG5
            const val = src[3];
            if (csize > dst.len) return error.DstSizeTooSmall; // EDBG6
            @memset(dst[0..csize], val);
            return csize;
        },
        .compressed => {
            const block_src = src[3 .. 3 + csize];
            return decompressCompressedBlock(state, dst, block_src, window);
        },
        .reserved => return error.InvalidBlock,
    }
}

fn decompressCompressedBlock(
    state: *entropy_mod.State,
    dst: []u8,
    src: []const u8,
    window: []const u8,
) errors.ZstdError!usize {
    if (src.len < 1) return error.SrcSizeWrong; // EDBG7

    var lit = try entropy_mod.decodeLiterals(state, src, constants_block_max);
    defer lit.section.deinit(state.allocator);

    if (lit.bytes_read >= src.len) {
        // No sequences section.
        if (lit.section.data.len > dst.len) return error.DstSizeTooSmall; // EDBG8
        @memcpy(dst[0..lit.section.data.len], lit.section.data);
        return lit.section.data.len;
    }

    return entropy_mod.decodeSequences(
        state,
        dst,
        lit.section.data,
        src[lit.bytes_read..],
        .{ .history = window },
    );
}

// The format caps literals at one block (1 << 17 bytes).
const constants_block_max: usize = 1 << 17;

pub fn decompressBlockStreaming(
    state: *entropy_mod.State,
    allocator: std.mem.Allocator,
    dst: []u8,
    src: []const u8,
    history: *std.ArrayList(u8),
) errors.ZstdError!usize {
    const hist_slice = history.items;
    const decoded = try decompressBlock(state, dst, src, hist_slice);
    try history.appendSlice(allocator, dst[0..decoded]);
    if (history.items.len > 1 << 27) {
        const keep = 1 << 27;
        const excess = history.items.len - keep;
        std.mem.copyForwards(u8, history.items[0..keep], history.items[excess .. excess + keep]);
        history.shrinkRetainingCapacity(keep);
    }
    return decoded;
}
