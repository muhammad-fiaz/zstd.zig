const std = @import("std");
const errors = @import("../common/errors.zig");
const dict_mod = @import("dictionary.zig");

pub const DictBuilderParams = struct {
    dict_size: usize = 112640,
    dict_id: u32 = 0,
    level: u32 = 3,
};

pub fn trainFromSamples(allocator: std.mem.Allocator, samples: []const []const u8, params: DictBuilderParams) errors.ZstdError!dict_mod.Dictionary {
    if (samples.len == 0) return error.InvalidDictionary;
    var total: usize = 0;
    for (samples) |s| total += s.len;
    if (total == 0) return error.InvalidDictionary;
    var dict_content = try allocator.alloc(u8, params.dict_size);
    errdefer allocator.free(dict_content);
    var pos: usize = 0;
    var sample_idx: usize = 0;
    while (pos < dict_content.len) {
        const s = samples[sample_idx % samples.len];
        const copy_len = @min(s.len, dict_content.len - pos);
        if (copy_len == 0) break;
        @memcpy(dict_content[pos .. pos + copy_len], s[0..copy_len]);
        pos += copy_len;
        sample_idx += 1;
        if (sample_idx > samples.len * 4 and pos < dict_content.len) {
            for (dict_content[pos..]) |*b| b.* = @truncate(pos);
            break;
        }
    }
    const dict = try dict_mod.createDictionaryFromData(allocator, dict_content[0..pos], params.dict_id);
    allocator.free(dict_content);
    return dict;
}

pub fn trainCoverImpl(allocator: std.mem.Allocator, samples: []const []const u8, params: DictBuilderParams, k: usize, d: usize) errors.ZstdError!dict_mod.Dictionary {
    _ = k;
    _ = d;
    return trainFromSamples(allocator, samples, params);
}

pub fn trainFastCoverImpl(allocator: std.mem.Allocator, samples: []const []const u8, params: DictBuilderParams, k: usize, d: usize, f: u32, accel: u32) errors.ZstdError!dict_mod.Dictionary {
    _ = k;
    _ = d;
    _ = f;
    _ = accel;
    return trainFromSamples(allocator, samples, params);
}

pub const DictionaryBuilder = struct {
    allocator: std.mem.Allocator,
    params: DictBuilderParams,

    pub fn init(allocator: std.mem.Allocator, params: DictBuilderParams) DictionaryBuilder {
        return .{ .allocator = allocator, .params = params };
    }

    pub fn train(self: *DictionaryBuilder, samples: []const []const u8) anyerror!dict_mod.Dictionary {
        return trainFromSamples(self.allocator, samples, self.params);
    }

    pub fn trainCover(self: *DictionaryBuilder, samples: []const []const u8, k: usize, d: usize) anyerror!dict_mod.Dictionary {
        return trainCoverImpl(self.allocator, samples, self.params, k, d);
    }

    pub fn trainFastCover(self: *DictionaryBuilder, samples: []const []const u8, k: usize, d: usize, f: u32, accel: u32) anyerror!dict_mod.Dictionary {
        return trainFastCoverImpl(self.allocator, samples, self.params, k, d, f, accel);
    }
};
