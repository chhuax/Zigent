//! `anthropic.zig` —— Anthropic Messages wire（请求体 + 流式解析）。
//!
//! ## 请求形状（`snake_case`，与 API 逐字一致）
//!
//! ```json
//! {
//!   "model": "...", "max_tokens": 8192, "system": "...", "stream": true,
//!   "thinking": {"type":"enabled","budget_tokens":N},
//!   "messages": [
//!     {"role":"user","content":[{"type":"text","text":"..."}]},
//!     {"role":"assistant","content":[{"type":"thinking","thinking":"...","signature":"..."},
//!                                    {"type":"text","text":"..."},
//!                                    {"type":"tool_use","id":"toolu_1","name":"Read","input":{...}}]},
//!     {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"...","is_error":false}]}
//!   ],
//!   "tools": [{"name":"Read","description":"...","input_schema":{...}}]
//! }
//! ```
//!
//! ## 三条硬约束（雷区 §C / §E）
//!
//! 1. **`signature` / `redacted_thinking` 是一等公民**：解析时随 thinking 块
//!    一起留存，下一轮请求必须原样回传 —— 漏一个字段 Anthropic 直接 400。
//! 2. **连续的 `tool_result` 必须合并进一个 user 轮**（否则触发 user/assistant
//!    交替校验）。
//! 3. **SYSTEM 不进 wire**：只有引擎注入的后台通知（正文含
//!    `<not_user_input>true</not_user_input>`）才渲染成 user 轮。
//!
//! ## 结束信号
//!
//! Anthropic **没有 `[DONE]`**，结束靠 `message_stop`。提前断流必须归类为
//! **可重试**，文案逐字为 `"Anthropic stream closed before message_stop"`。

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const json = common.json;
const llm = @import("root.zig");
const sse = @import("sse.zig");
const toolcalls = @import("toolcalls.zig");

pub const ANTHROPIC_VERSION = "2023-06-01";
pub const DEFAULT_BASE_URL = "https://api.anthropic.com/v1/";

/// 引擎注入的后台通知标记 —— 只有带它的 SYSTEM 才进 wire。
pub const NOT_USER_INPUT_MARKER = "<not_user_input>true</not_user_input>";

/// 保留顶层 key（extra_body 去重，避免序列化出重复顶层 key）。
pub const RESERVED_TOP_KEYS = [_][]const u8{
    "model", "max_tokens", "system", "messages", "tools",
    "stream",  "temperature", "thinking",
};

// ─────────────────────────────────────────────────────────────────────────────
// URL 归一化（雷区 §E）
// ─────────────────────────────────────────────────────────────────────────────

/// Anthropic 端点：`baseUrl` 常以 `…/anthropic` 结尾，client 再补 `/v1/messages`。
pub fn messagesUrl(gpa: Allocator, base_url: []const u8) ![]u8 {
    const raw = if (base_url.len == 0) DEFAULT_BASE_URL else base_url;
    const b = std.mem.trimEnd(u8, raw, "/");
    if (std.mem.endsWith(u8, b, "/messages")) return gpa.dupe(u8, b);
    if (std.mem.endsWith(u8, b, "/v1")) return std.fmt.allocPrint(gpa, "{s}/messages", .{b});
    return std.fmt.allocPrint(gpa, "{s}/v1/messages", .{b});
}

// ─────────────────────────────────────────────────────────────────────────────
// thinking 块（一等公民）
// ─────────────────────────────────────────────────────────────────────────────

pub const ThinkingKind = enum { thinking, redacted_thinking };

pub const ThinkingBlock = struct {
    kind: ThinkingKind = .thinking,
    thinking: []const u8 = "",
    /// ★ 丢了它下一轮就是 400。
    signature: []const u8 = "",
    /// `redacted_thinking` 的 `data`。同样必须回传。
    redacted_data: []const u8 = "",
};

/// 把 thinking 块编成可直接放进 `Message.extra["thinking_blocks"]` 的 JSON 值。
pub fn thinkingBlocksToValue(gpa: Allocator, blocks: []const ThinkingBlock) !json.Value {
    const arr = try gpa.alloc(json.Value, blocks.len);
    for (blocks, 0..) |b, i| {
        var obj = json.Object{};
        switch (b.kind) {
            .thinking => {
                try obj.put(gpa, "type", .{ .string = "thinking" });
                try obj.put(gpa, "thinking", .{ .string = b.thinking });
                try obj.put(gpa, "signature", .{ .string = b.signature });
            },
            .redacted_thinking => {
                try obj.put(gpa, "type", .{ .string = "redacted_thinking" });
                try obj.put(gpa, "data", .{ .string = b.redacted_data });
            },
        }
        arr[i] = .{ .object = obj };
    }
    return .{ .array = arr };
}

