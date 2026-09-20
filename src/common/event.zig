//! `StreamEvent`（union·33）—— L0 契约层，**唯一真源**。
//!
//! - 核心 19 种：客户端渲染必需，首期必须产出；
//! - 扩展 14 种：hook/task/agent/file 等，**类型先占位**，产出可后置。
//!
//! 收益（P1）：`switch` 必须穷尽 → 加第 34 种时编译器列出所有待改位置。
//! `error` 是 Zig 关键字 → union tag 用 `error_event`，但 **`wireTag` 必须返回 `"error"`**。
//!
//! ⚠️ wire 字段名以 `06-对外协议.md` §3.2 / 附录为准（事件面是 snake_case 契约；
//! `ContentBlock`/`Message` 面是 camelCase 契约 —— 两者属于不同平面，不要互相"统一"）。

const std = @import("std");
const json = @import("json.zig");
const msg = @import("message.zig");
const usage_mod = @import("usage.zig");
const ec = @import("error_code.zig");

pub const Usage = usage_mod.Usage;
pub const Message = msg.Message;
pub const ErrorCode = ec.ErrorCode;
pub const ErrorSource = ec.ErrorSource;
pub const TrajectoryOutcome = ec.TrajectoryOutcome;
pub const StopReason = ec.StopReason;

pub const FileChange = struct { path: []const u8, chars_added: i32, chars_removed: i32 };
pub const FileSnapshot = struct { path: []const u8, action: []const u8, hash: []const u8 };

// ── 核心 19 种的逐字段结构 ───────────────────────────────────────────────────

pub const ToolCallEvent = struct {
    tool_use_id: []const u8,
    tool_name: []const u8,
    /// ★ 原始 JSON 字符串（不变量 I1）
    input: []const u8,
    index: i32 = 0,
    start_time_ms: i64 = 0,
};

pub const ToolProgressEvent = struct {
    tool_use_id: []const u8,
    tool_name: []const u8,
    parent_tool_use_id: ?[]const u8 = null,
    elapsed_time_seconds: f64 = 0,
    task_id: ?[]const u8 = null,
    message: ?[]const u8 = null,
    percent: ?f64 = null,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    structured: json.Map = .{},
};

pub const ToolResultEvent = struct {
    tool_use_id: []const u8,
    output: []const u8,
    is_error: bool,
    duration_ms: i64 = 0,
    error_code: ?[]const u8 = null,
    error_message: ?[]const u8 = null,

    /// 失败且无 code → 兜底 `"unknown"`。
    pub fn effectiveErrorCode(self: ToolResultEvent) ?[]const u8 {
        if (!self.is_error) return null;
        return self.error_code orelse "unknown";
    }
};

pub const TurnCompleteEvent = struct {
    usage: Usage = .{},
    stop_reason: []const u8 = "end_turn",
    request_id: []const u8 = "",
    duration_ms: i64 = 0,
    payload_ref: ?[]const u8 = null,
    assistant_properties: json.Map = .{},
};

pub const StreamRequestStartEvent = struct {
    request_id: []const u8,
    model: []const u8,
    query_source: []const u8 = "",
    turn_index: i32 = 0,
    model_ref: ?[]const u8 = null,
    provider_id: []const u8 = "",
    resolved_model: []const u8 = "",
    temperature: ?f64 = null,
    max_tokens: i64 = 0,
    system_prompt_tokens: i64 = 0,
    payload_ref: ?[]const u8 = null,
    budget_snapshot: json.Map = .{},
};

pub const CompactBoundaryEvent = struct {
    kind: []const u8,
    before_messages: i32,
    after_messages: i32,
    reason: []const u8,
    tokens_before: i64,
    tokens_after: i64,
    preserved_segment: ?[]const u8 = null,
    metadata: json.Map = .{},
};

pub const TombstoneEvent = struct {
    target_uuid: []const u8,
    reason: []const u8,
    replacement_uuid: ?[]const u8 = null,
};

