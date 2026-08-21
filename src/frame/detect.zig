const constants = @import("../common/constants.zig");
const header = @import("header.zig");
const legacy = @import("../legacy/detect.zig");

pub const FrameKind = enum { zstd, skippable, legacy, unknown };

pub fn detectFrame(src: []const u8) FrameKind {
    if (src.len < 4) return .unknown;
    const magic = readLE32(src[0..4]);
    if (magic == constants.magic_number) return .zstd;
    if ((magic & constants.magic_skippable_mask) == constants.magic_skippable_start) return .skippable;
    if (legacy.isLegacy(src)) return .legacy;
    return .unknown;
}

fn readLE32(p: []const u8) u32 {
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);
}
