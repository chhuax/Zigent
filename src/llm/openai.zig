//! `openai.zig` —— OpenAI Chat Completions wire（含兼容网关 / DeepSeek）。
//!
//! ## 请求形状（`snake_case`）
//!
//! ```json
//! {
//!   "model": "...", "max_tokens": 8192, "stream": true,
//!   "stream_options": {"include_usage": true},
//!   "messages": [
//!     {"role":"system","content":"..."},
//!     {"role":"user","content":"..."},
//!     {"role":"assistant","content":"...","tool_calls":[
//!        {"id":"call_1","type":"function","function":{"name":"Read","arguments":"{...}"}}]},
//!     {"role":"tool","tool_call_id":"call_1","content":"..."}
//!   ],
//!   "tools": [{"type":"function","function":{"name":"Read","description":"...","parameters":{...}}}]
//! }
//! ```
//!
//! ## 硬约束
//!
//! - **结束信号是 `data: [DONE]`**；提前断流的文案逐字为
//!   `"OpenAI stream closed before [DONE]"`，且必须**可重试**。
//! - `prompt_tokens` **已包含** `cached_tokens` → `Usage.normalizeOpenAi`。
//! - DeepSeek 的缓存命中在**顶层** `prompt_cache_hit_tokens` →
//!   `Usage.normalizeDeepSeek`。
//! - **HTTP 200 但 body 含顶层 `error` 字段 = 失败**（`topLevelErrorEnvelope`）。
//! - `baseUrl` 归一化必须**保留 `/v1/`**（吃掉 `/v1` 会 404）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const json = common.json;
const llm = @import("root.zig");
const toolcalls = @import("toolcalls.zig");

pub const DEFAULT_BASE_URL = "https://api.openai.com/v1/";

pub const RESERVED_TOP_KEYS = [_][]const u8{
    "model",    "messages", "tools",  "stream",
    "temperature", "max_tokens", "stream_options",
};

// ─────────────────────────────────────────────────────────────────────────────
// URL 归一化（雷区 §E：兼容端点必须保留 /v1/）
// ─────────────────────────────────────────────────────────────────────────────

/// 归一化 base：确保以 `/<v1>/` 结尾，且**不吞掉已有的 `/v1/`**。
pub fn normalizeBaseUrl(gpa: Allocator, base_url: []const u8) ![]u8 {
    const raw = if (base_url.len == 0) DEFAULT_BASE_URL else base_url;
    const b = std.mem.trimEnd(u8, raw, "/");
    if (std.mem.endsWith(u8, b, "/v1") or std.mem.indexOf(u8, b, "/v1/") != null) {
        return std.fmt.allocPrint(gpa, "{s}/", .{b});
    }
    return std.fmt.allocPrint(gpa, "{s}/v1/", .{b});
}

pub fn chatCompletionsUrl(gpa: Allocator, base_url: []const u8) ![]u8 {
    const base = try normalizeBaseUrl(gpa, base_url);
    defer gpa.free(base);
    return std.fmt.allocPrint(gpa, "{s}chat/completions", .{base});
}

// ─────────────────────────────────────────────────────────────────────────────
// 顶层 error 信封
// ─────────────────────────────────────────────────────────────────────────────

pub const TopLevelError = struct {
    message: []const u8,
    code: common.ErrorCode,
    provider_type: []const u8 = "",
};

/// **HTTP 200 但 body 里有 `error`** 的兼容端点 —— 只按状态码判成败会静默拿到空回复。
///
/// 同时识别各家的顶层 `refusal` 字段。
pub fn topLevelErrorEnvelope(arena: Allocator, body: []const u8) ?TopLevelError {
    if (std.mem.trim(u8, body, " \t\r\n").len == 0) return null;
    const v = json.parse(arena, body) catch return null;
    if (v != .object) return null;

    if (v.get("error")) |err| {
        const msg: []const u8 = switch (err) {
            .string => |s| s,
            .object => err.getString("message") orelse "",
            else => "",
        };
        const ty: []const u8 = switch (err) {
            .object => err.getString("type") orelse err.getString("code") orelse "",
            else => "",
        };
        return .{ .message = msg, .code = errorCodeForType(ty), .provider_type = ty };
    }
    if (v.getString("refusal")) |r| {
        return .{ .message = r, .code = .unknown, .provider_type = "refusal" };
    }
    return null;
}

