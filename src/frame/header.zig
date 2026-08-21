const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const types = @import("../common/types.zig");

pub fn isSkippableFrame(src: []const u8) bool {
    if (src.len < 4) return false;
    const magic = readLE32(src[0..4]);
    return (magic & constants.magic_skippable_mask) == constants.magic_skippable_start;
}

pub fn isZstdFrame(src: []const u8) bool {
    if (src.len < 4) return false;
    const magic = readLE32(src[0..4]);
    if (magic == constants.magic_number) return true;
    if ((magic & constants.magic_skippable_mask) == constants.magic_skippable_start) return true;
    return false;
}

pub fn getFrameHeader(src: []const u8) errors.ZstdError!types.FrameHeader {
    if (src.len < 4) return error.PrefixUnknown;
    const magic = readLE32(src[0..4]);
    if ((magic & constants.magic_skippable_mask) == constants.magic_skippable_start) {
        if (src.len < 8) return error.SrcSizeWrong;
        const size = readLE32(src[4..8]);
        return types.FrameHeader{
            .frame_type = .skippable,
            .header_size = 8,
            .window_size = 0,
            .block_size_max = 0,
            .dict_id = magic -% constants.magic_skippable_start,
            .checksum_flag = false,
            .content_size = size,
        };
    }
    if (magic != constants.magic_number) return error.PrefixUnknown;
    if (src.len < 5) return error.SrcSizeWrong;
    const fhd = src[4];
    if ((fhd & 0x08) != 0) return error.FrameParameterUnsupported;
    const dict_id_code = fhd & 0x03;
    const checksum_flag = (fhd >> 2) & 1;
    const single_segment = (fhd >> 5) & 1;
    const fcs_code = fhd >> 6;
    var pos: usize = 5;
    var window_size: u64 = 0;
    if (single_segment == 0) {
        if (src.len <= pos) return error.SrcSizeWrong;
        const wl_byte = src[pos];
        pos += 1;
        const window_log: u8 = @intCast((wl_byte >> 3) + constants.window_log_absolutemin);
        if (window_log > constants.window_log_max) return error.WindowTooLarge;
        window_size = @as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(window_log));
        window_size += (window_size >> 3) * @as(u64, wl_byte & 7);
    }
    var dict_id: u32 = 0;
    const did_size = constants.did_field_size[dict_id_code];
    if (src.len < pos + did_size) return error.SrcSizeWrong;
    switch (dict_id_code) {
        0 => {},
        1 => {
            dict_id = src[pos];
            pos += 1;
        },
        2 => {
            dict_id = readLE16(src[pos..]);
            pos += 2;
        },
        3 => {
            dict_id = readLE32(src[pos..]);
            pos += 4;
        },
        else => unreachable,
    }
    var content_size: u64 = constants.contentsize_unknown;
    const fcs_size = constants.fcs_field_size[fcs_code];
    if (single_segment != 0 and fcs_code == 0) {
        if (src.len <= pos) return error.SrcSizeWrong;
        content_size = src[pos];
        pos += 1;
    } else {
        if (fcs_size > 0) {
            if (src.len < pos + fcs_size) return error.SrcSizeWrong;
            switch (fcs_code) {
                0 => content_size = constants.contentsize_unknown,
                1 => content_size = @as(u64, readLE16(src[pos..])) + 256,
                2 => content_size = readLE32(src[pos..]),
                3 => content_size = readLE64(src[pos..]),
                else => unreachable,
            }
            pos += fcs_size;
        } else {
            content_size = constants.contentsize_unknown;
        }
    }
    if (single_segment != 0) window_size = content_size;
    if (window_size == constants.contentsize_unknown) window_size = 0;
    const block_max_raw: u64 = @min(window_size, constants.block_size_max);
    const block_max: u32 = if (block_max_raw > 0xFFFFFFFF) 0xFFFFFFFF else @intCast(block_max_raw);
    const effective_block_max = if (block_max == 0 and single_segment == 0) @as(u32, constants.block_size_max) else block_max;
    return types.FrameHeader{
        .frame_type = .regular,
        .header_size = @intCast(pos),
        .window_size = window_size,
        .block_size_max = effective_block_max,
        .dict_id = dict_id,
        .checksum_flag = checksum_flag != 0,
        .content_size = content_size,
    };
}

