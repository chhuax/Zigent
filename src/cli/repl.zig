//! `cli/repl.zig` —— **交互式 REPL**：在终端里直接让 agent 干活。
//!
//! ## 这是"命令行让模型干活"缺的那一层
//!
//! 内核早就跑通了（`Session.submitMessage` 支持多轮、transcript 已落盘），
//! 缺的只是外面这层交互：
//!   1. 读 stdin 的循环（`--print` 是一次性的）；
//!   2. 人看的渲染（`--print` 吐的是 NDJSON）；
//!   3. **y/n 权限提示** —— 没有它，工具在非交互模式下走 fail-closed 会被**全部拒绝**，
//!      agent 根本干不了活。
//!
//! ## Ctrl-C 的语义（**两个含义要分开**）
//!
//! - 在**提示符**处按：退出程序。
//! - 在**跑的时候**按：只取消本轮，回到提示符。
//!
//! 所以装了 SIGINT 处理器，让它只置取消位、不杀进程（见 `util.io.installSigintCancel`）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const common = @import("common");
const engine = @import("engine");
const llm = @import("llm");
const config = @import("config");
const util = @import("util");

const render_mod = @import("render.zig");
const args_mod = @import("args.zig");
const commands = @import("commands.zig");

pub const USAGE_HINT =
    \\  直接输入你的要求，回车执行。
    \\  /help     显示帮助
    \\  /clear    只清屏（会话上下文仍保留）
    \\  /exit     退出（Ctrl-D 同效）
    \\  Ctrl-C    跑动时=取消本轮；在提示符处=退出
    \\
;

pub const Repl = struct {
    gpa: Allocator,
    io: Io,
    rt: *engine.Rt,
    render: render_mod.Renderer,
    broker: Broker,
    session: *engine.Session,
    turns: usize = 0,

    pub fn deinit(self: *Repl) void {
        self.session.deinit();
        self.gpa.destroy(self.session);
        self.broker.deinit();
        self.render.deinit();
    }

    /// 跑一轮；返回是否应当退出。
    pub fn submit(self: *Repl, line: []const u8) !bool {
        if (line.len == 0) return false;

        if (line[0] == '/') {
            if (std.mem.eql(u8, line, "/exit") or std.mem.eql(u8, line, "/quit")) return true;
            if (std.mem.eql(u8, line, "/help")) {
                util.io.writeStderr(self.io, USAGE_HINT);
                return false;
            }
            if (std.mem.eql(u8, line, "/clear")) {
                util.io.writeStdout(self.io, "\x1b[2J\x1b[H") catch {};
                return false;
            }
            util.io.writeStderr(self.io, "未知命令（/help 看列表）\n");
            return false;
        }

        self.turns += 1;
        const stop = self.session.submitMessage(line) catch |err| blk: {
            if (self.rt.cancelled()) break :blk common.StopReason.cancelled;
            var buf: [512]u8 = undefined;
            const m = std.fmt.bufPrint(&buf, "\n  \x1b[31m运行失败：{s}\x1b[0m\n", .{@errorName(err)}) catch "";
            util.io.writeStderr(self.io, m);
            break :blk common.StopReason.end_turn;
        };
        if (stop == .cancelled) {
            util.io.writeStderr(self.io, "  \x1b[33m[已取消本轮]\x1b[0m\n");
        }
        return false;
    }
};

