//! `client.zig` —— `Client` vtable（INTERFACES §4.2）+ 装饰器分层。
//!
//! ```text
//! ClientAdapter（§4.2 冻结 vtable）
//!   └─ Retrying      emittedOnAttempt 闸门 + 退避（Retry-After > 本地策略）
//!        └─ Routing  按 provider id 选路
//!             └─ ProviderAttempt / MockClient（Attempt vtable）
//!                  └─ http.Transport
//! ```
//!
//! ## 为什么内部还有一个 `Attempt` vtable
//!
//! §4.2 的 `Client.streamChat` 返回 `anyerror!StreamOutcome`，**错误里携带不了
//! 结构化的恢复信息**（status / error code / `Retry-After`）。重试层需要这些，
//! 所以内部再定义一层 `Attempt`：多一个 `err_out: *AttemptError` 出参。
//! 这是**内部扩展**，对外接口没有偏离 §4.2。
//!
//! ## 流式重试的唯一闸门（雷区 §F）
//!
//! `emittedOnAttempt`：本次尝试一旦向用户吐过**非 Error 事件**，就禁止重试。
//! `status`（心跳）与 `incremental_usage` 不算 emit —— 用
//! `common.StreamEvent.countsAsEmit()` 判定，只有那一个判据。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const common = @import("common");
const util = @import("util");
const llm = @import("root.zig");
const http = @import("http.zig");
const sse = @import("sse.zig");
const anthropic = @import("anthropic.zig");
const openai = @import("openai.zig");

// ─────────────────────────────────────────────────────────────────────────────
// Wire 选择
// ─────────────────────────────────────────────────────────────────────────────

pub const WireKind = enum {
    anthropic,
    openai,

    pub fn fromString(s: []const u8) WireKind {
        if (std.mem.eql(u8, s, "openai")) return .openai;
        return .anthropic;
    }

    /// mock 脚本没有显式 kind 时，从字节里嗅探（零网络）。
    pub fn detect(bytes: []const u8) WireKind {
        if (std.mem.indexOf(u8, bytes, "\"message_start\"") != null or
            std.mem.indexOf(u8, bytes, "\"content_block_delta\"") != null or
            std.mem.indexOf(u8, bytes, "\"message_stop\"") != null or
            std.mem.indexOf(u8, bytes, "event: message") != null)
        {
            return .anthropic;
        }
        return .openai;
    }

    pub fn endpoint(self: WireKind, arena: Allocator, base_url: []const u8) ![]u8 {
        return switch (self) {
            .anthropic => anthropic.messagesUrl(arena, base_url),
            .openai => openai.chatCompletionsUrl(arena, base_url),
        };
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 内部 Attempt vtable
// ─────────────────────────────────────────────────────────────────────────────

/// 一次尝试的失败元数据（`anyerror` 携带不了的恢复信息）。
pub const AttemptError = struct {
    status: ?u16 = null,
    code: common.ErrorCode = .unknown,
    message: []const u8 = "",
    /// 响应头 `Retry-After`（**优先级最高**）
    retry_after_ms: ?u64 = null,
};

pub const Attempt = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        attempt: *const fn (
            ptr: *anyopaque,
            io: Io,
            req: *const llm.ApiRequest,
            sink: llm.StreamSink,
            cancel: ?*const std.atomic.Value(bool),
            err_out: *AttemptError,
        ) anyerror!llm.StreamOutcome,
        deinit: *const fn (ptr: *anyopaque, gpa: Allocator) void,
    };

    pub fn run(
        self: Attempt,
        io: Io,
        req: *const llm.ApiRequest,
        sink: llm.StreamSink,
        cancel: ?*const std.atomic.Value(bool),
        err_out: *AttemptError,
    ) anyerror!llm.StreamOutcome {
        return self.vtable.attempt(self.ptr, io, req, sink, cancel, err_out);
    }

    pub fn deinit(self: Attempt, gpa: Allocator) void {
        self.vtable.deinit(self.ptr, gpa);
    }
};

fn noopDeinit(ptr: *anyopaque, gpa: Allocator) void {
    _ = ptr;
    _ = gpa;
}

// ─────────────────────────────────────────────────────────────────────────────
// 重试策略与闸门
// ─────────────────────────────────────────────────────────────────────────────

pub const RetryPolicy = struct {
    max_retries: u32 = 3,
    initial_delay_ms: u64 = 1_000,
    multiplier: f64 = 2.0,
    max_delay_ms: u64 = 30_000,
    jitter_ratio: f64 = 0.0,

    /// 传输层：对齐生产唯一在用的 `DEFAULT(3, 1s, ×2.0, cap 30s, jitter 0)`。
    pub const transport: RetryPolicy = .{};
    /// 恢复阶梯：cap 32s + 25% jitter（引擎层用；本层只保留语义）。
    pub const recovery: RetryPolicy = .{ .max_delay_ms = 32_000, .jitter_ratio = 0.25 };

    /// `attempt` 从 0 起。
    pub fn delayFor(self: RetryPolicy, attempt: u32) u64 {
        const base: f64 = @as(f64, @floatFromInt(self.initial_delay_ms)) *
            std.math.pow(f64, self.multiplier, @as(f64, @floatFromInt(attempt)));
        return @intFromFloat(@min(base, @as(f64, @floatFromInt(self.max_delay_ms))));
    }

    /// ★ `Retry-After` 响应头 > 异常携带 > 本地退避；仍受 cap 约束。
    pub fn delayForError(self: RetryPolicy, err: AttemptError, attempt: u32, io: Io) u64 {
        if (err.retry_after_ms) |ms| return @min(ms, self.max_delay_ms);
        const base = self.delayFor(attempt);
        if (self.jitter_ratio <= 0.0) return base;
        const jitter: u64 = @intFromFloat(@as(f64, @floatFromInt(base)) * self.jitter_ratio);
        if (jitter == 0) return base;
        var buf: [8]u8 = undefined;
        util.io.randomBytes(io, &buf);
        const r = std.mem.readInt(u64, &buf, .little);
        return @min(base - jitter + (r % (jitter * 2 + 1)), self.max_delay_ms);
    }
};

/// 一次尝试的可见性状态 —— retry 的**唯一闸门**。
pub const Gate = struct {
    emitted: bool = false,

    /// 只有「非 Error 事件且 countsAsEmit」才算 emit。心跳/`status` 不算。
    pub fn observe(self: *Gate, event: common.StreamEvent) void {
        if (event.countsAsEmit()) self.emitted = true;
    }

    pub fn mayRetry(self: *const Gate) bool {
        return !self.emitted;
    }

    pub fn reset(self: *Gate) void {
        self.emitted = false;
    }
};

const GateSink = struct {
    inner: llm.StreamSink,
    gate: *Gate,

    fn sink(self: *GateSink) llm.StreamSink {
        return .{ .ctx = self, .emit = emit };
    }

    fn emit(ctx: *anyopaque, ev: common.StreamEvent) anyerror!void {
        const self: *GateSink = @ptrCast(@alignCast(ctx));
        self.gate.observe(ev);
        try self.inner.send(ev);
    }
};

