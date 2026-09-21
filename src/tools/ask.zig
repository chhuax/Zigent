//! `tools/ask.zig` —— `ask_user_question`（**无别名**，文档 05 §4.8）。
//!
//! - 名称逐字保留 snake_case（其它 7 个是 PascalCase），transcript 依赖；
//! - 单问题 / 批次**二选一**（`anyOf` 在 `Field` 里表达不出来，故在 execute 里
//!   显式 XOR 检查 —— 把隐式约束显式化）；
//! - **没有交互宿主时不挂死**：直接返回「问题未能提出」的结果而不是空等；
//! - 真实宿主实现是会话级 pending-question 表（Web 走 HTTP 事件 + answer 端点），
//!   这里只经 `ctx.host.askQuestion`，不持有任何静态回调。

const std = @import("std");
const common = @import("common");
const json = common.json;
const specs = @import("specs.zig");
const truncate = @import("truncate.zig");

pub const spec = specs.ask_spec;

pub const definition = common.Tool{
    .name = "ask_user_question",
    .aliases = &.{},
    .description = "Ask the user a question and wait for the answer",
    .spec = spec,
    .is_read_only = alwaysTrue,
    .is_destructive = alwaysFalse,
    .is_concurrency_safe = alwaysFalse,
    .max_result_chars = common.ToolResult.MAX_TOOL_RESULT_CHARS,
    .execute = execute,
};

fn alwaysTrue(_: []const u8) bool {
    return true;
}
fn alwaysFalse(_: []const u8) bool {
    return false;
}

pub const MSG_NO_HOST = "Question could not be asked: no interactive host is available.";
/// 批次硬门槛（文档 05 §4.8 A2：**实际门槛 1–10**，与旧文案的 2–5 不同）。
pub const MAX_QUESTION_BATCH: usize = 10;
pub const MIN_OPTIONS: usize = 2;
pub const MAX_OPTIONS: usize = 4;

fn errFmt(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) anyerror!common.ToolResult {
    return .{ .output = try std.fmt.allocPrint(gpa, fmt, args), .is_error = true };
}

fn buildOptions(a: std.mem.Allocator, arr: ?[]const json.Value) ![]common.tool.QuestionOption {
    const values = arr orelse return &.{};
    var list = std.ArrayListUnmanaged(common.tool.QuestionOption).empty;
    for (values) |ov| {
        const label = ov.getString("label") orelse ov.asString() orelse "";
        if (label.len == 0) continue;
        const desc = ov.getString("description") orelse "";
        try list.append(a, .{ .option_id = label, .label = label, .description = desc });
    }
    return list.toOwnedSlice(a);
}

/// A3 缺省渲染：`QUESTION [id] [header]: <question>` + ` 1. <label> — <desc>`。
fn renderFallback(
    gpa: std.mem.Allocator,
    id: []const u8,
    header: ?[]const u8,
    question: []const u8,
    options: []const common.tool.QuestionOption,
) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(gpa);
    if (header) |h| {
        try out.print(gpa, "QUESTION [{s}] [{s}]: {s}\n", .{ id, h, question });
    } else {
        try out.print(gpa, "QUESTION [{s}]: {s}\n", .{ id, question });
    }
    for (options, 0..) |o, i| {
        if (o.description.len > 0) {
            try out.print(gpa, " {d}. {s} — {s}\n", .{ i + 1, o.label, o.description });
        } else {
            try out.print(gpa, " {d}. {s}\n", .{ i + 1, o.label });
        }
    }
    return out.toOwnedSlice(gpa);
}

pub fn execute(ctx: *common.ToolContext, input: []const u8) anyerror!common.ToolResult {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    if (try spec.validate(a, input)) |msg| return errFmt(ctx.gpa, "Invalid input: {s}", .{msg});
    const v = json.parse(a, input) catch return common.ToolResult.err("input must be valid JSON");

    const has_single = v.getString("question") != null;
    const has_batch = v.getArray("questions") != null;
    if (has_single and has_batch) {
        return errFmt(ctx.gpa, "provide either 'question' or 'questions', not both", .{});
    }
    if (!has_single and !has_batch) {
        return errFmt(ctx.gpa, "either 'question' or 'questions' must be provided", .{});
    }

    if (has_batch) return runBatch(ctx, a, v);
    return runSingle(ctx, a, v);
}

fn runSingle(ctx: *common.ToolContext, a: std.mem.Allocator, v: json.Value) anyerror!common.ToolResult {
    const question = v.getString("question").?;
    if (question.len == 0) return errFmt(ctx.gpa, "question must not be empty", .{});
    const header = v.getString("header");
    const options = try buildOptions(a, v.getArray("options"));
    const multi = v.getBool("multiSelect") orelse false;
    const id = v.getString("id") orelse "q1";
    return dispatch(ctx, a, id, header, question, options, multi);
}