pub const ErrorEvent = struct {
    message: []const u8,
    error_code: []const u8 = "unknown",
    retry_attempt: i32 = 0,
    max_retries: i32 = 0,
    retry_delay_ms: i64 = 0,
    terminal: bool = false,
    session_id: []const u8 = "",
    request_id: []const u8 = "",
    source: ErrorSource = .execution,

    pub fn of(message: []const u8) ErrorEvent {
        return .{ .message = message, .error_code = "unknown", .source = .execution };
    }

    pub fn terminalErr(message: []const u8, code: []const u8) ErrorEvent {
        return .{ .message = message, .error_code = code, .terminal = true, .source = .execution };
    }

    pub fn retryable(
        message: []const u8,
        code: []const u8,
        attempt: i32,
        max: i32,
        delay_ms: i64,
    ) ErrorEvent {
        return .{
            .message = message,
            .error_code = code,
            .retry_attempt = attempt,
            .max_retries = max,
            .retry_delay_ms = delay_ms,
            .terminal = false,
        };
    }
};

pub const AttachmentEvent = struct {
    attachment_type: []const u8,
    payload: json.Map = .{},
    severity: []const u8 = "info",
    dedupe_key: ?[]const u8 = null,
};

pub const IncrementalUsageEvent = struct {
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    cache_read_tokens: i64 = 0,
    cache_creation_tokens: i64 = 0,
};

pub const SessionStartedEvent = struct {
    session_id: []const u8,
    cwd: []const u8 = "",
    model: []const u8 = "",
    mode: []const u8 = "ASK",
    parent_session_id: ?[]const u8 = null,
    start_time_ms: i64 = 0,
};

pub const SessionEndedEvent = struct {
    session_id: []const u8,
    duration_ms: i64 = 0,
    total_cost: f64 = 0,
    total_tokens: i64 = 0,
    tool_call_count: i32 = 0,
    turn_count: i32 = 0,
    outcome: TrajectoryOutcome = .success,
};

// ── 扩展 14 种 ──────────────────────────────────────────────────────────────

pub const HookStartedEvent = struct {
    hook_id: []const u8,
    hook_name: []const u8,
    hook_event: []const u8,
    session_id: []const u8 = "",
};

pub const HookProgressEvent = struct {
    hook_id: []const u8,
    hook_name: []const u8,
    hook_event: []const u8,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    output: []const u8 = "",
    session_id: []const u8 = "",
};

pub const HookCompletedEvent = struct {
    hook_id: []const u8,
    hook_name: []const u8,
    hook_event: []const u8,
    exit_code: i32 = 0,
    outcome: []const u8 = "success",
    duration_ms: i64 = 0,
    session_id: []const u8 = "",

    /// `isError = outcome=="error" || exitCode!=0`
    pub fn isError(self: HookCompletedEvent) bool {
        return std.mem.eql(u8, self.outcome, "error") or self.exit_code != 0;
    }
};

pub const TaskStartedEvent = struct { task_id: []const u8, task_name: []const u8 };
pub const TaskProgressEvent = struct {
    task_id: []const u8,
    percent: f64 = 0,
    message: []const u8 = "",
};

pub const AgentSpawnedEvent = struct {
    agent_id: []const u8,
    agent_type: []const u8,
    description: []const u8 = "",
    parent_session_id: ?[]const u8 = null,
    transcript_ref: ?[]const u8 = null,
    mode: []const u8 = "",
    isolation: []const u8 = "",
    background: bool = false,
    parent_tool_use_id: ?[]const u8 = null,
    spawned_at: i64 = 0,
};

pub const AgentCompletedEvent = struct {
    agent_id: []const u8,
    duration_ms: i64 = 0,
    exit_status: []const u8 = "",
    token_usage: Usage = .{},
    tool_use_count: i32 = 0,
    summary: []const u8 = "",
    parent_tool_use_id: ?[]const u8 = null,
};