fn isCancelled(cancel: ?*const std.atomic.Value(bool)) bool {
    if (cancel) |c| return c.load(.acquire);
    return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// 运行配置
// ─────────────────────────────────────────────────────────────────────────────

const RunConfig = struct {
    kind: WireKind,
    api_key: []const u8 = "",
    user_agent: []const u8 = "zigent/0.1.0",
    send_thinking: bool = false,
    extra_body_json: ?[]const u8 = null,
    timeout_ms: u64 = 600_000,
};

fn buildHeaders(arena: Allocator, cfg: RunConfig) ![]const http.Header {
    var list: std.ArrayListUnmanaged(http.Header) = .empty;
    try list.append(arena, .{ .name = "content-type", .value = "application/json" });
    try list.append(arena, .{ .name = "accept", .value = "text/event-stream" });
    try list.append(arena, .{ .name = "user-agent", .value = cfg.user_agent });
    switch (cfg.kind) {
        .anthropic => {
            try list.append(arena, .{ .name = "x-api-key", .value = cfg.api_key });
            try list.append(arena, .{ .name = "anthropic-version", .value = anthropic.ANTHROPIC_VERSION });
        },
        .openai => {
            const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{cfg.api_key});
            try list.append(arena, .{ .name = "authorization", .value = auth });
        },
    }
    return list.items;
}

// ─────────────────────────────────────────────────────────────────────────────
// 一次尝试：读 body → SSE → StreamEvent
// ─────────────────────────────────────────────────────────────────────────────

const Mode = enum { unknown, sse, json };

const JSON_BODY_LIMIT = 256 * 1024;

const Parser = union(WireKind) {
    anthropic: anthropic.StreamParser,
    openai: openai.StreamParser,

    fn deinit(self: *Parser) void {
        switch (self.*) {
            .anthropic => self.anthropic.deinit(),
            .openai => self.openai.deinit(),
        }
    }
    fn handle(self: *Parser, data: []const u8, sink: llm.StreamSink) !bool {
        return switch (self.*) {
            .anthropic => self.anthropic.handle(data, sink),
            .openai => self.openai.handle(data, sink),
        };
    }
    fn finalize(self: *Parser, sink: llm.StreamSink, duration_ms: i64) !void {
        switch (self.*) {
            .anthropic => try self.anthropic.finalize(sink, duration_ms),
            .openai => try self.openai.finalize(sink, duration_ms),
        }
    }
    fn fillOutcome(self: *Parser, out: *llm.StreamOutcome) !void {
        switch (self.*) {
            .anthropic => try self.anthropic.fillOutcome(out),
            .openai => try self.openai.fillOutcome(out),
        }
    }
    fn failure(self: *Parser) ?Failure {
        return switch (self.*) {
            .anthropic => if (self.anthropic.failure) |f| .{ .code = f.code, .message = f.message } else null,
            .openai => if (self.openai.failure) |f| .{ .code = f.code, .message = f.message } else null,
        };
    }
};

const Failure = struct { code: common.ErrorCode, message: []const u8 };

const Session = struct {
    gpa: Allocator,
    arena: Allocator,
    model: []const u8,
    kind: WireKind,
    parser: Parser,
    decoder: sse.Decoder,
    outer: llm.StreamSink,

    status: u16 = 0,
    head_called: bool = false,
    ct_buf: [128]u8 = undefined,
    ct_len: usize = 0,
    retry_after_ms: ?u64 = null,
    request_id: []const u8 = "",
    mode: Mode = .unknown,
    probe: std.ArrayListUnmanaged(u8) = .empty,
    json_body: std.ArrayListUnmanaged(u8) = .empty,

    terminal: bool = false,
    emitted: bool = false,
    start_emitted: bool = false,
    drained_any: bool = false,

    fn init(gpa: Allocator, arena: Allocator, kind: WireKind, model: []const u8, outer: llm.StreamSink) Session {
        return .{
            .gpa = gpa,
            .arena = arena,
            .model = model,
            .kind = kind,
            .parser = switch (kind) {
                .anthropic => .{ .anthropic = anthropic.StreamParser.init(gpa, arena, model) },
                .openai => .{ .openai = openai.StreamParser.init(gpa, arena, model) },
            },
            .decoder = sse.Decoder.init(gpa),
            .outer = outer,
        };
    }

    fn deinit(self: *Session) void {
        self.parser.deinit();
        self.decoder.deinit();
        self.probe.deinit(self.gpa);
        self.json_body.deinit(self.gpa);
        self.* = undefined;
    }

    fn contentType(self: *const Session) []const u8 {
        return self.ct_buf[0..self.ct_len];
    }

    fn failure(self: *Session) ?Failure {
        return self.parser.failure();
    }

    fn tracked(self: *Session) llm.StreamSink {
        return .{ .ctx = self, .emit = trackedEmit };
    }

    fn trackedEmit(ctx: *anyopaque, ev: common.StreamEvent) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        if (ev.countsAsEmit()) self.emitted = true;
        try self.outer.send(ev);
    }

    fn emitStart(self: *Session) !void {
        if (self.start_emitted) return;
        self.start_emitted = true;
        try self.tracked().send(.{ .stream_request_start = .{
            .request_id = self.request_id,
            .model = self.model,
        } });
    }

    fn chunkSink(self: *Session) http.ChunkSink {
        return .{ .ctx = self, .on_head = onHead, .on_chunk = onChunk };
    }

    fn onHead(ctx: *anyopaque, head: *const http.Head) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        self.head_called = true;
        self.status = head.status;
        self.ct_len = @min(head.content_type.len, self.ct_buf.len);
        @memcpy(self.ct_buf[0..self.ct_len], head.content_type[0..self.ct_len]);
        self.retry_after_ms = head.retry_after_ms;
        if (head.request_id.len > 0) self.request_id = try self.arena.dupe(u8, head.request_id);

        if (head.status != 200) {
            self.mode = .json; // 错误体是有限的 JSON，允许缓冲
        } else if (std.mem.indexOf(u8, head.content_type, "text/event-stream") != null) {
            self.mode = .sse;
        } else if (std.mem.indexOf(u8, head.content_type, "json") != null) {
            self.mode = .json;
        } else {
            self.mode = .unknown; // 嗅探
        }
        if (self.mode == .sse) try self.emitStart();
    }

    fn onChunk(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(ctx));
        if (self.terminal) return; // 已收口：忽略尾随字节
        try self.feed(bytes);
    }

    fn feed(self: *Session, bytes: []const u8) !void {
        switch (self.mode) {
            .sse => try self.feedSse(bytes),
            .json => try self.feedJson(bytes),
            .unknown => {
                try self.probe.appendSlice(self.gpa, bytes);
                self.decideMode();
                switch (self.mode) {
                    .sse => {
                        const p = self.probe.items;
                        try self.feedSse(p);
                        self.probe.clearRetainingCapacity();
                    },
                    .json => {
                        const p = self.probe.items;
                        try self.feedJson(p);
                        self.probe.clearRetainingCapacity();
                    },
                    .unknown => {},
                }
            },
        }
    }

    fn decideMode(self: *Session) void {
        if (self.mode != .unknown) return;
        const t = std.mem.trimStart(u8, self.probe.items, " \t\r\n");
        if (t.len == 0) return;
        self.mode = if (t[0] == '{' or t[0] == '[') .json else .sse;
    }

    fn feedSse(self: *Session, bytes: []const u8) !void {
        try self.emitStart();
        try self.decoder.feed(bytes);
        try self.drain();
    }

    fn feedJson(self: *Session, bytes: []const u8) !void {
        if (self.json_body.items.len + bytes.len > JSON_BODY_LIMIT) return; // 截断但不失败
        try self.json_body.appendSlice(self.gpa, bytes);
    }

    fn drain(self: *Session) !void {
        while (self.decoder.next()) |ev| {
            self.drained_any = true;
            const term = try self.parser.handle(ev.data, self.tracked());
            if (term) {
                self.terminal = true;
                return;
            }
        }
    }
};