fn runBatch(ctx: *common.ToolContext, a: std.mem.Allocator, v: json.Value) anyerror!common.ToolResult {
    const questions = v.getArray("questions").?;
    if (questions.len == 0 or questions.len > MAX_QUESTION_BATCH) {
        return errFmt(ctx.gpa, "questions must contain between 1 and {d} items", .{MAX_QUESTION_BATCH});
    }
    for (questions, 0..) |qv, i| {
        const id = qv.getString("id") orelse "";
        const text = qv.getString("question") orelse "";
        if (id.len == 0) return errFmt(ctx.gpa, "questions[{d}].id must be a non-empty string", .{i});
        if (text.len == 0) return errFmt(ctx.gpa, "questions[{d}].question must be a non-empty string", .{i});
        // 批次内 id 必须唯一
        for (questions[0..i]) |prev| {
            if (std.mem.eql(u8, prev.getString("id") orelse "", id)) {
                return errFmt(ctx.gpa, "duplicate question id '{s}'", .{id});
            }
        }
        const opts = qv.getArray("options") orelse
            return errFmt(ctx.gpa, "questions[{d}] must include options", .{i});
        if (opts.len < MIN_OPTIONS or opts.len > MAX_OPTIONS) {
            return errFmt(ctx.gpa, "questions[{d}].options must contain {d}-{d} items", .{ i, MIN_OPTIONS, MAX_OPTIONS });
        }
    }

    // `Host.askQuestion` 是单问题信封：批次取第一题提问，其余题面并入提示词。
    const first = questions[0];
    const options = try buildOptions(a, first.getArray("options"));
    const multi = first.getBool("multiSelect") orelse false;
    var prompt_buf = std.ArrayListUnmanaged(u8).empty;
    try prompt_buf.appendSlice(a, first.getString("question").?);
    if (questions.len > 1) {
        try prompt_buf.print(a, "\n(then {d} more question(s) in this batch)", .{questions.len - 1});
    }
    return dispatch(ctx, a, first.getString("id").?, first.getString("header"), prompt_buf.items, options, multi);
}

fn dispatch(
    ctx: *common.ToolContext,
    a: std.mem.Allocator,
    id: []const u8,
    header: ?[]const u8,
    question: []const u8,
    options: []const common.tool.QuestionOption,
    multi: bool,
) anyerror!common.ToolResult {
    const fallback = try renderFallback(a, id, header, question, options);

    const host = ctx.host orelse {
        return errFmt(ctx.gpa, "{s}\n{s}", .{ MSG_NO_HOST, fallback });
    };
    const answer = host.askQuestion(question, options, multi) catch {
        return errFmt(ctx.gpa, "{s}\n{s}", .{ MSG_NO_HOST, fallback });
    };

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(ctx.gpa);
    if (answer.selected_option_ids.len > 0) {
        try out.appendSlice(ctx.gpa, "Answer: ");
        for (answer.selected_option_ids, 0..) |sel, i| {
            if (i > 0) try out.appendSlice(ctx.gpa, ", ");
            try out.appendSlice(ctx.gpa, sel);
        }
    } else {
        try out.appendSlice(ctx.gpa, "Answer: (no option selected)");
    }
    if (answer.free_text.len > 0) {
        try out.print(ctx.gpa, "\nFree text: {s}", .{answer.free_text});
    }
    var res = common.ToolResult.ok(try out.toOwnedSlice(ctx.gpa));
    // id 指向解析用的 arena → 必须拷贝后再进 metadata。
    try res.metadata.put(ctx.gpa, "questionId", .{ .string = try ctx.gpa.dupe(u8, id) });
    return truncate.finish(ctx.gpa, ctx, res, definition.max_result_chars);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

const FakeAsk = struct {
    prompt_buf: [512]u8 = undefined,
    prompt_len: usize = 0,
    asked_options: usize = 0,
    asked_multi: bool = false,
    answer: common.tool.Answer = .{},

    fn askedPrompt(self: *const FakeAsk) []const u8 {
        return self.prompt_buf[0..self.prompt_len];
    }

    fn requestPermission(_: *anyopaque, _: common.perm.Request) anyerror!common.perm.Response {
        return error.Unsupported;
    }
    fn askQuestion(
        ptr: *anyopaque,
        prompt: []const u8,
        options: []const common.tool.QuestionOption,
        multi_select: bool,
    ) anyerror!common.tool.Answer {
        const self: *FakeAsk = @ptrCast(@alignCast(ptr));
        // prompt 指向 execute 的 arena：必须立刻拷贝，调用返回后它就无效了。
        self.prompt_len = @min(prompt.len, self.prompt_buf.len);
        @memcpy(self.prompt_buf[0..self.prompt_len], prompt[0..self.prompt_len]);
        self.asked_options = options.len;
        self.asked_multi = multi_select;
        return self.answer;
    }
    fn emitProgress(_: *anyopaque, _: common.event.ToolProgressEvent) anyerror!void {
        return error.Unsupported;
    }
    fn persistOutput(_: *anyopaque, _: []const u8) anyerror![]const u8 {
        return error.Unsupported;
    }
    fn writeTodos(_: *anyopaque, _: []const common.tool.TodoItem) anyerror!void {
        return error.Unsupported;
    }
    fn readTodos(_: *anyopaque, _: std.mem.Allocator) anyerror![]common.tool.TodoItem {
        return error.Unsupported;
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

    fn host(self: *FakeAsk) common.tool.Host {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "ask: 无宿主时不挂死，返回「未能提出」" {
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/" };
    const res = try execute(&ctx, "{\"question\":\"Deploy now?\",\"header\":\"Deploy\",\"options\":[{\"label\":\"Yes\",\"description\":\"ship it\"},{\"label\":\"No\",\"description\":\"hold\"}]}");
    defer testing.allocator.free(res.output);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.output, "could not be asked") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "QUESTION [q1] [Deploy]: Deploy now?") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, " 1. Yes — ship it") != null);
}