pub fn errorCodeForType(t: []const u8) common.ErrorCode {
    if (std.mem.eql(u8, t, "overloaded_error")) return .model_overloaded;
    if (std.mem.eql(u8, t, "rate_limit_error") or std.mem.eql(u8, t, "rate_limit_exceeded")) return .rate_limited;
    if (std.mem.eql(u8, t, "insufficient_quota")) return .quota_exceeded;
    if (std.mem.eql(u8, t, "authentication_error") or std.mem.eql(u8, t, "invalid_api_key")) return .authentication;
    if (std.mem.eql(u8, t, "invalid_request_error")) return .unknown;
    if (std.mem.eql(u8, t, "context_length_exceeded")) return .prompt_too_long;
    if (std.mem.eql(u8, t, "server_error") or std.mem.eql(u8, t, "internal_server_error") or std.mem.eql(u8, t, "api_error")) return .transient;
    return .unknown;
}

pub fn mapStopReason(raw: []const u8) common.StopReason {
    if (std.mem.eql(u8, raw, "content_filter")) return .refusal;
    if (std.mem.eql(u8, raw, "cancelled")) return .cancelled;
    // "stop" / "length" / "tool_calls" 都归 end_turn（原始串仍在 turn_complete）
    return .end_turn;
}

// ─────────────────────────────────────────────────────────────────────────────
// 请求体构造
// ─────────────────────────────────────────────────────────────────────────────

pub const BuildOptions = struct {
    stream: bool = true,
    extra_body_json: ?[]const u8 = null,
    /// `reasoning_effort`（OpenAI 侧的思考下发形态）
    reasoning_effort: ?[]const u8 = null,
};

pub const NOT_USER_INPUT_MARKER = "<not_user_input>true</not_user_input>";

fn hasBackgroundMarker(m: common.Message) bool {
    for (m.content) |b| {
        if (b.asText()) |t| {
            if (std.mem.indexOf(u8, t, NOT_USER_INPUT_MARKER) != null) return true;
        }
    }
    return false;
}

fn textOf(m: common.Message, buf: *std.ArrayListUnmanaged(u8), gpa: Allocator) !void {
    for (m.content) |b| {
        if (b.asText()) |t| try buf.appendSlice(gpa, t);
    }
}

fn hasImage(m: common.Message) bool {
    for (m.content) |b| {
        if (b == .image) return true;
    }
    return false;
}

fn writeUserContent(e: *json.Encoder, m: common.Message, buf: *std.ArrayListUnmanaged(u8), gpa: Allocator) !void {
    if (!hasImage(m)) {
        buf.clearRetainingCapacity();
        try textOf(m, buf, gpa);
        try e.stringField("content", buf.items);
        return;
    }
    try e.key("content");
    try e.beginArray();
    for (m.content) |b| {
        switch (b) {
            .text => |t| {
                if (t.text.len == 0) continue;
                try e.beginObject();
                try e.stringField("type", "text");
                try e.stringField("text", t.text);
                try e.endObject();
            },
            .image => |img| switch (img.source) {
                .inline_data => |data| {
                    // data URL：OpenAI 兼容形态
                    const url = try std.fmt.allocPrint(gpa, "data:{s};base64,{s}", .{ img.media_type, data });
                    defer gpa.free(url);
                    try e.beginObject();
                    try e.stringField("type", "image_url");
                    try e.key("image_url");
                    try e.beginObject();
                    try e.stringField("url", url);
                    try e.endObject();
                    try e.endObject();
                },
                .reference => {},
            },
            else => {},
        }
    }
    try e.endArray();
}

fn writeExtraBody(e: *json.Encoder, arena: Allocator, extra: ?[]const u8) !void {
    const src = extra orelse return;
    if (src.len == 0) return;
    const v = json.parse(arena, src) catch return;
    if (v != .object) return;
    outer: for (v.object.entries.items) |entry| {
        for (RESERVED_TOP_KEYS) |k| {
            if (std.mem.eql(u8, entry.key, k)) continue :outer;
        }
        try e.key(entry.key);
        if (entry.raw) |raw| try e.raw(raw) else try e.value(entry.value);
    }
}