pub const AuthStatusEvent = struct {
    provider: []const u8,
    status: []const u8,
    message: []const u8 = "",
};

pub const RateLimitEvent = struct {
    status: []const u8,
    resets_at_epoch_ms: i64 = 0,
    rate_limit_type: []const u8 = "",
    utilization: f64 = 0,
};

pub const ModeChangeEvent = struct {
    current_mode_id: []const u8,
    previous_mode_id: []const u8,
};

pub const ReplayUserMessageEvent = struct {
    message_uuid: []const u8,
    parent_uuid: []const u8 = "",
    replay_reason: []const u8 = "",
};

// ── union·33 ────────────────────────────────────────────────────────────────

pub const StreamEvent = union(enum) {
    // ── 核心 19 ──
    text_delta: struct { text: []const u8 },
    reasoning_delta: struct { text: []const u8 },
    tool_call: ToolCallEvent,
    tool_progress: ToolProgressEvent,
    tool_result: ToolResultEvent,
    tool_summary: struct { summary: []const u8, metadata: json.Map = .{} },
    start_turn: struct { turn_number: i32 },
    end_turn: struct { turn_number: i32, tool_call_count: i32, cumulative_tokens: i64 },
    turn_complete: TurnCompleteEvent,
    stream_request_start: StreamRequestStartEvent,
    compact_boundary: CompactBoundaryEvent,
    cache_invalidation: struct {
        previous_fingerprint: []const u8,
        current_fingerprint: []const u8,
    },
    tombstone: TombstoneEvent,
    status: struct { message: []const u8 },
    error_event: ErrorEvent,
    attachment: AttachmentEvent,
    incremental_usage: IncrementalUsageEvent,
    session_started: SessionStartedEvent,
    session_ended: SessionEndedEvent,

    // ── 扩展 14（先占位）──
    hook_started: HookStartedEvent,
    hook_progress: HookProgressEvent,
    hook_completed: HookCompletedEvent,
    task_started: TaskStartedEvent,
    task_progress: TaskProgressEvent,
    agent_spawned: AgentSpawnedEvent,
    agent_completed: AgentCompletedEvent,
    file_attribution: struct { files: []const FileChange },
    file_history_snapshot: struct { files: []const FileSnapshot },
    auth_status: AuthStatusEvent,
    rate_limit: RateLimitEvent,
    mode_change: ModeChangeEvent,
    config_change: struct { config_options: json.Map = .{} },
    replay_user_message: ReplayUserMessageEvent,

    /// ★ wire tag 名必须与 stream-json 对齐。
    pub fn wireTag(self: StreamEvent) []const u8 {
        return switch (self) {
            .text_delta => "text_delta",
            .reasoning_delta => "reasoning_delta",
            .tool_call => "tool_call",
            .tool_progress => "tool_progress",
            .tool_result => "tool_result",
            .tool_summary => "tool_summary",
            .start_turn => "start_turn",
            .end_turn => "end_turn",
            .turn_complete => "turn_complete",
            .stream_request_start => "stream_request_start",
            .compact_boundary => "compact_boundary",
            .cache_invalidation => "cache_invalidation",
            .tombstone => "tombstone",
            .status => "status",
            // ⚠️ 内部 tag 叫 error_event（关键字），wire 名必须是 "error"
            .error_event => "error",
            .attachment => "attachment",
            .incremental_usage => "incremental_usage",
            .session_started => "session_started",
            .session_ended => "session_ended",
            .hook_started => "hook_started",
            .hook_progress => "hook_progress",
            .hook_completed => "hook_completed",
            .task_started => "task_started",
            .task_progress => "task_progress",
            .agent_spawned => "agent_spawned",
            .agent_completed => "agent_completed",
            .file_attribution => "file_attribution",
            .file_history_snapshot => "file_history_snapshot",
            .auth_status => "auth_status",
            .rate_limit => "rate_limit",
            .mode_change => "mode_change",
            .config_change => "config_change",
            .replay_user_message => "replay_user_message",
        };
    }

    /// 是否属于核心 19 种。
    pub fn isCore(self: StreamEvent) bool {
        return switch (self) {
            .hook_started,
            .hook_progress,
            .hook_completed,
            .task_started,
            .task_progress,
            .agent_spawned,
            .agent_completed,
            .file_attribution,
            .file_history_snapshot,
            .auth_status,
            .rate_limit,
            .mode_change,
            .config_change,
            .replay_user_message,
            => false,
            else => true,
        };
    }

    /// 是否算「已向用户吐过内容」（流式重试的唯一闸门；**心跳/status 不算**）。
    pub fn countsAsEmit(self: StreamEvent) bool {
        return switch (self) {
            .text_delta, .reasoning_delta, .tool_call, .tool_result, .tool_progress, .tool_summary => true,
            else => false,
        };
    }

    pub fn toJson(self: StreamEvent, e: *json.Encoder) !void {
        try e.beginObject();
        try e.stringField("type", self.wireTag());
        try payloadJson(self, e);
        try e.endObject();
    }
};

