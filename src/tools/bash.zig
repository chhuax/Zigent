//! `tools/bash.zig` —— `Bash`（别名 `bash`，文档 05 §4.4）。
//!
//! 关注点：
//!   - 超时 `clamp(1, min(requested, 600_000))`，缺省 **120 000 ms**；
//!   - 结果上限 **50 000**（模型上下文保护，刻意小于全局 backstop）；
//!   - `ctx.isCancelled()` 在启动前与结束后各查一次，**绝不挂死**；
//!   - argv 构造集中在一处（`sys.zig`），Windows 走 `-EncodedCommand`。

const std = @import("std");
const common = @import("common");
const json = common.json;
const specs = @import("specs.zig");
const sys = @import("sys.zig");
const truncate = @import("truncate.zig");

pub const spec = specs.bash_spec;

pub const definition = common.Tool{
    .name = "Bash",
    .aliases = &.{"bash"},
    .description = "Execute a shell command",
    .spec = spec,
    .is_read_only = readOnlyByInput,
    .is_destructive = alwaysFalse,
    .is_concurrency_safe = alwaysFalse,
    .max_result_chars = specs.SEARCH_MAX_RESULT_CHARS,
    .execute = execute,
};

fn alwaysFalse(_: []const u8) bool {
    return false;
}

/// 保守的只读判定（`perm/` 的完整 shell 分类器首期不在 tools 的依赖里）：
/// 只有明确无副作用的命令前缀才判只读，其余一律 false（fail-closed）。
pub fn readOnlyByInput(input: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const v = json.parse(arena.allocator(), input) catch return false;
    const cmd = v.getString("command") orelse return false;
    return isReadOnlyCommand(cmd);
}

const read_only_prefixes = [_][]const u8{
    "ls",     "pwd",  "cat",  "head", "tail", "wc",  "echo", "which", "type",
    "file",   "stat", "date", "env",  "grep", "rg",  "find", "du",    "df",
    "git status", "git log", "git diff", "git show", "git branch",
};

pub fn isReadOnlyCommand(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return false;
    // 任何 shell 组合子都放弃判定（`;` `|` `>` `&` `$(` 反引号）
    if (std.mem.indexOfAny(u8, trimmed, "|;&><`") != null) return false;
    if (std.mem.indexOf(u8, trimmed, "$(") != null) return false;
    for (read_only_prefixes) |p| {
        if (std.mem.eql(u8, trimmed, p)) return true;
        if (std.mem.startsWith(u8, trimmed, p) and trimmed.len > p.len and
            (trimmed[p.len] == ' ' or trimmed[p.len] == '\t')) return true;
    }
    return false;
}

fn errFmt(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) anyerror!common.ToolResult {
    return .{ .output = try std.fmt.allocPrint(gpa, fmt, args), .is_error = true };
}

pub const MSG_CANCELLED = "Bash was cancelled by user interrupt.";