/// 从 `Message.extra["thinking_blocks"]` 读回（切片指向 `v` 的底层内存）。
pub fn thinkingBlocksFromValue(gpa: Allocator, v: json.Value) ![]ThinkingBlock {
    const arr = switch (v) {
        .array => |a| a,
        else => return &.{},
    };
    var out = std.ArrayListUnmanaged(ThinkingBlock).empty;
    errdefer out.deinit(gpa);
    for (arr) |blk| {
        const t = blk.getString("type") orelse continue;
        if (std.mem.eql(u8, t, "thinking")) {
            try out.append(gpa, .{
                .kind = .thinking,
                .thinking = blk.getString("thinking") orelse "",
                .signature = blk.getString("signature") orelse "",
            });
        } else if (std.mem.eql(u8, t, "redacted_thinking")) {
            try out.append(gpa, .{
                .kind = .redacted_thinking,
                .redacted_data = blk.getString("data") orelse "",
            });
        }
    }
    return out.toOwnedSlice(gpa);
}

// ─────────────────────────────────────────────────────────────────────────────
// 请求体构造
// ─────────────────────────────────────────────────────────────────────────────

pub const BuildOptions = struct {
    stream: bool = true,
    /// 下发 `thinking:{type:enabled,...}`。**与 `return_thinking` 是两个独立开关。**
    send_thinking: bool = false,
    thinking_budget_tokens: ?i64 = null,
    extra_body_json: ?[]const u8 = null,
};

const WireBlock = union(enum) {
    text: []const u8,
    tool_use: struct { id: []const u8, name: []const u8, input: []const u8 },
    tool_result: struct { id: []const u8, content: []const u8, is_error: bool },
    image: struct { media_type: []const u8, data: []const u8 },
    /// 原样 re-encode 的 thinking / redacted_thinking（我们自己的数据，非工具入参）
    thinking: json.Value,
};

const WireTurn = struct {
    role: common.MessageRole,
    is_tool_result: bool = false,
    blocks: std.ArrayListUnmanaged(WireBlock) = .empty,
};

fn hasBackgroundMarker(m: common.Message) bool {
    for (m.content) |b| {
        if (b.asText()) |t| {
            if (std.mem.indexOf(u8, t, NOT_USER_INPUT_MARKER) != null) return true;
        }
    }
    return false;
}

/// wire 上的有效角色；`null` = 该消息不进 wire。
fn effectiveRole(m: common.Message) ?common.MessageRole {
    return switch (m.role) {
        .system => if (hasBackgroundMarker(m)) .user else null,
        .user => .user,
        .assistant => .assistant,
    };
}

fn messageHasToolResult(m: common.Message) bool {
    for (m.content) |b| {
        if (b == .tool_result) return true;
    }
    return false;
}

fn appendBlocks(
    gpa: Allocator,
    blocks: *std.ArrayListUnmanaged(WireBlock),
    m: common.Message,
    include_thinking: bool,
) !void {
    // thinking 必须在 content 数组最前
    if (include_thinking) {
        if (m.extra.get("thinking_blocks")) |tb| {
            if (tb == .array) {
                for (tb.array) |blk| try blocks.append(gpa, .{ .thinking = blk });
            }
        }
    }
    for (m.content) |b| {
        switch (b) {
            .text => |t| {
                if (t.text.len > 0) try blocks.append(gpa, .{ .text = t.text });
            },
            .tool_use => |tu| try blocks.append(gpa, .{ .tool_use = .{
                .id = tu.tool_use_id,
                .name = tu.tool_name,
                .input = if (tu.input.len == 0) "{}" else tu.input,
            } }),
            .tool_result => |tr| try blocks.append(gpa, .{ .tool_result = .{
                .id = tr.tool_use_id,
                .content = tr.output,
                .is_error = tr.is_error,
            } }),
            .image => |img| switch (img.source) {
                .inline_data => |data| try blocks.append(gpa, .{ .image = .{
                    .media_type = img.media_type,
                    .data = data,
                } }),
                // 外置引用在本层无法解析 → 跳过（不伪造空图）
                .reference => {},
            },
        }
    }
}

