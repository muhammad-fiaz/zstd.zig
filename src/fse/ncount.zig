//! Reads an FSE normalized-counter header in compact format: a 4-bit
//! tableLog field followed by interleaved count values with run-length
//! coding for repeated zeros.

const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");

fn le32At(src: []const u8, i: usize) u32 {
    return @as(u32, src[i]) |
        (@as(u32, src[i + 1]) << 8) |
        (@as(u32, src[i + 2]) << 16) |
        (@as(u32, src[i + 3]) << 24);
}

/// Reads normalized counts into `normalized[0..max_sv_ptr.*+1]` capacity,
/// updates `max_sv_ptr` and `table_log_ptr`, returns header bytes consumed.
pub fn readNCount(
    normalized: []i16,
    max_sv_ptr: *usize,
    table_log_ptr: *u8,
    src: []const u8,
) errors.ZstdError!usize {
    if (src.len == 0) return error.InvalidFseTable; // FDBG1

    // Buffers smaller than 8 bytes are zero-padded into an 8-byte window so
    // fixed-width reads stay in bounds.
    if (src.len < 8) {
        var buf: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
        @memcpy(buf[0..src.len], src);
        var max_sv = max_sv_ptr.*;
        var tl: u8 = 0;
        const n = try readBody(normalized, &max_sv, &tl, &buf);
        if (n > src.len) return error.Corruption; // FDBG2
        max_sv_ptr.* = max_sv;
        table_log_ptr.* = tl;
        return n;
    }
    return readBody(normalized, max_sv_ptr, table_log_ptr, src);
}

fn readBody(
    normalized: []i16,
    max_sv_ptr: *usize,
    table_log_ptr: *u8,
    src: []const u8,
) errors.ZstdError!usize {
    const iend = src.len;
    if (iend < 4) return error.InvalidFseTable; // FDBG3
    @memset(normalized, 0);

    var ip: usize = 0;
    var bit_stream: u32 = le32At(src, 0);
    const tl: u8 = @intCast((bit_stream & 0xF) + constants.min_fse_log);
    if (tl > constants.max_fse_log or tl < constants.min_fse_log) return error.TableLogTooLarge; // FDBG4
    table_log_ptr.* = tl;
    bit_stream >>= 4;
    var bit_count: u32 = 4;

    var remaining: i32 = (@as(i32, 1) << @intCast(tl)) + 1;
    var threshold: i32 = @as(i32, 1) << @intCast(tl);
    var nb_bits: u32 = @as(u32, tl) + 1;

    var charnum: usize = 0;
    var previous0: bool = false;
    const max_sv1 = max_sv_ptr.* + 1;

    while (true) {
        if (previous0) {
            // Runs of repeated zero counts encoded as consecutive 0b11 pairs.
            var repeats: u32 = @ctz(~bit_stream | 0x80000000) >> 1;
            while (repeats >= 12) {
                charnum += 3 * 12;
                if (charnum >= max_sv1) break;
                if (ip <= iend - 7) {
                    ip += 3;
                } else {
                    const diff = iend - 4 - ip;
                    bit_count -%= @as(u32, @intCast(diff * 8));
                    bit_count &= 31;
                    ip = iend - 4;
                }
                bit_stream = le32At(src, ip) >> @intCast(bit_count & 31);
                repeats = @ctz(~bit_stream | 0x80000000) >> 1;
            }
            charnum += 3 * repeats;
            bit_stream >>= @intCast(2 * repeats);
            bit_count += 2 * repeats;

            charnum += bit_stream & 3; // final partial repeat
            bit_count += 2;

            if (charnum >= max_sv1) break;
            // zero counts stay implicit (buffer pre-zeroed)

            if (ip <= iend - 7 or ip + (bit_count >> 3) <= iend - 4) {
                ip += bit_count >> 3;
                bit_count &= 7;
            } else {
                const diff = iend - 4 - ip;
                bit_count -%= @as(u32, @intCast(diff * 8));
                bit_count &= 31;
                ip = iend - 4;
            }
            bit_stream = le32At(src, ip) >> @intCast(bit_count & 31);
        }

        const max_val: i32 = (2 * threshold - 1) - remaining;
        var count: i32 = 0;
        if ((bit_stream & @as(u32, @intCast(threshold - 1))) < @as(u32, @intCast(max_val))) {
            count = @intCast(bit_stream & @as(u32, @intCast(threshold - 1)));
            bit_count += nb_bits - 1;
        } else {
            count = @intCast(bit_stream & @as(u32, @intCast(2 * threshold - 1)));
            if (count >= threshold) count -= max_val;
            bit_count += nb_bits;
        }

        count -= 1; // extra accuracy
        remaining -%= count;
        if (charnum < normalized.len) normalized[charnum] = @intCast(count);
        charnum += 1;
        previous0 = count == 0;

        if (remaining < threshold) {
            if (remaining <= 1) break;
            nb_bits = @as(u32, 31 - @clz(@as(u32, @intCast(remaining)))) + 1;
            threshold = @as(i32, 1) << @intCast(nb_bits - 1);
        }
        if (charnum >= max_sv1) break;

        if (ip <= iend - 7 or ip + (bit_count >> 3) <= iend - 4) {
            ip += bit_count >> 3;
            bit_count &= 7;
        } else {
            const diff = iend - 4 - ip;
            bit_count -%= @as(u32, @intCast(diff * 8));
            bit_count &= 31;
            ip = iend - 4;
        }
        bit_stream = le32At(src, ip) >> @intCast(bit_count & 31);
    }

    if (remaining != 1) return error.Corruption; // FDBG5
    if (charnum > max_sv1) return error.MaxSymbolValueTooSmall; // FDBG6
    if (bit_count > 32) return error.Corruption; // FDBG7

    max_sv_ptr.* = charnum - 1;
    ip += (bit_count + 7) >> 3;
    if (ip > iend) return error.Corruption; // FDBG8
    return ip;
}
