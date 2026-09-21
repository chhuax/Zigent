//! cli/ —— L4 入口
//!
//! 进程入口：解析 argv、组装 `Rt`、分发。**内核不认识这里**（engine 对 cli 零依赖）。
//!
//! 允许的依赖（由 `build.zig` 声明；**别的模块 import 不进来**）：
//!   ← common
//!   ← server
//!   ← client_proto
//!   ← engine
//!   ← config
//!   ← util

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const server = @import("server");
const client_proto = @import("client_proto");
const engine = @import("engine");
const config = @import("config");
const util = @import("util");
const llm = @import("llm");

const args_mod = @import("args.zig");
const commands = @import("commands.zig");
pub const repl = @import("repl.zig");
pub const render = @import("render.zig");

pub const args = args_mod;
pub const VERSION = commands.VERSION;

/// 模块自述 —— 也用来**强制引用每个声明的依赖**。
pub const module_info = .{
    .name = "cli",
    .layer = "L4 入口",
    .deps = &[_][]const u8{ "common", "server", "client_proto", "engine", "config", "util", "llm" },
};

comptime {
    _ = common.module_info.name;
    _ = server.module_info.name;
    _ = client_proto.module_info.name;
    _ = engine.module_info.name;
    _ = config.module_info.name;
    _ = util.module_info.name;
    _ = llm.module_info.name;
}

pub const ExitCode = u8;

/// 进程入口。**唯一的 `Rt` 构造点**（文档 11 验收 #6）。
pub fn run(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(gpa);
    defer gpa.free(argv);

    const opts = args_mod.parse(argv) catch {
        util.io.writeStderr(io, "error: unsupported flag\n");
        return 2;
    };

    if (opts.command == .version) {
        var buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "zigent {s} (protocol {d})\n", .{ VERSION, client_proto.PROTOCOL_VERSION });
        try util.io.writeStdout(io, line);
        return 0;
    }
    if (opts.command == .help) {
        try util.io.writeStdout(io, args_mod.USAGE);
        return 0;
    }

    // ── 组装 Rt（gpa + io + env + cwd + home + settings + paths）──
    //    ★ **唯一的 Rt 构造点**（文档 11 验收 #6）。
    const cwd = try util.io.cwdAlloc(io, gpa);
    defer gpa.free(cwd);

    // Paths 的字段借用 env/cwd 的存储，因此不需要单独释放。
    const paths = try config.Paths.discover(io, gpa, init.environ_map, cwd);
    const home = paths.home;

    var settings = try config.Settings.load(io, gpa, &paths, init.environ_map);
    defer settings.deinit(gpa);

    // 用户配置（provider / model）—— `config.json` 是**另一套**、与 settings 不合并
    const cfg_path = try paths.userConfigFile(gpa);
    defer gpa.free(cfg_path);
    var user_config = try config.UserConfig.load(io, gpa, cfg_path);
    defer user_config.deinit(gpa);

    // `config.json` 的 keys 层只抽 model.default（不是全量 settings 层）
    settings.applyKeysLayer(&user_config);

    // CLI 覆盖优先于分层配置
    if (opts.model) |m| settings.model = m;

    // ⚠️ `applyKeysLayer` 只写**档位名**（"default"），而"按档位解析具体模型"的路由
    //    尚未实现 —— 不覆盖它就会把字符串 "default" 当模型名发给 provider。
    //    （真实报错：`The supported API model names are …, but you passed .`）
    if (opts.model == null and user_config.default_model.len > 0) {
        settings.model = user_config.default_model;
    }
    if (opts.permission_mode) |pm| {
        if (common.perm.Mode.fromWire(pm)) |mode| settings.permission_mode = mode;
    }
    if (settings.model.len == 0 and user_config.default_model.len > 0) {
        settings.model = user_config.default_model;
    }

    var cancel = std.atomic.Value(bool).init(false);
    var logger = util.log.Logger{ .io = io, .tag = "zigent" };
    logger.min_level = if (opts.verbose) .debug else .info;

    var rt = engine.Rt{
        .gpa = gpa,
        .io = io,
        .env = init.environ_map,
        .cwd = cwd,
        .home = home,
        .settings = &settings,
        .paths = &paths,
        .session_id = "",
        .cancel = &cancel,
        .logger = logger,
    };

    try paths.ensureRuntimeDirs(io);

    return switch (opts.command) {
        .repl => repl.run(gpa, io, &rt, opts, &user_config),
        .serve => commands.serve(gpa, io, &rt, opts, &user_config),
        .print => commands.print(gpa, io, &rt, opts, &user_config),
        .acp => commands.acpServe(gpa, io, &rt, opts, &user_config),
        else => 0,
    };
}

test "cli: 依赖链可解析" {
    try std.testing.expectEqualStrings("cli", module_info.name);
}

test {
    std.testing.refAllDecls(@This());
}