fn mapField(e: *json.Encoder, key: []const u8, m: json.Map) !void {
    try e.key(key);
    try e.value(.{ .object = m });
}

fn payloadJson(self: StreamEvent, e: *json.Encoder) !void {
    switch (self) {
        .text_delta => |v| try e.stringField("text", v.text),
        .reasoning_delta => |v| try e.stringField("text", v.text),
        .tool_call => |v| {
            try e.stringField("tool_use_id", v.tool_use_id);
            try e.stringField("tool_name", v.tool_name);
            try e.stringField("input", v.input);
            try e.intField("index", v.index);
            try e.intField("start_time_ms", v.start_time_ms);
        },
        .tool_progress => |v| {
            try e.stringField("tool_use_id", v.tool_use_id);
            try e.stringField("tool_name", v.tool_name);
            try e.optStringField("parent_tool_use_id", v.parent_tool_use_id);
            try e.key("elapsed_time_seconds");
            try e.float(v.elapsed_time_seconds);
            try e.optStringField("task_id", v.task_id);
            try e.optStringField("message", v.message);
            if (v.percent) |p| {
                try e.key("percent");
                try e.float(p);
            }
            try e.optStringField("stdout", v.stdout);
            try e.optStringField("stderr", v.stderr);
            try mapField(e, "structured", v.structured);
        },
        .tool_result => |v| {
            try e.stringField("tool_use_id", v.tool_use_id);
            try e.stringField("output", v.output);
            try e.boolField("is_error", v.is_error);
            try e.intField("duration_ms", v.duration_ms);
            if (v.effectiveErrorCode()) |code| try e.stringField("error_code", code);
            try e.optStringField("error_message", v.error_message);
        },
        .tool_summary => |v| {
            try e.stringField("summary", v.summary);
            try mapField(e, "metadata", v.metadata);
        },
        .start_turn => |v| try e.intField("turn_number", v.turn_number),
        .end_turn => |v| {
            try e.intField("turn_number", v.turn_number);
            try e.intField("tool_call_count", v.tool_call_count);
            try e.intField("cumulative_tokens", v.cumulative_tokens);
        },
        .turn_complete => |v| {
            try e.key("usage");
            try v.usage.toJson(e);
            try e.stringField("stop_reason", v.stop_reason);
            try e.stringField("request_id", v.request_id);
            try e.intField("duration_ms", v.duration_ms);
            try e.optStringField("payload_ref", v.payload_ref);
            try mapField(e, "assistant_properties", v.assistant_properties);
        },
        .stream_request_start => |v| {
            try e.stringField("request_id", v.request_id);
            try e.stringField("model", v.model);
            try e.stringField("query_source", v.query_source);
            try e.intField("turn_index", v.turn_index);
            try e.optStringField("model_ref", v.model_ref);
            try e.stringField("provider_id", v.provider_id);
            try e.stringField("resolved_model", v.resolved_model);
            if (v.temperature) |t| {
                try e.key("temperature");
                try e.float(t);
            }
            try e.intField("max_tokens", v.max_tokens);
            try e.intField("system_prompt_tokens", v.system_prompt_tokens);
            try e.optStringField("payload_ref", v.payload_ref);
            try mapField(e, "budget_snapshot", v.budget_snapshot);
        },
        .compact_boundary => |v| {
            try e.stringField("kind", v.kind);
            try e.intField("before_messages", v.before_messages);
            try e.intField("after_messages", v.after_messages);
            try e.stringField("reason", v.reason);
            try e.intField("tokens_before", v.tokens_before);
            try e.intField("tokens_after", v.tokens_after);
            try e.optStringField("preserved_segment", v.preserved_segment);
            try mapField(e, "metadata", v.metadata);
        },
        .cache_invalidation => |v| {
            try e.stringField("previous_fingerprint", v.previous_fingerprint);
            try e.stringField("current_fingerprint", v.current_fingerprint);
        },
        .tombstone => |v| {
            try e.stringField("target_uuid", v.target_uuid);
            try e.stringField("reason", v.reason);
            try e.optStringField("replacement_uuid", v.replacement_uuid);
        },
        .status => |v| try e.stringField("message", v.message),
        .error_event => |v| {
            try e.stringField("message", v.message);
            try e.stringField("error_code", v.error_code);
            try e.intField("retry_attempt", v.retry_attempt);
            try e.intField("max_retries", v.max_retries);
            try e.intField("retry_delay_ms", v.retry_delay_ms);
            try e.boolField("terminal", v.terminal);
            try e.stringField("session_id", v.session_id);
            try e.stringField("request_id", v.request_id);
            try e.stringField("source", v.source.wireName());
        },
        .attachment => |v| {
            try e.stringField("attachment_type", v.attachment_type);
            try mapField(e, "payload", v.payload);
            try e.stringField("severity", v.severity);
            try e.optStringField("dedupe_key", v.dedupe_key);
        },
        .incremental_usage => |v| {
            try e.intField("input_tokens", v.input_tokens);
            try e.intField("output_tokens", v.output_tokens);
            try e.intField("cache_read_tokens", v.cache_read_tokens);
            try e.intField("cache_creation_tokens", v.cache_creation_tokens);
        },
        .session_started => |v| {
            try e.stringField("session_id", v.session_id);
            try e.stringField("cwd", v.cwd);
            try e.stringField("model", v.model);
            try e.stringField("mode", v.mode);
            try e.optStringField("parent_session_id", v.parent_session_id);
            try e.intField("start_time_ms", v.start_time_ms);
        },
        .session_ended => |v| {
            try e.stringField("session_id", v.session_id);
            try e.intField("duration_ms", v.duration_ms);
            try e.key("total_cost_usd");
            try e.float(v.total_cost);
            try e.intField("total_tokens", v.total_tokens);
            try e.intField("tool_call_count", v.tool_call_count);
            try e.intField("turn_count", v.turn_count);
            try e.stringField("outcome", v.outcome.wireName());
        },
        .hook_started => |v| {
            try e.stringField("hook_id", v.hook_id);
            try e.stringField("hook_name", v.hook_name);
            try e.stringField("hook_event", v.hook_event);
            try e.stringField("session_id", v.session_id);
        },
        .hook_progress => |v| {
            try e.stringField("hook_id", v.hook_id);
            try e.stringField("hook_name", v.hook_name);
            try e.stringField("hook_event", v.hook_event);
            try e.stringField("stdout", v.stdout);
            try e.stringField("stderr", v.stderr);
            try e.stringField("output", v.output);
            try e.stringField("session_id", v.session_id);
        },
        .hook_completed => |v| {
            try e.stringField("hook_id", v.hook_id);
            try e.stringField("hook_name", v.hook_name);
            try e.stringField("hook_event", v.hook_event);
            try e.intField("exit_code", v.exit_code);
            try e.stringField("outcome", v.outcome);
            try e.intField("duration_ms", v.duration_ms);
            try e.boolField("is_error", v.isError());
            try e.stringField("session_id", v.session_id);
        },
        .task_started => |v| {
            try e.stringField("task_id", v.task_id);
            try e.stringField("task_name", v.task_name);
        },
        .task_progress => |v| {
            try e.stringField("task_id", v.task_id);
            try e.key("percent");
            try e.float(v.percent);
            try e.stringField("message", v.message);
        },
        .agent_spawned => |v| {
            try e.stringField("agent_id", v.agent_id);
            try e.stringField("agent_type", v.agent_type);
            try e.stringField("description", v.description);
            try e.optStringField("parent_session_id", v.parent_session_id);
            try e.optStringField("transcript_ref", v.transcript_ref);
            try e.stringField("mode", v.mode);
            try e.stringField("isolation", v.isolation);
            try e.boolField("background", v.background);
            try e.optStringField("parent_tool_use_id", v.parent_tool_use_id);
            try e.intField("spawned_at", v.spawned_at);
        },
        .agent_completed => |v| {
            try e.stringField("agent_id", v.agent_id);
            try e.intField("duration_ms", v.duration_ms);
            try e.stringField("exit_status", v.exit_status);
            try e.key("token_usage");
            try v.token_usage.toJson(e);
            try e.intField("tool_use_count", v.tool_use_count);
            try e.stringField("summary", v.summary);
            try e.optStringField("parent_tool_use_id", v.parent_tool_use_id);
        },
        .file_attribution => |v| {
            try e.key("files");
            try e.beginArray();
            for (v.files) |f| {
                try e.beginObject();
                try e.stringField("path", f.path);
                try e.intField("chars_added", f.chars_added);
                try e.intField("chars_removed", f.chars_removed);
                try e.endObject();
            }
            try e.endArray();
        },
        .file_history_snapshot => |v| {
            try e.key("files");
            try e.beginArray();
            for (v.files) |f| {
                try e.beginObject();
                try e.stringField("path", f.path);
                try e.stringField("action", f.action);
                try e.stringField("hash", f.hash);
                try e.endObject();
            }
            try e.endArray();
        },
        .auth_status => |v| {
            try e.stringField("provider", v.provider);
            try e.stringField("status", v.status);
            try e.stringField("message", v.message);
        },
        .rate_limit => |v| {
            try e.stringField("status", v.status);
            try e.intField("resets_at_epoch_ms", v.resets_at_epoch_ms);
            try e.stringField("rate_limit_type", v.rate_limit_type);
            try e.key("utilization");
            try e.float(v.utilization);
        },
        .mode_change => |v| {
            try e.stringField("current_mode_id", v.current_mode_id);
            try e.stringField("previous_mode_id", v.previous_mode_id);
        },
        .config_change => |v| try mapField(e, "config_options", v.config_options),
        .replay_user_message => |v| {
            try e.stringField("message_uuid", v.message_uuid);
            try e.stringField("parent_uuid", v.parent_uuid);
            try e.stringField("replay_reason", v.replay_reason);
        },
    }
}

