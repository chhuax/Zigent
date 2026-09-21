//! `tools/todo.zig` —— `TodoWrite`（别名 `todo_write`，文档 05 §4.7）。
//!
//! ★ 两条轨的字段集**本来就不同**（T1）：
//!   模型轨：`content` / `status` / `activeForm`；
//!   内部轨：`id` / `content` / `status` / `priority`（+ `active_form` 仅记录）。
//! 本文件把模型轨交给 `specs.todo_item_spec` 校验，然后在 execute 里**显式映射**
//! 到 `common.tool.TodoItem`，再经 `ctx.host.writeTodos` 落库、`readTodos` 读回。
//! `activeForm` 只做记录，**行为上完全忽略**（T1）。

const std = @import("std");
const common = @import("common");
const json = common.json;
const specs = @import("specs.zig");
const truncate = @import("truncate.zig");

pub const spec = specs.todo_spec;

pub const definition = common.Tool{
    .name = "TodoWrite",
    .aliases = &.{"todo_write"},
    .description = "Write the session todo list",
    .spec = spec,
    .is_read_only = alwaysFalse,
    .is_destructive = alwaysFalse,
    .is_concurrency_safe = alwaysFalse,
    .max_result_chars = common.ToolResult.MAX_TOOL_RESULT_CHARS,
    .execute = execute,
};

fn alwaysFalse(_: []const u8) bool {
    return false;
}

fn errFmt(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) anyerror!common.ToolResult {
    return .{ .output = try std.fmt.allocPrint(gpa, fmt, args), .is_error = true };
}

/// status 落成**静态串**：宿主可能长期持有它，绝不能指向 execute 的 arena。
pub fn statusStatic(s: []const u8) []const u8 {
    if (std.mem.eql(u8, s, "pending")) return "pending";
    if (std.mem.eql(u8, s, "in_progress")) return "in_progress";
    if (std.mem.eql(u8, s, "completed")) return "completed";
    return "pending";
}

fn freeItems(gpa: std.mem.Allocator, alloc_items: []common.tool.TodoItem, built: usize) void {
    for (alloc_items[0..built]) |it| {
        gpa.free(it.id);
        gpa.free(it.content);
        if (it.active_form.len > 0) gpa.free(it.active_form);
    }
    // ⚠️ 必须用**完整长度**的切片去 free：0 长度切片在 DebugAllocator 下不会被回收。
    gpa.free(alloc_items);
}

