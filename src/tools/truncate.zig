//! `tools/truncate.zig` —— 工具结果长度治理（文档 03 §9 / 05 §4.0 三条横切约束）。
//!
//! 三条不能混的口径：
//!   1. **模型视图截断** `400_000`：`ToolResult.MAX_TOOL_RESULT_CHARS`，
//!      按 **code point** 计（雷区 H：朴素实现名字叫 BYTES，实际比的是 UTF-16 char；
//!      若按 UTF-8 字节算，中文会被提前 3 倍截断）。
//!   2. **单工具上限**：Bash/Grep `50_000`、Glob `65_536` —— 模型上下文保护，
//!      超了**直接截断**（不落盘）。
//!   3. **外置落盘**：超过 `MAX_TOOL_RESULT_CHARS` 时经 `ctx.host.persistOutput`
//!      落盘，结果里换成 `<persisted-output>` 占位符，并在 metadata 里登记路径。

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const usage = common.usage;

/// 占位符里保留的预览长度（code point）。
pub const PREVIEW_CHARS: usize = 2000;

pub const Outcome = struct {
    output: []const u8,
    persisted_path: ?[]const u8 = null,
};

/// 按 code point 判定并处理超长输出。返回的字符串分配在 `gpa` 上。
pub fn enforce(
    gpa: Allocator,
    ctx: *const common.ToolContext,
    output: []const u8,
    max_chars: usize,
) !Outcome {
    const total = usage.countCodePoints(output);
    if (total <= max_chars) return .{ .output = output };

    // ① 超过绝对 backstop → 外置落盘（有宿主时）
    if (total > common.ToolResult.MAX_TOOL_RESULT_CHARS) {
        if (ctx.host) |host| {
            if (host.persistOutput(output)) |path| {
                const preview = usage.truncateCodePoints(output, PREVIEW_CHARS);
                const placeholder = try std.fmt.allocPrint(
                    gpa,
                    "<persisted-output>\nFull output saved to: {s}\nPreview (first {d} of {d} chars):\n{s}\n</persisted-output>",
                    .{ path, PREVIEW_CHARS, total, preview },
                );
                return .{ .output = placeholder, .persisted_path = path };
            } else |_| {
                // 落盘不可用 → 退化为截断（绝不把 1.5 MB 直接喂给模型）
            }
        }
    }

    // ② 单工具上限 → 截断并显式说明
    const shown = usage.truncateCodePoints(output, max_chars);
    return .{
        .output = try std.fmt.allocPrint(
            gpa,
            "{s}\n... [truncated: {d} of {d} chars shown]",
            .{ shown, max_chars, total },
        ),
    };
}

