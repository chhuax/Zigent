//! `perm/describe.zig` —— 人类可读摘要（`Request.input_summary` 的内容）。
//!
//! 设计依据：`docs/analysis/2026-09-19-07-权限与安全设计.md` §11.1。
//!
//! ★ **摘要由内核生成，客户端不得自行拼**（契约 §11.2 与 §11.3 的硬性验收）：
//! 否则终端 / Web / ACP 三套渲染会各自漂移，同一份 golden fixture 的三种编码器
//! 输出不再语义等价。
//!
//! 分派形态（逐条对齐 §11.1 的表）：
//!   * `Bash` / `PowerShell`：固定头 + `Command:` + `CWD:` + `Classification:`
//!     + `Risk flags:` + `Reasons:`（命令截断 1000）
//!   * `Write` / `Edit`：固定头 + `Tool:` + `Path:` + `Preview:`
//!   * `mcp__*`：`Server:` + `Remote tool:`（`split("__", 3)`）
//!   * `Task` / agent 控制：`Tool:` + `Request:`
//!   * 其它：`Tool: <name>` +（输入是字符串时）`Input:` 截断 300
//!
//! ⚠️ 写工具的 `Preview:` 首期只显示输入的存稿（`content` / `new_string`）；
//! 朴素实现会读旧文件生成 **unified diff**（截断 4000）—— 那需要 `io` 与 `util.fsio`，
//! 而 `perm` 只依赖 `common`。**接口形状已留**（`Preview` 段的形成只有这一处），
//! 引擎侧补齐时只改本文件。

const std = @import("std");
const common = @import("common");
const shell = @import("shell.zig");
const classify = @import("classify.zig");

/// 各段的截断上限（与既有行为一致）。
pub const MAX_COMMAND_CHARS: usize = 1000;
pub const MAX_PREVIEW_CHARS: usize = 4000;
pub const MAX_PLAN_CHARS: usize = 4000;
pub const MAX_GENERIC_INPUT_CHARS: usize = 300;
pub const MAX_TARGET_CHARS: usize = 1000;

/// 截断到 `max` 个字符（按 codepoint，避免把 UTF-8 截断成半个字）。
pub fn truncate(text: []const u8, max: usize) []const u8 {
    return common.usage.truncateCodePoints(text, max);
}

/// 从输入里取一个字符串字段（`arena` 由调用方持有）。
pub fn inputField(arena: std.mem.Allocator, input: []const u8, key: []const u8) ?[]const u8 {
    const value = common.json.parse(arena, input) catch return null;
    return value.getString(key);
}

/// 取写工具的主体文本（`content` / `new_string` / `new_str`）。
fn editPreview(arena: std.mem.Allocator, input: []const u8) ?[]const u8 {
    if (inputField(arena, input, "content")) |c| return c;
    if (inputField(arena, input, "new_string")) |c| return c;
    if (inputField(arena, input, "new_str")) |c| return c;
    return null;
}

/// ★ 生成 `input_summary`。返回值归 `gpa`。
pub fn describeTool(
    gpa: std.mem.Allocator,
    tool_name: []const u8,
    input: []const u8,
    cwd: []const u8,
) ![]const u8 {
    const canon = classify.canonicalOf(tool_name);

    return switch (canon) {
        .bash, .powershell => describeShell(gpa, tool_name, input, cwd),
        .write, .edit => describeWrite(gpa, tool_name, input),
        .mcp => describeMcp(gpa, tool_name, input),
        .task => describeTask(gpa, tool_name, input),
        else => describeGeneric(gpa, tool_name, input),
    };
}

fn appendLine(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, line: []const u8) !void {
    if (buf.items.len > 0) try buf.append(gpa, '\n');
    try buf.appendSlice(gpa, line);
}

/// 追加一行**已分配**的字符串，并把它释放掉（文案拼接的方便写法）。
fn appendAlloc(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, line: []const u8) !void {
    defer gpa.free(line);
    try appendLine(buf, gpa, line);
}

/// 与 `appendAlloc` 同义，但**调用方保留所有权**（`errdefer` 的 `lines` 列表用）。
fn appendOwned(buf: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, owned: []const u8) !void {
    try appendLine(buf, gpa, owned);
}

fn describeShell(gpa: std.mem.Allocator, tool_name: []const u8, input: []const u8, cwd: []const u8) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const command = shell.commandFromInputArena(arena, input) orelse "";
    const assessment = shell.assess(command);

    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(gpa);

    const is_powershell = classify.canonicalOf(tool_name) == .powershell;
    try appendLine(&buf, gpa, if (is_powershell) "PowerShell command request" else "Bash command request");
    try appendAlloc(&buf, gpa, try std.fmt.allocPrint(gpa, "Command: {s}", .{truncate(command, MAX_COMMAND_CHARS)}));
    try appendAlloc(&buf, gpa, try std.fmt.allocPrint(gpa, "CWD: {s}", .{cwd}));

    const classification = switch (assessment.verdict) {
        .deny => try std.fmt.allocPrint(gpa, "Classification: destructive ({s})", .{assessment.risk_level.wireName()}),
        .allow => try gpa.dupe(u8, "Classification: read-only"),
        .ask, .deferred => try std.fmt.allocPrint(gpa, "Classification: requires review ({s})", .{assessment.risk_level.wireName()}),
    };
    try appendAlloc(&buf, gpa, classification);

    var names_buf: [11][]const u8 = undefined;
    const names = assessment.flags.wireNames(&names_buf);
    const flags_text = if (names.len == 0) try gpa.dupe(u8, "(none)") else try std.mem.join(gpa, ", ", names);
    defer gpa.free(flags_text);
    try appendAlloc(&buf, gpa, try std.fmt.allocPrint(gpa, "Risk flags: {s}", .{flags_text}));

    // Risks 的 Reasons 段：危险模式命中的 id + 人类可读原因（全部命中都记，不只第一条）。
    var reasons = std.ArrayListUnmanaged([]const u8).empty;
    defer reasons.deinit(gpa);
    defer {
        for (reasons.items) |r| gpa.free(r);
    }
    if (assessment.rule_id) |id| {
        try reasons.append(gpa, try std.fmt.allocPrint(gpa, "{s}: {s}", .{ id, assessment.reason }));
    } else {
        try reasons.append(gpa, try gpa.dupe(u8, assessment.reason));
    }
    const joined = try std.mem.join(gpa, "; ", reasons.items);
    defer gpa.free(joined);
    try appendAlloc(&buf, gpa, try std.fmt.allocPrint(gpa, "Reasons: {s}", .{joined}));

    return buf.toOwnedSlice(gpa);
}

