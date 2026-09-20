//! `engine/tool_exec.zig` —— 工具编排：**校验 → 权限 → 并发分批 → 顺序稳定 → 结果外置**。
//!
//! ## 为什么顺序必须稳定
//!
//! 模型给出的 tool_use 顺序是它对世界的推理顺序；把结果按完成顺序回填会破坏
//! 配对与语义。所以：**并发执行，按原序回填**。
//!
//! ## 并发分批
//!
//! 只有 `is_concurrency_safe` 的工具能与同批并跑；分批边界按原序切分。
//! 首期实现是**顺序执行 + 精确分批规划**（`planBatches`），
//! 分批结果已可用于将来的真并发（顺序语义与并发的正确性已固定）。
//!
//! ## 权限在这里，且**只在这里**
//!
//! 工具执行器的唯一调用点是 engine —— 保证"没有任何路径能绕过闸门"。

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const tools = @import("tools");
const perm = @import("perm");
const util = @import("util");

const Turn = @import("turn.zig").Turn;
const rt_mod = @import("rt.zig");
const host_mod = @import("host.zig");
const sink_mod = @import("sink.zig");

/// 工具查找的**窄接口** —— 让编排逻辑可以脱离 `tools.Registry` 单测，
/// 也避免 `engine` 触碰 registry 的内部字段。
pub const ToolLookup = struct {
    ctx: *anyopaque,
    get_fn: *const fn (ctx: *anyopaque, name: []const u8) ?common.Tool,

    pub fn get(self: ToolLookup, name: []const u8) ?common.Tool {
        return self.get_fn(self.ctx, name);
    }

    pub fn fromRegistry(reg: *const tools.Registry) ToolLookup {
        return .{ .ctx = @constCast(reg), .get_fn = registryGet };
    }

    fn registryGet(ctx: *anyopaque, name: []const u8) ?common.Tool {
        const reg: *const tools.Registry = @ptrCast(@alignCast(ctx));
        return reg.get(name);
    }
};

pub const Batch = struct {
    start: usize,
    len: usize,
    /// 本批内的调用**可以**并发（首期顺序执行，语义已固定）
    concurrent_safe: bool,
};

/// 按 `is_concurrency_safe` 把调用序列切成批次（**保持原序**）。
pub fn planBatches(
    gpa: Allocator,
    calls: []const common.ToolUseBlock,
    lookup: ToolLookup,
) Allocator.Error![]Batch {
    var out = std.ArrayListUnmanaged(Batch).empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (i < calls.len) {
        const tool = lookup.get(calls[i].tool_name);
        const safe = if (tool) |t| t.is_concurrency_safe(calls[i].input) else false;
        if (!safe) {
            try out.append(gpa, .{ .start = i, .len = 1, .concurrent_safe = false });
            i += 1;
            continue;
        }
        var j = i;
        while (j < calls.len) : (j += 1) {
            const t2 = lookup.get(calls[j].tool_name);
            const s2 = if (t2) |t| t.is_concurrency_safe(calls[j].input) else false;
            if (!s2) break;
        }
        try out.append(gpa, .{ .start = i, .len = j - i, .concurrent_safe = true });
        i = j;
    }
    return out.toOwnedSlice(gpa);
}

pub const ExecResult = struct {
    results: []common.ToolResultBlock,
    /// 是否因为取消而提前结束（未执行的调用由 `Turn.finishInterrupted` 补齐）
    interrupted: bool = false,
    tool_call_count: usize = 0,
};

