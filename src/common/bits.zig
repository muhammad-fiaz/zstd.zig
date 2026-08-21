pub fn highbit32(val: u32) u32 {
    return 31 - @clz(val);
}

pub fn countTrailingZeros32(val: u32) u32 {
    return @ctz(val);
}

pub fn countLeadingZeros32(val: u32) u32 {
    return @clz(val);
}

pub fn nbCommonBytes(val: usize) u32 {
    if (val == 0) return @sizeOf(usize);
    if (@import("builtin").target.cpu.arch.endian() == .little) {
        if (@sizeOf(usize) == 8) {
            return @as(u32, @ctz(@as(u64, val))) >> 3;
        } else {
            return @as(u32, @ctz(@as(u32, @truncate(val)))) >> 3;
        }
    } else {
        if (@sizeOf(usize) == 8) {
            return @as(u32, @clz(@as(u64, val))) >> 3;
        } else {
            return @as(u32, @clz(@as(u32, @truncate(val)))) >> 3;
        }
    }
}

pub fn rotateRightU32(val: u32, count: u32) u32 {
    return (val >> @truncate(count & 0x1F)) | (val << @truncate((@as(u32, 0) -% count) & 0x1F));
}

pub fn rotateRightU64(val: u64, count: u32) u64 {
    return (val >> @truncate(count & 0x3F)) | (val << @truncate((@as(u32, 0) -% count) & 0x3F));
}