pub fn execute(ctx: *common.ToolContext, input: []const u8) anyerror!common.ToolResult {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    if (try spec.validate(a, input)) |msg| return errFmt(ctx.gpa, "Invalid input: {s}", .{msg});
    const v = json.parse(a, input) catch return common.ToolResult.err("input must be valid JSON");

    const command = v.getString("command") orelse return common.ToolResult.err("missing required field 'command'");
    if (std.mem.trim(u8, command, " \t\r\n").len == 0) {
        return errFmt(ctx.gpa, "command must not be empty", .{});
    }

    const requested: u64 = if (v.getInt("timeout")) |t| @intCast(@max(1, t)) else specs.BASH_DEFAULT_TIMEOUT_MS;
    const timeout_ms: u64 = @min(requested, specs.BASH_MAX_TIMEOUT_MS);

    if (ctx.isCancelled()) return common.ToolResult.err(MSG_CANCELLED);

    var r = sys.runShell(ctx.io, ctx.gpa, command, .{
        .cwd = ctx.cwd,
        .timeout_ms = timeout_ms,
        .max_output_bytes = 1 << 20,
    }) catch |e| switch (e) {
        error.Timeout => return errFmt(ctx.gpa, "Command timed out after {d} ms: {s}", .{ timeout_ms, command }),
        else => return errFmt(ctx.gpa, "Failed to execute command: {s}", .{@errorName(e)}),
    };
    defer r.deinit(ctx.gpa);

    if (ctx.isCancelled()) return common.ToolResult.err(MSG_CANCELLED);

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(ctx.gpa);
    try out.print(ctx.gpa, "exit code: {d}\n", .{r.exit_code});
    if (r.stdout.len > 0) try out.appendSlice(ctx.gpa, r.stdout);
    if (r.stderr.len > 0) {
        if (r.stdout.len > 0 and r.stdout[r.stdout.len - 1] != '\n') try out.append(ctx.gpa, '\n');
        try out.appendSlice(ctx.gpa, "[stderr]\n");
        try out.appendSlice(ctx.gpa, r.stderr);
    }

    var res = common.ToolResult{
        .output = try out.toOwnedSlice(ctx.gpa),
        .is_error = r.exit_code != 0,
    };
    try res.metadata.put(ctx.gpa, "exitCode", .{ .integer = r.exit_code });
    try res.metadata.put(ctx.gpa, "durationMs", .{ .integer = r.duration_ms });
    if (r.signal) |s| try res.metadata.put(ctx.gpa, "signal", .{ .integer = s });
    return truncate.finish(ctx.gpa, ctx, res, definition.max_result_chars);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "bash: 只读判定 fail-closed（含组合子一律 false）" {
    try testing.expect(isReadOnlyCommand("ls -la"));
    try testing.expect(isReadOnlyCommand("git status"));
    try testing.expect(!isReadOnlyCommand("rm -rf /"));
    try testing.expect(!isReadOnlyCommand("ls && rm -rf /"));
    try testing.expect(!isReadOnlyCommand("cat x | sh"));
    try testing.expect(!isReadOnlyCommand("echo hi > /etc/passwd"));
    try testing.expect(!isReadOnlyCommand("git status; rm -rf /"));
}

test "bash: 退出码 / stderr / stdout 都进结果" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = "/tmp" };

    const ok = try execute(&ctx, "{\"command\":\"echo hello\"}");
    try testing.expect(!ok.is_error);
    try testing.expect(std.mem.indexOf(u8, ok.output, "exit code: 0") != null);
    try testing.expect(std.mem.indexOf(u8, ok.output, "hello") != null);

    const fail = try execute(&ctx, "{\"command\":\"echo oops >&2; exit 7\"}");
    try testing.expect(fail.is_error);
    try testing.expect(std.mem.indexOf(u8, fail.output, "exit code: 7") != null);
    try testing.expect(std.mem.indexOf(u8, fail.output, "oops") != null);
    try testing.expect(std.mem.indexOf(u8, fail.output, "[stderr]") != null);
    try testing.expectEqual(@as(i64, 7), fail.metadata.get("exitCode").?.asInt().?);
}

test "bash: 超时路径限时返回，不挂死" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = "/tmp" };

    const res = try execute(&ctx, "{\"command\":\"sleep 5\",\"timeout\":200}");
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.output, "timed out after 200 ms") != null);
}

test "bash: 取消令牌 → 直接返回取消文案" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var flag = std.atomic.Value(bool).init(true);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = "/tmp", .cancelled = &flag };

    const res = try execute(&ctx, "{\"command\":\"echo hi\"}");
    try testing.expect(res.is_error);
    try testing.expectEqualStrings(MSG_CANCELLED, res.output);
}

test "bash: 空 command 与坏输入都被拦下" {
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/" };
    const empty = try execute(&ctx, "{\"command\":\"   \"}");
    defer testing.allocator.free(empty.output);
    try testing.expect(empty.is_error);

    const bad = try execute(&ctx, "{\"timeout\":10}");
    defer testing.allocator.free(bad.output);
    try testing.expect(bad.is_error);
    try testing.expect(std.mem.indexOf(u8, bad.output, "Invalid input") != null);
}