pub fn execute(ctx: *common.ToolContext, input: []const u8) anyerror!common.ToolResult {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    if (try spec.validate(a, input)) |msg| return errFmt(ctx.gpa, "Invalid input: {s}", .{msg});
    const v = json.parse(a, input) catch return common.ToolResult.err("input must be valid JSON");

    const todos = v.getArray("todos") orelse
        return errFmt(ctx.gpa, "todos must be a non-empty array", .{});

    const items = try ctx.gpa.alloc(common.tool.TodoItem, todos.len);
    var built: usize = 0;
    errdefer freeItems(ctx.gpa, items, built);

    for (todos, 0..) |tv, i| {
        if (try specs.validateValue(a, specs.todo_item_spec, tv)) |msg| {
            freeItems(ctx.gpa, items, built);
            return errFmt(ctx.gpa, "{s}", .{msg});
        }
        const content = tv.getString("content").?;
        const status = tv.getString("status").?;
        const active = tv.getString("activeForm") orelse "";
        const id = try std.fmt.allocPrint(ctx.gpa, "todo-{d}", .{i + 1});
        errdefer ctx.gpa.free(id);
        const content_copy = try ctx.gpa.dupe(u8, content);
        errdefer ctx.gpa.free(content_copy);
        const active_copy: []const u8 = if (active.len > 0) try ctx.gpa.dupe(u8, active) else "";
        errdefer if (active_copy.len > 0) ctx.gpa.free(active_copy);
        items[i] = .{
            .id = id,
            .content = content_copy,
            .status = statusStatic(status),
            .priority = "",
            .active_form = active_copy,
        };
        built += 1;
    }

    const host = ctx.host orelse {
        freeItems(ctx.gpa, items, built);
        return errFmt(ctx.gpa, "TodoWrite requires a host with a todo store", .{});
    };

    host.writeTodos(items) catch |e| {
        freeItems(ctx.gpa, items, built);
        return errFmt(ctx.gpa, "Cannot write todos: {s}", .{@errorName(e)});
    };

    // 读回当前列表（T6：真实状态由会话级 store 持有，工具只做投影）。
    var read_back: usize = items.len;
    if (host.readTodos(ctx.gpa)) |current| {
        read_back = current.len;
        ctx.gpa.free(current);
    } else |_| {}

    freeItems(ctx.gpa, items, built);

    const out = try std.fmt.allocPrint(ctx.gpa, "{d} todo items written.", .{read_back});
    var res = common.ToolResult.ok(out);
    try res.metadata.put(ctx.gpa, "todoCount", .{ .integer = @intCast(read_back) });
    return truncate.finish(ctx.gpa, ctx, res, definition.max_result_chars);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// 会话级 todo store 的假实现 —— 重点验证「写进去、读回来」真的发生了。
const FakeTodos = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayListUnmanaged(common.tool.TodoItem) = .empty,
    write_calls: usize = 0,

    fn clear(self: *FakeTodos) void {
        for (self.items.items) |it| {
            self.gpa.free(it.id);
            self.gpa.free(it.content);
            self.gpa.free(it.status);
            self.gpa.free(it.priority);
            if (it.active_form.len > 0) self.gpa.free(it.active_form);
        }
        self.items.clearRetainingCapacity();
    }

    fn deinit(self: *FakeTodos) void {
        self.clear();
        self.items.deinit(self.gpa);
    }

    fn requestPermission(_: *anyopaque, _: common.perm.Request) anyerror!common.perm.Response {
        return error.Unsupported;
    }
    fn askQuestion(_: *anyopaque, _: []const u8, _: []const common.tool.QuestionOption, _: bool) anyerror!common.tool.Answer {
        return error.Unsupported;
    }
    fn emitProgress(_: *anyopaque, _: common.event.ToolProgressEvent) anyerror!void {
        return error.Unsupported;
    }
    fn persistOutput(_: *anyopaque, _: []const u8) anyerror![]const u8 {
        return error.Unsupported;
    }
    fn writeTodos(ptr: *anyopaque, list: []const common.tool.TodoItem) anyerror!void {
        const self: *FakeTodos = @ptrCast(@alignCast(ptr));
        self.clear();
        self.write_calls += 1;
        for (list) |it| {
            try self.items.append(self.gpa, .{
                .id = try self.gpa.dupe(u8, it.id),
                .content = try self.gpa.dupe(u8, it.content),
                .status = try self.gpa.dupe(u8, it.status),
                .priority = try self.gpa.dupe(u8, it.priority),
                .active_form = try self.gpa.dupe(u8, it.active_form),
            });
        }
    }
    fn readTodos(ptr: *anyopaque, gpa: std.mem.Allocator) anyerror![]common.tool.TodoItem {
        const self: *FakeTodos = @ptrCast(@alignCast(ptr));
        return gpa.dupe(common.tool.TodoItem, self.items.items);
    }
    fn notifyBackground(_: *anyopaque, _: []const u8) anyerror!void {
        return error.Unsupported;
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

    fn host(self: *FakeTodos) common.tool.Host {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "todo: 写入后经 host 读回，模型轨 → 内部轨映射正确" {
    var fake = FakeTodos{ .gpa = testing.allocator };
    defer fake.deinit();

    var ctx = common.ToolContext{
        .gpa = testing.allocator,
        .io = undefined,
        .cwd = "/",
        .host = fake.host(),
    };
    const input =
        \\{"todos":[
        \\  {"content":"write tests","status":"in_progress","activeForm":"writing tests"},
        \\  {"content":"ship it","status":"pending","activeForm":"shipping it"}
        \\ ]}
    ;
    const res = try execute(&ctx, input);
    defer testing.allocator.free(res.output);
    defer { var meta = res.metadata; meta.entries.deinit(testing.allocator); }
    try testing.expect(!res.is_error);
    try testing.expectEqualStrings("2 todo items written.", res.output);
    try testing.expectEqual(@as(i64, 2), res.metadata.get("todoCount").?.asInt().?);
    try testing.expectEqual(@as(usize, 1), fake.write_calls);
    try testing.expectEqual(@as(usize, 2), fake.items.items.len);

    const first = fake.items.items[0];
    try testing.expectEqualStrings("todo-1", first.id);
    try testing.expectEqualStrings("write tests", first.content);
    try testing.expectEqualStrings("in_progress", first.status);
    try testing.expectEqualStrings("", first.priority);
    // activeForm 被记录但不参与行为
    try testing.expectEqualStrings("writing tests", first.active_form);
}

test "todo: 非法 status / 缺字段 被拦下且不触碰 host" {
    var fake = FakeTodos{ .gpa = testing.allocator };
    defer fake.deinit();
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/", .host = fake.host() };

    const bad_status = try execute(&ctx, "{\"todos\":[{\"content\":\"x\",\"status\":\"nope\",\"activeForm\":\"y\"}]}");
    defer testing.allocator.free(bad_status.output);
    try testing.expect(bad_status.is_error);
    try testing.expect(std.mem.indexOf(u8, bad_status.output, "Invalid status") != null);

    const missing = try execute(&ctx, "{\"todos\":[{\"content\":\"x\"}]}");
    defer testing.allocator.free(missing.output);
    try testing.expect(missing.is_error);

    const not_array = try execute(&ctx, "{\"todos\":\"nope\"}");
    defer testing.allocator.free(not_array.output);
    try testing.expect(not_array.is_error);

    try testing.expectEqual(@as(usize, 0), fake.write_calls);
}

test "todo: 没有 host 时明确报错，不静默成功" {
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/" };
    const res = try execute(&ctx, "{\"todos\":[{\"content\":\"x\",\"status\":\"pending\",\"activeForm\":\"y\"}]}");
    defer testing.allocator.free(res.output);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.output, "requires a host") != null);
}

test "todo: 空数组是允许的（T3：文案说 non-empty，代码只查 isArray）" {
    var fake = FakeTodos{ .gpa = testing.allocator };
    defer fake.deinit();
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/", .host = fake.host() };
    const res = try execute(&ctx, "{\"todos\":[]}");
    defer testing.allocator.free(res.output);
    defer { var meta = res.metadata; meta.entries.deinit(testing.allocator); }
    try testing.expect(!res.is_error);
    try testing.expectEqualStrings("0 todo items written.", res.output);
}