fn planTurns(gpa: Allocator, messages: []const common.Message, include_thinking: bool) !std.ArrayListUnmanaged(WireTurn) {
    var turns: std.ArrayListUnmanaged(WireTurn) = .empty;
    for (messages) |m| {
        const role = effectiveRole(m) orelse continue;
        const has_tr = messageHasToolResult(m);
        const last_is_tr = turns.items.len > 0 and turns.items[turns.items.len - 1].is_tool_result;
        // ★ 连续 tool_result 合并进**一个** user 轮
        if (role == .user and has_tr and last_is_tr) {
            const t = &turns.items[turns.items.len - 1];
            try appendBlocks(gpa, &t.blocks, m, false);
        } else {
            try turns.append(gpa, .{ .role = role, .is_tool_result = has_tr });
            const t = &turns.items[turns.items.len - 1];
            try appendBlocks(gpa, &t.blocks, m, include_thinking);
        }
    }
    // 丢弃空 turn（空的 content 数组会被 400）
    var w: usize = 0;
    for (turns.items) |*t| {
        if (t.blocks.items.len == 0) {
            t.blocks.deinit(gpa);
            continue;
        }
        turns.items[w] = t.*;
        w += 1;
    }
    turns.shrinkRetainingCapacity(w);
    return turns;
}

fn freeTurns(gpa: Allocator, turns: *std.ArrayListUnmanaged(WireTurn)) void {
    for (turns.items) |*t| t.blocks.deinit(gpa);
    turns.deinit(gpa);
}

fn writeExtraBody(e: *json.Encoder, arena: Allocator, extra: ?[]const u8, reserved: []const []const u8) !void {
    const src = extra orelse return;
    if (src.len == 0) return;
    const v = json.parse(arena, src) catch return; // 透传失败不致命
    if (v != .object) return;
    outer: for (v.object.entries.items) |entry| {
        for (reserved) |k| {
            if (std.mem.eql(u8, entry.key, k)) continue :outer;
        }
        try e.key(entry.key);
        if (entry.raw) |raw| try e.raw(raw) else try e.value(entry.value);
    }
}

/// 构造 Anthropic Messages 请求体。调用方释放返回的切片。
pub fn buildRequestBody(gpa: Allocator, req: *const llm.ApiRequest, opts: BuildOptions) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var turns = try planTurns(arena, req.messages, opts.send_thinking);
    defer freeTurns(arena, &turns);

    var e = json.Encoder.init(gpa);
    errdefer e.deinit();
    try e.beginObject();
    try e.stringField("model", req.model);
    try e.intField("max_tokens", req.max_tokens);
    if (req.system.len > 0) try e.stringField("system", req.system);
    try e.boolField("stream", opts.stream);
    if (req.temperature) |t| {
        try e.key("temperature");
        try e.float(t);
    }
    if (opts.send_thinking) {
        try e.key("thinking");
        try e.beginObject();
        try e.stringField("type", "enabled");
        if (opts.thinking_budget_tokens) |b| try e.intField("budget_tokens", b);
        try e.endObject();
    }

    try e.key("messages");
    try e.beginArray();
    for (turns.items) |t| {
        try e.beginObject();
        try e.stringField("role", common.content.roleWireName(t.role));
        try e.key("content");
        try e.beginArray();
        for (t.blocks.items) |blk| {
            try e.beginObject();
            switch (blk) {
                .text => |s| {
                    try e.stringField("type", "text");
                    try e.stringField("text", s);
                },
                .tool_use => |tu| {
                    try e.stringField("type", "tool_use");
                    try e.stringField("id", tu.id);
                    try e.stringField("name", tu.name);
                    try e.key("input");
                    try e.raw(tu.input);
                },
                .tool_result => |tr| {
                    try e.stringField("type", "tool_result");
                    try e.stringField("tool_use_id", tr.id);
                    try e.stringField("content", tr.content);
                    try e.boolField("is_error", tr.is_error);
                },
                .image => |im| {
                    try e.stringField("type", "image");
                    try e.key("source");
                    try e.beginObject();
                    try e.stringField("type", "base64");
                    try e.stringField("media_type", im.media_type);
                    try e.stringField("data", im.data);
                    try e.endObject();
                },
                .thinking => |v| try e.value(v),
            }
            try e.endObject();
        }
        try e.endArray();
        try e.endObject();
    }
    try e.endArray();

    if (req.tools.len > 0) {
        try e.key("tools");
        try e.beginArray();
        for (req.tools) |t| {
            try e.beginObject();
            try e.stringField("name", t.name);
            try e.stringField("description", t.description);
            try e.key("input_schema");
            if (t.schema_json.len == 0) try e.raw("{}") else try e.raw(t.schema_json);
            try e.endObject();
        }
        try e.endArray();
    }

    try writeExtraBody(&e, arena, opts.extra_body_json, &RESERVED_TOP_KEYS);
    try e.endObject();
    return e.toOwnedSlice();
}

// ─────────────────────────────────────────────────────────────────────────────
// 流式解析 → common.StreamEvent
// ─────────────────────────────────────────────────────────────────────────────