test "ask: 有宿主时经 host.askQuestion 拿到答案" {
    var fake = FakeAsk{
        .answer = .{ .selected_option_ids = &.{"Yes"}, .free_text = "but wait for CI" },
    };
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/", .host = fake.host() };
    const res = try execute(&ctx, "{\"question\":\"Deploy now?\",\"options\":[{\"label\":\"Yes\",\"description\":\"ship\"},{\"label\":\"No\",\"description\":\"hold\"}]}");
    defer testing.allocator.free(res.output);
    defer { var meta = res.metadata; meta.entries.deinit(testing.allocator); }
    defer testing.allocator.free(res.metadata.get("questionId").?.asString().?);
    try testing.expect(!res.is_error);
    try testing.expectEqualStrings("Deploy now?", fake.askedPrompt());
    try testing.expectEqual(@as(usize, 2), fake.asked_options);
    try testing.expect(!fake.asked_multi);
    try testing.expect(std.mem.indexOf(u8, res.output, "Answer: Yes") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "Free text: but wait for CI") != null);
}

test "ask: question / questions 二选一，违反即报错" {
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/" };

    const neither = try execute(&ctx, "{}");
    defer testing.allocator.free(neither.output);
    try testing.expect(neither.is_error);
    try testing.expect(std.mem.indexOf(u8, neither.output, "either 'question' or 'questions'") != null);

    const both = try execute(&ctx, "{\"question\":\"a\",\"questions\":[{\"id\":\"q\",\"question\":\"b\",\"options\":[]}]}");
    defer testing.allocator.free(both.output);
    try testing.expect(both.is_error);
    try testing.expect(std.mem.indexOf(u8, both.output, "not both") != null);
}

test "ask: 批次门槛（1–10 / id 唯一 / options 2–4）" {
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/" };

    const empty = try execute(&ctx, "{\"questions\":[]}");
    defer testing.allocator.free(empty.output);
    try testing.expect(empty.is_error);
    try testing.expect(std.mem.indexOf(u8, empty.output, "between 1 and 10") != null);

    const one_option = try execute(&ctx, "{\"questions\":[{\"id\":\"a\",\"question\":\"q\",\"options\":[{\"label\":\"x\",\"description\":\"d\"}]}]}");
    defer testing.allocator.free(one_option.output);
    try testing.expect(one_option.is_error);
    try testing.expect(std.mem.indexOf(u8, one_option.output, "2-4 items") != null);

    const dup = try execute(&ctx, "{\"questions\":[" ++
        "{\"id\":\"a\",\"question\":\"q1\",\"options\":[{\"label\":\"x\",\"description\":\"d\"},{\"label\":\"y\",\"description\":\"d\"}]}," ++
        "{\"id\":\"a\",\"question\":\"q2\",\"options\":[{\"label\":\"x\",\"description\":\"d\"},{\"label\":\"y\",\"description\":\"d\"}]}]}");
    defer testing.allocator.free(dup.output);
    try testing.expect(dup.is_error);
    try testing.expect(std.mem.indexOf(u8, dup.output, "duplicate question id") != null);
}

test "ask: 合法批次会提问并拿到答案" {
    var fake = FakeAsk{ .answer = .{ .selected_option_ids = &.{"A"} } };
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/", .host = fake.host() };
    const input = "{\"questions\":[" ++
        "{\"id\":\"a\",\"question\":\"first?\",\"header\":\"One\",\"options\":[{\"label\":\"A\",\"description\":\"d\"},{\"label\":\"B\",\"description\":\"d\"}]}," ++
        "{\"id\":\"b\",\"question\":\"second?\",\"options\":[{\"label\":\"C\",\"description\":\"d\"},{\"label\":\"D\",\"description\":\"d\"}]}]}";
    const res = try execute(&ctx, input);
    defer testing.allocator.free(res.output);
    defer { var meta = res.metadata; meta.entries.deinit(testing.allocator); }
    defer testing.allocator.free(res.metadata.get("questionId").?.asString().?);
    try testing.expect(!res.is_error);
    try testing.expect(std.mem.indexOf(u8, fake.askedPrompt(), "first?") != null);
    try testing.expect(std.mem.indexOf(u8, fake.askedPrompt(), "1 more question") != null);
    try testing.expectEqualStrings("a", res.metadata.get("questionId").?.asString().?);
}
