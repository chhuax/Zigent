//! Zigent 构建图 —— **依赖方向在这里被强制，越界即编译失败**。
//!
//! 三条铁律（过去只能靠文档与评审维持，现在是编译器的事）：
//!   1. `common/` 零内部依赖      —— 它一旦依赖谁，所有模块被迫拖上谁
//!   2. `tools/` 绝不 import `engine/` —— 工具只通过 ToolExecutionContext 取运行时状态
//!   3. `engine/` 绝不 import `cli/`   —— 否则内核无法被 headless / ACP / Web 嵌入
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── 模块表：一层一个 createModule，依赖在下方显式声明 ──
    const util = mk(b, target, optimize, "util");
    const common = mk(b, target, optimize, "common");
    const llm = mk(b, target, optimize, "llm");
    const config = mk(b, target, optimize, "config");
    const perm = mk(b, target, optimize, "perm");
    const tools = mk(b, target, optimize, "tools");
    const memory = mk(b, target, optimize, "memory");
    const engine = mk(b, target, optimize, "engine");
    const server = mk(b, target, optimize, "server");
    const proto = mk(b, target, optimize, "client_proto");
    const cli = mk(b, target, optimize, "cli");
    const ext = mk(b, target, optimize, "ext");

    // L0′ / L0 —— 零内部依赖
    //   注意：这里**故意没有** common.addImport("util", util)。
    //   若 common 需要 util 里的纯函数（时间格式化之类），直接放进 common。

    // L1 接入：只依赖 L0
    link(llm, &.{ .{ "common", common }, .{ "util", util } });
    link(config, &.{ .{ "common", common }, .{ "util", util } });

    // L2 能力：**彼此零依赖**。
    //   - 权限的**契约类型**（Verdict/Outcome/Request/Response）在 `common/perm.zig`，
    //     所以 `tools` 只需要 `common`，不需要 `perm/`（实现）；这样三条流可完全并行。
    //   - `memory` 只做存储，路径由 engine 传入，因此也不依赖 `config`。
    link(perm, &.{.{ "common", common }});
    link(tools, &.{ .{ "common", common }, .{ "util", util } });
    link(memory, &.{ .{ "common", common }, .{ "util", util } });

    // L3 内核：绝不 import cli；但**必须**能碰操作系统边界（→ util）
    link(engine, &.{
        .{ "common", common }, .{ "llm", llm },       .{ "tools", tools },
        .{ "perm", perm },     .{ "memory", memory }, .{ "config", config },
        .{ "util", util },
    });

    // L4 协议与入口
    link(server, &.{ .{ "common", common }, .{ "engine", engine }, .{ "config", config }, .{ "util", util }, .{ "llm", llm } });
    link(proto, &.{ .{ "common", common }, .{ "engine", engine }, .{ "util", util } });
    link(cli, &.{
        .{ "common", common }, .{ "server", server }, .{ "client_proto", proto },
        .{ "engine", engine }, .{ "config", config }, .{ "util", util }, .{ "llm", llm },
    });
    link(ext, &.{ .{ "tools", tools }, .{ "common", common } });

    // ── 可执行 ──
    const exe = b.addExecutable(.{
        .name = "zigent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("cli", cli);
    b.installArtifact(exe);

    // ── 测试：**每个模块各自成一个测试产物** ──
    //   这一步是铁律强制的关键：只有把每个模块当测试根，Zig 才会**完整分析它的文件**。
    //   否则惰性分析会让「import 了一个未声明的模块」这种越界悄悄溜过去。
    const test_step = b.step("test", "跑全部模块测试");
    const mods = .{
        .{ "util", util },         .{ "common", common },   .{ "llm", llm },
        .{ "config", config },     .{ "perm", perm },       .{ "tools", tools },
        .{ "memory", memory },     .{ "engine", engine },   .{ "server", server },
        .{ "client_proto", proto },.{ "cli", cli },         .{ "ext", ext },
    };
    inline for (mods) |m| {
        const t = b.addTest(.{ .root_module = m[1] });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ── run：`zig build run -- serve` / `zig build run -- --print "…"` ──
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |a| run_cmd.addArgs(a);
    b.step("run", "构建并运行 zigent").dependOn(&run_cmd.step);

    // ── guard：把两条"只写进文档"的架构约束变成**可执行检查** ──
    //   文档 11 §10 验收：
    //     #2 除 util/io.zig 外，任何文件不 import std.posix
    //     #3 common/ 下不出现 std.Io（唯一例外：tool.zig 的宿主总线）
    //   这两条过去只能靠人盯 review；现在是 `zig build guard`。
    const guard = b.step("guard", "架构约束检查（std.posix 隔离 / common 纯逻辑）");
    guard.dependOn(&b.addSystemCommand(&.{
        "sh", "-c",
        \\set -e
        \\bad=$(grep -rn "std\\.posix" src --include=*.zig | grep -v "^src/util/io.zig" | grep -v "^[^:]*:[0-9]*: *//" || true)
        \\if [ -n "$bad" ]; then
        \\  echo "GUARD FAIL: std.posix 只允许出现在 src/util/io.zig"; echo "$bad"; exit 1
        \\fi
        \\bad2=$(grep -rln "std\.Io" src/common --include=*.zig | grep -v "^src/common/tool.zig$" || true)
        \\if [ -n "$bad2" ]; then
        \\  echo "GUARD FAIL: common/ 必须保持纯逻辑（tool.zig 的宿主总线除外）"; echo "$bad2"; exit 1
        \\fi
        \\echo "guard: OK"
    }).step);
}

fn mk(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(b.fmt("src/{s}/root.zig", .{name})),
        .target = target,
        .optimize = optimize,
    });
}

fn link(m: *std.Build.Module, deps: []const struct { []const u8, *std.Build.Module }) void {
    for (deps) |d| m.addImport(d[0], d[1]);
}