pub const Failure = struct {
    code: common.ErrorCode,
    message: []const u8,
};

/// `redacted_thinking` / `signature` 的**事件级**承载：作为 `attachment` 事件
/// 随流吐出，引擎持久化到消息 attributes，下轮经 `thinking_blocks` 回填。
pub const THINKING_ATTACHMENT_TYPE = "anthropic_thinking";

pub const StreamParser = struct {
    gpa: Allocator,
    /// 本 attempt 的生命周期 arena（outcome 切片指向它）。
    arena: Allocator,
    scratch: std.heap.ArenaAllocator,
    model: []const u8,
    acc: toolcalls.AnthropicAccumulator,

    raw_input: i64 = 0,
    raw_cache_read: i64 = 0,
    raw_cache_creation: i64 = 0,
    raw_output: i64 = 0,
    cache_5m: i64 = 0,
    cache_1h: i64 = 0,

    stop_reason_raw: []const u8 = "end_turn",
    request_id: []const u8 = "",
    text: std.ArrayListUnmanaged(u8) = .empty,
    reasoning: std.ArrayListUnmanaged(u8) = .empty,
    thinkings: std.ArrayListUnmanaged(ThinkingBlock) = .empty,

    open: std.ArrayListUnmanaged(OpenThinking) = .empty,
    saw_any_event: bool = false,
    saw_message_stop: bool = false,
    failure: ?Failure = null,
    terminal: bool = false,
    finalized: bool = false,
    duration_ms: i64 = 0,

    const OpenThinking = struct {
        index: u32,
        kind: ThinkingKind,
        text: std.ArrayListUnmanaged(u8) = .empty,
        signature: std.ArrayListUnmanaged(u8) = .empty,
    };

    pub fn init(gpa: Allocator, arena: Allocator, model: []const u8) StreamParser {
        return .{
            .gpa = gpa,
            .arena = arena,
            .scratch = std.heap.ArenaAllocator.init(gpa),
            .model = model,
            .acc = toolcalls.AnthropicAccumulator.init(arena),
        };
    }

    pub fn deinit(self: *StreamParser) void {
        self.scratch.deinit();
        self.acc.deinit();
        self.text.deinit(self.arena);
        self.reasoning.deinit(self.arena);
        self.thinkings.deinit(self.arena);
        for (self.open.items) |*o| {
            o.text.deinit(self.arena);
            o.signature.deinit(self.arena);
        }
        self.open.deinit(self.arena);
        self.* = undefined;
    }

    /// ★ 一等公民出口：解析到的 thinking 块（含 signature / redacted）。
    pub fn thinkingBlocks(self: *const StreamParser) []const ThinkingBlock {
        return self.thinkings.items;
    }

    pub fn usageNormalized(self: *const StreamParser) common.Usage {
        var u = common.Usage.normalizeAnthropic(
            self.model,
            self.raw_input,
            self.raw_cache_read,
            self.raw_cache_creation,
            self.raw_output,
        );
        u.cache_creation_input_tokens_5m = @max(0, self.cache_5m);
        u.cache_creation_input_tokens_1h = @max(0, self.cache_1h);
        return u;
    }

    fn dupe(self: *StreamParser, s: []const u8) ![]const u8 {
        return self.arena.dupe(u8, s);
    }

    fn openFor(self: *StreamParser, index: u32, kind: ThinkingKind) !*OpenThinking {
        for (self.open.items) |*o| {
            if (o.index == index) return o;
        }
        try self.open.append(self.arena, .{ .index = index, .kind = kind });
        return &self.open.items[self.open.items.len - 1];
    }

    fn closeThinking(self: *StreamParser, index: u32, sink: llm.StreamSink) !void {
        var i: usize = 0;
        while (i < self.open.items.len) : (i += 1) {
            if (self.open.items[i].index != index) continue;
            var o = self.open.orderedRemove(i);
            const blk = ThinkingBlock{
                .kind = o.kind,
                .thinking = try self.dupe(o.text.items),
                .signature = try self.dupe(o.signature.items),
            };
            o.text.deinit(self.arena);
            o.signature.deinit(self.arena);
            try self.thinkings.append(self.arena, blk);
            try self.emitThinking(sink, blk);
            return;
        }
    }

    fn emitThinking(self: *StreamParser, sink: llm.StreamSink, blk: ThinkingBlock) !void {
        var payload = json.Map{};
        try payload.put(self.arena, "signature", .{ .string = blk.signature });
        try payload.put(self.arena, "thinking", .{ .string = blk.thinking });
        try payload.put(self.arena, "redacted", .{ .boolean = blk.kind == .redacted_thinking });
        try sink.send(.{ .attachment = .{
            .attachment_type = THINKING_ATTACHMENT_TYPE,
            .payload = payload,
            .severity = "info",
        } });
    }

    /// 处理一条已提交的 SSE `data:` 载荷。返回 `true` 表示流已终结。
    pub fn handle(self: *StreamParser, data: []const u8, sink: llm.StreamSink) !bool {
        if (self.terminal) return true;
        const trimmed = std.mem.trim(u8, data, " \t\r\n");
        if (trimmed.len == 0) return false;
        self.saw_any_event = true;

        _ = self.scratch.reset(.retain_capacity);
        const v = json.parse(self.scratch.allocator(), trimmed) catch return false;
        if (v != .object) return false;
        const t = v.getString("type") orelse return false;

        if (std.mem.eql(u8, t, "message_start")) {
            const m = v.get("message") orelse return false;
            if (m.getString("id")) |id| self.request_id = try self.dupe(id);
            if (m.get("usage")) |u| self.absorbUsage(u);
            return false;
        }

        if (std.mem.eql(u8, t, "content_block_start")) {
            const idx: u32 = @intCast(@max(0, v.getInt("index") orelse 0));
            const cb = v.get("content_block") orelse return false;
            const btype = cb.getString("type") orelse "";
            if (std.mem.eql(u8, btype, "tool_use")) {
                try self.acc.onBlockStart(idx, "tool_use", cb.getString("id"), cb.getString("name"));
            } else if (std.mem.eql(u8, btype, "thinking")) {
                const o = try self.openFor(idx, .thinking);
                if (cb.getString("thinking")) |pre| try o.text.appendSlice(self.arena, pre);
            } else if (std.mem.eql(u8, btype, "redacted_thinking")) {
                // redacted 块一次性给全 `data`，没有 delta
                const blk = ThinkingBlock{
                    .kind = .redacted_thinking,
                    .redacted_data = try self.dupe(cb.getString("data") orelse ""),
                };
                try self.thinkings.append(self.arena, blk);
                try self.emitThinking(sink, blk);
            }
            return false;
        }

        if (std.mem.eql(u8, t, "content_block_delta")) {
            const idx: u32 = @intCast(@max(0, v.getInt("index") orelse 0));
            const d = v.get("delta") orelse return false;
            const dtype = d.getString("type") orelse "";
            if (std.mem.eql(u8, dtype, "text_delta")) {
                const s = d.getString("text") orelse "";
                if (s.len > 0) {
                    try self.text.appendSlice(self.arena, s);
                    try sink.send(.{ .text_delta = .{ .text = s } });
                }
            } else if (std.mem.eql(u8, dtype, "thinking_delta")) {
                const s = d.getString("thinking") orelse "";
                const o = try self.openFor(idx, .thinking);
                try o.text.appendSlice(self.arena, s);
                if (s.len > 0) {
                    try self.reasoning.appendSlice(self.arena, s);
                    try sink.send(.{ .reasoning_delta = .{ .text = s } });
                }
            } else if (std.mem.eql(u8, dtype, "signature_delta")) {
                // ★ 不丢：签名字节全部累积
                const s = d.getString("signature") orelse "";
                const o = try self.openFor(idx, .thinking);
                try o.signature.appendSlice(self.arena, s);
            } else if (std.mem.eql(u8, dtype, "input_json_delta")) {
                try self.acc.onInputJsonDelta(idx, d.getString("partial_json") orelse "");
            }
            return false;
        }

        if (std.mem.eql(u8, t, "content_block_stop")) {
            const idx: u32 = @intCast(@max(0, v.getInt("index") orelse 0));
            try self.closeThinking(idx, sink);
            try self.acc.onBlockStop(idx);
            return false;
        }

        if (std.mem.eql(u8, t, "message_delta")) {
            if (v.get("delta")) |d| {
                if (d.getString("stop_reason")) |sr| self.stop_reason_raw = try self.dupe(sr);
            }
            if (v.get("usage")) |u| self.absorbUsage(u);
            return false;
        }

        if (std.mem.eql(u8, t, "message_stop")) {
            self.saw_message_stop = true;
            self.terminal = true;
            return true;
        }

        if (std.mem.eql(u8, t, "ping")) return false; // 心跳：不算 emit

        if (std.mem.eql(u8, t, "error")) {
            const err = v.get("error") orelse json.Value{ .object = .{} };
            const etype = err.getString("type") orelse "";
            const emsg = err.getString("message") orelse "anthropic stream error";
            self.failure = .{
                .code = errorCodeForType(etype),
                .message = try self.dupe(emsg),
            };
            self.terminal = true;
            return true;
        }
        return false;
    }

    fn absorbUsage(self: *StreamParser, u: json.Value) void {
        self.raw_input = u.getInt("input_tokens") orelse self.raw_input;
        self.raw_cache_read = u.getInt("cache_read_input_tokens") orelse self.raw_cache_read;
        self.raw_cache_creation = u.getInt("cache_creation_input_tokens") orelse self.raw_cache_creation;
        self.raw_output = u.getInt("output_tokens") orelse self.raw_output;
        self.cache_5m = u.getInt("cache_creation_input_tokens_5m") orelse self.cache_5m;
        self.cache_1h = u.getInt("cache_creation_input_tokens_1h") orelse self.cache_1h;
    }

    /// 终态收口：由 client 在流结束后调用（此时才能拿到真实耗时）。
    /// 幂等。先发 `tool_call`，再发 `turn_complete`。
    pub fn finalize(self: *StreamParser, sink: llm.StreamSink, duration_ms: i64) !void {
        if (self.finalized) return;
        self.finalized = true;
        self.terminal = true;
        self.duration_ms = duration_ms;

        var completes: std.ArrayListUnmanaged(toolcalls.Complete) = .empty;
        defer completes.deinit(self.arena);
        self.acc.finish(&completes) catch {};
        for (completes.items) |c| {
            try sink.send(.{ .tool_call = .{
                .tool_use_id = c.id,
                .tool_name = c.name,
                .input = c.arguments,
                .index = @intCast(c.index),
            } });
        }
        try sink.send(.{ .turn_complete = .{
            .usage = self.usageNormalized(),
            .stop_reason = self.stop_reason_raw,
            .request_id = self.request_id,
            .duration_ms = self.duration_ms,
        } });
    }

    pub fn fillOutcome(self: *StreamParser, out: *llm.StreamOutcome) !void {
        out.usage = self.usageNormalized();
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
};

/// provider 错误码 → 本项目错误码。
pub fn errorCodeForType(t: []const u8) common.ErrorCode {
    if (std.mem.eql(u8, t, "overloaded_error")) return .model_overloaded;
    if (std.mem.eql(u8, t, "rate_limit_error")) return .rate_limited;
    if (std.mem.eql(u8, t, "authentication_error")) return .authentication;
    if (std.mem.eql(u8, t, "permission_error")) return .authentication;
    if (std.mem.eql(u8, t, "invalid_request_error")) return .unknown;
    if (std.mem.eql(u8, t, "api_error")) return .transient;
    if (std.mem.eql(u8, t, "timeout_error")) return .stale_connection;
    return .unknown;
}

/// Anthropic 的 stop_reason → 内部 `StopReason`（原始串仍在 `turn_complete` 里）。
pub fn mapStopReason(raw: []const u8) common.StopReason {
    if (std.mem.eql(u8, raw, "refusal")) return .refusal;
    if (std.mem.eql(u8, raw, "cancelled")) return .cancelled;
    return .end_turn;
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "anthropic: URL 归一化（base 已含 /v1、已含 /messages、裸 host）" {
    const gpa = testing.allocator;
    const a = try messagesUrl(gpa, "https://api.anthropic.com/v1/");
    defer gpa.free(a);
    try testing.expectEqualStrings("https://api.anthropic.com/v1/messages", a);

    const b = try messagesUrl(gpa, "https://gw.example.com/anthropic");
    defer gpa.free(b);
    try testing.expectEqualStrings("https://gw.example.com/anthropic/v1/messages", b);

    const c = try messagesUrl(gpa, "https://gw.example.com/anthropic/v1/messages");
    defer gpa.free(c);
    try testing.expectEqualStrings("https://gw.example.com/anthropic/v1/messages", c);

    const d = try messagesUrl(gpa, "");
    defer gpa.free(d);
    try testing.expectEqualStrings("https://api.anthropic.com/v1/messages", d);
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
    fn firstText(self: *const Sink) []const u8 {
        for (self.events.items) |e| {
            if (e == .text_delta) return e.text_delta.text;
        }
        return "";
    }
};

/// 从 SSE 字节跑完整解析（测试用；真实路径经 client.zig）。
fn runSse(gpa: Allocator, bytes: []const u8, sink: *Sink, parser: *StreamParser) !void {
    var dec = sse.Decoder.init(gpa);
    defer dec.deinit();
    try dec.feed(bytes);
    try dec.finish();
    while (dec.next()) |ev| {
        _ = try parser.handle(ev.data, sink.sink());
    }
}

test "anthropic: 请求体 snake_case 形状 + input 原样透传 + input_schema" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const blocks = [_]common.ContentBlock{
        common.content.text("hi"),
        .{ .tool_use = .{ .tool_use_id = "toolu_1", .tool_name = "Read", .input = "{\"file_path\":\"/x\", \"n\": 9007199254740993}" } },
    };
    const msgs = [_]common.Message{
        try common.Message.system(arena.allocator(), "sys"),
        .{ .role = .user, .content = &blocks },
    };
    const tools = [_]llm.ToolSpec{.{
        .name = "Read",
        .description = "read a file",
        .schema_json = "{\"type\":\"object\",\"properties\":{\"file_path\":{\"type\":\"string\"}}}",
    }};

    const body = try buildRequestBody(gpa, &.{
        .model = "claude-sonnet-4",
        .system = "SYS",
        .messages = &msgs,
        .tools = &tools,
        .max_tokens = 4096,
        .temperature = 0.2,
    }, .{});
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":4096") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"system\":\"SYS\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_use\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"id\":\"toolu_1\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"name\":\"Read\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"input_schema\"") != null);
    // I1：工具入参逐字节保真（空格 + 大数字）
    try testing.expect(std.mem.indexOf(u8, body, "{\"file_path\":\"/x\", \"n\": 9007199254740993}") != null);
    // SYSTEM 消息不进 wire（只有顶层 system 字符串）
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") == null);
}

