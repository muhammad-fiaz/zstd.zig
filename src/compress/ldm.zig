pub const LdmParams = struct { hash_log: u8 = 20, min_match: u32 = 64, bucket_log: u8 = 3, hash_rate_log: u8 = 0 };
pub fn enableLdm(enable: bool) bool {
    return enable;
}