// ── 信封（三种传输通用语义，文档 06 §3.1）────────────────────────────────────

pub const Envelope = struct {
    uuid: []const u8,
    session_id: []const u8,
    timestamp: []const u8,
    event: StreamEvent,

    pub fn toJson(self: Envelope, e: *json.Encoder) !void {
        try e.beginObject();
        try e.stringField("type", self.event.wireTag());
        try e.stringField("uuid", self.uuid);
        try e.stringField("session_id", self.session_id);
        try e.stringField("timestamp", self.timestamp);
        try payloadJson(self.event, e);
        try e.endObject();
    }
};

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "event: 33 种事件且 switch 穷尽" {
    const fields = @typeInfo(StreamEvent).@"union".fields;
    try testing.expectEqual(@as(usize, 33), fields.len);
}

test "event: wireTag 全部非空且唯一，error_event → \"error\"" {
    var seen = std.StringHashMap(void).init(testing.allocator);
    defer seen.deinit();
    const fields = @typeInfo(StreamEvent).@"union".fields;
    inline for (fields) |f| {
        const tag = comptime f.name;
        // 用 comptime 构造一个零值变体来取 wireTag
        const ev: StreamEvent = @unionInit(StreamEvent, tag, zeroValue(f.type));
        const w = ev.wireTag();
        try testing.expect(w.len > 0);
        try testing.expect(!seen.contains(w));
        try seen.put(w, {});
    }
    const err: StreamEvent = .{ .error_event = ErrorEvent.of("x") };
    try testing.expectEqualStrings("error", err.wireTag());
}

