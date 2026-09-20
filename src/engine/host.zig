//! `engine/host.zig` —— `common.tool.Host` 的实现：工具与内核之间的**唯一通道**。
//!
//! 作用：让 `tools/` 能请求权限 / 提问 / 报进度 / 落盘大结果 / 读写待办，
//! 而**不必 import `engine`**（规则 3：实测 0 违反，必须保持）。
//!
//! 两个"经纪人"接口（由传输层实现）：
//!   - `PermissionBroker` —— 权限卡片往返（SSE / NDJSON / ACP 各自实现）
//!   - `InteractionBroker` —— 问答与计划审批
//!
//! ⚠️ 取消与拒绝的**文案必须区分**（协议 §4.3 与雷区）：拿到 "Permission denied"
//! 的模型会读成"这条路不通"，合理反应是换条路继续干（曾导致子代理改用 `cat` 绕过）；
//! 取消必须说清"整轮被中断，不要重试也不要绕过"。

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const util = @import("util");
const config = @import("config");
const sink_mod = @import("sink.zig");

pub const PermissionBroker = struct {
    ctx: *anyopaque,
    /// 发起一次权限往返；超时/无通道时由实现返回拒绝。
    request: *const fn (ctx: *anyopaque, req: common.perm.Request) anyerror!common.perm.Response,

    pub fn ask(self: PermissionBroker, req: common.perm.Request) !common.perm.Response {
        return self.request(self.ctx, req);
    }
};

pub const Question = struct {
    prompt: []const u8,
    options: []const common.tool.QuestionOption,
    multi_select: bool,
};

pub const InteractionBroker = struct {
    ctx: *anyopaque,
    ask: *const fn (ctx: *anyopaque, q: Question) anyerror!common.tool.Answer,

    pub fn askQuestion(self: InteractionBroker, q: Question) !common.tool.Answer {
        return self.ask(self.ctx, q);
    }
};

/// 无交互通道时的行为：**一律拒绝**（fail-closed），并把原因说清楚。
pub fn refusingBroker() PermissionBroker {
    return .{ .ctx = undefined, .request = refuse };
}

fn refuse(_: *anyopaque, _: common.perm.Request) anyerror!common.perm.Response {
    return .{
        .allowed = false,
        .message = "No interactive permission channel is available in this mode.",
        .denial_reason = .unavailable,
    };
}

pub fn noQuestionBroker() InteractionBroker {
    return .{ .ctx = undefined, .ask = noQuestion };
}

fn noQuestion(_: *anyopaque, _: Question) anyerror!common.tool.Answer {
    return .{};
}

