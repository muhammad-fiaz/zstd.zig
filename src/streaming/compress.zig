const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const compress_mod = @import("../compress/compress.zig");
const header_mod = @import("../frame/header.zig");
const checksum_mod = @import("../frame/checksum.zig");
const block_mod = @import("../compress/block.zig");

pub const EndDirective = enum { cont, flush, end };

pub const StreamingCompressor = struct {
    allocator: std.mem.Allocator,
    options: compress_mod.CompressionOptions,
    buffer: std.ArrayList(u8),
    checksum_state: checksum_mod.ChecksumState,
    finished: bool,
    header_written: bool,
    level: i32,

    pub fn init(allocator: std.mem.Allocator, level: i32) !StreamingCompressor {
        return StreamingCompressor{
            .allocator = allocator,
            .options = compress_mod.getCompressionParameters(level, 0, 0),
            .buffer = .empty,
            .checksum_state = checksum_mod.ChecksumState.init(),
            .finished = false,
            .header_written = false,
            .level = level,
        };
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, options: compress_mod.CompressionOptions) StreamingCompressor {
        return StreamingCompressor{
            .allocator = allocator,
            .options = options,
            .buffer = .empty,
            .checksum_state = checksum_mod.ChecksumState.init(),
            .finished = false,
            .header_written = false,
            .level = options.level,
        };
    }

    pub fn deinit(self: *StreamingCompressor) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn setPledgedSrcSize(self: *StreamingCompressor, size: ?u64) void {
        self.options.content_size = size;
    }

    pub fn setChecksumFlag(self: *StreamingCompressor, flag: bool) void {
        self.options.checksum = flag;
    }

    pub fn compressStream(self: *StreamingCompressor, out: []u8, in_data: []const u8, directive: EndDirective) errors.ZstdError!struct { in_consumed: usize, out_produced: usize, remaining: usize } {
        if (self.finished and directive != .end) return error.StageWrong;
        var out_pos: usize = 0;
        if (!self.header_written) {
            const window_size: u64 = if (self.options.window_log != 0) @as(u64, 1) << @as(std.math.Log2Int(u64), @intCast(self.options.window_log)) else @as(u64, 1) << 17;
            const single_segment = self.options.content_size != null and self.options.content_size.? < 256 * 1024 and window_size >= (self.options.content_size orelse 0);
            const header_size = header_mod.writeFrameHeader(out[out_pos..], self.options.content_size, window_size, self.options.dict_id, self.options.checksum, single_segment);
            out_pos += header_size;
            self.header_written = true;
        }
        if (in_data.len > 0) {
            try self.buffer.appendSlice(self.allocator, in_data);
            self.checksum_state.update(in_data);
        }
        const in_consumed = in_data.len;
        if (directive == .flush or directive == .end) {
            const to_compress = self.buffer.items;
            if (to_compress.len > 0) {
                var remaining = to_compress.len;
                var src_pos: usize = 0;
                while (remaining > 0) {
                    const chunk = @min(remaining, constants.block_size_max);
                    const is_last = directive == .end and src_pos + chunk >= to_compress.len;
                    const block_buf = out[out_pos..];
                    if (block_buf.len < chunk + 3) return error.DstSizeTooSmall;
                    const written = try block_mod.compressBlock(block_buf, to_compress[src_pos .. src_pos + chunk], is_last);
                    out_pos += written;
                    src_pos += chunk;
                    remaining -= chunk;
                    if (out_pos + 128 > out.len and remaining > 0) break;
                }
                if (directive == .end) {
                    self.buffer.clearRetainingCapacity();
                } else {
                    if (src_pos > 0) {
                        const left = to_compress.len - src_pos;
                        if (left > 0) std.mem.copyForwards(u8, self.buffer.items[0..left], to_compress[src_pos..]);
                        self.buffer.shrinkRetainingCapacity(left);
                    }
                }
            } else if (directive == .end) {
                if (out.len < out_pos + 3) return error.DstSizeTooSmall;
                const written = try block_mod.compressBlock(out[out_pos..], &[_]u8{}, true);
                out_pos += written;
            }
        }
        if (directive == .end) {
            if (self.options.checksum) {
                if (out.len < out_pos + 4) return error.DstSizeTooSmall;
                const chk = self.checksum_state.final();
                checksum_mod.writeChecksum(out[out_pos..], chk);
                out_pos += 4;
            }
            self.finished = true;
            return .{ .in_consumed = in_consumed, .out_produced = out_pos, .remaining = 0 };
        }
        return .{ .in_consumed = in_consumed, .out_produced = out_pos, .remaining = self.buffer.items.len };
    }

    pub fn reset(self: *StreamingCompressor) void {
        self.buffer.clearRetainingCapacity();
        self.checksum_state = checksum_mod.ChecksumState.init();
        self.finished = false;
        self.header_written = false;
    }
};

pub const CStream = StreamingCompressor;