fn zeroValue(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .@"struct" => std.mem.zeroes(T),
        else => std.mem.zeroes(T),
    };
}

test "event: 心跳/status 不算 emit" {
    try testing.expect(!(StreamEvent{ .status = .{ .message = "ping" } }).countsAsEmit());
    try testing.expect((StreamEvent{ .text_delta = .{ .text = "hi" } }).countsAsEmit());
    try testing.expect(!(StreamEvent{ .error_event = ErrorEvent.of("x") }).countsAsEmit());
}

test "event: 核心 19 / 扩展 14 分级" {
    var core: usize = 0;
    var ext: usize = 0;
    inline for (@typeInfo(StreamEvent).@"union".fields) |f| {
        const ev: StreamEvent = @unionInit(StreamEvent, f.name, zeroValue(f.type));
        if (ev.isCore()) core += 1 else ext += 1;
    }
    try testing.expectEqual(@as(usize, 19), core);
    try testing.expectEqual(@as(usize, 14), ext);
}

test "event: tool_result 失败无 code 兜底 unknown" {
    const v = ToolResultEvent{ .tool_use_id = "t", .output = "boom", .is_error = true };
    try testing.expectEqualStrings("unknown", v.effectiveErrorCode().?);
    const ok = ToolResultEvent{ .tool_use_id = "t", .output = "ok", .is_error = false };
    try testing.expect(ok.effectiveErrorCode() == null);
}

