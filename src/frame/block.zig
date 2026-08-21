const errors = @import("../common/errors.zig");
const types = @import("../common/types.zig");
const constants = @import("../common/constants.zig");

pub fn getBlockHeader(src: []const u8) errors.ZstdError!types.BlockProperties {
    if (src.len < 3) return error.SrcSizeWrong;
    const b0 = src[0];
    const b1 = src[1];
    const b2 = src[2];
    const header: u32 = @as(u32, b0) | (@as(u32, b1) << 8) | (@as(u32, b2) << 16);
    const last_block = (header & 1) != 0;
    const block_type_raw = (header >> 1) & 0x3;
    const block_type: types.BlockType = switch (block_type_raw) {
        0 => .raw,
        1 => .rle,
        2 => .compressed,
        3 => .reserved,
        else => unreachable,
    };
    if (block_type == .reserved) return error.InvalidBlock;
    const c_size: u32 = header >> 3;
    return types.BlockProperties{
        .block_type = block_type,
        .last_block = last_block,
        .orig_size = c_size,
    };
}

pub fn writeBlockHeader(buf: []u8, last: bool, block_type: types.BlockType, size: u32) void {
    var header: u32 = 0;
    if (last) header |= 1;
    header |= (@as(u32, @intFromEnum(block_type)) & 0x3) << 1;
    header |= (size << 3);
    buf[0] = @truncate(header);
    buf[1] = @truncate(header >> 8);
    buf[2] = @truncate(header >> 16);
}

pub fn getCBlockSize(src: []const u8) errors.ZstdError!usize {
    const prop = try getBlockHeader(src);
    if (prop.block_type == .rle) return 1;
    return prop.orig_size;
}
