pub const magic_number: u32 = 0xFD2FB528;
pub const magic_dictionary: u32 = 0xEC30A437;
pub const magic_skippable_start: u32 = 0x184D2A50;
pub const magic_skippable_mask: u32 = 0xFFFFFFF0;
pub const block_size_log_max: u5 = 17;
pub const block_size_max: usize = 1 << block_size_log_max;
pub const window_log_absolutemin: u8 = 10;
pub const window_log_min: u8 = 10;
pub const window_log_max: u8 = if (@sizeOf(usize) == 4) 30 else 31;
pub const window_log_limit_default: u8 = 27;
pub const hash_log_min: u8 = 6;
pub const hash_log_max: u8 = 30;
pub const chain_log_min: u8 = 6;
pub const chain_log_max: u8 = 30;
pub const search_log_min: u8 = 1;
pub const search_log_max: u8 = 30;
pub const min_match_min: u8 = 3;
pub const min_match_max: u8 = 7;
pub const target_length_min: usize = 0;
pub const target_length_max: usize = 131072;
pub const strategy_min: u8 = 1;
pub const strategy_max: u8 = 9;
pub const c_level_default: i32 = 3;
pub const c_level_min: i32 = -131072;
pub const c_level_max: i32 = 22;
pub const frame_header_size_min: usize = 5;
pub const frame_header_size_max: usize = 18;
pub const skippable_header_size: usize = 8;
pub const block_header_size: usize = 3;
pub const frame_checksum_size: usize = 4;
pub const min_sequences_size: usize = 1;
pub const max_input_size: usize = if (@sizeOf(usize) == 8) 0xFF00FF00FF00FF00 else 0xFF00FF00;
pub const contentsize_unknown: u64 = 0xFFFFFFFFFFFFFFFF - 1;
pub const contentsize_error: u64 = 0xFFFFFFFFFFFFFFFF - 2;
pub const rep_num: usize = 3;
pub const rep_start_value = [3]u32{ 1, 4, 8 };
pub const min_match: usize = 3;
pub const litbits: u8 = 8;
pub const lit_huf_log: u8 = 11;
pub const max_lit: usize = 255;
pub const max_ll: usize = 35;
pub const max_ml: usize = 52;
pub const max_off: usize = 31;
pub const default_max_off: usize = 28;
pub const ml_fse_log: u8 = 9;
pub const ll_fse_log: u8 = 9;
pub const off_fse_log: u8 = 8;
pub const max_fse_log: u8 = 9;
pub const max_ll_bits: u8 = 16;
pub const max_ml_bits: u8 = 16;
pub const long_nb_seq: usize = 0x7F00;

pub const ll_bits = [36]u8{
    0,  0,  0,  0,  0, 0,  0,  0,
    0,  0,  0,  0,  0, 0,  0,  0,
    1,  1,  1,  1,  2, 2,  3,  3,
    4,  6,  7,  8,  9, 10, 11, 12,
    13, 14, 15, 16,
};
pub const ll_default_norm = [36]i16{
    4,  3,  2,  2,  2, 2, 2, 2,
    2,  2,  2,  2,  2, 1, 1, 1,
    2,  2,  2,  2,  2, 2, 2, 2,
    2,  3,  2,  1,  1, 1, 1, 1,
    -1, -1, -1, -1,
};
pub const ll_default_norm_log: u32 = 6;
pub const ml_bits = [53]u8{
    0,  0,  0,  0,  0,  0, 0,  0,
    0,  0,  0,  0,  0,  0, 0,  0,
    0,  0,  0,  0,  0,  0, 0,  0,
    0,  0,  0,  0,  0,  0, 0,  0,
    1,  1,  1,  1,  2,  2, 3,  3,
    4,  4,  5,  7,  8,  9, 10, 11,
    12, 13, 14, 15, 16,
};
pub const ml_default_norm = [53]i16{
    1,  4,  3,  2,  2,  2, 2,  2,
    2,  1,  1,  1,  1,  1, 1,  1,
    1,  1,  1,  1,  1,  1, 1,  1,
    1,  1,  1,  1,  1,  1, 1,  1,
    1,  1,  1,  1,  1,  1, 1,  1,
    1,  1,  1,  1,  1,  1, -1, -1,
    -1, -1, -1, -1, -1,
};
pub const ml_default_norm_log: u32 = 6;
pub const of_default_norm = [29]i16{
    1,  1,  1,  1,  1,  1, 2, 2,
    2,  1,  1,  1,  1,  1, 1, 1,
    1,  1,  1,  1,  1,  1, 1, 1,
    -1, -1, -1, -1, -1,
};
pub const of_default_norm_log: u32 = 5;

pub const fcs_field_size = [4]usize{ 0, 2, 4, 8 };
pub const did_field_size = [4]usize{ 0, 1, 2, 4 };

pub const Strategy = enum(u8) {
    fast = 1,
    dfast = 2,
    greedy = 3,
    lazy = 4,
    lazy2 = 5,
    btlazy2 = 6,
    btopt = 7,
    btultra = 8,
    btultra2 = 9,
};

pub fn compressBound(src_size: usize) usize {
    if (src_size >= max_input_size) return 0;
    var bound = src_size + (src_size >> 8);
    if (src_size < (128 << 10)) {
        bound += ((128 << 10) - src_size) >> 11;
    }
    return bound;
}