test "anthropic: 连续 tool_result 合并进一个 user 轮" {
    const gpa = testing.allocator;

    const tr1 = [_]common.ContentBlock{.{ .tool_result = .{ .tool_use_id = "t1", .output = "one", .is_error = false } }};
    const tr2 = [_]common.ContentBlock{.{ .tool_result = .{ .tool_use_id = "t2", .output = "two", .is_error = true } }};
    const msgs = [_]common.Message{
        .{ .role = .user, .content = &tr1 },
        .{ .role = .user, .content = &tr2 },
    };

    const body = try buildRequestBody(gpa, &.{
        .model = "m",
        .system = "",
        .messages = &msgs,
    }, .{});
    defer gpa.free(body);

    // 只应有一个 user turn
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, body, i, "\"role\":\"user\"")) |pos| {
        count += 1;
        i = pos + 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expect(std.mem.indexOf(u8, body, "\"tool_use_id\":\"t1\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"tool_use_id\":\"t2\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"is_error\":true") != null);
}

test "anthropic: SYSTEM 默认不进 wire，只有后台通知标记才渲染成 user" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const sys_plain = try common.Message.system(a, "plain system");
    const sys_notify = try common.Message.system(a, "<not_user_input>true</not_user_input>\njob done");
    const msgs = [_]common.Message{ sys_plain, sys_notify };

    const body = try buildRequestBody(gpa, &.{ .model = "m", .system = "", .messages = &msgs }, .{});
    defer gpa.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "plain system") == null);
    try testing.expect(std.mem.indexOf(u8, body, "job done") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
}

