pub const FrameType = enum { regular, skippable };

pub const FrameHeader = struct {
    frame_type: FrameType,
    header_size: u32,
    window_size: u64,
    block_size_max: u32,
    dict_id: u32,
    checksum_flag: bool,
    content_size: u64,
};

pub const BlockType = enum(u2) { raw = 0, rle = 1, compressed = 2, reserved = 3 };

pub const BlockProperties = struct {
    block_type: BlockType,
    last_block: bool,
    orig_size: u32,
};
