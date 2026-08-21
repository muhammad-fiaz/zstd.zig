pub fn copy8(dst: [*]u8, src: [*]const u8) void {
    dst[0..8].* = src[0..8].*;
}

pub fn copy16(dst: [*]u8, src: [*]const u8) void {
    dst[0..16].* = src[0..16].*;
}
