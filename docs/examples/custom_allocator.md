---
title: Custom Allocator
description: TrackingAllocator usage and leak checking.
---

# Custom Allocator

`examples/custom_allocator.zig` — `TrackingAllocator` with `zstd`.

## Client Code

```zig
const TrackingAllocator = struct {
    parent: std.mem.Allocator,
    allocated: usize = 0,
    allocs: usize = 0,
    frees: usize = 0,
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 { /* ... */ }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void { /* ... */ }
    fn allocator(self: *TrackingAllocator) std.mem.Allocator { return .{ .ptr = self, .vtable = &.{ .alloc=alloc, .resize=resize, .remap=remap, .free=free } }; }
};
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var tracking = TrackingAllocator{ .parent = gpa.allocator() };
    const allocator = tracking.allocator();
    const data = "Custom allocator example: tracking allocations during compression." ** 5;
    {
        const c = try zstd.compress(allocator, data);
        defer allocator.free(c);
        std.debug.print("Compressed {d} -> {d} bytes with tracking allocator: {d} allocs, {d} bytes net (live)\n", .{ data.len, c.len, tracking.allocs, tracking.allocated });
        const d = try zstd.decompress(allocator, c);
        defer allocator.free(d);
        std.debug.assert(std.mem.eql(u8, data, d));
        std.debug.print("Decompressed {d} bytes, verified\n", .{d.len});
    }
    std.debug.print("After free: {d} allocs, {d} frees, {d} bytes net (balanced)\n", .{ tracking.allocs, tracking.frees, tracking.allocated });
    std.debug.assert(tracking.allocated == 0);
    std.debug.assert(tracking.allocs == tracking.frees);
}
```

## Output

```text
Compressed 330 -> 340 bytes with tracking allocator: 1 allocs, 340 bytes net (live)
Decompressed 330 bytes, verified
After free: 2 allocs, 2 frees, 0 bytes net (balanced)
```

## Explanation

- All public APIs (`compress`, `decompress`, `Streaming*`, `Dictionary`) are `allocator`-aware and propagate `error.OutOfMemory`.
- `TrackingAllocator` demonstrates `rawAlloc`/`rawFree`/`rawResize`/`rawRemap` accounting; `zstd` never leaks — `allocated` returns to 0 after `free`.

Run:

```bash
zig build run-custom_allocator
```
