//! `Tool` vtable + `ToolResult` + `ToolContext` —— L0 契约层。
//!
//! 规则 3（文档 03 §2）：**`tools` 绝不 import `engine`**。
//! 工具通过本文件定义的 `ToolContext`（弱类型上下文总线 + vtable）反向取运行时状态。
//! 实测朴素实现里这条 0 违反，必须保持。
//!
//! ⚠️ 本文件是 `common/` 里**唯一**引用 `std.Io` 的文件：它承载"宿主总线"。
//! `json/content/message/usage/event/perm/schema` 全部保持纯逻辑、零 IO。

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const schema = @import("schema.zig");
const perm = @import("perm.zig");
const event = @import("event.zig");

/// 已知 metadata 键（P3：这些也要显式化，不用裸字符串）。
pub const KEY_CONTENT_BLOCKS = "contentBlocks";
pub const KEY_STRUCTURED_CONTENT = "structuredContent";
pub const KEY_PERSISTED_OUTPUT_PATH = "persistedOutputPath";
pub const KEY_COMPLETED_WORKFLOW_ID = "completedWorkflowId";

pub const ToolResult = struct {
    output: []const u8,
    is_error: bool = false,
    metadata: json.Map = .{},

    /// 给**模型**看的长度上限。
    pub const MODEL_VIEW_MAX_LENGTH = 8000;

    /// ⚠️ 工具结果落盘阈值 `400_000`：名字叫 BYTES，**实际比较的是 UTF-16 char**
    /// （雷区 H）。本项目按 **code point** 计（CJK 在 BMP 内与 UTF-16 一致）。
    pub const MAX_TOOL_RESULT_CHARS = 400_000;

    pub fn ok(output: []const u8) ToolResult {
        return .{ .output = output };
    }

    pub fn err(output: []const u8) ToolResult {
        return .{ .output = output, .is_error = true };
    }

    /// 截断到 8000 code point（给模型看的视图）。
    pub fn modelView(self: ToolResult) []const u8 {
        const usage = @import("usage.zig");
        return usage.truncateCodePoints(self.output, MODEL_VIEW_MAX_LENGTH);
    }

    /// 原样（user / transcript 视图）。**刻意与 modelView 分开，别合并。**
    pub fn userView(self: ToolResult) []const u8 {
        return self.output;
    }

    pub fn persistedOutputPath(self: ToolResult) ?[]const u8 {
        const v = self.metadata.get(KEY_PERSISTED_OUTPUT_PATH) orelse return null;
        return v.asString();
    }

    /// 是否需要外置落盘（超阈值）。
    pub fn needsPersistence(self: ToolResult) bool {
        return @import("usage.zig").countCodePoints(self.output) > MAX_TOOL_RESULT_CHARS;
    }
};

/// 待办项（`TodoWrite` 的**内部轨**：字段集与模型轨不同 —— 见文档 03 §9.7）。
pub const TodoItem = struct {
    id: []const u8,
    content: []const u8,
    status: []const u8,
    priority: []const u8 = "",
    /// 模型轨的 `activeForm`：`execute` **完全忽略**它，只做记录。
    active_form: []const u8 = "",
};

/// 交互应答（`ask_user_question` / 计划模式统一信封）。
pub const Answer = struct {
    selected_option_ids: []const []const u8 = &.{},
    free_text: []const u8 = "",
};

pub const QuestionOption = struct {
    option_id: []const u8,
    label: []const u8,
    description: []const u8 = "",
};

/// 宿主服务总线 —— 工具**只**通过它请求权限 / 提问 / 报进度 / 落盘。
pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 请求权限裁决。引擎实现为"四级防御 + 权限卡片"。
        requestPermission: *const fn (ptr: *anyopaque, req: perm.Request) anyerror!perm.Response,
        /// 提问（无交互通道时返回空应答）。
        askQuestion: *const fn (
            ptr: *anyopaque,
            prompt: []const u8,
            options: []const QuestionOption,
            multi_select: bool,
        ) anyerror!Answer,
        /// 进度上报（可能被丢弃）。
        emitProgress: *const fn (ptr: *anyopaque, ev: event.ToolProgressEvent) anyerror!void,
        /// 大结果外置落盘，返回可读回的路径/引用。
        persistOutput: *const fn (ptr: *anyopaque, content: []const u8) anyerror![]const u8,
        /// 写待办列表（`TodoWrite` 用；引擎持有会话内的真实状态）。
        writeTodos: *const fn (ptr: *anyopaque, items: []const TodoItem) anyerror!void,
        /// 读待办列表（返回内存在传入 gpa 上，调用方释放）。
        readTodos: *const fn (ptr: *anyopaque, gpa: Allocator) anyerror![]TodoItem,
        /// 后台子代理/任务回流通知（`ext/` 用；首期可返回 error.Unsupported）。
        notifyBackground: *const fn (ptr: *anyopaque, text: []const u8) anyerror!void,
    };

    pub fn requestPermission(self: Host, req: perm.Request) !perm.Response {
        return self.vtable.requestPermission(self.ptr, req);
    }

    pub fn askQuestion(
        self: Host,
        prompt: []const u8,
        options: []const QuestionOption,
        multi_select: bool,
    ) !Answer {
        return self.vtable.askQuestion(self.ptr, prompt, options, multi_select);
    }

    pub fn emitProgress(self: Host, ev: event.ToolProgressEvent) !void {
        return self.vtable.emitProgress(self.ptr, ev);
    }

    pub fn persistOutput(self: Host, content: []const u8) ![]const u8 {
        return self.vtable.persistOutput(self.ptr, content);
    }

    pub fn writeTodos(self: Host, items: []const TodoItem) !void {
        return self.vtable.writeTodos(self.ptr, items);
    }

    pub fn readTodos(self: Host, gpa: Allocator) ![]TodoItem {
        return self.vtable.readTodos(self.ptr, gpa);
    }

    pub fn notifyBackground(self: Host, text: []const u8) !void {
        return self.vtable.notifyBackground(self.ptr, text);
    }
};