pub const Executor = struct {
    /// 最近一次拒绝的文案（区分"用户拒绝"与"整轮取消"）
    last_deny_message: []const u8 = common.perm.Response.MSG_DENIED,
    rt: *const rt_mod.Rt,
    registry: *const tools.Registry,
    checker: *perm.Checker,
    host_impl: *host_mod.HostImpl,
    sink: sink_mod.EventSink,

    /// 执行一轮里的全部工具调用。
    ///
    /// 返回的结果**与入参同序**；取消时返回已完成的那些（长度 < 调用数）。
    pub fn executeTurn(
        self: *Executor,
        gpa: Allocator,
        assistant: common.Message,
    ) !ExecResult {
        var calls = std.ArrayListUnmanaged(common.ToolUseBlock).empty;
        defer calls.deinit(gpa);
        for (assistant.content) |b| {
            if (b.asToolUse()) |tu| try calls.append(gpa, tu);
        }

        var results = std.ArrayListUnmanaged(common.ToolResultBlock).empty;
        errdefer results.deinit(gpa);

        var interrupted = false;
        for (calls.items) |call| {
            if (self.rt.cancelled()) {
                interrupted = true;
                break;
            }
            const r = try self.executeOne(gpa, call);
            try results.append(gpa, r);
        }

        return .{
            .results = try results.toOwnedSlice(gpa),
            .interrupted = interrupted,
            .tool_call_count = calls.items.len,
        };
    }

    fn executeOne(self: *Executor, gpa: Allocator, call: common.ToolUseBlock) !common.ToolResultBlock {
        const started = util.io.monotonicMillis(self.rt.io);

        // ── 0. 未知工具 ──
        const tool = self.registry.get(call.tool_name) orelse {
            return .{
                .tool_use_id = call.tool_use_id,
                .output = try std.fmt.allocPrint(
                    gpa,
                    "Unknown tool: {s}. Available tools: {s}.",
                    .{ call.tool_name, try self.toolNameList(gpa) },
                ),
                .is_error = true,
            };
        };

        // ── 1. 入参校验（**与模型 schema 同源**，只读，不改写 input）──
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        if (try tool.spec.validate(arena.allocator(), call.input)) |msg| {
            // `tool_call` 事件已由 llm 在"参数拼装完成"时发出（协议 §3.3(b)），
            // 这里只补 `tool_result`（校验失败也算一次结果，客户端才不会挂起）。
            try self.sink.send(.{ .tool_result = .{
                .tool_use_id = call.tool_use_id,
                .output = msg,
                .is_error = true,
                .duration_ms = util.io.monotonicMillis(self.rt.io) - started,
                .error_code = "malformed_tool_input",
                .error_message = msg,
            } });
            return .{ .tool_use_id = call.tool_use_id, .output = msg, .is_error = true };
        }

        // ── 2. 权限闸门（唯一调用点）──
        const path = extractString(arena.allocator(), call.input, &.{ "file_path", "path", "notebook_path" }) catch null;
        const command = extractString(arena.allocator(), call.input, &.{"command"}) catch null;

        const outcome = self.checker.evaluate(.{
            .tool_name = tool.name,
            .tool_use_id = call.tool_use_id,
            .input = call.input,
            .is_read_only = tool.is_read_only(call.input),
            .is_destructive = tool.is_destructive(call.input),
            .path = path,
            .command = command,
        }) catch |err| {
            return self.errorResult(gpa, call, started, "permission check failed", @errorName(err));
        };

        switch (outcome.verdict) {
            .deny => return self.errorResult(gpa, call, started, outcome.reason, "permission_denied"),
            .ask => {
                const allowed = try self.promptPermission(gpa, &tool, call, outcome, path);
                if (!allowed) {
                    return self.errorResult(gpa, call, started, self.last_deny_message, "permission_denied");
                }
            },
            .allow, .deferred => {},
        }

        // ── 3. 执行 ──
        // （`tool_call` 事件由 llm 发；此处只保证 `tool_result` 一定紧随其后）
        self.host_impl.tool_use_id = call.tool_use_id;
        var ctx = common.ToolContext{
            .gpa = gpa,
            .io = self.rt.io,
            .cwd = self.rt.cwd,
            .session_id = self.rt.session_id,
            .tool_use_id = call.tool_use_id,
            .host = self.host_impl.host(),
            .cancelled = self.rt.cancel,
        };

        var result = tool.execute(&ctx, call.input) catch |err| common.ToolResult.err(
            try std.fmt.allocPrint(gpa, "Tool {s} failed: {s}", .{ tool.name, @errorName(err) }),
        );

        // ── 5. 结果外置与截断（**按 code point，不是字节**）──
        result.output = try self.finalizeOutput(gpa, &result);

        const duration = util.io.monotonicMillis(self.rt.io) - started;
        try self.sink.send(.{ .tool_result = .{
            .tool_use_id = call.tool_use_id,
            .output = result.output,
            .is_error = result.is_error,
            .duration_ms = duration,
            .error_code = if (result.is_error) "tool_error" else null,
            .error_message = if (result.is_error) util_mod.truncate(result.output, 500) else null,
        } });

        return .{
            .tool_use_id = call.tool_use_id,
            .output = result.output,
            .is_error = result.is_error,
        };
    }

    /// 结果超过上限 → 落盘留引用 + `<persisted-output>` 占位（截断会丢证据）。
    fn finalizeOutput(self: *Executor, gpa: Allocator, result: *common.ToolResult) ![]const u8 {
        if (!result.needsPersistence()) return result.output;
        const path = self.host_impl.host().persistOutput(result.output) catch {
            // 落盘失败也不能把原样大文本塞给模型 —— 截断兜底
            return common.ToolResult.modelView(result.*);
        };
        return std.fmt.allocPrint(
            gpa,
            "{s}\n<persisted-output path=\"{s}\" totalChars=\"{d}\" />",
            .{ common.ToolResult.modelView(result.*), path, common.usage.countCodePoints(result.output) },
        );
    }

    /// `ask` → 权限卡片往返。
    fn promptPermission(
        self: *Executor,
        gpa: Allocator,
        tool: *const common.Tool,
        call: common.ToolUseBlock,
        outcome: common.perm.Outcome,
        path: ?[]const u8,
    ) !bool {
        _ = path;
        const summary = perm.describeTool(gpa, tool.name, call.input, self.rt.cwd) catch
            try std.fmt.allocPrint(gpa, "Tool: {s}", .{tool.name});
        var raw: [1000]u8 = undefined;
        const raw_input = util_mod.truncateInto(&raw, call.input);

        const req = common.perm.Request{
            .session_id = self.rt.session_id,
            .agent_id = "",
            .tool_use_id = call.tool_use_id,
            .tool_name = tool.name,
            .tool_risk_level = outcome.risk_level,
            .command_risk_level = outcome.command_risk_level,
            .risk_flags = &.{},
            .input_summary = summary,
            .raw_input = raw_input,
            .cwd = self.rt.cwd,
            .reason = outcome.reason,
            .trace = outcome.trace,
        };

        const resp = self.host_impl.host().requestPermission(req) catch {
            self.last_deny_message = common.perm.Response.MSG_DENIED;
            return false;
        };

        // 身份校验：不一致 → unavailable（否则并发子代理会互相回答对方的卡片）
        if (!resp.matchesIdentity(req)) {
            self.last_deny_message = "Permission response identity mismatch";
            return false;
        }
        if (resp.allowed) {
            if (resp.cache_decision) {
                self.checker.cacheAllowAlways(gpa, tool.name, null, tool.is_read_only(call.input)) catch {};
            }
            return true;
        }
        self.last_deny_message = switch (resp.denial_reason orelse .user_denied) {
            .cancelled => common.perm.Response.MSG_CANCELLED,
            .timed_out => common.perm.Response.MSG_TIMEOUT,
            .unavailable => resp.message,
            else => common.perm.Response.MSG_DENIED,
        };
        return false;
    }

    fn errorResult(
        self: *Executor,
        _: Allocator,
        call: common.ToolUseBlock,
        started: i64,
        message: []const u8,
        code: []const u8,
    ) !common.ToolResultBlock {
        try self.sink.send(.{ .tool_result = .{
            .tool_use_id = call.tool_use_id,
            .output = message,
            .is_error = true,
            .duration_ms = util.io.monotonicMillis(self.rt.io) - started,
            .error_code = code,
            .error_message = message,
        } });
        return .{ .tool_use_id = call.tool_use_id, .output = message, .is_error = true };
    }

    fn toolNameList(self: *Executor, gpa: Allocator) ![]const u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(gpa);
        for (self.registry.tools, 0..) |t, i| {
            if (i > 0) try out.appendSlice(gpa, ", ");
            try out.appendSlice(gpa, t.name);
        }
        return out.toOwnedSlice(gpa);
    }
};

