pub const LdmParams = struct { hash_log: u8 = 20, min_match: u32 = 64, bucket_log: u8 = 3, hash_rate_log: u8 = 0 };
pub fn enableLdm(enable: bool) bool {
    return enable;
}

const testing = @import("std").testing;

test "ldm defaults" {
    const p = LdmParams{};
    try testing.expectEqual(@as(u8, 20), p.hash_log);
    try testing.expectEqual(@as(u32, 64), p.min_match);
}

test "ldm enable" {
    try testing.expect(enableLdm(true));
    try testing.expect(!enableLdm(false));
}
