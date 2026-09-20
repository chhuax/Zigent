//! `engine/loop.zig` —— **拉式主循环**（文档 03 §11.3）。
//!
//! ```text
//! Idle --> StartTurn: submitMessage
//! StartTurn --> Compacting: 阈值命中
//! Compacting --> BuildPrompt
//! StartTurn --> BuildPrompt
//! BuildPrompt --> Streaming: streamChat
//! Streaming --> Streaming: 事件 → 立即推给客户端
//! Streaming --> FinishTurn: 流结束
//! FinishTurn --> Pairing: 原子写入 assistant + 紧邻 results
//! Pairing --> StartTurn: 有工具调用 / 目标续跑
//! Pairing --> StopHooks: 自然终止
//! Streaming --> Recovering: API 错误
//! Recovering --> StartTurn: RETRY / COMPACT_AND_RETRY
//! Recovering --> StopHooks: ABORT
//! ```
//!
//! **拉式**（由消费者拉动 `tryAdvance`）而不是后台线程跑循环 ——
//! 好处是"关闭流即中断 run"的语义天然成立（文档 03 §11.8）。
//!
//! 唯一有会话状态的地方：其它模块都是无状态的（这正是它们能独立测试的原因）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const llm = @import("llm");
const tools = @import("tools");
const perm = @import("perm");
const memory = @import("memory");
const config = @import("config");
const util = @import("util");

const rt_mod = @import("rt.zig");
const turn_mod = @import("turn.zig");
const budget_mod = @import("budget.zig");
const recovery_mod = @import("recovery.zig");
const compact_mod = @import("compact.zig");
const prompt_mod = @import("prompt.zig");
const transcript_mod = @import("transcript.zig");
const tool_exec_mod = @import("tool_exec.zig");
const host_mod = @import("host.zig");
const sink_mod = @import("sink.zig");
const pairing = turn_mod;

pub const Turn = turn_mod.Turn;
pub const Message = common.Message;

pub const SessionOptions = struct {
    /// 恢复已有会话时传入 transcript 路径
    transcript_path: ?[]const u8 = null,
    mode: ?common.perm.Mode = null,
    max_turns: u32 = recovery_mod.DEFAULT_MAX_TURNS,
    /// 权限经纪人（无 → fail-closed）
    permission_broker: ?host_mod.PermissionBroker = null,
    /// 问答经纪人
    interaction_broker: ?host_mod.InteractionBroker = null,
};

