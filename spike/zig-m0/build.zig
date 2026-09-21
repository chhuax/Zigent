const std = @import("std");

// M0 spike 构建脚本。
//
// ⚠️ 版本敏感：Zig 0.15 起 `addExecutable` 用 `root_module`；0.13/0.14 用
// `root_source_file` / `target` / `optimize` 平铺字段。0.17 的 build system 又
// 有一轮重写（约 3 万行 PR）。所以：
//   - 先跑 `zig build --help` 看当前版本接受哪种形式；
//   - 若报 `no field named 'root_module'`，把下面两处切到注释里的旧写法。
//
// 这也是 spike E1 要回答的问题之一：build API 的迁移成本有多大。

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zig-m0",
        .root_module = mod,
        // 旧写法（0.13/0.14）：
        //   .root_source_file = b.path("src/main.zig"),
        //   .target = target,
        //   .optimize = optimize,
    });
    b.installArtifact(exe);

    // zig build run -- e2
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the M0 spike probes");
    run_step.dependOn(&run_cmd.step);

    // zig build test
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run the contract tests (no network)");
    test_step.dependOn(&run_tests.step);

    // zig build test-tsan —— E1 的数据竞争探针（需要编译器支持 -fsanitize-thread）
    const tsan_mod = b.createModule(.{
        .root_source_file = b.path("src/e1_io.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = true,
    });
    const tsan_tests = b.addTest(.{ .root_module = tsan_mod });
    const run_tsan = b.addRunArtifact(tsan_tests);
    const tsan_step = b.step("test-tsan", "E1 race probe under ThreadSanitizer");
    tsan_step.dependOn(&run_tsan.step);
}
