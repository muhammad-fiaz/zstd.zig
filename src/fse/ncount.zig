//! Reads an FSE normalized-counter header in compact format: a 4-bit
//! tableLog field followed by interleaved count values with run-length
//! coding for repeated zeros.
const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const bits = @import("../common/bits.zig");
const testing = std.testing;
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
        std.mem.copyForwards(u8, buf[0..src.len], src);
        var maxSv = max_sv_ptr.*;
        var tl: u8 = 0;
        const n = try readBody(normalized, &maxSv, &tl, &buf);
        if (n > src.len) return error.Corruption; // FDBG2
        max_sv_ptr.* = maxSv;
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
    var bitStream: u32 = bits.readLe32(src[0..]);
    const tl: u8 = @intCast((bitStream & 0xF) + constants.min_fse_log);
    if (tl > constants.max_fse_log or tl < constants.min_fse_log) return error.TableLogTooLarge; // FDBG4
    table_log_ptr.* = tl;
    bitStream >>= 4;
    var bitCount: u32 = 4;

    var remaining: i32 = (@as(i32, 1) << @intCast(tl)) + 1;
    var threshold: i32 = @as(i32, 1) << @intCast(tl);
    var nbBits: u32 = @as(u32, tl) + 1;

    var charNum: usize = 0;
    var previous0: bool = false;
    const maxSv1 = max_sv_ptr.* + 1;

    while (true) {
        if (previous0) {
            // Runs of repeated zero counts encoded as consecutive 0b11 pairs.
            var repeats: u32 = @ctz(~bitStream | 0x80000000) >> 1;
            while (repeats >= 12) {
                charNum += 3 * 12;
                if (charNum >= maxSv1) break;
                if (ip <= iend - 7) {
                    ip += 3;
                } else {
                    const diff = iend - 4 - ip;
                    bitCount -%= @as(u32, @intCast(diff * 8));
                    bitCount &= 31;
                    ip = iend - 4;
                }
                bitStream = bits.readLe32(src[ip..]) >> @intCast(bitCount & 31);
                repeats = @ctz(~bitStream | 0x80000000) >> 1;
            }
            charNum += 3 * repeats;
            bitStream >>= @intCast(2 * repeats);
            bitCount += 2 * repeats;

            charNum += bitStream & 3; // final partial repeat
            bitCount += 2;

            if (charNum >= maxSv1) break;
            // zero counts stay implicit (buffer pre-zeroed)

            if (ip <= iend - 7 or ip + (bitCount >> 3) <= iend - 4) {
                ip += bitCount >> 3;
                bitCount &= 7;
            } else {
                const diff = iend - 4 - ip;
                bitCount -%= @as(u32, @intCast(diff * 8));
                bitCount &= 31;
                ip = iend - 4;
            }
            bitStream = bits.readLe32(src[ip..]) >> @intCast(bitCount & 31);
        }

        const max_val: i32 = (2 * threshold - 1) - remaining;
        var count: i32 = 0;
        // `max_val` goes negative once `remaining` outgrows the range the
        // current threshold can express; the comparison is against its
        // two's-complement bit pattern, which makes every such case take the
        // wide branch below.
        const max_val_bits: u32 = @bitCast(max_val);
        if ((bitStream & @as(u32, @intCast(threshold - 1))) < max_val_bits) {
            count = @intCast(bitStream & @as(u32, @intCast(threshold - 1)));
            bitCount += nbBits - 1;
        } else {
            count = @intCast(bitStream & @as(u32, @intCast(2 * threshold - 1)));
            if (count >= threshold) count -= max_val;
            bitCount += nbBits;
        }

        count -= 1; // extra accuracy: -1 encodes "less than one", 0 encodes "zero"
        // Both a real count and the -1 "less than one" marker consume one unit
        // of the table, so the absolute value is what shrinks `remaining`.
        remaining -= if (count < 0) -count else count;
        if (charNum < normalized.len) normalized[charNum] = @intCast(count);
        charNum += 1;
        previous0 = count == 0;

        if (remaining < threshold) {
            if (remaining <= 1) break;
            nbBits = @as(u32, 31 - @clz(@as(u32, @intCast(remaining)))) + 1;
            threshold = @as(i32, 1) << @intCast(nbBits - 1);
        }
        if (charNum >= maxSv1) break;

        if (ip <= iend - 7 or ip + (bitCount >> 3) <= iend - 4) {
            ip += bitCount >> 3;
            bitCount &= 7;
        } else {
            const diff = iend - 4 - ip;
            bitCount -%= @as(u32, @intCast(diff * 8));
            bitCount &= 31;
            ip = iend - 4;
        }
        bitStream = bits.readLe32(src[ip..]) >> @intCast(bitCount & 31);
    }

    if (remaining != 1) return error.Corruption; // FDBG5
    if (charNum > maxSv1) return error.MaxSymbolValueTooSmall; // FDBG6
    if (bitCount > 32) return error.Corruption; // FDBG7

    max_sv_ptr.* = charNum - 1;
    ip += (bitCount + 7) >> 3;
    if (ip > iend) return error.Corruption; // FDBG8
    return ip;
}
test "readNCount accepts a header the encoder wrote" {
    // Regression: a header whose counts reached the "less than one" marker drove
    // `remaining` the wrong way, so counts no longer summed to `1 << tableLog`
    // and every block using them was rejected. This covers the -1 marker, the
    // zero runs and the short-buffer path at once.
    const fse_w = @import("compress.zig");
    var written_norm: [64]i16 = @splat(0);
    // A wide, uneven distribution: heavy symbols, a rare one marked "less than one",
    // and one the alphabet cannot produce at all, summing to `1 << table_log`.
    written_norm[0] = 1;
    written_norm[1] = 1;
    written_norm[2] = 1;
    written_norm[3] = 16;
    written_norm[4] = 8;
    written_norm[5] = 4;
    written_norm[6] = -1;
    const max_sv = 6;
    const table_log: u8 = 5;
    var header: [64]u8 = undefined;
    const used = try fse_w.writeNCount(&header, written_norm[0 .. max_sv + 1], max_sv, table_log);
    try testing.expect(used > 0);

    var norm: [64]i16 = undefined;
    var max_read: usize = max_sv;
    var log_read: u8 = 0;
    const read = try readNCount(&norm, &max_read, &log_read, header[0..used]);
    try testing.expectEqual(used, read);
    try testing.expectEqual(table_log, log_read);
    try testing.expectEqual(max_sv, max_read);
    for (written_norm[0 .. max_sv + 1], 0..) |c, i| try testing.expectEqual(c, norm[i]);
}
test "readNCount either rejects a header or returns a table that adds up" {
    // Property: whatever the reader accepts must describe a table the builder
    // can turn into a decoding table, i.e. the counts must sum to exactly
    // `1 << tableLog`. Anything else has to be an error, never a table that
    // silently fails later.
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const random = prng.random();
    var trial: usize = 0;
    while (trial < 512) : (trial += 1) {
        var header: [16]u8 = undefined;
        random.bytes(&header);
        var norm: [64]i16 = undefined;
        var max_sv: usize = 63;
        var table_log: u8 = 0;
        const result = readNCount(&norm, &max_sv, &table_log, &header);
        if (result) |used| {
            try testing.expect(used >= 1 and used <= header.len);
            try testing.expect(table_log >= constants.min_fse_log);
            try testing.expect(table_log <= constants.max_fse_log);
            try testing.expect(max_sv < 64);
            var total: i32 = 0;
            for (norm[0 .. max_sv + 1]) |c| {
                try testing.expect(c >= -1);
                total += if (c < 0) 1 else c;
            }
            try testing.expectEqual(@as(i32, 1) << @intCast(table_log), total);
        } else |_| {}
    }
}
