---
title: Custom Allocator
description: TrackingAllocator usage and leak checking.
---

# Custom Allocator

`examples/custom_allocator.zig` - `TrackingAllocator` with `zstd`.

## Client Code

```zig
const std = @import("std");
const zstd = @import("zstd");

const TrackingAllocator = struct {
    parent: std.mem.Allocator,
    allocated: usize = 0,
    allocs: usize = 0,
    frees: usize = 0,

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocated += len;
        self.allocs += 1;
        return ptr;
    }
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.parent.rawResize(buf, alignment, new_len, ret_addr);
        if (ok) {
            if (new_len > buf.len) self.allocated += new_len - buf.len else self.allocated -= buf.len - new_len;
        }
        return ok;
    }
    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const old_len = buf.len;
        const new_ptr = self.parent.rawRemap(buf, alignment, new_len, ret_addr) orelse return null;
        if (new_ptr != buf.ptr) {
            self.allocs += 1;
            self.frees += 1;
            self.allocated += new_len;
            self.allocated -= old_len;
        } else {
            if (new_len > old_len) self.allocated += new_len - old_len else self.allocated -= old_len - new_len;
        }
        return new_ptr;
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.allocated -= buf.len;
        self.frees += 1;
        self.parent.rawFree(buf, alignment, ret_addr);
    }
    fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var tracking = TrackingAllocator{ .parent = gpa.allocator() };
    const allocator = tracking.allocator();

    // One client allocator flows into one reusable context, which performs
    // many operations without ever creating its own allocator.
    var ctx = zstd.Context.init(allocator);
    defer ctx.deinit();

    {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(allocator);
        for (0..5) |_| try data.appendSlice(allocator, "Custom allocator example: tracking allocations during compression.");

        const c = try ctx.compress(data.items);
        defer allocator.free(c);
        std.debug.print("Compressed {d} -> {d} bytes with tracking allocator: {d} allocs, {d} bytes net (live)\n", .{ data.items.len, c.len, tracking.allocs, tracking.allocated });
        const d = try ctx.decompress(c);
        defer allocator.free(d);
        std.debug.assert(std.mem.eql(u8, data.items, d));
        std.debug.print("Decompressed {d} bytes, verified\n", .{d.len});

        // A second round through the SAME context and allocator proves reuse.
        const c2 = try ctx.compress("second payload through the same context");
        defer allocator.free(c2);
        const d2 = try ctx.decompress(c2);
        defer allocator.free(d2);
        std.debug.assert(std.mem.eql(u8, "second payload through the same context", d2));
    }

    std.debug.print("After free: {d} allocs, {d} frees, {d} bytes net (balanced)\n", .{ tracking.allocs, tracking.frees, tracking.allocated });
    std.debug.assert(tracking.allocated == 0);
    std.debug.assert(tracking.allocs == tracking.frees);
}
```

## Output

```text
Compressed 330 -> 77 bytes with tracking allocator: 10 allocs, 601 bytes net (live)
Decompressed 330 bytes, verified
After free: 24 allocs, 24 frees, 0 bytes net (balanced)
```

## Explanation

- All public APIs (`compress`, `decompress`, `Streaming*`, `Dictionary`) are `allocator`-aware and propagate `error.OutOfMemory`.
- `TrackingAllocator` demonstrates `rawAlloc`/`rawFree`/`rawResize`/`rawRemap` accounting; `zstd` never leaks - `allocated` returns to 0 after `free`.

Run:

```bash
zig build run-custom_allocator
```