test "anthropic: thinking signature / redacted_thinking 是一等公民并可回传" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const stream =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":10,\"output_tokens\":1}}}\n\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"let me think\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"SIG-ABC-123\"}}\n\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"REDACTED-XX\"}}\n\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";

    var parser = StreamParser.init(gpa, a, "claude-sonnet-4");
    defer parser.deinit();
    var sink = Sink.init(gpa);
    defer sink.deinit();

    try runSse(gpa, stream, &sink, &parser);

    const blocks = parser.thinkingBlocks();
    try testing.expectEqual(@as(usize, 2), blocks.len);
    try testing.expectEqualStrings("let me think", blocks[0].thinking);
    try testing.expectEqualStrings("SIG-ABC-123", blocks[0].signature); // ★ 没丢
    try testing.expectEqual(ThinkingKind.redacted_thinking, blocks[1].kind);
    try testing.expectEqualStrings("REDACTED-XX", blocks[1].redacted_data); // ★ 没丢

    // 事件级承载：attachment 带上 signature
    try testing.expect(sink.count(.reasoning_delta) == 1);
    try testing.expect(sink.count(.attachment) == 2);

    // 回传：写进 assistant 消息的 extra，再构造请求体
    const value = try thinkingBlocksToValue(a, blocks);
    var extra = json.Object{};
    try extra.put(a, "thinking_blocks", value);
    const asst_blocks = [_]common.ContentBlock{common.content.text("done")};
    const msgs = [_]common.Message{.{ .role = .assistant, .content = &asst_blocks, .extra = extra }};
    const body = try buildRequestBody(gpa, &.{ .model = "m", .system = "", .messages = &msgs }, .{ .send_thinking = true, .thinking_budget_tokens = 1024 });
    defer gpa.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"signature\":\"SIG-ABC-123\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"data\":\"REDACTED-XX\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"enabled\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"budget_tokens\":1024") != null);
}