fn runOnce(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    cfg: RunConfig,
    transport: http.Transport,
    url: []const u8,
    req: *const llm.ApiRequest,
    sink: llm.StreamSink,
    cancel: ?*const std.atomic.Value(bool),
    err_out: *AttemptError,
) anyerror!llm.StreamOutcome {
    err_out.* = .{};
    if (isCancelled(cancel)) {
        err_out.* = .{ .code = .cancelled, .message = "request cancelled" };
        return error.Cancelled;
    }
    const start = util.io.monotonicMillis(io);

    const body = switch (cfg.kind) {
        .anthropic => try anthropic.buildRequestBody(arena, req, .{
            .stream = true,
            .send_thinking = cfg.send_thinking,
            .extra_body_json = cfg.extra_body_json,
        }),
        .openai => try openai.buildRequestBody(arena, req, .{
            .stream = true,
            .extra_body_json = cfg.extra_body_json,
        }),
    };
    const headers = try buildHeaders(arena, cfg);

    var session = Session.init(gpa, arena, cfg.kind, req.model, sink);
    defer session.deinit();

    const hreq = http.Request{
        .url = url,
        .headers = headers,
        .body = body,
        .timeout_ms = cfg.timeout_ms,
    };

    const send_result = transport.send(io, &hreq, session.chunkSink());

    // 无论成功失败，都把解码器里剩下的字节 flush 出来（A3）
    session.decoder.finish() catch {};
    session.drain() catch {};
    if (session.mode == .unknown and session.probe.items.len > 0) {
        session.mode = .json;
        session.feedJson(session.probe.items) catch {};
    }

    const duration = util.io.monotonicMillis(io) - start;

    if (isCancelled(cancel)) {
        err_out.* = .{ .code = .cancelled, .message = "request cancelled" };
        return error.Cancelled;
    }

    if (send_result) |_| {} else |_| {
        err_out.* = .{
            .status = if (session.head_called) session.status else null,
            .code = .transient,
            .message = "transport failure while streaming response",
            .retry_after_ms = session.retry_after_ms,
        };
        return error.ProviderFailure;
    }

    if (session.head_called and session.status != 200) {
        const raw: []const u8 = if (session.json_body.items.len > 0)
            session.json_body.items
        else
            session.contentType();
        const msg = try arena.dupe(u8, raw);
        err_out.* = .{
            .status = session.status,
            .code = common.error_code.classifyHttp(session.status, msg),
            .message = msg,
            .retry_after_ms = session.retry_after_ms,
        };
        return error.ProviderFailure;
    }

    // 200 + JSON body：兼容端点常见「200 但 body 里是 error」
    if (session.mode == .json) {
        if (openai.topLevelErrorEnvelope(arena, session.json_body.items)) |te| {
            err_out.* = .{
                .status = 200,
                .code = te.code,
                .message = te.message,
                .retry_after_ms = session.retry_after_ms,
            };
            return error.ProviderFailure;
        }
        err_out.* = .{
            .status = 200,
            .code = .transient,
            .message = try std.fmt.allocPrint(arena, "{s} (content-type: {s})", .{ sse.ERR_EMPTY_STREAM, session.contentType() }),
            .retry_after_ms = session.retry_after_ms,
        };
        return error.ProviderFailure;
    }

    if (session.failure()) |f| {
        err_out.* = .{
            .status = session.status,
            .code = f.code,
            .message = f.message,
            .retry_after_ms = session.retry_after_ms,
        };
        return error.ProviderFailure;
    }

    if (!session.terminal) {
        if (!session.drained_any) {
            // 零事件的 200：必须把 Content-Type 打出来
            err_out.* = .{
                .status = session.status,
                .code = .transient,
                .message = try std.fmt.allocPrint(arena, "{s} (content-type: {s})", .{ sse.ERR_EMPTY_STREAM, session.contentType() }),
                .retry_after_ms = session.retry_after_ms,
            };
        } else {
            const wording = switch (cfg.kind) {
                .anthropic => sse.ERR_ANTHROPIC_PREMATURE,
                .openai => sse.ERR_OPENAI_PREMATURE,
            };
            err_out.* = .{
                .status = session.status,
                .code = .stale_connection,
                .message = wording,
                .retry_after_ms = session.retry_after_ms,
            };
        }
        return error.ProviderFailure;
    }

    // 终态收口（发 tool_call + turn_complete）
    try session.parser.finalize(session.tracked(), duration);
    if (session.failure()) |f| {
        err_out.* = .{
            .status = session.status,
            .code = f.code,
            .message = f.message,
            .retry_after_ms = session.retry_after_ms,
        };
        return error.ProviderFailure;
    }

    var outcome = llm.StreamOutcome{};
    try session.parser.fillOutcome(&outcome);
    outcome.emitted = session.emitted;
    return outcome;
}

// ─────────────────────────────────────────────────────────────────────────────
// Retrying 装饰器
// ─────────────────────────────────────────────────────────────────────────────