/// `enforce` + 写回 `ToolResult`（含 `persistedOutputPath` metadata）。
pub fn finish(
    gpa: Allocator,
    ctx: *const common.ToolContext,
    res: common.ToolResult,
    max_chars: usize,
) !common.ToolResult {
    const out = try enforce(gpa, ctx, res.output, max_chars);
    var done = res;
    done.output = out.output;
    if (out.persisted_path) |p| {
        try done.metadata.put(gpa, common.tool.KEY_PERSISTED_OUTPUT_PATH, .{ .string = p });
    }
    return done;
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

const FakeHost = struct {
    persist_calls: usize = 0,
    last_persisted: []const u8 = "",

    fn requestPermission(_: *anyopaque, _: common.perm.Request) anyerror!common.perm.Response {
        return error.Unsupported;
    }
    fn askQuestion(_: *anyopaque, _: []const u8, _: []const common.tool.QuestionOption, _: bool) anyerror!common.tool.Answer {
        return error.Unsupported;
    }
    fn emitProgress(_: *anyopaque, _: common.event.ToolProgressEvent) anyerror!void {
        return error.Unsupported;
    }
    fn persistOutput(ptr: *anyopaque, content: []const u8) anyerror![]const u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ptr));
        self.persist_calls += 1;
        self.last_persisted = content;
        return "/tmp/fake/persisted-output.txt";
    }
    fn writeTodos(_: *anyopaque, _: []const common.tool.TodoItem) anyerror!void {
        return error.Unsupported;
    }
    fn readTodos(_: *anyopaque, _: Allocator) anyerror![]common.tool.TodoItem {
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

    fn host(self: *FakeHost) common.tool.Host {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "truncate: 短输出原样返回（不分配、不落盘）" {
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/" };
    const out = try enforce(testing.allocator, &ctx, "hello", 100);
    try testing.expectEqualStrings("hello", out.output);
    try testing.expect(out.persisted_path == null);
}

test "truncate: 超过单工具上限 → 截断并带说明（不落盘）" {
    var host = FakeHost{};
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/", .host = host.host() };
    const big = "a" ** 500;
    const out = try enforce(testing.allocator, &ctx, big, 100);
    defer testing.allocator.free(out.output);
    try testing.expectEqual(@as(usize, 0), host.persist_calls);
    try testing.expect(std.mem.indexOf(u8, out.output, "[truncated: 100 of 500 chars shown]") != null);
    try testing.expect(std.mem.startsWith(u8, out.output, "a" ** 100));
}

test "truncate: 100_000 个汉字（300_000 字节）不落盘 —— code point 口径" {
    var host = FakeHost{};
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/", .host = host.host() };
    const cjk = "中" ** 100_000;
    const out = try enforce(testing.allocator, &ctx, cjk, common.ToolResult.MAX_TOOL_RESULT_CHARS);
    try testing.expectEqual(@as(usize, 0), host.persist_calls);
    try testing.expectEqualStrings(cjk, out.output);
    try testing.expect(out.persisted_path == null);
}

test "truncate: 200_000 个汉字 = 600_000 字节但 200_000 码点 → 仍不落盘（按字节会误判）" {
    var host = FakeHost{};
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/", .host = host.host() };
    const cjk = "中" ** 200_000;
    try testing.expect(cjk.len > common.ToolResult.MAX_TOOL_RESULT_CHARS);
    const out = try enforce(testing.allocator, &ctx, cjk, common.ToolResult.MAX_TOOL_RESULT_CHARS);
    try testing.expectEqual(@as(usize, 0), host.persist_calls);
    try testing.expectEqualStrings(cjk, out.output);
}

test "truncate: 超过 400_000 码点 → 经 host.persistOutput 落盘并给出占位符" {
    var host = FakeHost{};
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/", .host = host.host() };
    const cjk = "中" ** 500_000;
    const out = try enforce(testing.allocator, &ctx, cjk, common.ToolResult.MAX_TOOL_RESULT_CHARS);
    defer testing.allocator.free(out.output);
    try testing.expectEqual(@as(usize, 1), host.persist_calls);
    try testing.expectEqualStrings("/tmp/fake/persisted-output.txt", out.persisted_path.?);
    try testing.expect(std.mem.indexOf(u8, out.output, "<persisted-output>") != null);
    try testing.expect(std.mem.indexOf(u8, out.output, "/tmp/fake/persisted-output.txt") != null);
    try testing.expectEqualStrings(cjk, host.last_persisted);
}

test "truncate: finish 把 persistedOutputPath 写进 metadata" {
    var host = FakeHost{};
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/", .host = host.host() };
    const cjk = "中" ** 500_000;
    const res = try finish(testing.allocator, &ctx, common.ToolResult.ok(cjk), common.ToolResult.MAX_TOOL_RESULT_CHARS);
    defer testing.allocator.free(res.output);
    defer { var meta = res.metadata; meta.entries.deinit(testing.allocator); }
    try testing.expectEqualStrings("/tmp/fake/persisted-output.txt", res.persistedOutputPath().?);
}

test "truncate: 无宿主且超 backstop → 不挂死，退化为截断" {
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/" };
    const cjk = "中" ** 500_000;
    const out = try enforce(testing.allocator, &ctx, cjk, 400_000);
    defer testing.allocator.free(out.output);
    try testing.expect(out.persisted_path == null);
    try testing.expect(std.mem.indexOf(u8, out.output, "[truncated: 400000 of 500000 chars shown]") != null);
    try testing.expect(usage.countCodePoints(out.output) < usage.countCodePoints(cjk));
}
