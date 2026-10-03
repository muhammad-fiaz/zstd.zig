//! Compile-time CPU feature queries for optional fast paths. Zig 0.17 exposes
//! architecture grouping through `builtin.cpu.arch.family()`; the older
//! `isARM()`/`isAARCH64()` helpers are gone. Queries go through
//! `cpu.has(family, feature)` so one call site covers every variant, including
//! the big-endian and thumb twins of a family.

const std = @import("std");
const builtin = @import("builtin");

/// Bit indices used by `getCpuFeatures`. Kept stable so callers may cache
/// the value across the lifetime of a context.
pub const Feature = struct {
    pub const bmi2: u6 = 0;
    pub const sse4_2: u6 = 1;
    pub const avx2: u6 = 2;
    pub const crc: u6 = 3;
    pub const neon: u6 = 4;
};

/// True when the target CPU model guarantees BMI2 support.
pub fn supportsBmi2() bool {
    const cpu = builtin.cpu;
    return cpu.arch == .x86_64 and cpu.has(.x86, .bmi2);
}

/// True when the target has a hardware CRC32 instruction, which the
/// dictionary and frame checksum paths can exploit.
pub fn supportsCrc32() bool {
    const cpu = builtin.cpu;
    return switch (cpu.arch.family()) {
        .aarch64 => cpu.has(.aarch64, .crc),
        .x86 => cpu.has(.x86, .sse4_2),
        else => false,
    };
}

/// Bitset of architecture features relevant to this library.
pub fn getCpuFeatures() u64 {
    const cpu = builtin.cpu;
    var bits: u64 = 0;
    switch (cpu.arch.family()) {
        .x86 => {
            if (cpu.has(.x86, .bmi2)) bits |= 1 << Feature.bmi2;
            if (cpu.has(.x86, .sse4_2)) bits |= 1 << Feature.sse4_2;
            if (cpu.has(.x86, .avx2)) bits |= 1 << Feature.avx2;
        },
        .aarch64 => {
            if (cpu.has(.aarch64, .crc)) bits |= 1 << Feature.crc;
            if (cpu.has(.aarch64, .neon)) bits |= 1 << Feature.neon;
        },
        .arm => {
            if (cpu.has(.arm, .neon)) bits |= 1 << Feature.neon;
        },
        else => {},
    }
    return bits;
}

/// True when the architecture is one where a 64-bit load is cheap and the
/// byte order is explicitly little-endian. All Zstandard streams are
/// little-endian, so this gates the unaligned-load fast paths.
pub fn isLittleEndian() bool {
    return builtin.cpu.arch.endian() == .little;
}

// Tests

const testing = std.testing;

test "cpu features are queryable on every target" {
    // The exact bits are target dependent; only the invariants are asserted.
    const bmi2 = supportsBmi2();
    const crc = supportsCrc32();
    const bits = getCpuFeatures();
    _ = crc;
    if (bmi2) try testing.expect(bits & (1 << Feature.bmi2) != 0);
    if (bits & (1 << Feature.bmi2) != 0) try testing.expect(bmi2);
}

test "little endian check agrees with target" {
    try testing.expectEqual(
        builtin.cpu.arch.endian() == .little,
        isLittleEndian(),
    );
}
