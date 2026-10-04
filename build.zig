const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zstd_mod = b.addModule("zstd", .{
        .root_source_file = b.path("src/zstd.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });

    const lib = b.addLibrary(.{
        .name = "zstd",
        .root_module = zstd_mod,
    });

    b.installArtifact(lib);

    // `zig build test` - unit tests for the whole library. The root is
    // `src/zstd.zig`, which references every module, so a file nothing imports
    // cannot silently drop its tests out of the run.
    const test_step = b.step("test", "Run all tests");
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/zstd.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    // `zig build check` - compile tests, examples, and the standalone test
    // programs without running them. Useful for cross-compilation targets
    // that cannot execute here.
    const check_step = b.step("check", "Compile tests and examples without running");
    check_step.dependOn(&tests.step);

    // `zig build docs` - emit autodocs into zig-out/docs.
    const docs_step = b.step("docs", "Generate documentation");
    const docs = b.addTest(.{ .root_module = test_mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_docs.step);

    const examples = [_]struct { name: []const u8, file: []const u8 }{
        .{ .name = "basic_compression", .file = "examples/basic_compression.zig" },
        .{ .name = "custom_level", .file = "examples/custom_level.zig" },
        .{ .name = "advanced_params", .file = "examples/advanced_params.zig" },
        .{ .name = "dictionary_compression", .file = "examples/dictionary_compression.zig" },
        .{ .name = "dictionary_training", .file = "examples/dictionary_training.zig" },
        .{ .name = "streaming_compression", .file = "examples/streaming_compression.zig" },
        .{ .name = "streaming_decompression", .file = "examples/streaming_decompression.zig" },
        .{ .name = "custom_allocator", .file = "examples/custom_allocator.zig" },
        .{ .name = "error_handling", .file = "examples/error_handling.zig" },
        .{ .name = "legacy_decompression", .file = "examples/legacy_decompression.zig" },
        .{ .name = "compression_bound", .file = "examples/compression_bound.zig" },
        .{ .name = "frame_iteration", .file = "examples/frame_iteration.zig" },
        .{ .name = "prepared_dictionary", .file = "examples/prepared_dictionary.zig" },
        .{ .name = "window_limit", .file = "examples/window_limit.zig" },
        .{ .name = "file_compression", .file = "examples/file_compression.zig" },
        .{ .name = "large_file_compression", .file = "examples/large_file_compression.zig" },
        .{ .name = "custom_strategy", .file = "examples/custom_strategy.zig" },
        .{ .name = "long_distance_matching", .file = "examples/long_distance_matching.zig" },
        .{ .name = "parallel_compression", .file = "examples/parallel_compression.zig" },
    };

    const examples_step = b.step("examples", "Build all examples");
    const run_all = b.step("run-all-examples", "Run all examples");

    // The differential harness against a reference binary lives in the test
    // root: `zig build test` runs the self round trips always, and the two
    // reference directions when ZSTD_REFERENCE_PATH names a reference binary.

    inline for (examples) |example| {
        const run_step = b.step(
            "run-" ++ example.name,
            "Run " ++ example.name ++ " example",
        );

        const exe = b.addExecutable(.{
            .name = "example-" ++ example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zstd", .module = zstd_mod },
                },
            }),
        });

        examples_step.dependOn(&exe.step);
        check_step.dependOn(&exe.step);

        const run_exe = b.addRunArtifact(exe);
        run_step.dependOn(&run_exe.step);
        run_all.dependOn(&run_exe.step);
        run_exe.step.dependOn(&lib.step);
    }
}