/// 构造 Chat Completions 请求体。
pub fn buildRequestBody(gpa: Allocator, req: *const llm.ApiRequest, opts: BuildOptions) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var e = json.Encoder.init(gpa);
    errdefer e.deinit();

    var text_buf: std.ArrayListUnmanaged(u8) = .empty;

    try e.beginObject();
    try e.stringField("model", req.model);
    try e.intField("max_tokens", req.max_tokens);
    if (req.temperature) |t| {
        try e.key("temperature");
        try e.float(t);
    }
    if (opts.reasoning_effort) |eff| try e.stringField("reasoning_effort", eff);
    try e.boolField("stream", opts.stream);
    if (opts.stream) {
        try e.key("stream_options");
        try e.beginObject();
        try e.boolField("include_usage", true);
        try e.endObject();
    }

    try e.key("messages");
    try e.beginArray();
    // 顶层 system 进 messages 首条（OpenAI 没有顶层 system 字段）
    if (req.system.len > 0) {
        try e.beginObject();
        try e.stringField("role", "system");
        try e.stringField("content", req.system);
        try e.endObject();
    }
    for (req.messages) |m| {
        switch (m.role) {
            .system => {
                if (!hasBackgroundMarker(m)) continue;
                try e.beginObject();
                try e.stringField("role", "user");
                try writeUserContent(&e, m, &text_buf, arena);
                try e.endObject();
            },
            .user => {
                var wrote_tool = false;
                for (m.content) |b| {
                    if (b.asToolResult()) |tr| {
                        try e.beginObject();
                        try e.stringField("role", "tool");
                        try e.stringField("tool_call_id", tr.tool_use_id);
                        try e.stringField("content", tr.output);
                        try e.endObject();
                        wrote_tool = true;
                    }
                }
                // 纯文本 user 轮（无可下发内容时跳过，避免空 content 被拒）
                var has_text_or_image = false;
                for (m.content) |b| {
                    switch (b) {
                        .text => |t| {
                            if (t.text.len > 0) has_text_or_image = true;
                        },
                        .image => has_text_or_image = true,
                        else => {},
                    }
                }
                if (!has_text_or_image and wrote_tool) continue;
                try e.beginObject();
                try e.stringField("role", "user");
                try writeUserContent(&e, m, &text_buf, arena);
                try e.endObject();
            },
            .assistant => {
                const has_calls = m.countToolUses() > 0;
                try e.beginObject();
                try e.stringField("role", "assistant");
                text_buf.clearRetainingCapacity();
                try textOf(m, &text_buf, arena);
                if (text_buf.items.len > 0 or !has_calls) {
                    try e.stringField("content", text_buf.items);
                }
                if (has_calls) {
                    try e.key("tool_calls");
                    try e.beginArray();
                    for (m.content) |b| {
                        if (b.asToolUse()) |tu| {
                            try e.beginObject();
                            try e.stringField("id", tu.tool_use_id);
                            try e.stringField("type", "function");
                            try e.key("function");
                            try e.beginObject();
                            try e.stringField("name", tu.tool_name);
                            // arguments 原样透传（不 parse → re-serialize）
                            try e.stringField("arguments", if (tu.input.len == 0) "{}" else tu.input);
                            try e.endObject();
                            try e.endObject();
                        }
                    }
                    try e.endArray();
                }
                try e.endObject();
            },
        }
    }
    try e.endArray();

    if (req.tools.len > 0) {
        try e.key("tools");
        try e.beginArray();
        for (req.tools) |t| {
            try e.beginObject();
            try e.stringField("type", "function");
            try e.key("function");
            try e.beginObject();
            try e.stringField("name", t.name);
            try e.stringField("description", t.description);
            try e.key("parameters");
            if (t.schema_json.len == 0) try e.raw("{}") else try e.raw(t.schema_json);
            try e.endObject();
            try e.endObject();
        }
        try e.endArray();
    }

    try writeExtraBody(&e, arena, opts.extra_body_json);
    try e.endObject();
    return e.toOwnedSlice();
}

// ─────────────────────────────────────────────────────────────────────────────
// 流式解析
// ─────────────────────────────────────────────────────────────────────────────