/// 工具执行上下文（**唯一的运行时状态入口**）。
pub const ToolContext = struct {
    gpa: Allocator,
    io: std.Io,
    cwd: []const u8,
    session_id: []const u8 = "",
    /// 当前工具调用的 id（进度/权限事件回带用）
    tool_use_id: []const u8 = "",
    host: ?Host = null,
    /// 已取消？（工具应在长循环里轮询）
    cancelled: ?*const std.atomic.Value(bool) = null,

    pub fn isCancelled(self: *const ToolContext) bool {
        const c = self.cancelled orelse return false;
        return c.load(.acquire);
    }

    pub fn child(self: *const ToolContext, tool_use_id: []const u8) ToolContext {
        var c = self.*;
        c.tool_use_id = tool_use_id;
        return c;
    }
};

/// 工具定义。`check_permissions` 是**可选**的：
/// 实测首期 8 个工具一个都没覆盖它（全走 default defer），
/// 强制实现 = 8 个空函数。
pub const Tool = struct {
    name: []const u8,
    /// 遗留别名（`Read` ↔ `read_file`）：transcript / 旧技能 / 旧 hook 配置里都是遗留名。
    aliases: []const []const u8 = &.{},
    description: []const u8,
    /// **单一真源**
    spec: schema.Spec = .{},
    is_read_only: *const fn (input: []const u8) bool = alwaysFalse,
    is_destructive: *const fn (input: []const u8) bool = alwaysFalse,
    is_concurrency_safe: *const fn (input: []const u8) bool = alwaysTrue,
    max_result_chars: usize = ToolResult.MAX_TOOL_RESULT_CHARS,
    /// 唯一副作用点。
    execute: *const fn (ctx: *ToolContext, input: []const u8) anyerror!ToolResult,
    /// 缺省 `defer`。
    check_permissions: ?*const fn (self: *const Tool, input: []const u8, ctx: *const ToolContext) perm.Outcome = null,

    fn alwaysFalse(_: []const u8) bool {
        return false;
    }
    fn alwaysTrue(_: []const u8) bool {
        return true;
    }

    /// 名字/别名匹配。
    pub fn matches(self: Tool, name: []const u8) bool {
        if (std.mem.eql(u8, self.name, name)) return true;
        for (self.aliases) |a| {
            if (std.mem.eql(u8, a, name)) return true;
        }
        return false;
    }

    pub fn permissions(self: Tool, input: []const u8, ctx: *const ToolContext) perm.Outcome {
        if (self.check_permissions) |f| return f(&self, input, ctx);
        return perm.Outcome.deferred("tool does not self-assess", .safe);
    }
};

const testing = std.testing;

fn fakeReadOnly(_: []const u8) bool {
    return true;
}
fn fakeExec(_: *ToolContext, _: []const u8) anyerror!ToolResult {
    return ToolResult.ok("ok");
}

test "tool: 缺省 check_permissions 返回 defer" {
    const t = Tool{
        .name = "Read",
        .description = "read",
        .is_read_only = fakeReadOnly,
        .execute = fakeExec,
    };
    var ctx = ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/" };
    try testing.expectEqual(perm.Verdict.deferred, t.permissions("{}", &ctx).verdict);
    try testing.expect(t.is_read_only("{}"));
}

test "tool: 别名匹配" {
    const t = Tool{ .name = "Read", .aliases = &.{"read_file"}, .description = "d", .execute = fakeExec };
    try testing.expect(t.matches("Read"));
    try testing.expect(t.matches("read_file"));
    try testing.expect(!t.matches("Write"));
}

test "tool: modelView 截断到 8000 code point，userView 原样" {
    const long = "中" ** 9000;
    const r = ToolResult.ok(long);
    try testing.expectEqual(@as(usize, 8000), @import("usage.zig").countCodePoints(r.modelView()));
    try testing.expectEqual(@as(usize, 27000), r.userView().len);
}

test "tool: 大结果判定按 code point 而不是字节（CJK 差 3 倍）" {
    // 100_000 个汉字 = 300_000 字节 < 400_000（按字节会误判为"不用落盘"）
    const cjk = "中" ** 100_000;
    const r = ToolResult.ok(cjk);
    try testing.expect(!r.needsPersistence());
    // 500_000 个汉字 = 1_500_000 字节 → 两种口径都超
    const big = "中" ** 500_000;
    try testing.expect(ToolResult.ok(big).needsPersistence());
}

test "tool: persistedOutputPath 读取" {
    var m = json.Map{};
    try m.put(testing.allocator, KEY_PERSISTED_OUTPUT_PATH, .{ .string = "/tmp/out" });
    defer m.entries.deinit(testing.allocator);
    const r = ToolResult{ .output = "x", .metadata = m };
    try testing.expectEqualStrings("/tmp/out", r.persistedOutputPath().?);
}

test "tool: 取消令牌" {
    var flag = std.atomic.Value(bool).init(false);
    var ctx = ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/", .cancelled = &flag };
    try testing.expect(!ctx.isCancelled());
    flag.store(true, .release);
    try testing.expect(ctx.isCancelled());
}
