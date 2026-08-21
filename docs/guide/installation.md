---
title: Installation
description: How to install and set up zstd.zig in your Zig project.
---

# Installation

## Requirements

- **Zig 0.16.0** — download from [ziglang.org](https://ziglang.org/download/)
- No external dependencies required

## Setup

### 1. Add to build.zig.zon

Add zstd.zig as a dependency in your `build.zig.zon`:

```zig
.{
    .name = .your_project,
    .version = "0.1.0",
    .dependencies = .{
        .zstd = .{
            .url = "https://github.com/muhammad-fiaz/zstd.zig/archive/refs/heads/dev.tar.gz",
            .hash = "...",  // zig will tell you the correct hash
        },
    },
    // ...
}
```

### 2. Import in build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zstd = b.dependency("zstd", .{});
    exe.root_module.addImport("zstd", zstd.module("zstd"));

    b.installArtifact(exe);
}
```

### 3. Use in your code

```zig
const zstd = @import("zstd");

// You're ready to go!
const compressed = try zstd.compress(allocator, data, .{});
```

## Verify Installation

Run `zig build` to fetch the dependency and compile. If it succeeds, zstd.zig is properly installed.