/// 从原始 JSON 里**只读地**取一个字符串字段（绝不复写 input）。
pub fn extractString(gpa: Allocator, raw: []const u8, keys: []const []const u8) !?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const v = common.json.parse(arena.allocator(), raw) catch return null;
    for (keys) |k| {
        if (v.getString(k)) |s| return try gpa.dupe(u8, s);
    }
    return null;
}

const util_mod = struct {
    fn truncate(s: []const u8, n: usize) []const u8 {
        return common.usage.truncateCodePoints(s, n);
    }
    fn truncateInto(buf: []u8, s: []const u8) []const u8 {
        const t = common.usage.truncateCodePoints(s, buf.len);
        @memcpy(buf[0..t.len], t);
        return buf[0..t.len];
    }
};

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const content = common.content;

fn concSafeTrue(_: []const u8) bool {
    return true;
}
fn concSafeFalse(_: []const u8) bool {
    return false;
}
fn fakeExec(_: *common.ToolContext, _: []const u8) anyerror!common.ToolResult {
    return common.ToolResult.ok("done");
}

/// ⚠️ 不能用函数内部的 `var` 当状态（那是**全局**，所有实例共享）。
/// 并发安全性通过**传不同的函数指针**来表达。
fn fakeTool(name: []const u8, safe: bool) common.Tool {
    return .{
        .name = name,
        .description = "fake",
        .execute = fakeExec,
        .is_concurrency_safe = if (safe) concSafeTrue else concSafeFalse,
    };
}