pub const Failure = struct {
    code: common.ErrorCode,
    message: []const u8,
};

pub const StreamParser = struct {
    gpa: Allocator,
    arena: Allocator,
    scratch: std.heap.ArenaAllocator,
    model: []const u8,
    acc: toolcalls.OpenAiAccumulator,

    usage: common.Usage = .{},
    stop_reason_raw: []const u8 = "stop",
    request_id: []const u8 = "",
    text: std.ArrayListUnmanaged(u8) = .empty,
    reasoning: std.ArrayListUnmanaged(u8) = .empty,

    saw_done: bool = false,
    saw_any_event: bool = false,
    failure: ?Failure = null,
    terminal: bool = false,
    finalized: bool = false,
    duration_ms: i64 = 0,

    pub fn init(gpa: Allocator, arena: Allocator, model: []const u8) StreamParser {
        return .{
            .gpa = gpa,
            .arena = arena,
            .scratch = std.heap.ArenaAllocator.init(gpa),
            .model = model,
            .acc = toolcalls.OpenAiAccumulator.init(arena),
        };
    }

    pub fn deinit(self: *StreamParser) void {
        self.scratch.deinit();
        self.acc.deinit();
        self.text.deinit(self.arena);
        self.reasoning.deinit(self.arena);
        self.* = undefined;
    }

    fn dupe(self: *StreamParser, s: []const u8) ![]const u8 {
        return self.arena.dupe(u8, s);
    }

    pub fn fillOutcome(self: *StreamParser, out: *llm.StreamOutcome) !void {
        out.usage = self.usage;
        out.stop_reason = mapStopReason(self.stop_reason_raw);
        out.request_id = self.request_id;
        out.text = try self.dupe(self.text.items);
        out.reasoning = try self.dupe(self.reasoning.items);

        var completes: std.ArrayListUnmanaged(toolcalls.Complete) = .empty;
        try self.acc.finish(&completes);
        const calls = try self.arena.alloc(llm.ToolCall, completes.items.len);
        for (completes.items, 0..) |c, i| {
            // 必须拷进 arena：accumulator 会在 parser.deinit() 时释放内部缓冲
            calls[i] = .{
                .tool_use_id = try self.dupe(c.id),
                .tool_name = try self.dupe(c.name),
                .input = try self.dupe(c.arguments),
            };
        }
        out.tool_calls = calls;
    }

    pub fn handle(self: *StreamParser, data: []const u8, sink: llm.StreamSink) !bool {
        if (self.terminal) return true;
        const trimmed = std.mem.trim(u8, data, " \t\r\n");
        if (trimmed.len == 0) return false;
        self.saw_any_event = true;

        // ★ OpenAI 的结束信号
        if (std.mem.eql(u8, trimmed, "[DONE]")) {
            self.saw_done = true;
            self.terminal = true;
            return true;
        }

        _ = self.scratch.reset(.retain_capacity);
        const v = json.parse(self.scratch.allocator(), trimmed) catch return false;
        if (v != .object) return false;

        // 200 也可能夹带 error 帧
        if (v.get("error")) |err| {
            const msg = switch (err) {
                .string => |s| s,
                .object => err.getString("message") orelse "",
                else => "",
            };
            const ty = switch (err) {
                .object => err.getString("type") orelse err.getString("code") orelse "",
                else => "",
            };
            self.failure = .{ .code = errorCodeForType(ty), .message = try self.dupe(msg) };
            self.terminal = true;
            return true;
        }

        if (v.getString("id")) |id| self.request_id = try self.dupe(id);
        if (v.get("usage")) |u| self.absorbUsage(u);

        const choices = v.getArray("choices") orelse return false;
        if (choices.len == 0) return false;
        const choice = choices[0];

        if (choice.getString("finish_reason")) |fr| self.stop_reason_raw = try self.dupe(fr);

        const delta = choice.get("delta") orelse choice.get("message") orelse return false;

        if (delta.getString("refusal")) |r| {
            self.failure = .{ .code = .unknown, .message = try self.dupe(r) };
            self.terminal = true;
            return true;
        }
        if (delta.getString("content")) |s| {
            if (s.len > 0) {
                try self.text.appendSlice(self.arena, s);
                try sink.send(.{ .text_delta = .{ .text = s } });
            }
        }
        // 两套 reasoning 字段名都要认
        const reason = delta.getString("reasoning_content") orelse delta.getString("reasoning");
        if (reason) |s| {
            if (s.len > 0) {
                try self.reasoning.appendSlice(self.arena, s);
                try sink.send(.{ .reasoning_delta = .{ .text = s } });
            }
        }
        if (delta.getArray("tool_calls")) |calls| {
            for (calls) |c| {
                const idx: u32 = @intCast(@max(0, c.getInt("index") orelse 0));
                const fn_ = c.get("function");
                const name = if (fn_) |f| f.getString("name") else null;
                const args = if (fn_) |f| f.getString("arguments") else null;
                try self.acc.onDelta(idx, c.getString("id"), name, args);
            }
        }
        return false;
    }

    fn absorbUsage(self: *StreamParser, u: json.Value) void {
        const prompt = u.getInt("prompt_tokens") orelse 0;
        const completion = u.getInt("completion_tokens") orelse 0;
        // DeepSeek：缓存命中在**顶层** `prompt_cache_hit_tokens`
        if (u.getInt("prompt_cache_hit_tokens")) |hit| {
            self.usage = common.Usage.normalizeDeepSeek(prompt, hit, completion);
            return;
        }
        // OpenAI：`prompt_tokens` **已包含** `prompt_tokens_details.cached_tokens`
        var cached: i64 = 0;
        if (u.get("prompt_tokens_details")) |d| {
            if (d.getInt("cached_tokens")) |c| cached = c;
        }
        self.usage = common.Usage.normalizeOpenAi(prompt, cached, completion);
    }

    /// 终态收口：由 client 在流结束后调用（此时才能拿到真实耗时）。幂等。
    pub fn finalize(self: *StreamParser, sink: llm.StreamSink, duration_ms: i64) !void {
        if (self.finalized) return;
        self.finalized = true;
        self.terminal = true;
        self.duration_ms = duration_ms;

        var completes: std.ArrayListUnmanaged(toolcalls.Complete) = .empty;
        defer completes.deinit(self.arena);
        self.acc.finish(&completes) catch |err| switch (err) {
            error.MissingToolCallId => {
                self.failure = .{ .code = .unknown, .message = "tool_call id missing in stream" };
                return;
            },
            else => return err,
        };
        for (completes.items) |c| {
            try sink.send(.{ .tool_call = .{
                .tool_use_id = c.id,
                .tool_name = c.name,
                .input = c.arguments,
                .index = @intCast(c.index),
            } });
        }
        try sink.send(.{ .turn_complete = .{
            .usage = self.usage,
            .stop_reason = self.stop_reason_raw,
            .request_id = self.request_id,
            .duration_ms = self.duration_ms,
        } });
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "openai: URL 归一化保留 /v1/（吃掉 /v1 会 404）" {
    const gpa = testing.allocator;

    const a = try chatCompletionsUrl(gpa, "https://gw.example.com/openai/v1/");
    defer gpa.free(a);
    try testing.expectEqualStrings("https://gw.example.com/openai/v1/chat/completions", a);

    const b = try chatCompletionsUrl(gpa, "https://gw.example.com/openai/v1");
    defer gpa.free(b);
    try testing.expectEqualStrings("https://gw.example.com/openai/v1/chat/completions", b);

    const c = try chatCompletionsUrl(gpa, "https://api.deepseek.com");
    defer gpa.free(c);
    try testing.expectEqualStrings("https://api.deepseek.com/v1/chat/completions", c);

    const d = try chatCompletionsUrl(gpa, "");
    defer gpa.free(d);
    try testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", d);

    // 归一化后的 base 本身保持 /v1/ 尾斜杠
    const e = try normalizeBaseUrl(gpa, "https://gw.example.com/openai/v1/");
    defer gpa.free(e);
    try testing.expectEqualStrings("https://gw.example.com/openai/v1/", e);
}

test "openai: topLevelErrorEnvelope —— 200 但 body 里有 error 也是失败" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const e1 = topLevelErrorEnvelope(a, "{\"error\":{\"type\":\"invalid_request_error\",\"message\":\"bad model\"}}").?;
    try testing.expectEqualStrings("bad model", e1.message);
    try testing.expectEqual(common.ErrorCode.unknown, e1.code);

    const e2 = topLevelErrorEnvelope(a, "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow\"}}").?;
    try testing.expectEqual(common.ErrorCode.rate_limited, e2.code);

    const e3 = topLevelErrorEnvelope(a, "{\"error\":\"plain string error\"}").?;
    try testing.expectEqualStrings("plain string error", e3.message);

    const e4 = topLevelErrorEnvelope(a, "{\"refusal\":\"I cannot help\"}").?;
    try testing.expectEqual(common.ErrorCode.unknown, e4.code);

    try testing.expect(topLevelErrorEnvelope(a, "{\"choices\":[]}") == null);
    try testing.expect(topLevelErrorEnvelope(a, "not json") == null);
}

test "openai: 请求体形状（tool_calls / tool / parameters 原样）" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const asst_blocks = [_]common.ContentBlock{
        common.content.text("let me"),
        .{ .tool_use = .{ .tool_use_id = "call_1", .tool_name = "Read", .input = "{\"file_path\":\"/x\", \"n\": 9007199254740993}" } },
    };
    const tr_blocks = [_]common.ContentBlock{.{ .tool_result = .{ .tool_use_id = "call_1", .output = "file body", .is_error = false } }};
    const msgs = [_]common.Message{
        try common.Message.system(a, "ignored system"),
        .{ .role = .assistant, .content = &asst_blocks },
        .{ .role = .user, .content = &tr_blocks },
    };
    const tools = [_]llm.ToolSpec{.{
        .name = "Read",
        .description = "read",
        .schema_json = "{\"type\":\"object\"}",
    }};

    const body = try buildRequestBody(gpa, &.{
        .model = "gpt-4o",
        .system = "SYS",
        .messages = &msgs,
        .tools = &tools,
    }, .{});
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\",\"content\":\"SYS\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "ignored system") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"tool_calls\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"id\":\"call_1\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"function\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"arguments\":\"{\\\"file_path\\\":\\\"/x\\\", \\\"n\\\": 9007199254740993}\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"tool\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"call_1\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"parameters\":{\"type\":\"object\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"include_usage\":true") != null);
}

