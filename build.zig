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

    const test_step = b.step("test", "Run all tests");
    const tests = b.addTest(.{
        .root_module = zstd_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    const test_files = [_]struct { name: []const u8, file: []const u8 }{
        .{ .name = "integration", .file = "tests/integration.zig" },
        .{ .name = "common", .file = "tests/common.zig" },
        .{ .name = "frame", .file = "tests/frame.zig" },
        .{ .name = "fse", .file = "tests/fse.zig" },
        .{ .name = "huffman", .file = "tests/huffman.zig" },
        .{ .name = "compress", .file = "tests/compress.zig" },
        .{ .name = "decompress", .file = "tests/decompress.zig" },
        .{ .name = "streaming", .file = "tests/streaming.zig" },
        .{ .name = "dictionary", .file = "tests/dictionary.zig" },
        .{ .name = "legacy", .file = "tests/legacy.zig" },
    };

    const internal_mod = b.createModule(.{
        .root_source_file = b.path("src/internal.zig"),
        .target = target,
        .optimize = optimize,
    });

    inline for (test_files) |tf| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(tf.file),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zstd", .module = zstd_mod },
                .{ .name = "internal", .module = internal_mod },
            },
        });
        const tf_test = b.addTest(.{
            .root_module = test_mod,
        });
        const tf_run = b.addRunArtifact(tf_test);
        test_step.dependOn(&tf_run.step);
    }

    const docs_step = b.step("docs", "Generate documentation");
    const docs = b.addTest(.{
        .root_module = zstd_mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_docs.step);

    const examples = [_]struct { name: []const u8, file: []const u8 }{
        .{ .name = "basic_compression", .file = "examples/basic_compression.zig" },
        .{ .name = "basic_decompression", .file = "examples/basic_decompression.zig" },
        .{ .name = "custom_level", .file = "examples/custom_level.zig" },
        .{ .name = "advanced_params", .file = "examples/advanced_params.zig" },
        .{ .name = "dictionary_compression", .file = "examples/dictionary_compression.zig" },
        .{ .name = "dictionary_training", .file = "examples/dictionary_training.zig" },
        .{ .name = "streaming_compression", .file = "examples/streaming_compression.zig" },
        .{ .name = "streaming_decompression", .file = "examples/streaming_decompression.zig" },
        .{ .name = "custom_allocator", .file = "examples/custom_allocator.zig" },
        .{ .name = "error_handling", .file = "examples/error_handling.zig" },
        .{ .name = "legacy_decompression", .file = "examples/legacy_decompression.zig" },
        .{ .name = "file_compression", .file = "examples/file_compression.zig" },
    };

    const run_all = b.step("run-all-examples", "Run all examples");

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

        const run_exe = b.addRunArtifact(exe);
        run_step.dependOn(&run_exe.step);
        run_all.dependOn(&run_exe.step);
        run_exe.step.dependOn(&lib.step);
    }
}