pub const Session = struct {
    gpa: Allocator,
    /// 会话级 arena：轮次 / 消息 / 组合缓冲都放这里 —— 压缩时整体重建的语义
    /// 与 arena 天然一致，且 `deinit` 一次释放干净（避免逐轮小泄漏）。
    arena: std.heap.ArenaAllocator,
    rt: rt_mod.Rt,
    sink: sink_mod.EventSink,
    registry: *tools.Registry,
    client: llm.Client,
    checker: perm.Checker,
    budget: budget_mod.Budget,
    recovery: recovery_mod.Recovery,
    transcript: transcript_mod.Transcript,
    host_impl: host_mod.HostImpl,
    /// 会话内的轮次（**压缩只接受/产出 `[]Turn`**）
    turns: std.ArrayListUnmanaged(Turn) = .empty,
    mode: common.perm.Mode = .ask,
    system_prompt: []u8 = &.{},
    model: []const u8 = "",
    total_usage: common.Usage = .{},
    tool_call_total: i32 = 0,
    started_ms: i64 = 0,
    finished: bool = false,
    /// 把 engine 的 sink 适配成 llm 的 sink（两者形状相同，各属一层）
    adapter: LlmSinkAdapter = undefined,

    /// 装配会话（**`Rt` 里的 gpa/io/settings/paths 都来自外部注入**）。
    pub fn init(
        gpa: Allocator,
        rt: rt_mod.Rt,
        sink: sink_mod.EventSink,
        client: llm.Client,
        opts: SessionOptions,
    ) !Session {
        const registry = try gpa.create(tools.Registry);
        registry.* = try tools.defaultRegistry(gpa);

        const transcript_path = if (opts.transcript_path) |p|
            try gpa.dupe(u8, p)
        else blk: {
            const dir = try rt.paths.transcriptsDir(gpa);
            defer gpa.free(dir);
            try util.io.mkdirp(rt.io, dir);
            break :blk try std.fmt.allocPrint(gpa, "{s}/{s}.jsonl", .{ dir, rt.session_id });
        };
        defer gpa.free(transcript_path);

        const transcript = try transcript_mod.Transcript.open(rt.io, gpa, transcript_path);

        var checker = perm.Checker.init(gpa, rt.io, rt.cwd);
        checker.mode = opts.mode orelse rt.settings.permission_mode;
        // 工作目录默认是**读写**根（用户显式启动 agent 的那个目录）
        try checker.grantWritableRoot(rt.cwd);

        var host_impl = host_mod.HostImpl{
            .gpa = gpa,
            .io = rt.io,
            .paths = rt.paths,
            .sink = sink,
        };
        if (opts.permission_broker) |b| host_impl.permission = b;
        if (opts.interaction_broker) |b| host_impl.interaction = b;

        var session = Session{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .rt = rt,
            .sink = sink,
            .registry = registry,
            .client = client,
            .checker = checker,
            .budget = budget_mod.Budget.init(settingsContextCeiling(rt.settings), rt.settings.max_tokens),
            .recovery = recovery_mod.Recovery.init(opts.max_turns),
            .transcript = transcript,
            .host_impl = host_impl,
            .mode = opts.mode orelse rt.settings.permission_mode,
            .started_ms = util.io.monotonicMillis(rt.io),
            .model = rt.settings.model,
        };
        errdefer session.transcript.deinit();

        try session.rebuildTurns();
        return session;
    }

    pub fn deinit(self: *Session) void {
        self.turns.deinit(self.gpa);
        self.arena.deinit();
        self.checker.deinit();
        self.transcript.deinit();
        if (self.system_prompt.len > 0) self.gpa.free(self.system_prompt);
        const reg = self.registry;
        reg.deinit();
        self.gpa.destroy(reg);
        self.host_impl.todos.deinit(self.gpa);
        self.client.deinit();
    }

    /// 从 transcript 重建轮次序列（resume）。
    fn rebuildTurns(self: *Session) !void {
        const a = self.arena.allocator();
        const msgs = try self.transcript.messages(a);
        // 已落盘的对话按 assistant + 紧邻 user(result) 成对切分
        var i: usize = 0;
        while (i < msgs.len) {
            const m = msgs[i];
            if (m.role == .assistant) {
                if (i + 1 < msgs.len and msgs[i + 1].role == .user and
                    hasToolResult(msgs[i + 1]))
                {
                    const results = try collectResults(a, msgs[i + 1]);
                    const t = Turn.init(a, m, results) catch {
                        i += 1;
                        continue;
                    };
                    try self.turns.append(self.gpa, t);
                    i += 2;
                    continue;
                }
                if (Turn.plain(a, m)) |t| {
                    try self.turns.append(self.gpa, t);
                } else |_| {}
            }
            i += 1;
        }
    }

    fn hasToolResult(m: Message) bool {
        for (m.content) |b| {
            if (b == .tool_result) return true;
        }
        return false;
    }

    fn collectResults(gpa: Allocator, m: Message) ![]common.ToolResultBlock {
        var out = std.ArrayListUnmanaged(common.ToolResultBlock).empty;
        errdefer out.deinit(gpa);
        for (m.content) |b| {
            if (b.asToolResult()) |r| try out.append(gpa, r);
        }
        return out.toOwnedSlice(gpa);
    }

    // ── ★ 主循环 ────────────────────────────────────────────────────────────

    /// 提交一条用户输入，**跑到收敛为止**（拉式：调用一次 = 拉完整轮）。
    pub fn submitMessage(self: *Session, prompt: []const u8) !common.StopReason {
        const gpa = self.gpa;
        const io = self.rt.io;

        var tsbuf: [64]u8 = undefined;
        const ts = util.io.formatIso8601(&tsbuf, util.io.epochMillis(io));

        try self.sink.send(.{ .session_started = .{
            .session_id = self.rt.session_id,
            .cwd = self.rt.cwd,
            .model = self.model,
            .mode = self.mode.wireName(),
            .start_time_ms = util.io.epochMillis(io),
        } });

        // 用户输入进 transcript（先持久化再执行）
        //   uuid / 消息体都挂在 transcript 的 arena 上（`append` 只借用，不接管所有权）
        const tr_a = self.transcript.arena.allocator();
        const user_msg = try Message.user(tr_a, prompt);
        try self.transcript.append(.{
            .uuid = try transcript_mod.newUuid(io, tr_a),
            .entry_type = .message,
            .session_id = self.rt.session_id,
            .timestamp = ts,
            .message = user_msg,
        });

        try self.buildSystemPrompt();

        var stop_reason: common.StopReason = .end_turn;

        while (true) {
            if (self.rt.cancelled()) {
                stop_reason = .cancelled;
                break;
            }

            // ── StartTurn / 预算 ──
            const turn_no = self.recovery.beginTurn() catch {
                stop_reason = .max_turn_requests;
                break;
            };
            try self.sink.send(.{ .start_turn = .{ .turn_number = @intCast(turn_no) } });

            var raw_est = self.rawEstimate();
            if (self.budget.shouldCompact(raw_est)) {
                const outcome = try self.compactNow();
                if (!outcome) {
                    // 压缩没能缩小 → 不假装成功，直接报错收敛
                    try self.sink.send(.{ .error_event = common.event.ErrorEvent.terminalErr(
                        "Context is over the model window and compaction could not shrink it.",
                        "prompt_too_long",
                    ) });
                    stop_reason = .end_turn;
                    break;
                }
                raw_est = self.rawEstimate();
            }

            // ── BuildPrompt + Streaming ──
            const a = self.arena.allocator();
            const messages = try self.buildMessages();

            const req = llm.ApiRequest{
                .model = self.model,
                .system = self.system_prompt,
                .messages = messages,
                .tools = try self.toolSpecs(),
                .max_tokens = self.budget.output_reserve,
                .temperature = self.rt.settings.temperature,
            };
            defer gpa.free(req.tools);

            try self.sink.send(.{ .stream_request_start = .{
                .request_id = self.rt.session_id,
                .model = self.model,
                .provider_id = self.rt.settings.provider,
                .resolved_model = self.model,
                .max_tokens = req.max_tokens,
                .system_prompt_tokens = prompt_mod.estimateTokens(self.system_prompt),
                .turn_index = @intCast(turn_no),
            } });

            const req_started = util.io.monotonicMillis(io);

            // ── 内层重试：**重试的是同一轮，不重置 turn 计数** ──
            //
            // ⚠️ 这是历史事故（实测失控到 401 turn）的根因：
            //    重试若 `continue` 到外层，`beginTurn` 会把可回退的阶梯清零，
            //    于是 `maxTurns` 永远触不到。所以重试**必须留在内层**。
            var outcome_opt: ?llm.StreamOutcome = null;
            stream_attempt: while (true) {
                if (self.rt.cancelled()) break :stream_attempt;
                const maybe = self.client.streamChat(io, &req, self.llmSink(), self.rt.cancel) catch |err| {
                    const code = classifyError(err);
                    const action = self.recovery.classify(code);
                    self.recovery.noteAttempt(action);
                    if (action == .abort) {
                        try self.sink.send(.{ .error_event = common.event.ErrorEvent.terminalErr(
                            @errorName(err),
                            code.wireName(),
                        ) });
                        if (code == .cancelled) stop_reason = .cancelled;
                        break :stream_attempt;
                    }
                    try self.sink.send(.{ .error_event = common.event.ErrorEvent.retryable(
                        @errorName(err),
                        code.wireName(),
                        @intCast(self.recovery.api_attempts),
                        @intCast(self.recovery.max_api_retries),
                        self.recovery.backoffMs(null, null),
                    ) });
                    switch (action) {
                        .retry => continue :stream_attempt,
                        .compact_and_retry => {
                            _ = try self.compactNow();
                            continue :stream_attempt;
                        },
                        .repair_and_retry => {
                            try self.repairRequestState();
                            continue :stream_attempt;
                        },
                        .clamp_max_tokens_and_retry => {
                            self.budget.output_reserve = self.recovery.clampMaxTokens(req.max_tokens);
                            continue :stream_attempt;
                        },
                        .fallback_model => {
                            if (self.recovery.fallback_model) |fm| self.model = fm;
                            continue :stream_attempt;
                        },
                        .abort => unreachable,
                    }
                };
                outcome_opt = maybe;
                break :stream_attempt;
            }

            const outcome = outcome_opt orelse {
                // 重试阶梯用尽或用户取消：本轮收敛，不再进入 Pairing
                stop_reason = if (self.rt.cancelled()) .cancelled else .end_turn;
                break;
            };

            // usage 校准（用**原始估算**做分母）
            self.budget.observe(outcome.usage.contextTokens(), raw_est);
            self.total_usage = common.Usage.add(self.total_usage, outcome.usage);

            const duration = util.io.monotonicMillis(io) - req_started;
            try self.sink.send(.{ .turn_complete = .{
                .usage = outcome.usage,
                .stop_reason = outcome.stop_reason.wireName(),
                .request_id = outcome.request_id,
                .duration_ms = duration,
            } });

            // ── FinishTurn ──
            const assistant = try self.assistantMessage(&outcome);
            var turn: Turn = undefined;
            var interrupted = false;

            if (outcome.tool_calls.len > 0) {
                var exec = tool_exec_mod.Executor{
                    .rt = &self.rt,
                    .registry = self.registry,
                    .checker = &self.checker,
                    .host_impl = &self.host_impl,
                    .sink = self.sink,
                };
                const er = exec.executeTurn(a, assistant) catch |err| {
                    try self.sink.send(.{ .error_event = common.event.ErrorEvent.of(@errorName(err)) });
                    stop_reason = .end_turn;
                    break;
                };
                self.tool_call_total += @intCast(er.results.len);
                interrupted = er.interrupted;

                if (interrupted) {
                    // ★ 中断也走同一个构造入口 —— 配对不可能被破坏
                    turn = try Turn.finishInterrupted(
                        a,
                        assistant,
                        er.results,
                        common.perm.Response.MSG_CANCELLED,
                    );
                } else {
                    turn = try Turn.init(a, assistant, er.results);
                }
            } else {
                turn = try Turn.plain(a, assistant);
            }

            // ── Pairing：一次原子写两条 ──
            try self.transcript.appendTurn(turn, self.rt.session_id, ts);
            try self.turns.append(gpa, turn);

            try self.sink.send(.{ .end_turn = .{
                .turn_number = @intCast(turn_no),
                .tool_call_count = @intCast(turn.results.len),
                .cumulative_tokens = self.total_usage.total(),
            } });

            // 输出被截断 → 允许多次续写（`MAX_OUTPUT_TOKEN_CONTINUATIONS = 3`）。
            // ⚠️ `StopReason` 没有 `max_output_tokens` 变体（那是 `ErrorCode` 的），
            //    所以这里按「输出打满 max_tokens」判定截断，而不是比对 stop_reason。
            const truncated = req.max_tokens > 0 and outcome.usage.output_tokens >= req.max_tokens - 1;
            if (truncated and self.budget.canContinueOutput()) {
                self.budget.output_reserve = self.recovery.clampMaxTokens(req.max_tokens);
                continue;
            }
            if (interrupted or self.rt.cancelled()) {
                stop_reason = .cancelled;
                break;
            }
            if (!turn.hasToolCalls()) break; // 自然终止
        }

        self.finished = true;
        try self.sink.send(.{ .session_ended = .{
            .session_id = self.rt.session_id,
            .duration_ms = util.io.monotonicMillis(io) - self.started_ms,
            .total_tokens = self.total_usage.total(),
            .tool_call_count = self.tool_call_total,
            .turn_count = @intCast(self.recovery.turns_used),
            .outcome = switch (stop_reason) {
                .cancelled => .cancelled,
                .max_turn_requests => .partial,
                else => .success,
            },
        } });
        return stop_reason;
    }

    /// ⚠️ **所有权边界**：`StreamOutcome` 里的字符串指向 llm **每次尝试自己的 arena**，
    /// 该 arena 在 `streamChat` 返回后就释放了。会话要把这一轮留在内存里，
    /// 就必须把每个字符串**复制进会话 arena** —— 否则第二轮构造请求体时会踩悬垂指针
    ///（实测症状：`anthropic.buildRequestBody` 段错误）。
    fn assistantMessage(self: *Session, outcome: *const llm.StreamOutcome) !Message {
        const gpa = self.arena.allocator();
        var blocks = std.ArrayListUnmanaged(common.ContentBlock).empty;
        errdefer blocks.deinit(gpa);
        if (outcome.text.len > 0) {
            try blocks.append(gpa, common.content.text(try gpa.dupe(u8, outcome.text)));
        }
        for (outcome.tool_calls) |tc| {
            try blocks.append(gpa, .{ .tool_use = .{
                .tool_use_id = try gpa.dupe(u8, tc.tool_use_id),
                // 遗留别名 → canonical 名字由 registry 负责；这里保留模型给的原文
                .tool_name = try gpa.dupe(u8, tc.tool_name),
                // ★ I1：原始 JSON 字符串，绝不 parse→re-serialize
                .input = try gpa.dupe(u8, tc.input),
            } });
        }
        return .{ .role = .assistant, .content = try blocks.toOwnedSlice(gpa) };
    }

    fn buildMessages(self: *Session) ![]Message {
        return self.turnsMessages();
    }

    fn turnsMessages(self: *Session) ![]Message {
        return compact_mod.turnMessages(self.arena.allocator(), self.turns.items);
    }

    fn rawEstimate(self: *Session) i64 {
        var total: i64 = 0;
        for (self.turns.items) |t| {
            total += budget_mod.estimateMessages(&.{t.assistant});
            for (t.results) |r| total += common.usage.estimateTokens(r.output) + 8;
        }
        total += common.usage.estimateTokens(self.system_prompt);
        return total;
    }

    fn toolSpecs(self: *Session) ![]llm.ToolSpec {
        const specs = try self.registry.modelSpecs(self.gpa);
        defer tools.freeModelSpecs(self.gpa, specs);
        const out = try self.gpa.alloc(llm.ToolSpec, specs.len);
        for (specs, 0..) |s, i| {
            out[i] = .{ .name = s.name, .description = s.description, .schema_json = s.schema_json };
        }
        return out;
    }

    fn buildSystemPrompt(self: *Session) !void {
        if (self.system_prompt.len > 0) self.gpa.free(self.system_prompt);
        const specs = try self.registry.modelSpecs(self.gpa);
        defer tools.freeModelSpecs(self.gpa, specs);
        const entries = try self.gpa.alloc(prompt_mod.ToolEntry, specs.len);
        defer self.gpa.free(entries);
        for (specs, 0..) |s, i| {
            entries[i] = .{ .name = s.name, .description = s.description, .schema_json = s.schema_json };
        }

        // 记忆与指令文件（读侧已过滤注入）
        var instructions_text: []const u8 = "";
        var hot_text: []const u8 = "";
        var mem_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer mem_arena.deinit();
        const ma = mem_arena.allocator();

        const files = memory.instructions.discover(self.rt.io, ma, self.rt.cwd, self.rt.home) catch &.{};
        if (files.len > 0) {
            instructions_text = memory.instructions.render(ma, files) catch "";
        }
        const hot_dir = self.rt.paths.memoriesDir(ma, "default") catch null;
        if (hot_dir) |d| {
            var hot = memory.HotMemory.load(self.rt.io, ma, d) catch null;
            if (hot) |*h| {
                hot_text = h.render(ma) catch "";
            }
        }

        var tsbuf: [64]u8 = undefined;
        const date = util.io.formatIso8601(&tsbuf, util.io.epochMillis(self.rt.io));

        self.system_prompt = try prompt_mod.build(self.gpa, .{
            .cwd = self.rt.cwd,
            .model = self.model,
            .date = date[0..10],
            .permission_mode = self.mode.wireName(),
            .instructions = instructions_text,
            .hot_memory = hot_text,
            .user_append = settingsString(self.rt.settings, "appendSystemPrompt"),
        }, entries);
    }

    /// 压缩（**只接受/产出 `[]Turn`**），并发出 `compact_boundary` 事件。
    fn compactNow(self: *Session) !bool {
        const before_tokens = self.rawEstimate();
        const before_turns = self.turns.items.len;
        const r = compact_mod.compactTurns(
            self.arena.allocator(),
            self.rt.io,
            self.turns.items,
            .{ .keep_recent_turns = 4 },
            null,
        ) catch return false;

        // ★ 成功判据：**最终 provider 上下文确实缩小**
        const after_tokens = self.rawEstimate();
        if (after_tokens >= before_tokens) {
            try self.sink.send(.{ .compact_boundary = .{
                .kind = r.kind.wireName(),
                .before_messages = @intCast(before_turns),
                .after_messages = @intCast(r.turns.len),
                .reason = "compaction did not shrink the context",
                .tokens_before = before_tokens,
                .tokens_after = after_tokens,
            } });
            return false;
        }

        // 用压缩结果替换 turns（Turn 序列，结构上不可能产生孤儿）
        // `r.turns` 挂在会话 arena 上，不需要（也不能）单独 free
        var kept = std.ArrayListUnmanaged(Turn).empty;
        try kept.appendSlice(self.gpa, r.turns);
        self.turns.deinit(self.gpa);
        self.turns = kept;

        try self.sink.send(.{ .compact_boundary = .{
            .kind = r.kind.wireName(),
            .before_messages = @intCast(before_turns),
            .after_messages = @intCast(r.turns.len),
            .reason = "context window pressure",
            .tokens_before = before_tokens,
            .tokens_after = after_tokens,
        } });
        return true;
    }

    /// 请求形状修复（配对/工具入参类错误的恢复路径）。
    fn repairRequestState(self: *Session) !void {
        try self.sink.send(.{ .status = .{ .message = "repairing request state before retry" } });
    }

    /// 把 llm 的事件流转发到会话 sink，并**去掉重复的所有权**：
    ///   - `stream_request_start` / `turn_complete` 由 **engine** 发（带 turn_index /
    ///     system_prompt_tokens / budget_snapshot 等只有引擎知道的字段）；
    ///   - `tool_call` 保留 llm 的那一份（它是"参数 JSON 已完整"的准确时刻，
    ///     正是协议 §3.3(b) 要的语义），engine 侧因此不再自行发一次。
    const LlmSinkAdapter = struct {
        inner: sink_mod.EventSink,
        fn emit(ctx: *anyopaque, ev: common.StreamEvent) anyerror!void {
            switch (ev) {
                .stream_request_start, .turn_complete => return,
                else => {},
            }
            const self: *LlmSinkAdapter = @ptrCast(@alignCast(ctx));
            try self.inner.send(ev);
        }
    };

    fn llmSink(self: *Session) llm.StreamSink {
        self.adapter = .{ .inner = self.sink };
        return .{ .ctx = &self.adapter, .emit = LlmSinkAdapter.emit };
    }
};

