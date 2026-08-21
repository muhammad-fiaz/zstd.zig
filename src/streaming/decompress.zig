const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const decompress_mod = @import("../decompress/decompress.zig");
const header_mod = @import("../frame/header.zig");
const types = @import("../common/types.zig");
const block_mod = @import("../frame/block.zig");
const checksum_mod = @import("../frame/checksum.zig");
const block_decompress = @import("../decompress/block.zig");

pub const StreamingDecompressor = struct {
    allocator: std.mem.Allocator,
    in_buffer: std.ArrayList(u8),
    out_buffer: std.ArrayList(u8),
    stage: Stage,
    frame_header: ?types.FrameHeader,
    checksum_state: checksum_mod.ChecksumState,
    finished: bool,

    const Stage = enum { header, blocks, checksum, done };

    pub fn init(allocator: std.mem.Allocator) StreamingDecompressor {
        return .{
            .allocator = allocator,
            .in_buffer = .empty,
            .out_buffer = .empty,
            .stage = .header,
            .frame_header = null,
            .checksum_state = checksum_mod.ChecksumState.init(),
            .finished = false,
        };
    }

    pub fn deinit(self: *StreamingDecompressor) void {
        self.in_buffer.deinit(self.allocator);
        self.out_buffer.deinit(self.allocator);
    }

    pub fn decompressStream(self: *StreamingDecompressor, out: []u8, in_data: []const u8) errors.ZstdError!struct { in_consumed: usize, out_produced: usize, needs_more: bool } {
        try self.in_buffer.appendSlice(self.allocator, in_data);
        var in_consumed: usize = 0;
        var out_produced: usize = 0;
        while (true) {
            if (self.stage == .header) {
                if (self.in_buffer.items.len - in_consumed < 5) break;
                const slice = self.in_buffer.items[in_consumed..];
                const magic = readLE32(slice[0..4]);
                if ((magic & constants.magic_skippable_mask) == constants.magic_skippable_start) {
                    if (slice.len < 8) break;
                    const sz = readLE32(slice[4..8]);
                    const total = @as(usize, sz) + 8;
                    if (slice.len < total) break;
                    in_consumed += total;
                    continue;
                }
                if (magic != constants.magic_number) return error.PrefixUnknown;
                const fh = try header_mod.getFrameHeader(slice);
                self.frame_header = fh;
                in_consumed += fh.header_size;
                if (fh.checksum_flag) self.checksum_state = checksum_mod.ChecksumState.init();
                self.stage = .blocks;
            }
            if (self.stage == .blocks) {
                if (self.in_buffer.items.len - in_consumed < 3) break;
                const prop = try block_mod.getBlockHeader(self.in_buffer.items[in_consumed..]);
                const csize = prop.orig_size;
                const needed: usize = 3 + (if (prop.block_type == .rle) @as(usize, 1) else @as(usize, csize));
                if (self.in_buffer.items.len - in_consumed < needed) break;
                const block_slice = self.in_buffer.items[in_consumed .. in_consumed + needed];
                const history_slice: []const u8 = self.out_buffer.items;
                const decoded = try block_decompress.decompressBlock(out[out_produced..], block_slice, history_slice);
                if (self.frame_header != null and self.frame_header.?.checksum_flag) {
                    self.checksum_state.update(out[out_produced .. out_produced + decoded]);
                }
                try self.out_buffer.appendSlice(self.allocator, out[out_produced .. out_produced + decoded]);
                out_produced += decoded;
                in_consumed += needed;
                if (prop.last_block) {
                    if (self.frame_header != null and self.frame_header.?.checksum_flag) {
                        self.stage = .checksum;
                    } else {
                        self.stage = .header;
                        self.frame_header = null;
                        if (in_consumed >= self.in_buffer.items.len and out_produced > 0) break;
                    }
                }
                if (out_produced >= out.len) break;
            }
            if (self.stage == .checksum) {
                if (self.in_buffer.items.len - in_consumed < 4) break;
                const expected = checksum_mod.readChecksum(self.in_buffer.items[in_consumed..]);
                const got = self.checksum_state.final();
                if (expected != got) return error.ChecksumWrong;
                in_consumed += 4;
                self.stage = .header;
                self.frame_header = null;
            }
            if (self.stage == .done) break;
            if (in_consumed >= self.in_buffer.items.len) break;
        }
        if (in_consumed > 0) {
            const remaining = self.in_buffer.items.len - in_consumed;
            if (remaining > 0) std.mem.copyForwards(u8, self.in_buffer.items[0..remaining], self.in_buffer.items[in_consumed..]);
            self.in_buffer.shrinkRetainingCapacity(remaining);
        }
        const needs_more = self.stage != .header or self.in_buffer.items.len > 0;
        return .{ .in_consumed = in_data.len, .out_produced = out_produced, .needs_more = needs_more };
    }

    pub fn reset(self: *StreamingDecompressor) void {
        self.in_buffer.clearRetainingCapacity();
        self.out_buffer.clearRetainingCapacity();
        self.stage = .header;
        self.frame_header = null;
        self.checksum_state = checksum_mod.ChecksumState.init();
        self.finished = false;
    }

    pub fn decompressAll(self: *StreamingDecompressor, out: []u8, in_data: []const u8) errors.ZstdError!usize {
        _ = self;
        return decompress_mod.decompressInto(out, in_data);
    }
};

pub const DStream = StreamingDecompressor;

fn readLE32(p: []const u8) u32 {
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);
}