const FakeRegistry = struct {
    items: []const common.Tool,
    fn get(ctx: *anyopaque, name: []const u8) ?common.Tool {
        const self: *FakeRegistry = @ptrCast(@alignCast(ctx));
        for (self.items) |t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }
    fn lookup(self: *FakeRegistry) ToolLookup {
        return .{ .ctx = self, .get_fn = FakeRegistry.get };
    }
};

test "tool_exec: 分批 —— 非并发安全的工具单独成批" {
    var reg = FakeRegistry{ .items = &.{ fakeTool("A", true), fakeTool("B", false), fakeTool("C", true) } };
    const calls = [_]common.ToolUseBlock{
        .{ .tool_use_id = "1", .tool_name = "A", .input = "{}" },
        .{ .tool_use_id = "2", .tool_name = "B", .input = "{}" },
        .{ .tool_use_id = "3", .tool_name = "C", .input = "{}" },
    };
    const batches = try planBatches(testing.allocator, &calls, reg.lookup());
    defer testing.allocator.free(batches);
    try testing.expectEqual(@as(usize, 3), batches.len);
    try testing.expect(batches[0].concurrent_safe);
    try testing.expect(!batches[1].concurrent_safe);
}

test "tool_exec: 连续并发安全工具合并成一批（顺序不变）" {
    var reg = FakeRegistry{ .items = &.{ fakeTool("A", true), fakeTool("C", true) } };
    const calls = [_]common.ToolUseBlock{
        .{ .tool_use_id = "1", .tool_name = "A", .input = "{}" },
        .{ .tool_use_id = "2", .tool_name = "C", .input = "{}" },
    };
    const batches = try planBatches(testing.allocator, &calls, reg.lookup());
    defer testing.allocator.free(batches);
    try testing.expectEqual(@as(usize, 1), batches.len);
    try testing.expectEqual(@as(usize, 2), batches[0].len);
}

test "tool_exec: 未知工具单独成批（fail-safe）" {
    var reg = FakeRegistry{ .items = &.{fakeTool("A", true)} };
    const calls = [_]common.ToolUseBlock{
        .{ .tool_use_id = "1", .tool_name = "Nope", .input = "{}" },
    };
    const batches = try planBatches(testing.allocator, &calls, reg.lookup());
    defer testing.allocator.free(batches);
    try testing.expectEqual(@as(usize, 1), batches.len);
    try testing.expect(!batches[0].concurrent_safe);
}

test "tool_exec: 只读取字段，不改写 input（I1）" {
    const raw = "{\"file_path\": \"/a/b\",   \"command\":\"ls\"}";
    const p = try extractString(testing.allocator, raw, &.{"file_path"});
    defer if (p) |v| testing.allocator.free(v);
    try testing.expectEqualStrings("/a/b", p.?);
    // 原文没被动过
    try testing.expectEqualStrings("{\"file_path\": \"/a/b\",   \"command\":\"ls\"}", raw);
}

test "tool_exec: 缺字段返回 null 而不是 panic" {
    const p = try extractString(testing.allocator, "{}", &.{"file_path"});
    try testing.expect(p == null);
    const q = try extractString(testing.allocator, "not json", &.{"file_path"});
    try testing.expect(q == null);
}