/// 交互式权限/问答经纪人。
///
/// ★ 这是"让 agent 真能干活"的关键：非交互模式下一律拒绝（fail-closed），
/// 交互模式下一张卡片 + 一个 y/n。
pub const Broker = struct {
    gpa: Allocator,
    io: Io,
    /// 用户选过"总是允许"的工具名
    always: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *Broker) void {
        var it = self.always.iterator();
        while (it.next()) |e| self.gpa.free(e.key_ptr.*);
        self.always.deinit(self.gpa);
    }

    fn request(ctx: *anyopaque, req: common.perm.Request) anyerror!common.perm.Response {
        const self: *Broker = @ptrCast(@alignCast(ctx));

        if (self.always.contains(req.tool_name)) {
            return .{ .allowed = true, .cache_decision = false };
        }

        var w = std.ArrayListUnmanaged(u8).empty;
        defer w.deinit(self.gpa);
        const risk = req.tool_risk_level.wireName();

        w.print(self.gpa, "\n\x1b[1m需要你的许可\x1b[0m  \x1b[36m{s}\x1b[0m \x1b[2m[{s}]\x1b[0m\n", .{ req.tool_name, risk }) catch {};
        // 摘要是**内核生成**的多行文本，原样展示（客户端不要自己拼）
        var lines_it = std.mem.splitScalar(u8, req.input_summary, '\n');
        while (lines_it.next()) |ln| {
            if (ln.len == 0) continue;
            w.print(self.gpa, "  \x1b[2m{s}\x1b[0m\n", .{common.usage.truncateCodePoints(ln, 200)}) catch {};
        }
        if (req.reason.len > 0) {
            w.print(self.gpa, "  \x1b[33m{s}\x1b[0m\n", .{common.usage.truncateCodePoints(req.reason, 200)}) catch {};
        }
        w.appendSlice(self.gpa, "  允许？ \x1b[2m[y]一次  [a]总是  [n]拒绝\x1b[0m › ") catch {};
        util.io.writeStderr(self.io, w.items);

        const answer = (try util.io.readLine(self.io, self.gpa, 64)) orelse "";
        defer self.gpa.free(answer);
        const ch = std.mem.trim(u8, answer, " \t");

        if (std.mem.eql(u8, ch, "y") or std.mem.eql(u8, ch, "Y") or ch.len == 0) {
            util.io.writeStderr(self.io, "  \x1b[32m→ 允许一次\x1b[0m\n");
            return common.perm.responseForOption("allow_once");
        }
        if (std.mem.eql(u8, ch, "a") or std.mem.eql(u8, ch, "A")) {
            const k = self.gpa.dupe(u8, req.tool_name) catch null;
            if (k) |key| self.always.put(self.gpa, key, {}) catch self.gpa.free(key);
            util.io.writeStderr(self.io, "  \x1b[32m→ 本会话内总是允许该工具\x1b[0m\n");
            return common.perm.responseForOption("allow_always");
        }
        util.io.writeStderr(self.io, "  \x1b[31m→ 拒绝\x1b[0m\n");
        return common.perm.responseForOption("reject_once");
    }

    /// `InteractionBroker` 的 vtable 形状（多了 Question 包装）。
    fn questionBridge(ctx: *anyopaque, q: engine.host.Question) anyerror!common.tool.Answer {
        return askQuestion(ctx, q.prompt, q.options, q.multi_select);
    }

    fn askQuestion(
        ctx: *anyopaque,
        prompt: []const u8,
        options: []const common.tool.QuestionOption,
        multi_select: bool,
    ) anyerror!common.tool.Answer {
        const self: *Broker = @ptrCast(@alignCast(ctx));

        var w = std.ArrayListUnmanaged(u8).empty;
        defer w.deinit(self.gpa);
        w.print(self.gpa, "\n\x1b[1m问题\x1b[0m  {s}\n", .{prompt}) catch {};
        for (options, 0..) |o, i| {
            w.print(self.gpa, "  [{d}] {s}", .{ i + 1, o.label }) catch {};
            if (o.description.len > 0) w.print(self.gpa, " \x1b[2m— {s}\x1b[0m", .{o.description}) catch {};
            w.append(self.gpa, '\n') catch {};
        }
        w.print(self.gpa, "  选择（{s}，或直接输入文字）› ", .{if (multi_select) "可多选，逗号分隔" else "单选"}) catch {};
        util.io.writeStderr(self.io, w.items);

        const line = (try util.io.readLine(self.io, self.gpa, 1024)) orelse "";
        defer self.gpa.free(line);
        const trimmed = std.mem.trim(u8, line, " \t");

        var picked = std.ArrayListUnmanaged([]const u8).empty;
        defer picked.deinit(self.gpa);

        var free_text: []const u8 = "";
        if (trimmed.len > 0 and trimmed[0] >= '1' and trimmed[0] <= '9') {
            var it = std.mem.splitScalar(u8, trimmed, ',');
            while (it.next()) |piece| {
                const idx = std.fmt.parseInt(usize, std.mem.trim(u8, piece, " "), 10) catch continue;
                if (idx >= 1 and idx <= options.len) {
                    try picked.append(self.gpa, options[idx - 1].option_id);
                }
            }
        } else {
            free_text = trimmed;
        }

        return .{ .selected_option_ids = try picked.toOwnedSlice(self.gpa), .free_text = free_text };
    }
};

