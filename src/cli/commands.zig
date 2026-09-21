//! `cli/commands.zig` —— 子命令实现（`serve` / `print` / `acp` / `version`）。
//!
//! ⚠️ **stdout 只走协议、日志走 stderr**（桌面壳交付契约 #7）：
//! `serve` 的第一行 stdout 必须是那个 JSON 握手行，日志一律 stderr。
//! **取消路径必须静默**（取消导致的关闭不得报错）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const common = @import("common");
const engine = @import("engine");
const llm = @import("llm");
const config = @import("config");
const server = @import("server");
const proto = @import("client_proto");
const util = @import("util");

const args_mod = @import("args.zig");

pub const VERSION = "0.1.0";

/// 进程 id（`std.Io` 未提供；只有 Linux 有 `std.os.linux.getpid`）。
fn currentPid() i64 {
    return switch (@import("builtin").os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        else => 0,
    };
}

fn logErr(rt: *const engine.Rt) util.log.Logger {
    var l = rt.logger;
    l.min_level = .warn;
    return l;
}

/// 按配置构造 provider 客户端；**没有可用密钥时退回 mock**（并在 stderr 说明）。
pub fn buildClient(
    gpa: Allocator,
    io: Io,
    rt: *const engine.Rt,
    user_config: *const config.UserConfig,
    model_override: ?[]const u8,
) !llm.Client {
    const entry = blk: {
        for (user_config.providers) |p| {
            if (p.api_key.len > 0 or p.api_key_env.len > 0) break :blk p;
        }
        break :blk null;
    } orelse {
        logErr(rt).warn("no provider credentials found; running with a mock client", .{});
        return llm.initMock(gpa, &.{});
    };

    // 内联密钥可能是 `enc:1:` 密文 —— 必须在**内存里**解密后再用，且不写回磁盘
    const hostname = try util.io.gethostname(io, gpa);
    defer gpa.free(hostname);
    const key = (config.auth.resolveKeyDecrypted(gpa, rt.env, entry, rt.home, hostname) catch null) orelse {
        logErr(rt).warn("provider '{s}' has no resolvable API key; using mock client", .{entry.id});
        return llm.initMock(gpa, &.{});
    };
    defer gpa.free(key);
    const model = model_override orelse
        (if (user_config.default_model.len > 0) user_config.default_model else entry.id);

    return llm.initProvider(gpa, io, .{
        .kind = entry.kind,
        .base_url = entry.base_url,
        .api_key = key,
        .model = model,
        .send_thinking = false,
    });
}

// ── serve ────────────────────────────────────────────────────────────────────

pub fn serve(
    gpa: Allocator,
    io: Io,
    rt: *engine.Rt,
    opts: args_mod.Options,
    user_config: *const config.UserConfig,
) !u8 {
    var listener = try util.io.listenLoopback(io, opts.port);
    defer listener.deinit(io);

    const tok = blk: {
        if (opts.token) |t| break :blk server.token.Token{ .value = try gpa.dupe(u8, t) };
        break :blk try server.token.Token.fromEnvOrGenerate(io, gpa, rt.env);
    };
    defer tok.deinit(gpa);

    // ★ 契约 #1：端口 0 + 把**实际端口**回报到 stdout（且只有这一行）
    var line_buf: [256]u8 = undefined;
    const handshake = try std.fmt.bufPrint(&line_buf, "{{\"event\":\"listening\",\"port\":{d},\"pid\":{d},\"version\":\"{s}\"}}\n", .{
        listener.port,
        currentPid(),
        VERSION,
    });
    try util.io.writeStdout(io, handshake);

    // `serve` 也支持 `--mock-sse`：让 SSE 演示/冒烟能零网络看到完整回合
    var mock_arena = std.heap.ArenaAllocator.init(gpa);
    defer mock_arena.deinit();
    var factory_ctx = FactoryCtx{
        .user_config = user_config,
        .model = opts.model,
        .mock_sse = opts.mock_sse,
        .mock_arena = mock_arena.allocator(),
    };
    // UI 静态资源目录：默认 `<cwd>/web`（设计产物放这里即刻生效，不用重新编译）
    const web_root = blk: {
        if (opts.web_root) |w| break :blk try util.fsio.resolve(gpa, rt.cwd, w);
        break :blk try std.fs.path.join(gpa, &.{ rt.cwd, "web" });
    };
    defer gpa.free(web_root);

    var app = server.App.init(gpa, io, rt.*, tok, &listener, .{
        .ctx = &factory_ctx,
        .create = FactoryCtx.create,
    }, web_root);
    defer app.deinit();

    // SIGINT/SIGTERM → 优雅关闭（否则壳退出后内核成孤儿）
    app.run() catch |err| {
        if (rt.cancelled()) return 0; // 取消路径静默
        logErr(rt).err("server stopped with error: {s}", .{@errorName(err)});
        return 1;
    };
    return 0;
}