pub fn writeFrameHeader(buf: []u8, content_size: ?u64, window_size: u64, dict_id: u32, checksum: bool, single_segment: bool) usize {
    var pos: usize = 0;
    writeLE32(buf[pos..], constants.magic_number);
    pos += 4;
    var fhd: u8 = 0;
    var did_code: u8 = 0;
    if (dict_id == 0) did_code = 0 else if (dict_id < 256) did_code = 1 else if (dict_id < 65536) did_code = 2 else did_code = 3;
    fhd |= did_code;
    if (checksum) fhd |= 0x04;
    if (single_segment) fhd |= 0x20;
    var fcs_code: u8 = 0;
    if (content_size) |cs| {
        if (single_segment and cs < 256) {
            fcs_code = 0;
        } else if (cs < 65792 and cs >= 256) {
            fcs_code = 1;
        } else if (cs < 0x100000000) {
            fcs_code = 2;
        } else {
            fcs_code = 3;
        }
    } else {
        fcs_code = 0;
    }
    fhd |= (fcs_code << 6);
    if (!single_segment) {
        const ws = if (window_size == 0) @as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(constants.window_log_limit_default)) else window_size;
        var window_log: u8 = @intCast(@min(@as(u64, 63 - @clz(ws)), @as(u64, constants.window_log_max)));
        if (window_log < constants.window_log_absolutemin) window_log = constants.window_log_absolutemin;
        const wl_byte: u8 = @as(u8, (window_log - constants.window_log_absolutemin) << 3);
        buf[pos] = fhd;
        pos += 1;
        buf[pos] = wl_byte;
        pos += 1;
    } else {
        buf[pos] = fhd;
        pos += 1;
    }
    switch (did_code) {
        0 => {},
        1 => {
            buf[pos] = @truncate(dict_id);
            pos += 1;
        },
        2 => {
            writeLE16(buf[pos..], @truncate(dict_id));
            pos += 2;
        },
        3 => {
            writeLE32(buf[pos..], dict_id);
            pos += 4;
        },
        else => unreachable,
    }
    if (content_size) |cs| {
        switch (fcs_code) {
            0 => {
                if (single_segment) {
                    buf[pos] = @truncate(cs);
                    pos += 1;
                }
            },
            1 => {
                writeLE16(buf[pos..], @truncate(cs -% 256));
                pos += 2;
            },
            2 => {
                writeLE32(buf[pos..], @truncate(cs));
                pos += 4;
            },
            3 => {
                writeLE64(buf[pos..], cs);
                pos += 8;
            },
            else => unreachable,
        }
    }
    return pos;
}

pub fn readSkippableFrameSize(src: []const u8) errors.ZstdError!usize {
    if (src.len < 8) return error.SrcSizeWrong;
    const size = readLE32(src[4..8]);
    const total = @as(usize, size) + 8;
    if (total < size) return error.FrameParameterUnsupported;
    if (total > src.len) return error.SrcSizeWrong;
    return total;
}

pub fn frameHeaderSize(src: []const u8) errors.ZstdError!usize {
    const h = try getFrameHeader(src);
    return h.header_size;
}

fn readLE16(p: []const u8) u16 {
    return @as(u16, p[0]) | (@as(u16, p[1]) << 8);
}
fn readLE32(p: []const u8) u32 {
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);
}
fn readLE64(p: []const u8) u64 {
    return @as(u64, p[0]) | (@as(u64, p[1]) << 8) | (@as(u64, p[2]) << 16) | (@as(u64, p[3]) << 24) | (@as(u64, p[4]) << 32) | (@as(u64, p[5]) << 40) | (@as(u64, p[6]) << 48) | (@as(u64, p[7]) << 56);
}
fn writeLE16(p: []u8, v: u16) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
}
fn writeLE32(p: []u8, v: u32) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
    p[2] = @truncate(v >> 16);
    p[3] = @truncate(v >> 24);
}
fn writeLE64(p: []u8, v: u64) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
    p[2] = @truncate(v >> 16);
    p[3] = @truncate(v >> 24);
    p[4] = @truncate(v >> 32);
    p[5] = @truncate(v >> 40);
    p[6] = @truncate(v >> 48);
    p[7] = @truncate(v >> 56);
}
