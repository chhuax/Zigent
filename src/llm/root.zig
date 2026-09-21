//! llm/ —— L1 接入：Provider 传输（系统的唯一外网出口）。
//!
//! 本文件是 `docs/internal/INTERFACES-v1.md` §4.2 的**逐字实现**，
//! 并 re-export 纯逻辑子模块。分层（文档 03 §7.3）：
//!
//! ```text
//! engine
//!   └─ Client（§4.2 冻结 vtable）
//!        └─ RoutingClient        选 provider
//!             └─ RetryingClient   emittedOnAttempt 闸门 + 退避
//!                  └─ ProviderAttempt  ── transport（http.zig）
//!                       ├─ anthropic.zig ─┐
//!                       └─ openai.zig    ─┴─ sse.zig（读）─ toolcalls.zig
//! ```
//!
//! 允许的依赖（由 `build.zig` 声明；**别的模块 import 不进来**）：
//!   ← common
//!   ← util
//!
//! 铁律：不用 `std.json`（用 `common.json`）；不用 `std.Io` 系统级原语
//! （socket / file / sleep / random 一律走 `util.io` / `util.proc`）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const util = @import("util");

/// 模块自述 —— 也用来**强制引用每个声明的依赖**。
pub const module_info = .{
    .name = "llm",
    .layer = "L1 接入",
    .deps = &[_][]const u8{ "common", "util" },
};

comptime {
    _ = common.module_info.name;
    _ = util.module_info.name;
}

// ── 纯逻辑子模块 ─────────────────────────────────────────────────────────────

pub const sse = @import("sse.zig");
pub const toolcalls = @import("toolcalls.zig");
pub const anthropic = @import("anthropic.zig");
pub const openai = @import("openai.zig");
pub const http = @import("http.zig");
pub const client = @import("client.zig");

// ── 契约类型（INTERFACES §4.2，**逐字**）──────────────────────────────────────

pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    /// 原始 JSON 对象字符串（`common.schema.Spec.modelSchemaAlloc` 的产物）。
    /// 原样透传，绝不 parse → re-serialize。
    schema_json: []const u8,
};

pub const ApiRequest = struct {
    model: []const u8,
    system: []const u8,
    messages: []const common.Message,
    tools: []const ToolSpec = &.{},
    max_tokens: i64 = 8192,
    temperature: ?f64 = null,
    stream: bool = true,
};

pub const ToolCall = struct {
    tool_use_id: []const u8,
    tool_name: []const u8,
    input: []const u8,
};

pub const StreamOutcome = struct {
    usage: common.Usage = .{},
    stop_reason: common.StopReason = .end_turn,
    text: []const u8 = "",
    reasoning: []const u8 = "",
    tool_calls: []const ToolCall = &.{},
    request_id: []const u8 = "",
    /// **流式重试的唯一闸门**：向用户吐过非 Error 事件后禁止重试。
    emitted: bool = false,
};

pub const StreamSink = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, ev: common.StreamEvent) anyerror!void,

    pub fn send(self: StreamSink, ev: common.StreamEvent) !void {
        return self.emit(self.ctx, ev);
    }
};

pub const Client = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    gpa: Allocator,

    pub const VTable = struct {
        streamChat: *const fn (
            ptr: *anyopaque,
            io: std.Io,
            req: *const ApiRequest,
            sink: StreamSink,
            cancel: ?*const std.atomic.Value(bool),
        ) anyerror!StreamOutcome,
        deinit: *const fn (ptr: *anyopaque, gpa: Allocator) void,
    };

    pub fn streamChat(
        self: Client,
        io: std.Io,
        req: *const ApiRequest,
        sink: StreamSink,
        cancel: ?*const std.atomic.Value(bool),
    ) !StreamOutcome {
        return self.vtable.streamChat(self.ptr, io, req, sink, cancel);
    }

    pub fn deinit(self: Client) void {
        self.vtable.deinit(self.ptr, self.gpa);
    }
};

pub const ProviderConfig = struct {
    kind: []const u8, // "anthropic" | "openai"
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    user_agent: []const u8 = "zigent/0.1.0",
    /// `ZIGENT_EXTRA_BODY` 透传（顶层 key 去重后合并）。
    extra_body_json: ?[]const u8 = null,
    return_thinking: bool = true,
    send_thinking: bool = false,
    max_retries: u32 = 3,
    timeout_ms: u64 = 600_000,
};

/// 真实 HTTP（`std.http.Client`；见 `http.zig` 文件头关于流式不缓冲的说明）。
pub fn initProvider(gpa: Allocator, io: std.Io, cfg: ProviderConfig) !Client {
    return client.initProvider(gpa, io, cfg);
}

/// 测试用，**零网络**：按脚本回放 SSE 字节，走与真实路径完全相同的解析栈。
pub fn initMock(gpa: Allocator, script: []const MockTurn) !Client {
    return client.initMock(gpa, script);
}

pub const MockTurn = struct {
    sse_bytes: []const u8,
    expect_path: ?[]const u8 = null,
};

// ── 测试聚合 ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "llm: 依赖链可解析" {
    try testing.expectEqualStrings("llm", module_info.name);
    try testing.expectEqualStrings("common", common.module_info.name);
    try testing.expectEqualStrings("util", util.module_info.name);
}

test "llm: 契约类型形状（冻结）" {
    const req = ApiRequest{ .model = "m", .system = "s", .messages = &.{} };
    try testing.expectEqual(@as(i64, 8192), req.max_tokens);
    try testing.expect(req.stream);
    const out = StreamOutcome{};
    try testing.expect(!out.emitted);
    try testing.expectEqual(common.StopReason.end_turn, out.stop_reason);
    const cfg = ProviderConfig{ .kind = "anthropic", .base_url = "b", .api_key = "k", .model = "m" };
    try testing.expectEqual(@as(u32, 3), cfg.max_retries);
    try testing.expectEqual(@as(u64, 600_000), cfg.timeout_ms);
}

test {
    _ = @import("sse.zig");
    _ = @import("toolcalls.zig");
    _ = @import("anthropic.zig");
    _ = @import("openai.zig");
    _ = @import("http.zig");
    _ = @import("client.zig");
}
