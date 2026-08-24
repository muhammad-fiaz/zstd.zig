//! Compile-time CPU feature queries for optional fast paths.

const builtin = @import("builtin");

/// True when the target CPU model guarantees BMI2 support.
pub fn supportsBmi2() bool {
    return builtin.cpu.arch == .x86_64 and builtin.cpu.has(.x86, .bmi2);
}

/// Bitset of architecture features relevant to this library.
pub fn getCpuFeatures() u64 {
    var bits: u64 = 0;
    if (builtin.cpu.arch == .x86_64) {
        if (builtin.cpu.has(.x86, .bmi2)) bits |= 1 << 0;
        if (builtin.cpu.has(.x86, .sse4_2)) bits |= 1 << 1;
        if (builtin.cpu.has(.x86, .avx2)) bits |= 1 << 2;
    } else if (builtin.cpu.arch.isARM() or builtin.cpu.arch.isAARCH64()) {
        if (builtin.cpu.has(.aarch64, .crc)) bits |= 1 << 3;
    }
    return bits;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = @import("std").testing;

test "cpu functions" {
    const _bmi2 = supportsBmi2();
    const _features = getCpuFeatures();
    _ = _bmi2;
    _ = _features;
}