const Sink = struct {
    events: std.ArrayListUnmanaged(common.StreamEvent) = .empty,
    gpa: Allocator,

    fn init(gpa: Allocator) Sink {
        return .{ .gpa = gpa };
    }
    fn deinit(self: *Sink) void {
        self.events.deinit(self.gpa);
    }
    fn sink(self: *Sink) llm.StreamSink {
        return .{ .ctx = self, .emit = emit };
    }
    fn emit(ctx: *anyopaque, ev: common.StreamEvent) anyerror!void {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        try self.events.append(self.gpa, ev);
    }
    fn count(self: *const Sink, comptime tag: std.meta.Tag(common.StreamEvent)) usize {
        var n: usize = 0;
        for (self.events.items) |e| {
            if (std.meta.activeTag(e) == tag) n += 1;
        }
        return n;
    }
};

fn runSse(gpa: Allocator, bytes: []const u8, sink: *Sink, parser: *StreamParser) !void {
    var dec = @import("sse.zig").Decoder.init(gpa);
    defer dec.deinit();
    try dec.feed(bytes);
    try dec.finish();
    while (dec.next()) |ev| {
        _ = try parser.handle(ev.data, sink.sink());
    }
}

test "openai: 完整 mock 流 → stream_request_start/text_delta/tool_call/turn_complete" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const stream =
        "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"hel\"}}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"lo\"}}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"Bash\",\"arguments\":\"{\\\"command\\\":\"}}]}}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"ls\\\"}\"}}]}}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":20,\"prompt_tokens_details\":{\"cached_tokens\":40}}}\n\n" ++
        "data: [DONE]\n\n";

    var parser = StreamParser.init(gpa, a, "gpt-4o");
    defer parser.deinit();
    var sink = Sink.init(gpa);
    defer sink.deinit();

    try sink.sink().send(.{ .stream_request_start = .{ .request_id = "", .model = "gpt-4o" } });
    try runSse(gpa, stream, &sink, &parser);
    try testing.expect(parser.saw_done);
    try parser.finalize(sink.sink(), 7);

    const tags = [_][]const u8{ "stream_request_start", "text_delta", "text_delta", "tool_call", "turn_complete" };
    try testing.expectEqual(tags.len, sink.events.items.len);
    for (tags, 0..) |want, i| {
        try testing.expectEqualStrings(want, sink.events.items[i].wireTag());
    }
    try testing.expectEqualStrings("{\"command\":\"ls\"}", sink.events.items[3].tool_call.input);
    try testing.expectEqualStrings("tool_calls", sink.events.items[4].turn_complete.stop_reason);
    // ★ prompt_tokens 已含 cached_tokens → 必须相减
    try testing.expectEqual(@as(i64, 60), sink.events.items[4].turn_complete.usage.input_tokens);
    try testing.expectEqual(@as(i64, 40), sink.events.items[4].turn_complete.usage.cache_read_tokens);

    var outcome = llm.StreamOutcome{};
    try parser.fillOutcome(&outcome);
    try testing.expectEqualStrings("hello", outcome.text);
    try testing.expectEqual(@as(usize, 1), outcome.tool_calls.len);
    try testing.expectEqualStrings("chatcmpl-1", outcome.request_id);
}