test "anthropic: thinkingBlocksFromValue 读回 signature / redacted（一等公民往返）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blocks = [_]ThinkingBlock{
        .{ .kind = .thinking, .thinking = "t", .signature = "SIG-1" },
        .{ .kind = .redacted_thinking, .redacted_data = "RED-1" },
    };
    const v = try thinkingBlocksToValue(a, &blocks);
    const back = try thinkingBlocksFromValue(a, v);
    defer a.free(back);
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqualStrings("SIG-1", back[0].signature);
    try testing.expectEqual(ThinkingKind.redacted_thinking, back[1].kind);
    try testing.expectEqualStrings("RED-1", back[1].redacted_data);
}

test "anthropic: 完整 mock 流产生规定顺序的事件序列" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const stream =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_42\",\"usage\":{\"input_tokens\":100,\"cache_read_input_tokens\":40,\"output_tokens\":1}}}\n\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hel\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"lo\"}}\n\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_9\",\"name\":\"Bash\",\"input\":{}}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"ls -la\\\"}\"}}\n\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":33}}\n\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";

    var parser = StreamParser.init(gpa, a, "claude-sonnet-4");
    defer parser.deinit();
    var sink = Sink.init(gpa);
    defer sink.deinit();

    // 与 client.zig 一致：attempt 开始时先发 stream_request_start
    try sink.sink().send(.{ .stream_request_start = .{ .request_id = "", .model = "claude-sonnet-4" } });
    try runSse(gpa, stream, &sink, &parser);
    try testing.expect(parser.saw_message_stop);
    try parser.finalize(sink.sink(), 7);

    // 顺序：stream_request_start → text_delta* → tool_call → turn_complete
    const tags = [_][]const u8{ "stream_request_start", "text_delta", "text_delta", "tool_call", "turn_complete" };
    try testing.expectEqual(tags.len, sink.events.items.len);
    for (tags, 0..) |want, i| {
        try testing.expectEqualStrings(want, sink.events.items[i].wireTag());
    }
    // tool_call 的入参原样
    try testing.expectEqualStrings("{\"command\":\"ls -la\"}", sink.events.items[3].tool_call.input);
    // turn_complete 的 usage：原生 claude 不相减
    try testing.expectEqual(@as(i64, 100), sink.events.items[4].turn_complete.usage.input_tokens);
    try testing.expectEqual(@as(i64, 40), sink.events.items[4].turn_complete.usage.cache_read_tokens);

    var outcome = llm.StreamOutcome{};
    try parser.fillOutcome(&outcome);
    try testing.expectEqualStrings("hello", outcome.text);
    try testing.expectEqual(@as(usize, 1), outcome.tool_calls.len);
    try testing.expectEqualStrings("toolu_9", outcome.tool_calls[0].tool_use_id);
    try testing.expectEqualStrings("{\"command\":\"ls -la\"}", outcome.tool_calls[0].input);
    try testing.expectEqualStrings("msg_42", outcome.request_id);
    try testing.expectEqual(@as(usize, 0), parser.thinkingBlocks().len); // 本流没有 thinking 块
}