pub const Retrying = struct {
    gpa: Allocator,
    inner: Attempt,
    policy: RetryPolicy = RetryPolicy.transport,
    /// 测试注入点：替代 `util.io.sleep`（策略里 jitter 为 0 时本就是确定性的）。
    sleep_fn: ?*const fn (Io, u64) anyerror!void = null,
    /// 最近一次错误文案的稳定副本（`err_out.message` 指向 attempt 的 arena）。
    err_buf: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *Retrying) void {
        self.err_buf.deinit(self.gpa);
    }

    pub fn attempt(self: *Retrying) Attempt {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Attempt.VTable{ .attempt = attemptImpl, .deinit = noopDeinit };

    fn rememberError(self: *Retrying, msg: []const u8) ![]const u8 {
        self.err_buf.clearRetainingCapacity();
        try self.err_buf.appendSlice(self.gpa, msg);
        return self.err_buf.items;
    }

    fn sleep(self: *Retrying, io: Io, ms: u64) anyerror!void {
        if (ms == 0) return;
        if (self.sleep_fn) |f| return f(io, ms);
        util.io.sleep(io, ms) catch return error.Cancelled;
    }

    fn attemptImpl(
        ptr: *anyopaque,
        io: Io,
        req: *const llm.ApiRequest,
        sink: llm.StreamSink,
        cancel: ?*const std.atomic.Value(bool),
        err_out: *AttemptError,
    ) anyerror!llm.StreamOutcome {
        const self: *Retrying = @ptrCast(@alignCast(ptr));

        var gate = Gate{};
        var gate_sink = GateSink{ .inner = sink, .gate = &gate };

        var attempt_no: u32 = 0;
        while (true) {
            if (isCancelled(cancel)) {
                err_out.* = .{ .code = .cancelled, .message = "request cancelled" };
                return error.Cancelled;
            }
            gate.reset();
            err_out.* = .{};
            const result = self.inner.run(io, req, gate_sink.sink(), cancel, err_out);
            if (result) |outcome| {
                var o = outcome;
                o.emitted = o.emitted or gate.emitted;
                return o;
            } else |err| {
                if (err == error.Cancelled) {
                    err_out.* = .{ .code = .cancelled, .message = "request cancelled" };
                    return error.Cancelled;
                }
                const msg = if (err_out.message.len > 0) err_out.message else "provider request failed";
                const stable = try self.rememberError(msg);

                // ★ 唯一闸门：吐过非 Error 事件 → 禁止重试
                if (!gate.mayRetry()) {
                    try sink.send(.{ .error_event = common.event.ErrorEvent.of(stable) });
                    return err;
                }

                const code = err_out.code;
                if (!code.retryable() or attempt_no >= self.policy.max_retries) {
                    try sink.send(.{ .error_event = common.event.ErrorEvent.terminalErr(stable, code.wireName()) });
                    return err;
                }

                const delay = self.policy.delayForError(err_out.*, attempt_no, io);
                try sink.send(.{ .error_event = common.event.ErrorEvent.retryable(
                    stable,
                    code.wireName(),
                    @intCast(attempt_no + 1),
                    @intCast(self.policy.max_retries),
                    @intCast(delay),
                ) });
                try self.sleep(io, delay);
                attempt_no += 1;
            }
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Routing 装饰器
// ─────────────────────────────────────────────────────────────────────────────

/// 按 provider id 选路。**拥有**注册进来的 `Attempt`（`deinit` 会级联释放）。
pub const Routing = struct {
    gpa: Allocator,
    routes: std.ArrayListUnmanaged(Route) = .empty,
    active: usize = 0,

    pub const Route = struct { id: []u8, target: Attempt };

    pub fn init(gpa: Allocator) Routing {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Routing) void {
        for (self.routes.items) |r| {
            self.gpa.free(r.id);
            r.target.deinit(self.gpa);
        }
        self.routes.deinit(self.gpa);
    }

    pub fn add(self: *Routing, id: []const u8, target: Attempt) !void {
        try self.routes.append(self.gpa, .{ .id = try self.gpa.dupe(u8, id), .target = target });
    }

    pub fn select(self: *Routing, id: []const u8) bool {
        for (self.routes.items, 0..) |r, i| {
            if (std.mem.eql(u8, r.id, id)) {
                self.active = i;
                return true;
            }
        }
        return false;
    }

    pub fn activeId(self: *const Routing) ?[]const u8 {
        if (self.routes.items.len == 0) return null;
        return self.routes.items[self.active].id;
    }

    pub fn attempt(self: *Routing) Attempt {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Attempt.VTable{ .attempt = attemptImpl, .deinit = noopDeinit };

    fn attemptImpl(
        ptr: *anyopaque,
        io: Io,
        req: *const llm.ApiRequest,
        sink: llm.StreamSink,
        cancel: ?*const std.atomic.Value(bool),
        err_out: *AttemptError,
    ) anyerror!llm.StreamOutcome {
        const self: *Routing = @ptrCast(@alignCast(ptr));
        if (self.routes.items.len == 0) {
            err_out.* = .{ .code = .invalid_model, .message = "no provider route registered" };
            return error.NoRoute;
        }
        return self.routes.items[self.active].target.run(io, req, sink, cancel, err_out);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 脚本化 Attempt（测试 / 选路用）
// ─────────────────────────────────────────────────────────────────────────────

pub const ScriptVerdict = enum { succeed, fail_retryable, fail_terminal, emit_then_fail };

pub const ScriptedAttempt = struct {
    gpa: Allocator,
    verdict: ScriptVerdict,
    code: common.ErrorCode = .transient,
    calls: usize = 0,

    pub fn create(gpa: Allocator, verdict: ScriptVerdict) !*ScriptedAttempt {
        const s = try gpa.create(ScriptedAttempt);
        s.* = .{ .gpa = gpa, .verdict = verdict };
        return s;
    }

    pub fn destroy(self: *ScriptedAttempt) void {
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn attempt(self: *ScriptedAttempt) Attempt {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Attempt.VTable{ .attempt = attemptImpl, .deinit = destroyImpl };

    fn destroyImpl(ptr: *anyopaque, gpa: Allocator) void {
        _ = gpa;
        const self: *ScriptedAttempt = @ptrCast(@alignCast(ptr));
        self.destroy();
    }

    fn attemptImpl(
        ptr: *anyopaque,
        io: Io,
        req: *const llm.ApiRequest,
        sink: llm.StreamSink,
        cancel: ?*const std.atomic.Value(bool),
        err_out: *AttemptError,
    ) anyerror!llm.StreamOutcome {
        _ = io;
        _ = req;
        _ = cancel;
        const self: *ScriptedAttempt = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        switch (self.verdict) {
            .succeed => return llm.StreamOutcome{ .text = "ok" },
            .fail_retryable, .fail_terminal => {
                err_out.* = .{ .status = 503, .code = self.code, .message = "scripted failure" };
                return error.ProviderFailure;
            },
            .emit_then_fail => {
                try sink.send(.{ .text_delta = .{ .text = "partial" } });
                err_out.* = .{ .status = 500, .code = self.code, .message = "stream broke after emit" };
                return error.ProviderFailure;
            },
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// MockClient（initMock）：零网络，走与真实路径完全相同的解析栈
// ─────────────────────────────────────────────────────────────────────────────

pub const MockClient = struct {
    gpa: Allocator,
    owned: []OwnedTurn,
    index: usize = 0,
    kind_override: ?WireKind = null,
    base_url: []const u8 = "mock://provider",
    last_path: ?[]const u8 = null,
    arena: std.heap.ArenaAllocator,
    /// 每次 attempt 都按固定尺寸切片喂入 —— 顺带覆盖 A7（分块）。
    chunk_size: usize = 5,

    pub const OwnedTurn = struct { sse: []u8, expect_path: ?[]u8 };

    pub fn init(gpa: Allocator, script: []const llm.MockTurn) !MockClient {
        const owned = try gpa.alloc(OwnedTurn, script.len);
        var filled: usize = 0;
        errdefer {
            for (owned[0..filled]) |t| {
                gpa.free(t.sse);
                if (t.expect_path) |p| gpa.free(p);
            }
            gpa.free(owned);
        }
        for (script, 0..) |t, i| {
            owned[i] = .{
                .sse = try gpa.dupe(u8, t.sse_bytes),
                .expect_path = if (t.expect_path) |p| try gpa.dupe(u8, p) else null,
            };
            filled = i + 1;
        }
        return .{ .gpa = gpa, .owned = owned, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *MockClient) void {
        for (self.owned) |t| {
            self.gpa.free(t.sse);
            if (t.expect_path) |p| self.gpa.free(p);
        }
        self.gpa.free(self.owned);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn attempt(self: *MockClient) Attempt {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Attempt.VTable{ .attempt = attemptImpl, .deinit = noopDeinit };

    fn attemptImpl(
        ptr: *anyopaque,
        io: Io,
        req: *const llm.ApiRequest,
        sink: llm.StreamSink,
        cancel: ?*const std.atomic.Value(bool),
        err_out: *AttemptError,
    ) anyerror!llm.StreamOutcome {
        const self: *MockClient = @ptrCast(@alignCast(ptr));
        if (self.owned.len == 0) return error.MockScriptExhausted;
        const i = @min(self.index, self.owned.len - 1);
        self.index += 1;
        const turn = self.owned[i];

        const kind = self.kind_override orelse WireKind.detect(turn.sse);
        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();

        const url = try kind.endpoint(arena, self.base_url);
        const path = http.urlPath(url);
        self.last_path = path;
        if (turn.expect_path) |want| {
            if (!std.mem.eql(u8, want, path)) {
                err_out.* = .{ .code = .unknown, .message = "mock: unexpected request path" };
                return error.ExpectPathMismatch;
            }
        }

        var transport = http.MockTransport.init(self.gpa, &.{.{
            .status = 200,
            .content_type = "text/event-stream",
            .body = turn.sse,
            .chunk_size = self.chunk_size,
        }});
        defer transport.deinit();

        const cfg = RunConfig{ .kind = kind };
        return runOnce(self.gpa, arena, io, cfg, transport.transport(), url, req, sink, cancel, err_out);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Client 适配器 + 句柄（§4.2 的唯一出口）
// ─────────────────────────────────────────────────────────────────────────────

pub const ClientAdapter = struct {
    attempt: Attempt,
    gpa: Allocator,
    on_deinit: ?*const fn (self: *ClientAdapter) void = null,

    pub fn client(self: *ClientAdapter) llm.Client {
        return .{ .ptr = self, .gpa = self.gpa, .vtable = &vtable };
    }

    const vtable = llm.Client.VTable{ .streamChat = streamChatImpl, .deinit = deinitImpl };

    fn streamChatImpl(
        ptr: *anyopaque,
        io: Io,
        req: *const llm.ApiRequest,
        sink: llm.StreamSink,
        cancel: ?*const std.atomic.Value(bool),
    ) anyerror!llm.StreamOutcome {
        const self: *ClientAdapter = @ptrCast(@alignCast(ptr));
        var err = AttemptError{};
        return self.attempt.run(io, req, sink, cancel, &err);
    }

    fn deinitImpl(ptr: *anyopaque, gpa: Allocator) void {
        _ = gpa;
        const self: *ClientAdapter = @ptrCast(@alignCast(ptr));
        if (self.on_deinit) |f| f(self);
    }
};

const OwnedConfig = struct {
    gpa: Allocator,
    kind: []u8,
    base_url: []u8,
    api_key: []u8,
    model: []u8,
    user_agent: []u8,
    extra_body_json: ?[]u8,
    send_thinking: bool,
    max_retries: u32,
    timeout_ms: u64,

    fn init(gpa: Allocator, cfg: llm.ProviderConfig) !OwnedConfig {
        const kind = try gpa.dupe(u8, cfg.kind);
        errdefer gpa.free(kind);
        const base_url = try gpa.dupe(u8, cfg.base_url);
        errdefer gpa.free(base_url);
        const api_key = try gpa.dupe(u8, cfg.api_key);
        errdefer gpa.free(api_key);
        const model = try gpa.dupe(u8, cfg.model);
        errdefer gpa.free(model);
        const user_agent = try gpa.dupe(u8, cfg.user_agent);
        errdefer gpa.free(user_agent);
        const extra = if (cfg.extra_body_json) |x| try gpa.dupe(u8, x) else null;
        return .{
            .gpa = gpa,
            .kind = kind,
            .base_url = base_url,
            .api_key = api_key,
            .model = model,
            .user_agent = user_agent,
            .extra_body_json = extra,
            .send_thinking = cfg.send_thinking,
            .max_retries = cfg.max_retries,
            .timeout_ms = cfg.timeout_ms,
        };
    }

    fn deinit(self: *OwnedConfig) void {
        self.gpa.free(self.kind);
        self.gpa.free(self.base_url);
        self.gpa.free(self.api_key);
        self.gpa.free(self.model);
        self.gpa.free(self.user_agent);
        if (self.extra_body_json) |x| self.gpa.free(x);
    }
};

const ProviderAttempt = struct {
    cfg: *const OwnedConfig,
    transport: http.Transport,
    arena: std.heap.ArenaAllocator,

    fn attempt(self: *ProviderAttempt) Attempt {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Attempt.VTable{ .attempt = attemptImpl, .deinit = noopDeinit };

    fn attemptImpl(
        ptr: *anyopaque,
        io: Io,
        req: *const llm.ApiRequest,
        sink: llm.StreamSink,
        cancel: ?*const std.atomic.Value(bool),
        err_out: *AttemptError,
    ) anyerror!llm.StreamOutcome {
        const self: *ProviderAttempt = @ptrCast(@alignCast(ptr));
        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();
        const kind = WireKind.fromString(self.cfg.kind);
        const url = try kind.endpoint(arena, self.cfg.base_url);
        const cfg = RunConfig{
            .kind = kind,
            .api_key = self.cfg.api_key,
            .user_agent = self.cfg.user_agent,
            .send_thinking = self.cfg.send_thinking,
            .extra_body_json = self.cfg.extra_body_json,
            .timeout_ms = self.cfg.timeout_ms,
        };
        return runOnce(self.cfg.gpa, arena, io, cfg, self.transport, url, req, sink, cancel, err_out);
    }
};

// ── 真实 provider 句柄 ───────────────────────────────────────────────────────

const RealHandle = struct {
    gpa: Allocator,
    cfg: OwnedConfig,
    http_transport: http.HttpTransport,
    provider: ProviderAttempt,
    retrying: Retrying,
    adapter: ClientAdapter,

    fn destroy(self: *RealHandle) void {
        const gpa = self.gpa;
        self.retrying.deinit();
        self.provider.arena.deinit();
        self.http_transport.deinit();
        self.cfg.deinit();
        gpa.destroy(self);
    }

    fn onAdapterDeinit(adapter: *ClientAdapter) void {
        const self: *RealHandle = @fieldParentPtr("adapter", adapter);
        self.destroy();
    }
};

/// 真实 HTTP（`std.http.Client`；网络层在 `http.zig` 的 `Transport` 后面）。
pub fn initProvider(gpa: Allocator, io: Io, cfg: llm.ProviderConfig) !llm.Client {
    _ = io; // 每次 attempt 由 vtable 传入 io；这里仅保持签名与 §4.2 一致
    const h = try gpa.create(RealHandle);
    errdefer gpa.destroy(h);
    h.gpa = gpa;
    h.cfg = try OwnedConfig.init(gpa, cfg);
    errdefer h.cfg.deinit();
    h.http_transport = http.HttpTransport.init(gpa);
    h.provider = .{
        .cfg = &h.cfg,
        .transport = h.http_transport.transport(),
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    h.retrying = .{
        .gpa = gpa,
        .inner = h.provider.attempt(),
        .policy = .{ .max_retries = cfg.max_retries },
    };
    h.adapter = .{
        .attempt = h.retrying.attempt(),
        .gpa = gpa,
        .on_deinit = RealHandle.onAdapterDeinit,
    };
    return h.adapter.client();
}

// ── Mock 句柄 ────────────────────────────────────────────────────────────────

const MockHandle = struct {
    gpa: Allocator,
    mock: MockClient,
    adapter: ClientAdapter,

    fn destroy(self: *MockHandle) void {
        const gpa = self.gpa;
        self.mock.deinit();
        gpa.destroy(self);
    }

    fn onAdapterDeinit(adapter: *ClientAdapter) void {
        const self: *MockHandle = @fieldParentPtr("adapter", adapter);
        self.destroy();
    }
};

/// 测试用，**零网络**。
pub fn initMock(gpa: Allocator, script: []const llm.MockTurn) !llm.Client {
    const h = try gpa.create(MockHandle);
    errdefer gpa.destroy(h);
    h.gpa = gpa;
    h.mock = try MockClient.init(gpa, script);
    errdefer h.mock.deinit();
    h.adapter = .{
        .attempt = h.mock.attempt(),
        .gpa = gpa,
        .on_deinit = MockHandle.onAdapterDeinit,
    };
    return h.adapter.client();
}

/// 显式指定 wire 的 mock（默认按字节嗅探）。
pub fn initMockFor(gpa: Allocator, kind: WireKind, script: []const llm.MockTurn) !llm.Client {
    const h = try gpa.create(MockHandle);
    errdefer gpa.destroy(h);
    h.gpa = gpa;
    h.mock = try MockClient.init(gpa, script);
    h.mock.kind_override = kind;
    errdefer h.mock.deinit();
    h.adapter = .{
        .attempt = h.mock.attempt(),
        .gpa = gpa,
        .on_deinit = MockHandle.onAdapterDeinit,
    };
    return h.adapter.client();
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// 测试用真实 Io（只用于取时间戳 / sleep）；Retrying 另注入 sleep_fn。
/// `Threaded` 必须活在稳定地址上，所以放堆上、测试结束不回收。
var g_threaded: ?*std.Io.Threaded = null;

fn testIo() Io {
    if (g_threaded == null) {
        // 用 page_allocator：这是测试基建，不该被 testing.allocator 记成泄漏
        const pa = std.heap.page_allocator;
        const t = pa.create(std.Io.Threaded) catch @panic("OOM");
        t.* = std.Io.Threaded.init(pa, .{});
        g_threaded = t;
    }
    return g_threaded.?.io();
}

const EventLog = struct {
    gpa: Allocator,
    events: std.ArrayListUnmanaged(common.StreamEvent) = .empty,

    fn init(gpa: Allocator) EventLog {
        return .{ .gpa = gpa };
    }
    fn deinit(self: *EventLog) void {
        self.events.deinit(self.gpa);
    }
    fn sink(self: *EventLog) llm.StreamSink {
        return .{ .ctx = self, .emit = emit };
    }
    fn emit(ctx: *anyopaque, ev: common.StreamEvent) anyerror!void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        try self.events.append(self.gpa, ev);
    }
    fn tags(self: *const EventLog, out: *std.ArrayListUnmanaged([]const u8)) !void {
        for (self.events.items) |e| try out.append(self.gpa, e.wireTag());
    }
    fn count(self: *const EventLog, comptime tag: std.meta.Tag(common.StreamEvent)) usize {
        var n: usize = 0;
        for (self.events.items) |e| {
            if (std.meta.activeTag(e) == tag) n += 1;
        }
        return n;
    }
};

var sleep_calls: usize = 0;
var sleep_total_ms: u64 = 0;

fn fakeSleep(io: Io, ms: u64) anyerror!void {
    _ = io;
    sleep_calls += 1;
    sleep_total_ms += ms;
}

test "client: RetryPolicy 退避序列（1s, 2s, 4s, cap 30s）" {
    const p = RetryPolicy.transport;
    try testing.expectEqual(@as(u64, 1_000), p.delayFor(0));
    try testing.expectEqual(@as(u64, 2_000), p.delayFor(1));
    try testing.expectEqual(@as(u64, 4_000), p.delayFor(2));
    try testing.expectEqual(@as(u64, 8_000), p.delayFor(3));
    try testing.expectEqual(@as(u64, 16_000), p.delayFor(4));
    try testing.expectEqual(@as(u64, 30_000), p.delayFor(5));
    try testing.expectEqual(@as(u64, 30_000), p.delayFor(40));

    // Retry-After 优先，且仍受 cap
    const err = AttemptError{ .code = .rate_limited, .message = "slow", .retry_after_ms = 7_000 };
    try testing.expectEqual(@as(u64, 7_000), p.delayForError(err, 0, testIo()));
    const huge = AttemptError{ .code = .rate_limited, .message = "", .retry_after_ms = 999_999 };
    try testing.expectEqual(@as(u64, 30_000), p.delayForError(huge, 0, testIo()));
    // 无 Retry-After → 本地退避
    const plain = AttemptError{ .code = .transient, .message = "" };
    try testing.expectEqual(@as(u64, 1_000), p.delayForError(plain, 0, testIo()));
}

test "client: Gate —— 只有非 Error 事件算 emit（心跳不算）" {
    var g = Gate{};
    g.observe(.{ .status = .{ .message = "ping" } });
    try testing.expect(g.mayRetry());
    g.observe(.{ .incremental_usage = .{} });
    try testing.expect(g.mayRetry());
    g.observe(.{ .stream_request_start = .{ .request_id = "", .model = "m" } });
    try testing.expect(g.mayRetry());
    g.observe(.{ .error_event = common.event.ErrorEvent.of("x") });
    try testing.expect(g.mayRetry());
    g.observe(.{ .text_delta = .{ .text = "hi" } });
    try testing.expect(!g.mayRetry());
    g.reset();
    try testing.expect(g.mayRetry());
}

test "client: 可重试错误重试 max_retries 次（无 emit）" {
    const gpa = testing.allocator;
    const s = try ScriptedAttempt.create(gpa, .fail_retryable);
    defer s.destroy();
    s.code = .rate_limited;

    var r = Retrying{ .gpa = gpa, .inner = s.attempt(), .policy = .{ .max_retries = 2 }, .sleep_fn = fakeSleep };
    defer r.deinit();

    sleep_calls = 0;
    sleep_total_ms = 0;

    var log = EventLog.init(gpa);
    defer log.deinit();

    var err = AttemptError{};
    const res = r.attempt().run(testIo(), &.{ .model = "m", .system = "", .messages = &.{} }, log.sink(), null, &err);
    try testing.expectError(error.ProviderFailure, res);

    try testing.expectEqual(@as(usize, 3), s.calls); // 1 + 2 retries
    try testing.expectEqual(@as(usize, 2), sleep_calls);
    try testing.expectEqual(@as(u64, 1_000 + 2_000), sleep_total_ms); // ×2.0
    // 2 次 retryable + 1 次耗尽后的 terminal
    try testing.expectEqual(@as(usize, 3), log.count(.error_event));
    try testing.expect(!log.events.items[0].error_event.terminal);
    try testing.expect(log.events.items[log.events.items.len - 1].error_event.terminal);
}

test "client: 不可重试错误只尝试一次并 terminal" {
    const gpa = testing.allocator;
    const s = try ScriptedAttempt.create(gpa, .fail_terminal);
    defer s.destroy();
    s.code = .authentication;

    var r = Retrying{ .gpa = gpa, .inner = s.attempt(), .policy = .{ .max_retries = 3 }, .sleep_fn = fakeSleep };
    defer r.deinit();

    var log = EventLog.init(gpa);
    defer log.deinit();
    var err = AttemptError{};
    const res = r.attempt().run(testIo(), &.{ .model = "m", .system = "", .messages = &.{} }, log.sink(), null, &err);
    try testing.expectError(error.ProviderFailure, res);
    try testing.expectEqual(@as(usize, 1), s.calls);
    try testing.expectEqual(@as(usize, 1), log.count(.error_event));
    try testing.expect(log.events.items[0].error_event.terminal);
}

test "client: 吐过非 Error 事件后禁止重试（流式重试的唯一闸门）" {
    const gpa = testing.allocator;
    const s = try ScriptedAttempt.create(gpa, .emit_then_fail);
    defer s.destroy();
    s.code = .transient;

    var r = Retrying{ .gpa = gpa, .inner = s.attempt(), .policy = .{ .max_retries = 3 }, .sleep_fn = fakeSleep };
    defer r.deinit();

    sleep_calls = 0;
    var log = EventLog.init(gpa);
    defer log.deinit();
    var err = AttemptError{};
    const res = r.attempt().run(testIo(), &.{ .model = "m", .system = "", .messages = &.{} }, log.sink(), null, &err);
    try testing.expectError(error.ProviderFailure, res);

    // 只试一次：text_delta 已经吐出去了
    try testing.expectEqual(@as(usize, 1), s.calls);
    try testing.expectEqual(@as(usize, 0), sleep_calls);
    try testing.expectEqual(@as(usize, 1), log.count(.text_delta));
    try testing.expectEqual(@as(usize, 1), log.count(.error_event));
}

test "client: 重试耗尽且全程 emit 后回来的 ErrorEvent 不再是 retry 形态" {
    const gpa = testing.allocator;
    const s = try ScriptedAttempt.create(gpa, .emit_then_fail);
    defer s.destroy();
    var r = Retrying{ .gpa = gpa, .inner = s.attempt(), .sleep_fn = fakeSleep };
    defer r.deinit();
    var log = EventLog.init(gpa);
    defer log.deinit();
    var err = AttemptError{};
    _ = r.attempt().run(testIo(), &.{ .model = "m", .system = "", .messages = &.{} }, log.sink(), null, &err) catch {};
    const ev = log.events.items[log.events.items.len - 1].error_event;
    try testing.expectEqual(@as(i32, 0), ev.retry_attempt);
    try testing.expect(!ev.terminal);
}

test "client: Routing 选路" {
    const gpa = testing.allocator;
    const a = try ScriptedAttempt.create(gpa, .succeed);
    const b = try ScriptedAttempt.create(gpa, .succeed);
    var routing = Routing.init(gpa);
    defer routing.deinit();
    try routing.add("anthropic", a.attempt());
    try routing.add("openai", b.attempt());

    try testing.expect(routing.select("openai"));
    try testing.expectEqualStrings("openai", routing.activeId().?);
    try testing.expect(!routing.select("nope"));

    var log = EventLog.init(gpa);
    defer log.deinit();
    var err = AttemptError{};
    const out = try routing.attempt().run(testIo(), &.{ .model = "m", .system = "", .messages = &.{} }, log.sink(), null, &err);
    try testing.expectEqualStrings("ok", out.text);
    try testing.expectEqual(@as(usize, 1), b.calls);
    try testing.expectEqual(@as(usize, 0), a.calls);
}

test "client: initMock 完整 Anthropic 流（含 chunk 切分）" {
    const gpa = testing.allocator;
    const stream =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_7\",\"usage\":{\"input_tokens\":10,\"output_tokens\":1}}}\n\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi \"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"there\"}}\n\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Read\",\"input\":{}}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"file_path\\\":\\\"/x\\\"}\"}}\n\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":5}}\n\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";

    const c = try initMock(gpa, &.{.{ .sse_bytes = stream, .expect_path = "/v1/messages" }});
    defer c.deinit();

    var log = EventLog.init(gpa);
    defer log.deinit();

    const outcome = try c.streamChat(testIo(), &.{ .model = "claude-sonnet-4", .system = "", .messages = &.{} }, log.sink(), null);

    var want = std.ArrayListUnmanaged([]const u8).empty;
    defer want.deinit(gpa);
    try want.appendSlice(gpa, &.{ "stream_request_start", "text_delta", "text_delta", "tool_call", "turn_complete" });
    try testing.expectEqual(want.items.len, log.events.items.len);
    for (want.items, 0..) |w, i| try testing.expectEqualStrings(w, log.events.items[i].wireTag());

    try testing.expectEqualStrings("hi there", outcome.text);
    try testing.expectEqual(@as(usize, 1), outcome.tool_calls.len);
    try testing.expectEqualStrings("{\"file_path\":\"/x\"}", outcome.tool_calls[0].input);
    try testing.expectEqualStrings("msg_7", outcome.request_id);
    try testing.expect(outcome.emitted);
    try testing.expectEqual(common.StopReason.end_turn, outcome.stop_reason);
}

test "client: initMock 完整 OpenAI 流" {
    const gpa = testing.allocator;
    const stream =
        "data: {\"id\":\"chatcmpl-9\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hello\"}}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-9\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_9\",\"function\":{\"name\":\"Bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}]}}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-9\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":50,\"completion_tokens\":7,\"prompt_tokens_details\":{\"cached_tokens\":20}}}\n\n" ++
        "data: [DONE]\n\n";

    const c = try initMock(gpa, &.{.{ .sse_bytes = stream, .expect_path = "/v1/chat/completions" }});
    defer c.deinit();

    var log = EventLog.init(gpa);
    defer log.deinit();
    const outcome = try c.streamChat(testIo(), &.{ .model = "gpt-4o", .system = "", .messages = &.{} }, log.sink(), null);

    var want = std.ArrayListUnmanaged([]const u8).empty;
    defer want.deinit(gpa);
    try want.appendSlice(gpa, &.{ "stream_request_start", "text_delta", "tool_call", "turn_complete" });
    try testing.expectEqual(want.items.len, log.events.items.len);
    for (want.items, 0..) |w, i| try testing.expectEqualStrings(w, log.events.items[i].wireTag());

    try testing.expectEqualStrings("hello", outcome.text);
    try testing.expectEqualStrings("call_9", outcome.tool_calls[0].tool_use_id);
    try testing.expectEqual(@as(i64, 30), outcome.usage.input_tokens);
    try testing.expectEqual(@as(i64, 20), outcome.usage.cache_read_tokens);
}

test "client: initMock 的 expect_path 不符会失败（断言请求形状）" {
    const gpa = testing.allocator;
    const c = try initMock(gpa, &.{.{ .sse_bytes = "data: [DONE]\n\n", .expect_path = "/wrong" }});
    defer c.deinit();
    var log = EventLog.init(gpa);
    defer log.deinit();
    try testing.expectError(
        error.ExpectPathMismatch,
        c.streamChat(testIo(), &.{ .model = "m", .system = "", .messages = &.{} }, log.sink(), null),
    );
}

test "client: Anthropic 提前断流 → 逐字文案且可重试" {
    const gpa = testing.allocator;
    const partial = "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"half\"}}\n\n";
    var transport = http.MockTransport.init(gpa, &.{.{
        .status = 200,
        .content_type = "text/event-stream",
        .body = partial,
    }});
    defer transport.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var log = EventLog.init(gpa);
    defer log.deinit();
    var err = AttemptError{};
    const res = runOnce(gpa, arena, testIo(), .{ .kind = .anthropic }, transport.transport(), "https://x/v1/messages", &.{ .model = "m", .system = "", .messages = &.{} }, log.sink(), null, &err);
    try testing.expectError(error.ProviderFailure, res);
    try testing.expectEqualStrings(sse.ERR_ANTHROPIC_PREMATURE, err.message);
    try testing.expectEqual(common.ErrorCode.stale_connection, err.code);
    try testing.expect(err.code.retryable());
}

test "client: OpenAI 提前断流 → 逐字文案" {
    const gpa = testing.allocator;
    const partial = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"half\"}}]}\n\n";
    var transport = http.MockTransport.init(gpa, &.{.{
        .status = 200,
        .content_type = "text/event-stream",
        .body = partial,
    }});
    defer transport.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var log = EventLog.init(gpa);
    defer log.deinit();
    var err = AttemptError{};
    const res = runOnce(gpa, arena_state.allocator(), testIo(), .{ .kind = .openai }, transport.transport(), "https://x/v1/chat/completions", &.{ .model = "m", .system = "", .messages = &.{} }, log.sink(), null, &err);
    try testing.expectError(error.ProviderFailure, res);
    try testing.expectEqualStrings(sse.ERR_OPENAI_PREMATURE, err.message);
    try testing.expectEqual(common.ErrorCode.stale_connection, err.code);
}

test "client: HTTP 401 → authentication（不可重试）+ Retry-After 透传" {
    const gpa = testing.allocator;
    var transport = http.MockTransport.init(gpa, &.{.{
        .status = 401,
        .content_type = "application/json",
        .retry_after_ms = 3_000,
        .body = "{\"error\":{\"message\":\"invalid api key\"}}",
    }});
    defer transport.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var log = EventLog.init(gpa);
    defer log.deinit();
    var err = AttemptError{};
    const res = runOnce(gpa, arena_state.allocator(), testIo(), .{ .kind = .openai }, transport.transport(), "https://x/v1/chat/completions", &.{ .model = "m", .system = "", .messages = &.{} }, log.sink(), null, &err);
    try testing.expectError(error.ProviderFailure, res);
    try testing.expectEqual(@as(?u16, 401), err.status);
    try testing.expectEqual(common.ErrorCode.authentication, err.code);
    try testing.expect(!err.code.retryable());
    try testing.expectEqual(@as(?u64, 3_000), err.retry_after_ms);
}

test "client: HTTP 200 但 body 是 error 信封 → 失败（不当成空回复）" {
    const gpa = testing.allocator;
    var transport = http.MockTransport.init(gpa, &.{.{
        .status = 200,
        .content_type = "application/json",
        .body = "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}",
    }});
    defer transport.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var log = EventLog.init(gpa);
    defer log.deinit();
    var err = AttemptError{};
    const res = runOnce(gpa, arena_state.allocator(), testIo(), .{ .kind = .openai }, transport.transport(), "https://x/v1/chat/completions", &.{ .model = "m", .system = "", .messages = &.{} }, log.sink(), null, &err);
    try testing.expectError(error.ProviderFailure, res);
    try testing.expectEqual(common.ErrorCode.rate_limited, err.code);
    try testing.expectEqualStrings("slow down", err.message);
}

test "client: 零事件的 200 报 empty stream 且带 content-type" {
    const gpa = testing.allocator;
    var transport = http.MockTransport.init(gpa, &.{.{
        .status = 200,
        .content_type = "text/event-stream",
        .body = "",
    }});
    defer transport.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var log = EventLog.init(gpa);
    defer log.deinit();
    var err = AttemptError{};
    const res = runOnce(gpa, arena_state.allocator(), testIo(), .{ .kind = .anthropic }, transport.transport(), "https://x/v1/messages", &.{ .model = "m", .system = "", .messages = &.{} }, log.sink(), null, &err);
    try testing.expectError(error.ProviderFailure, res);
    try testing.expect(std.mem.indexOf(u8, err.message, "empty stream") != null);
    try testing.expect(std.mem.indexOf(u8, err.message, "text/event-stream") != null);
}

test "client: 取消路径不重试" {
    const gpa = testing.allocator;
    var flag = std.atomic.Value(bool).init(true);
    const s = try ScriptedAttempt.create(gpa, .fail_retryable);
    defer s.destroy();
    var r = Retrying{ .gpa = gpa, .inner = s.attempt(), .sleep_fn = fakeSleep };
    defer r.deinit();
    var log = EventLog.init(gpa);
    defer log.deinit();
    var err = AttemptError{};
    try testing.expectError(error.Cancelled, r.attempt().run(testIo(), &.{ .model = "m", .system = "", .messages = &.{} }, log.sink(), &flag, &err));
    try testing.expectEqual(@as(usize, 0), s.calls);
    try testing.expectEqual(common.ErrorCode.cancelled, err.code);
}

test "client: initProvider 真实路径可构造并释放" {
    const gpa = testing.allocator;
    const c = try initProvider(gpa, testIo(), .{
        .kind = "openai",
        .base_url = "https://api.deepseek.com",
        .api_key = "sk-test",
        .model = "deepseek-chat",
    });
    defer c.deinit();
    // 只验证生命周期可构造/可释放（真实网络调用不在单测范围）
    try testing.expect(@intFromPtr(c.ptr) != 0);
}