test "openai: DeepSeek 顶层 prompt_cache_hit_tokens 归一化" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var parser = StreamParser.init(gpa, arena.allocator(), "deepseek-chat");
    defer parser.deinit();
    var sink = Sink.init(gpa);
    defer sink.deinit();

    const stream =
        "data: {\"id\":\"d1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"x\"}}]}\n\n" ++
        "data: {\"id\":\"d1\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":500,\"completion_tokens\":10,\"prompt_cache_hit_tokens\":400}}\n\n" ++
        "data: [DONE]\n\n";
    try runSse(gpa, stream, &sink, &parser);
    try parser.finalize(sink.sink(), 0);

    const u = parser.usage;
    try testing.expectEqual(@as(i64, 100), u.input_tokens);
    try testing.expectEqual(@as(i64, 400), u.cache_read_tokens);
    try testing.expectEqual(@as(i64, 10), u.output_tokens);
}

test "openai: reasoning_content 出 reasoning_delta" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var parser = StreamParser.init(gpa, arena.allocator(), "deepseek-reasoner");
    defer parser.deinit();
    var sink = Sink.init(gpa);
    defer sink.deinit();

    const stream =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"think\"}}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"answer\"}}]}\n\n" ++
        "data: [DONE]\n\n";
    try runSse(gpa, stream, &sink, &parser);
    try testing.expectEqual(@as(usize, 1), sink.count(.reasoning_delta));
    try testing.expectEqual(@as(usize, 1), sink.count(.text_delta));
    try testing.expectEqualStrings("think", parser.reasoning.items);
    try testing.expectEqualStrings("answer", parser.text.items);
}