fn describeWrite(gpa: std.mem.Allocator, tool_name: []const u8, input: []const u8) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(gpa);
    try appendLine(&buf, gpa, "File modification request");
    try appendAlloc(&buf, gpa, try std.fmt.allocPrint(gpa, "Tool: {s}", .{classify.canonicalToolName(tool_name)}));
    if (inputField(arena, input, "file_path")) |p| {
        try appendAlloc(&buf, gpa, try std.fmt.allocPrint(gpa, "Path: {s}", .{p}));
    }
    if (editPreview(arena, input)) |preview| {
        try appendAlloc(&buf, gpa, try std.fmt.allocPrint(gpa, "Preview:\n{s}", .{truncate(preview, MAX_PREVIEW_CHARS)}));
    }
    return buf.toOwnedSlice(gpa);
}

fn describeMcp(gpa: std.mem.Allocator, tool_name: []const u8, input: []const u8) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(gpa);
    try appendLine(&buf, gpa, "MCP tool request");
    try appendAlloc(&buf, gpa, try std.fmt.allocPrint(gpa, "Tool: {s}", .{tool_name}));

    // `split("__", 3)`：`mcp__<server>__<remote tool>`
    const rest = tool_name["mcp__".len..];
    if (std.mem.indexOf(u8, rest, "__")) |idx| {
        try appendAlloc(&buf, gpa, try std.fmt.allocPrint(gpa, "Server: {s}", .{rest[0..idx]}));
        try appendAlloc(&buf, gpa, try std.fmt.allocPrint(gpa, "Remote tool: {s}", .{rest[idx + 2 ..]}));
    }
    try appendAlloc(&buf, gpa, try std.fmt.allocPrint(gpa, "Arguments: {s}", .{truncate(input, MAX_COMMAND_CHARS)}));
    return buf.toOwnedSlice(gpa);
}

fn describeTask(gpa: std.mem.Allocator, tool_name: []const u8, input: []const u8) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(gpa);
    try appendLine(&buf, gpa, "Agent/task control request");
    try appendAlloc(&buf, gpa, try std.fmt.allocPrint(gpa, "Tool: {s}", .{tool_name}));
    try appendAlloc(&buf, gpa, try std.fmt.allocPrint(gpa, "Request: {s}", .{truncate(input, MAX_COMMAND_CHARS)}));
    return buf.toOwnedSlice(gpa);
}

fn describeGeneric(gpa: std.mem.Allocator, tool_name: []const u8, input: []const u8) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(gpa);
    try appendAlloc(&buf, gpa, try std.fmt.allocPrint(gpa, "Tool: {s}", .{tool_name}));
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len > 0) {
        try appendAlloc(&buf, gpa, try std.fmt.allocPrint(gpa, "Input: {s}", .{truncate(trimmed, MAX_GENERIC_INPUT_CHARS)}));
    }
    return buf.toOwnedSlice(gpa);
}

/// 权限卡片上「为什么问」的一行文案（客户端可直接渲染）。
pub fn reasonLine(assessment: shell.Assessment) []const u8 {
    return assessment.reason;
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "describe: Bash 摘要含 Command / Classification / Risk flags" {
    const s = try describeTool(testing.allocator, "Bash", "{\"command\":\"rm -rf /tmp/x\"}", "/repo");
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "Bash command request") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Command: rm -rf /tmp/x") != null);
    try testing.expect(std.mem.indexOf(u8, s, "CWD: /repo") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Classification: destructive (HIGH)") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Reasons: rm_force") != null);
}

test "describe: 只读命令的摘要是 read-only" {
    const s = try describeTool(testing.allocator, "Bash", "{\"command\":\"ls -la\"}", "/repo");
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "Classification: read-only") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Risk flags: (none)") != null);
}

test "describe: 写工具摘要含 Path / Preview" {
    const s = try describeTool(testing.allocator, "Write", "{\"file_path\":\"/repo/a.zig\",\"content\":\"const x = 1;\"}", "/repo");
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "File modification request") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Tool: Write") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Path: /repo/a.zig") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Preview:\nconst x = 1;") != null);
}

test "describe: MCP 拆 server / remote tool" {
    const s = try describeTool(testing.allocator, "mcp__github__create_issue", "{\"title\":\"x\"}", "/repo");
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "Server: github") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Remote tool: create_issue") != null);
}

test "describe: 未知工具落通用分支" {
    const s = try describeTool(testing.allocator, "SomeFutureTool", "hello", "/repo");
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "Tool: SomeFutureTool") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Input: hello") != null);
}

test "describe: 截断按 codepoint" {
    try testing.expectEqualStrings("abc", truncate("abcdef", 3));
    try testing.expectEqualStrings("中", truncate("中文", 1));
}
