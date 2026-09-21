//! `engine/prompt.zig` —— 系统提示词分段装配。
//!
//! 注入顺序（文档 03 §10.3，`engine` 决定，`memory` 只负责"怎么发现/存储/渲染"）：
//!
//!   基础策略 → 环境信息 → settings → **记忆段** → 技能摘要 → MCP 指令
//!   → 工具清单 → 用户追加
//!
//! ⚠️ 记忆段**来自可能被外部写入的文件** —— 它同时是提示词注入面，
//! 所以这一层只装配，**过滤由 `memory.injection` 负责**（发现即过滤）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");

pub const Segment = struct {
    title: []const u8,
    body: []const u8,
    /// 空 body 是否省略
    skip_if_empty: bool = true,
};

pub const ToolEntry = struct {
    name: []const u8,
    description: []const u8,
    schema_json: []const u8,
};

pub const Options = struct {
    cwd: []const u8 = "",
    platform: []const u8 = @tagName(@import("builtin").os.tag),
    model: []const u8 = "",
    date: []const u8 = "",
    permission_mode: []const u8 = "ASK",
    /// 项目约定（AGENTS.md 等，已由 memory 渲染好）
    instructions: []const u8 = "",
    /// 持久记忆（MEMORY.md/USER.md，已由 memory 渲染好）
    hot_memory: []const u8 = "",
    /// 技能摘要
    skills: []const u8 = "",
    /// MCP 指令
    mcp: []const u8 = "",
    /// 用户追加（settings 里的 appendSystemPrompt）
    user_append: []const u8 = "",
    extra: []const Segment = &.{},
};

/// 基础策略 —— 稳定的前缀（对 prompt caching 友好，**放在最前**）。
pub const BASE_POLICY =
    \\You are Zigent, an autonomous coding agent operating in the user's working directory.
    \\
    \\Core rules:
    \\- Use the provided tools to inspect and modify the codebase. Never guess file contents.
    \\- Prefer small, verifiable changes. After editing, verify when a cheap check exists.
    \\- Tool results may be truncated; if you need more, ask for a narrower range.
    \\- Never fabricate command output or test results.
    \\- When a tool call is denied by the user, do not retry it through another route.
    \\
;

/// 渲染完整的系统提示词。
pub fn build(gpa: Allocator, opts: Options, tools: []const ToolEntry) Allocator.Error![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, BASE_POLICY);

    // ── 环境信息 ──
    try out.appendSlice(gpa, "\n# Environment\n");
    try out.print(gpa, "- Working directory: {s}\n", .{opts.cwd});
    try out.print(gpa, "- Platform: {s}\n", .{opts.platform});
    if (opts.date.len > 0) try out.print(gpa, "- Date: {s}\n", .{opts.date});
    if (opts.model.len > 0) try out.print(gpa, "- Model: {s}\n", .{opts.model});
    try out.print(gpa, "- Permission mode: {s}\n", .{opts.permission_mode});

    if (opts.instructions.len > 0) {
        try out.appendSlice(gpa, "\n# Project instructions\n");
        try out.appendSlice(gpa, opts.instructions);
        try out.append(gpa, '\n');
    }
    if (opts.hot_memory.len > 0) {
        try out.appendSlice(gpa, "\n# Memory\n");
        try out.appendSlice(gpa, opts.hot_memory);
        try out.append(gpa, '\n');
    }
    if (opts.skills.len > 0) {
        try out.appendSlice(gpa, "\n# Skills\n");
        try out.appendSlice(gpa, opts.skills);
        try out.append(gpa, '\n');
    }
    if (opts.mcp.len > 0) {
        try out.appendSlice(gpa, "\n# MCP\n");
        try out.appendSlice(gpa, opts.mcp);
        try out.append(gpa, '\n');
    }

    // ── 工具清单（单一真源：来自 tools registry 的 Spec）──
    if (tools.len > 0) {
        try out.appendSlice(gpa, "\n# Tools\n");
        for (tools) |t| {
            if (t.description.len > 0) {
                try out.print(gpa, "\n## {s}\n{s}\n", .{ t.name, t.description });
            } else {
                try out.print(gpa, "\n## {s}\n", .{t.name});
            }
        }
    }

    for (opts.extra) |seg| {
        if (seg.skip_if_empty and seg.body.len == 0) continue;
        try out.print(gpa, "\n# {s}\n", .{seg.title});
        try out.appendSlice(gpa, seg.body);
        try out.append(gpa, '\n');
    }

    if (opts.user_append.len > 0) {
        try out.appendSlice(gpa, "\n# Additional instructions\n");
        try out.appendSlice(gpa, opts.user_append);
        try out.append(gpa, '\n');
    }

    return out.toOwnedSlice(gpa);
}

/// 估算系统提示词的 token（用于 `stream_request_start` 的 `systemPromptTokens`）。
pub fn estimateTokens(system: []const u8) i64 {
    return common.usage.estimateTokens(system);
}

/// 把工具清单编码成 provider wire 需要的形状（`{name, description, schema_json}`）。
pub fn toolEntriesFrom(specs: []const ToolEntry) []const ToolEntry {
    return specs;
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "prompt: 段落顺序稳定（基础策略在最前）" {
    const s = try build(testing.allocator, .{
        .cwd = "/repo",
        .model = "claude-sonnet-4",
        .instructions = "项目约定：注释用中文",
        .hot_memory = "用户偏好简洁",
    }, &.{});
    defer testing.allocator.free(s);

    const i_base = std.mem.indexOf(u8, s, "You are Zigent").?;
    const i_env = std.mem.indexOf(u8, s, "# Environment").?;
    const i_ins = std.mem.indexOf(u8, s, "# Project instructions").?;
    const i_mem = std.mem.indexOf(u8, s, "# Memory").?;
    try testing.expect(i_base < i_env);
    try testing.expect(i_env < i_ins);
    try testing.expect(i_ins < i_mem);
}

test "prompt: 空段被省略" {
    const s = try build(testing.allocator, .{ .cwd = "/repo" }, &.{});
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "# Memory") == null);
    try testing.expect(std.mem.indexOf(u8, s, "# Skills") == null);
}

test "prompt: 工具清单来自 Spec" {
    const s = try build(testing.allocator, .{ .cwd = "/repo" }, &.{
        .{ .name = "Read", .description = "Read a file", .schema_json = "{}" },
        .{ .name = "Edit", .description = "Edit a file", .schema_json = "{}" },
    });
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "## Read") != null);
    try testing.expect(std.mem.indexOf(u8, s, "## Edit") != null);
}

test "prompt: 权限模式可见（模型知道当前闸门）" {
    const s = try build(testing.allocator, .{ .cwd = "/r", .permission_mode = "PLAN" }, &.{});
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "PLAN") != null);
}