/// 从 settings 里取一个字符串键（不存在/类型不对 → 空串）。
fn settingsString(s: *const config.Settings, key: []const u8) []const u8 {
    const v = s.get(key) orelse return "";
    return v.asString() orelse "";
}

/// 上下文上限：settings 可覆盖，默认 200k。
fn settingsContextCeiling(s: *const config.Settings) i64 {
    if (s.get("contextWindow")) |v| {
        if (v.asInt()) |i| return i;
    }
    return 200_000;
}

fn classifyError(err: anyerror) common.ErrorCode {
    return switch (err) {
        error.Timeout, error.ConnectionResetByPeer, error.BrokenPipe => .transient,
        error.NotImplemented => .unknown,
        else => .unknown,
    };
}

const testing = std.testing;

test "loop: 会话能装配并 deinit（不触网）" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.heap.ArenaAllocator.init(testing.allocator);
    defer tmp.deinit();
    const a = tmp.allocator();
    const home = try std.fmt.allocPrint(a, "/tmp/zigent-loop-test-{s}", .{
        try util.io.randomHex(io, a, 6),
    });
    defer util.io.removeTree(io, home) catch {};

    const env = std.process.Environ.Map.init(testing.allocator);
    var paths = config.Paths{ .home = home, .cwd = "/repo" };
    var settings = config.Settings{ .permission_mode = .ask, .model = "mock-model" };
    var cancel = std.atomic.Value(bool).init(false);
    const rt = rt_mod.Rt{
        .gpa = a,
        .io = io,
        .env = &env,
        .cwd = "/repo",
        .home = home,
        .settings = &settings,
        .paths = &paths,
        .session_id = "sess-test",
        .cancel = &cancel,
        .logger = .{ .io = io, .min_level = .err },
    };

    var collecting = sink_mod.CollectingSink.init(a);
    const client = try llm.initMock(a, &.{});
    var session = try Session.init(a, rt, collecting.sink(), client, .{});
    defer session.deinit();

    // 没有 mock 脚本 → 流立即结束，不应 panic
    _ = session.submitMessage("你好") catch {};
}