test "anthropic: message_stop 缺失 → 解析器不自行终结（由 client 判提前断流）" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var parser = StreamParser.init(gpa, arena.allocator(), "claude-sonnet-4");
    defer parser.deinit();
    var sink = Sink.init(gpa);
    defer sink.deinit();

    const stream =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial\"}}\n\n";
    try runSse(gpa, stream, &sink, &parser);

    try testing.expect(!parser.saw_message_stop);
    try testing.expect(parser.saw_any_event);
    try testing.expectEqual(@as(usize, 1), sink.count(.text_delta));
}

test "anthropic: error 事件带 provider 错误码，可重试" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var parser = StreamParser.init(gpa, arena.allocator(), "m");
    defer parser.deinit();
    var sink = Sink.init(gpa);
    defer sink.deinit();

    const stream = "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n";
    try runSse(gpa, stream, &sink, &parser);
    try testing.expectEqual(common.ErrorCode.model_overloaded, parser.failure.?.code);
    try testing.expect(common.ErrorCode.model_overloaded.retryable());
    try testing.expectEqualStrings("Overloaded", parser.failure.?.message);
}

test "anthropic: extra_body 透传且不与 typed 字段撞车（顶层 key 去重）" {
    const gpa = testing.allocator;
    const body = try buildRequestBody(gpa, &.{
        .model = "real-model",
        .system = "",
        .messages = &.{},
        .max_tokens = 100,
    }, .{ .extra_body_json = "{\"model\":\"hacked\",\"top_k\":7}" });
    defer gpa.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"hacked\"") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"real-model\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"top_k\":7") != null);
}
