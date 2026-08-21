const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");

pub const Dictionary = struct {
    data: []u8,
    dict_id: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Dictionary) void {
        self.allocator.free(self.data);
    }

    pub fn dictId(self: *const Dictionary) u32 {
        return self.dict_id;
    }

    pub fn content(self: *const Dictionary) []const u8 {
        if (self.data.len < 8) return &[_]u8{};
        const magic = readLE32(self.data[0..4]);
        if (magic == constants.magic_dictionary) {
            const id = readLE32(self.data[4..8]);
            _ = id;
            return self.data[8..];
        }
        return self.data;
    }
};

pub fn loadDictionary(allocator: std.mem.Allocator, data: []const u8) errors.ZstdError!Dictionary {
    const buf = try allocator.alloc(u8, data.len);
    @memcpy(buf, data);
    var dict_id: u32 = 0;
    if (data.len >= 8 and readLE32(data[0..4]) == constants.magic_dictionary) {
        dict_id = readLE32(data[4..8]);
    }
    return Dictionary{ .data = buf, .dict_id = dict_id, .allocator = allocator };
}

pub fn createDictionaryFromData(allocator: std.mem.Allocator, data: []const u8, dict_id: u32) errors.ZstdError!Dictionary {
    var buf = try allocator.alloc(u8, data.len + 8);
    writeLE32(buf[0..4], constants.magic_dictionary);
    writeLE32(buf[4..8], dict_id);
    @memcpy(buf[8..], data);
    return Dictionary{ .data = buf, .dict_id = dict_id, .allocator = allocator };
}

fn readLE32(p: []const u8) u32 {
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);
}
fn writeLE32(p: []u8, v: u32) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
    p[2] = @truncate(v >> 16);
    p[3] = @truncate(v >> 24);
}
