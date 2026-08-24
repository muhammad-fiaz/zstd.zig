//! FSE decoding: compact normalized-counter headers, decoding tables, and
//! two-state symbol streaming.

const std = @import("std");
const errors = @import("../common/errors.zig");
const constants = @import("../common/constants.zig");
const ncount_mod = @import("ncount.zig");
const dtable_mod = @import("dtable.zig");
const bitstream_mod = @import("../common/bitstream.zig");

pub const readNCount = ncount_mod.readNCount;
pub const DTable = dtable_mod.DTable;
pub const Entry = dtable_mod.Entry;
pub const buildDTable = dtable_mod.build;
pub const buildRleDTable = dtable_mod.buildRle;

/// Two-state FSE decoder over a reverse bitstream.
pub const Decoder = struct {
    table: DTable,
    s1: u16,
    s2: u16,
    ds: bitstream_mod.BIT_DStream,

    /// Reads the compact normalized-counter header from `src`, builds the
    /// decoding table, initializes both states, and binds the remainder of
    /// `src` as the symbol bitstream. Returns bytes consumed by the header.
    pub fn initFromHeader(allocator: std.mem.Allocator, src: []const u8, max_symbol_hint: usize, max_log: u8) errors.ZstdError!struct { dec: Decoder, header_bytes: usize } {
        var norm: [256]i16 = undefined;
        var max_sv: usize = max_symbol_hint;
        var tl: u8 = 0;
        const hdr = try readNCount(&norm, &max_sv, &tl, src);
        if (tl > max_log) return error.TableLogTooLarge;
        const dec = try init(allocator, norm[0 .. max_sv + 1], max_sv, tl, src[hdr..]);
        return .{ .dec = dec, .header_bytes = hdr };
    }

    pub fn init(allocator: std.mem.Allocator, norm: []const i16, max_symbol: usize, table_log: u8, src: []const u8) errors.ZstdError!Decoder {
        var table = try dtable_mod.build(allocator, norm, max_symbol, table_log);
        errdefer table.deinit();
        var ds = bitstream_mod.BIT_DStream.init(src) catch return error.Corruption;
        const s1: u16 = @intCast(ds.readBits(table.log));
        const s2: u16 = @intCast(ds.readBits(table.log));
        return .{ .table = table, .s1 = s1, .s2 = s2, .ds = ds };
    }

    pub fn deinit(self: *Decoder) void {
        self.table.deinit();
    }

    fn step(self: *Decoder, state: *u16) u8 {
        const e = self.table.entries[state.*];
        const low = self.ds.readBits(e.nb_bits);
        state.* = e.new_state +% @as(u16, @truncate(low));
        return @truncate(e.symbol);
    }

    /// Decode exactly `out.len` symbols (two interleaved states).
    pub fn decode(self: *Decoder, out: []u8) errors.ZstdError!void {
        var i: usize = 0;
        while (i + 4 <= out.len) : (i += 4) {
            _ = self.ds.reload();
            out[i] = self.step(&self.s1);
            out[i + 1] = self.step(&self.s2);
            out[i + 2] = self.step(&self.s1);
            out[i + 3] = self.step(&self.s2);
        }
        while (i < out.len) : (i += 1) {
            _ = self.ds.reload();
            out[i] = if (i % 2 == 0) self.step(&self.s1) else self.step(&self.s2);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = @import("std").testing;

test "decoder reproduces encoder output" {
    // Encode symbols through the CTable, then decode and compare.
    const ctable_mod = @import("ctable.zig");
    const alloc = testing.allocator;

    const norm = [_]i16{ 12, 10, 6, 4 };
    var ct = try ctable_mod.buildCTable(alloc, &norm, norm.len - 1, 5);
    defer ct.deinit(alloc);

    var buf: [64]u8 = undefined;
    var bc = try bitstream_mod.BIT_CStream.init(&buf);
    var st1: ctable_mod.CState = .{};
    var st2: ctable_mod.CState = .{};
    // Two-state encoding: initialize from the last two symbols, walk the rest
    // backwards alternating states, then flush state2 followed by state1 —
    // the exact mirror of this module's decoder.
    st1.initState(&ct, 2);
    st2.initState(&ct, 1);
    st1.encodeSymbol(&ct, &bc, 0);
    st2.flushState(&bc);
    st1.flushState(&bc);
    const n = try bc.close();

    var dec = try Decoder.init(alloc, &norm, norm.len - 1, 5, buf[0..n]);
    defer dec.deinit();
    var out: [3]u8 = undefined;
    try dec.decode(&out);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2 }, &out);
}