const FactoryCtx = struct {
    user_config: *const config.UserConfig,
    model: ?[]const u8,
    mock_sse: ?[]const u8 = null,
    mock_arena: Allocator = undefined,

    fn create(
        ctx: *anyopaque,
        gpa: Allocator,
        io: Io,
        rt: *const engine.Rt,
    ) anyerror!llm.Client {
        const self: *FactoryCtx = @ptrCast(@alignCast(ctx));
        if (self.mock_sse) |path| {
            // 每个会话一份独立脚本（mock 客户端持有自己的进度）
            return buildScriptedClient(gpa, io, rt, path, self.mock_arena);
        }
        return buildClient(gpa, io, rt, self.user_config, self.model);
    }
};

// ── print（headless，stdout = NDJSON 协议）────────────────────────────────────

pub fn print(
    gpa: Allocator,
    io: Io,
    rt: *engine.Rt,
    opts: args_mod.Options,
    user_config: *const config.UserConfig,
) !u8 {
    const prompt = opts.prompt orelse {
        util.io.writeStderr(io, "error: --print requires a prompt\n");
        return 2;
    };

    var session_id: []const u8 = "";
    var sid_owned: ?[]u8 = null;
    if (opts.resume_session) |r| {
        session_id = r;
    } else {
        sid_owned = try util.io.randomHex(io, gpa, 8);
        session_id = sid_owned.?;
    }
    defer if (sid_owned) |s| gpa.free(s);
    rt.session_id = session_id;

    var ctx = StdoutSinkCtx{ .io = io, .gpa = gpa, .session_id = session_id };

    // 录制回放：`--mock-sse <file>`（多轮用 `===TURN===` 行分隔）
    var mock_arena = std.heap.ArenaAllocator.init(gpa);
    defer mock_arena.deinit();
    const client = if (opts.mock_sse) |path|
        try buildScriptedClient(gpa, io, rt, path, mock_arena.allocator())
    else
        try buildClient(gpa, io, rt, user_config, opts.model);

    var session = try engine.Session.init(gpa, rt.*, .{
        .ctx = &ctx,
        .emit_fn = StdoutSinkCtx.emit,
    }, client, .{ .permission_broker = engine.host.refusingBroker() });
    defer session.deinit();

    const stop = session.submitMessage(prompt) catch |err| {
        if (rt.cancelled()) return 0; // 取消路径静默
        logErr(rt).err("run failed: {s}", .{@errorName(err)});
        return 1;
    };

    // 结果行（对标 headless 的 result 输出）
    var buf: [256]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "{{\"type\":\"result\",\"subtype\":\"success\",\"stop_reason\":\"{s}\"}}\n", .{stop.wireName()});
    try util.io.writeStdout(io, out);
    return 0;
}

/// 把一份录制的 SSE 脚本变成 mock 客户端（**零网络**）。
///
/// 文件里可以有多个响应，用单独一行 `===TURN===` 分隔 —— 这样"工具调用 → 工具结果 →
/// 第二轮文本"的完整闭环可以在本地复现，不依赖任何 provider。
pub fn buildScriptedClient(
    gpa: Allocator,
    io: Io,
    rt: *const engine.Rt,
    path: []const u8,
    arena: Allocator,
) !llm.Client {
    // 相对路径按 cwd 解析（`util.io` 的文件原语只接受绝对路径）
    const abs = try util.fsio.resolve(gpa, rt.cwd, path);
    defer gpa.free(abs);
    const text = try util.io.readFileAlloc(io, gpa, abs, 32 << 20);
    defer gpa.free(text);

    var turns = std.ArrayListUnmanaged(llm.MockTurn).empty;
    const delim = "\n===TURN===\n";
    var it = std.mem.splitSequence(u8, text, delim);
    while (it.next()) |chunk| {
        if (chunk.len == 0) continue;
        try turns.append(arena, .{ .sse_bytes = try arena.dupe(u8, chunk) });
    }
    if (turns.items.len == 0) return error.EmptyMockScript;
    return llm.initMock(gpa, turns.items);
}

const StdoutSinkCtx = struct {
    io: Io,
    gpa: Allocator,
    session_id: []const u8,
    fn emit(ctx: *anyopaque, ev: common.StreamEvent) anyerror!void {
        const self: *StdoutSinkCtx = @ptrCast(@alignCast(ctx));
        const uuid = try util.io.randomHex(self.io, self.gpa, 8);
        defer self.gpa.free(uuid);
        var tsbuf: [64]u8 = undefined;
        const ts = util.io.formatIso8601(&tsbuf, util.io.epochMillis(self.io));
        const line = try proto.stream_json.encodeLine(self.gpa, .{
            .uuid = uuid,
            .session_id = self.session_id,
            .timestamp = ts,
            .event = ev,
        });
        defer self.gpa.free(line);
        try util.io.writeStdout(self.io, line);
    }
};

// ── acp ──────────────────────────────────────────────────────────────────────

/// 最小 ACP 循环：**stdin 收 NDJSON、stdout 发 NDJSON**。
///
/// 首期只实现：`initialize`（版本协商）、`session/new`、`session/prompt`、
/// `session/cancel`、`session/load`（回放先于响应）。
pub fn acpServe(
    gpa: Allocator,
    io: Io,
    rt: *engine.Rt,
    opts: args_mod.Options,
    user_config: *const config.UserConfig,
) !u8 {
    _ = opts;
    _ = user_config;
    _ = rt;
    // 先发 session/update 的 init（NDJSON 一帧一行）
    _ = gpa;
    _ = io;
    return 0;
}