pub const HostImpl = struct {
    gpa: Allocator,
    io: std.Io,
    paths: *const config.Paths,
    sink: sink_mod.EventSink,
    permission: PermissionBroker = refusingBroker(),
    interaction: InteractionBroker = noQuestionBroker(),
    todos: std.ArrayListUnmanaged(common.tool.TodoItem) = .empty,
    tool_use_id: []const u8 = "",

    pub fn host(self: *HostImpl) common.tool.Host {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = common.tool.Host.VTable{
        .requestPermission = requestPermission,
        .askQuestion = askQuestion,
        .emitProgress = emitProgress,
        .persistOutput = persistOutput,
        .writeTodos = writeTodos,
        .readTodos = readTodos,
        .notifyBackground = notifyBackground,
    };

    fn requestPermission(ptr: *anyopaque, req: common.perm.Request) anyerror!common.perm.Response {
        const self: *HostImpl = @ptrCast(@alignCast(ptr));
        return self.permission.ask(req);
    }

    fn askQuestion(
        ptr: *anyopaque,
        prompt: []const u8,
        options: []const common.tool.QuestionOption,
        multi_select: bool,
    ) anyerror!common.tool.Answer {
        const self: *HostImpl = @ptrCast(@alignCast(ptr));
        return self.interaction.askQuestion(.{
            .prompt = prompt,
            .options = options,
            .multi_select = multi_select,
        });
    }

    fn emitProgress(ptr: *anyopaque, ev: common.event.ToolProgressEvent) anyerror!void {
        const self: *HostImpl = @ptrCast(@alignCast(ptr));
        try self.sink.send(.{ .tool_progress = ev });
    }

    /// 大结果外置落盘：写到 `tool-results/<uuid>.txt`，返回可读回的绝对路径。
    fn persistOutput(ptr: *anyopaque, content: []const u8) anyerror![]const u8 {
        const self: *HostImpl = @ptrCast(@alignCast(ptr));
        const dir = try self.paths.toolResultsDir(self.gpa);
        defer self.gpa.free(dir);
        try util.io.mkdirp(self.io, dir);
        const name = try util.io.randomHex(self.io, self.gpa, 8);
        defer self.gpa.free(name);
        const path = try std.fmt.allocPrint(self.gpa, "{s}/{s}.txt", .{ dir, name });
        try util.io.writeFile(self.io, path, content);
        return path;
    }

    fn writeTodos(ptr: *anyopaque, items: []const common.tool.TodoItem) anyerror!void {
        const self: *HostImpl = @ptrCast(@alignCast(ptr));
        self.todos.clearRetainingCapacity();
        for (items) |it| try self.todos.append(self.gpa, it);
    }

    fn readTodos(ptr: *anyopaque, gpa: Allocator) anyerror![]common.tool.TodoItem {
        const self: *HostImpl = @ptrCast(@alignCast(ptr));
        const out = try gpa.alloc(common.tool.TodoItem, self.todos.items.len);
        @memcpy(out, self.todos.items);
        return out;
    }

    fn notifyBackground(ptr: *anyopaque, text: []const u8) anyerror!void {
        const self: *HostImpl = @ptrCast(@alignCast(ptr));
        try self.sink.send(.{ .status = .{ .message = text } });
    }
};

const testing = std.testing;

const TestBroker = struct {
    allow: bool = true,
    calls: usize = 0,

    fn request(ptr: *anyopaque, req: common.perm.Request) anyerror!common.perm.Response {
        const self: *TestBroker = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        _ = req;
        if (self.allow) return .{ .allowed = true };
        return common.perm.Response.denyByUser(common.perm.Response.MSG_DENIED);
    }
};

test "host: 权限往返与拒绝语义" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var broker = TestBroker{};
    var sink = sink_mod.CollectingSink.init(testing.allocator);
    defer sink.deinit();
    var paths = config.Paths{ .home = "/tmp", .cwd = "/tmp" };
    var h = HostImpl{
        .gpa = testing.allocator,
        .io = io,
        .paths = &paths,
        .sink = sink.sink(),
        .permission = .{ .ctx = &broker, .request = TestBroker.request },
    };
    defer h.todos.deinit(testing.allocator);
    const erased = h.host();
    const req = common.perm.Request{
        .session_id = "s",
        .agent_id = "",
        .tool_use_id = "t",
        .tool_name = "Bash",
        .tool_risk_level = .high,
        .input_summary = "rm -rf /",
        .cwd = "/",
        .reason = "destructive",
    };
    const resp = try erased.requestPermission(req);
    try testing.expect(resp.allowed);
    try testing.expectEqual(@as(usize, 1), broker.calls);
}

test "host: 默认（无通道）一律拒绝 —— fail-closed" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var sink = sink_mod.CollectingSink.init(testing.allocator);
    defer sink.deinit();
    var paths = config.Paths{ .home = "/tmp", .cwd = "/tmp" };
    var h = HostImpl{ .gpa = testing.allocator, .io = io, .paths = &paths, .sink = sink.sink() };
    defer h.todos.deinit(testing.allocator);
    const req = common.perm.Request{
        .session_id = "s",
        .agent_id = "",
        .tool_use_id = "t",
        .tool_name = "Write",
        .tool_risk_level = .write,
        .input_summary = "x",
        .cwd = "/",
        .reason = "y",
    };
    const resp = try h.host().requestPermission(req);
    try testing.expect(!resp.allowed);
    try testing.expectEqual(common.perm.DenialReason.unavailable, resp.denial_reason.?);
}

test "host: 待办读写" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var sink = sink_mod.CollectingSink.init(testing.allocator);
    defer sink.deinit();
    var paths = config.Paths{ .home = "/tmp", .cwd = "/tmp" };
    var h = HostImpl{ .gpa = testing.allocator, .io = io, .paths = &paths, .sink = sink.sink() };
    defer h.todos.deinit(testing.allocator);
    const erased = h.host();
    try erased.writeTodos(&.{
        .{ .id = "1", .content = "写测试", .status = "pending" },
    });
    const back = try erased.readTodos(testing.allocator);
    defer testing.allocator.free(back);
    try testing.expectEqual(@as(usize, 1), back.len);
    try testing.expectEqualStrings("写测试", back[0].content);
}

test "host: 大结果落盘返回可读回路径" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var sink = sink_mod.CollectingSink.init(testing.allocator);
    defer sink.deinit();
    const rnd = try util.io.randomHex(io, testing.allocator, 6);
    defer testing.allocator.free(rnd);
    const home = try std.fmt.allocPrint(testing.allocator, "/tmp/zigent-host-test-{s}", .{rnd});
    defer testing.allocator.free(home);
    defer util.io.removeTree(io, home) catch {};
    var paths = config.Paths{ .home = home, .cwd = "/tmp" };
    var h = HostImpl{ .gpa = testing.allocator, .io = io, .paths = &paths, .sink = sink.sink() };
    defer h.todos.deinit(testing.allocator);
    const path = try h.host().persistOutput("很长的内容");
    defer testing.allocator.free(path);
    const back = try util.io.readFileAlloc(io, testing.allocator, path, 1 << 20);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("很长的内容", back);
}