test "openai: 无 [DONE] 时解析器不自行终结（由 client 判提前断流）" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var parser = StreamParser.init(gpa, arena.allocator(), "gpt-4o");
    defer parser.deinit();
    var sink = Sink.init(gpa);
    defer sink.deinit();

    const stream = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"}}]}\n\n";
    try runSse(gpa, stream, &sink, &parser);
    try testing.expect(!parser.saw_done);
    try testing.expect(parser.saw_any_event);
    try testing.expectEqual(@as(usize, 0), sink.count(.turn_complete));
}

test "openai: tool_call id 后到也能收口；缺 id 是协议错误" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var parser = StreamParser.init(gpa, arena.allocator(), "gpt-4o");
    defer parser.deinit();
    var sink = Sink.init(gpa);
    defer sink.deinit();

    const stream =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"Read\",\"arguments\":\"{\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_late\",\"function\":{\"arguments\":\"}\"}}]}}]}\n\n" ++
        "data: [DONE]\n\n";
    try runSse(gpa, stream, &sink, &parser);
    try parser.finalize(sink.sink(), 0);

    try testing.expectEqual(@as(usize, 1), sink.count(.tool_call));
    for (sink.events.items) |ev| {
        if (ev == .tool_call) {
            try testing.expectEqualStrings("call_late", ev.tool_call.tool_use_id);
            try testing.expectEqualStrings("{}", ev.tool_call.input);
        }
    }
}