/// 装配并进入 REPL。
pub fn run(
    gpa: Allocator,
    io: Io,
    rt: *engine.Rt,
    opts: args_mod.Options,
    user_config: *const config.UserConfig,
) !u8 {
    // Ctrl-C：只置取消位，不杀进程
    util.io.installSigintCancel(rt.cancel);

    // 会话 id（REPL 全程一个会话，transcript 落在同一个文件里）
    const sid = try util.io.randomHex(io, gpa, 8);
    defer gpa.free(sid);
    rt.session_id = sid;

    // 非交互（管道）且没给要求 → 打帮助就退出，别把脚本挂住
    if (!util.io.stdinIsTty(io) and opts.prompt == null) {
        try util.io.writeStdout(io, args_mod.USAGE);
        return 0;
    }

    // `--mock-sse` 也要在 REPL 下生效（零网络演示/自检）
    var mock_arena = std.heap.ArenaAllocator.init(gpa);
    defer mock_arena.deinit();
    const client = if (opts.mock_sse) |path|
        try commands.buildScriptedClient(gpa, io, rt, path, mock_arena.allocator())
    else
        try commands.buildClient(gpa, io, rt, user_config, opts.model);

    const session = try gpa.create(engine.Session);
    var inited = false;
    // ⚠️ sink/broker 的 ctx 必须指向**最终位置**（`repl` 里的字段），
    //    不能指向先前的临时局部变量 —— 否则结构体一拷，指针就悬垂了。
    var repl = Repl{
        .gpa = gpa,
        .io = io,
        .rt = rt,
        .render = render_mod.Renderer.init(gpa, io),
        .broker = Broker{ .gpa = gpa, .io = io },
        .session = session,
    };
    defer if (!inited) gpa.destroy(session);
    session.* = try engine.Session.init(gpa, rt.*, repl.render.sink(), client, .{
        .permission_broker = .{ .ctx = &repl.broker, .request = Broker.request },
        .interaction_broker = .{ .ctx = &repl.broker, .ask = Broker.questionBridge },
    });
    inited = true;
    defer repl.deinit();

    repl.render.banner(commands.VERSION);

    // 命令行上直接给了要求 → 先跑一轮，然后进交互
    if (opts.prompt) |p| {
        _ = try repl.submit(p);
    }

    while (true) {
        // 提示符处 Ctrl-C = 退出（跑动中的 Ctrl-C 已在 submit 里处理并重置）
        if (rt.cancelled()) {
            rt.cancel.store(false, .release);
            util.io.writeStderr(io, "\n");
            break;
        }
        util.io.writeStdout(io, "\x1b[1m›\x1b[0m ") catch {};

        const line = util.io.readLine(io, gpa, 1 << 16) catch |err| {
            if (err == error.ReadLineFailed and rt.cancelled()) break;
            break;
        } orelse {
            util.io.writeStderr(io, "\n");
            break; // EOF / Ctrl-D
        };
        defer gpa.free(line);

        if (rt.cancelled()) {
            rt.cancel.store(false, .release);
            util.io.writeStderr(io, "\n");
            break;
        }
        if (try repl.submit(line)) break;

        // 跑动中被 Ctrl-C 打断 → 清标志，回到提示符
        if (rt.cancelled()) rt.cancel.store(false, .release);
    }
    return 0;
}
