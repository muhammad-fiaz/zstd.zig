const std = @import("std");
const errors = @import("../common/errors.zig");
const decoder = @import("decoder.zig");
const modern = @import("../decompress/decompress.zig");

const magic: u32 = 0xFD2FB526;
const modern_magic: u32 = 0xFD2FB528;

fn readLE32(p: []const u8) u32 {
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);
}

fn writeLE32(p: []u8, v: u32) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
    p[2] = @truncate(v >> 16);
    p[3] = @truncate(v >> 24);
}

pub fn findFrameSize(src: []const u8) errors.ZstdError!usize {
    if (src.len < 4) return error.SrcSizeWrong;
    if (readLE32(src[0..4]) != magic) return error.PrefixUnknown;
    var tmp = std.heap.page_allocator.alloc(u8, src.len) catch return error.MemoryAllocation;
    defer std.heap.page_allocator.free(tmp);
    @memcpy(tmp, src);
    writeLE32(tmp[0..4], modern_magic);
    const sz = try modern.findFrameCompressedSize(tmp);
    return @min(sz, src.len);
}

pub fn decompress(dst: []u8, src: []const u8) errors.ZstdError!decoder.Result {
    if (src.len < 4) return error.SrcSizeWrong;
    if (readLE32(src[0..4]) != magic) return error.PrefixUnknown;
    const frame_size = try findFrameSize(src);
    const actual = @min(frame_size, src.len);
    var tmp = std.heap.page_allocator.alloc(u8, actual) catch return error.MemoryAllocation;
    defer std.heap.page_allocator.free(tmp);
    @memcpy(tmp, src[0..actual]);
    writeLE32(tmp[0..4], modern_magic);
    const decoded = modern.decompressInto(dst, tmp) catch |e| {
        if (e == error.PrefixUnknown) return error.Corruption;
        return e;
    };
    return decoder.Result{ .decoded = decoded, .consumed = actual };
}
