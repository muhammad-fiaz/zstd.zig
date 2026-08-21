const constants = @import("../common/constants.zig");

pub fn isLegacy(src: []const u8) bool {
    if (src.len < 4) return false;
    const magic = readLE32(src[0..4]);
    const legacy_magics = [_]u32{
        0xFD2FB521, 0xFD2FB522, 0xFD2FB523, 0xFD2FB524,
        0xFD2FB525, 0xFD2FB526, 0xFD2FB527,
    };
    for (legacy_magics) |m| if (magic == m) return true;
    return false;
}

pub fn legacyVersion(src: []const u8) ?u8 {
    if (src.len < 4) return null;
    const magic = readLE32(src[0..4]);
    return switch (magic) {
        0xFD2FB521 => 1,
        0xFD2FB522 => 2,
        0xFD2FB523 => 3,
        0xFD2FB524 => 4,
        0xFD2FB525 => 5,
        0xFD2FB526 => 6,
        0xFD2FB527 => 7,
        else => null,
    };
}

fn readLE32(p: []const u8) u32 {
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);
}