test "event: tool_call 的 input 原样输出为字符串" {
    var e = json.Encoder.init(testing.allocator);
    defer e.deinit();
    const ev = StreamEvent{ .tool_call = .{
        .tool_use_id = "t1",
        .tool_name = "Read",
        .input = "{\"file_path\":\"/x\"}",
    } };
    try ev.toJson(&e);
    try testing.expect(std.mem.indexOf(u8, e.text(), "\"input\":\"{\\\"file_path\\\":\\\"/x\\\"}\"") != null);
}

test "event: 信封含四个公共字段" {
    var e = json.Encoder.init(testing.allocator);
    defer e.deinit();
    try (Envelope{
        .uuid = "u1",
        .session_id = "s1",
        .timestamp = "2026-01-01T00:00:00Z",
        .event = .{ .text_delta = .{ .text = "hi" } },
    }).toJson(&e);
    const out = e.text();
    try testing.expect(std.mem.indexOf(u8, out, "\"type\":\"text_delta\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"uuid\":\"u1\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"timestamp\"") != null);
}

test "event: hook_completed isError 判据" {
    const ok = HookCompletedEvent{ .hook_id = "h", .hook_name = "n", .hook_event = "e", .exit_code = 0 };
    try testing.expect(!ok.isError());
    const bad = HookCompletedEvent{ .hook_id = "h", .hook_name = "n", .hook_event = "e", .exit_code = 2 };
    try testing.expect(bad.isError());
}
