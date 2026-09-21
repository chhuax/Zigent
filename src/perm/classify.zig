//! `perm/classify.zig` —— L3 确定性分类器 + 工具风险等级。
//!
//! 设计依据：`docs/analysis/2026-09-19-07-权限与安全设计.md` §2.1（第 3 层）、
//! §4.5（shell 分级）、§11.1（`riskLevel` 的分派顺序）。
//!
//! ## ★ 两条独立的风险轴（这里是 `tool_risk_level` 那一轴）
//! `riskLevelOf("Bash")` 与 `riskLevelOf("bash")` **恒为 `.high`**，连 `ls` 也一样 ——
//! 真实分级在命令轴（`shell.assess(...).risk_level` → `Outcome.command_risk_level`）。
//! 朴素实现把一个等级藏在 `inputSummary` 的文本里，Zig 拆成两个字段。
//! （契约里 `RiskLevel` 没有 `DESTRUCTIVE` 变体，其 wire 名 `HIGH` 就是它的载体。）
//!
//! ## 分派顺序（§11.1 的反直觉点 2）
//! `mcp__` 与 `Bash`/`PowerShell` 都排在「写工具」**之前**判，所以
//! `mcp__x/y` 不会先被当成写工具。Zig 统一走 `canonicalToolName` 后再判，
//! 不把 `bash`/`Bash`/`powershell`/`write_file`/`edit_file` 这些字面量散落各处。

const std = @import("std");
const common = @import("common");
const shell = @import("shell.zig");

/// L3 的输入：工具自陈的 `read_only` / `destructive`（来自工具自判层）。
pub const SafetyInput = struct {
    tool_name: []const u8,
    input: []const u8,
    is_read_only: bool,
    is_destructive: bool,
};

/// 工具名的规范形态（契约名单，逐字）。
pub const CanonicalTool = enum {
    read,
    glob,
    grep,
    lsp,
    write,
    edit,
    bash,
    powershell,
    task,
    mcp,
    unknown,

    pub fn wireName(self: CanonicalTool) []const u8 {
        return switch (self) {
            .read => "Read",
            .glob => "Glob",
            .grep => "Grep",
            .lsp => "Lsp",
            .write => "Write",
            .edit => "Edit",
            .bash => "Bash",
            .powershell => "PowerShell",
            .task => "Task",
            .mcp => "mcp__",
            .unknown => "unknown",
        };
    }
};

/// 别名归一。**未登记的名字走 `unknown`**（由 `riskLevelOf` fail-closed 成写类，§5.2）。
pub fn canonicalOf(tool_name: []const u8) CanonicalTool {
    if (std.mem.startsWith(u8, tool_name, "mcp__")) return .mcp;
    if (std.mem.eql(u8, tool_name, "Read") or std.mem.eql(u8, tool_name, "read_file") or std.mem.eql(u8, tool_name, "read")) return .read;
    if (std.mem.eql(u8, tool_name, "Glob") or std.mem.eql(u8, tool_name, "glob")) return .glob;
    if (std.mem.eql(u8, tool_name, "Grep") or std.mem.eql(u8, tool_name, "grep")) return .grep;
    if (std.mem.eql(u8, tool_name, "Lsp") or std.mem.eql(u8, tool_name, "lsp")) return .lsp;
    if (std.mem.eql(u8, tool_name, "Write") or std.mem.eql(u8, tool_name, "write_file") or std.mem.eql(u8, tool_name, "write")) return .write;
    if (std.mem.eql(u8, tool_name, "Edit") or std.mem.eql(u8, tool_name, "edit_file") or std.mem.eql(u8, tool_name, "edit") or std.mem.eql(u8, tool_name, "notebook_edit")) return .edit;
    if (std.mem.eql(u8, tool_name, "Bash") or std.mem.eql(u8, tool_name, "bash")) return .bash;
    if (std.mem.eql(u8, tool_name, "PowerShell") or std.mem.eql(u8, tool_name, "powershell")) return .powershell;
    if (std.mem.eql(u8, tool_name, "Task") or std.mem.eql(u8, tool_name, "Agent") or
        std.mem.eql(u8, tool_name, "agent") or std.mem.eql(u8, tool_name, "TaskCreate") or
        std.mem.eql(u8, tool_name, "TaskUpdate") or std.mem.eql(u8, tool_name, "TaskList") or
        std.mem.eql(u8, tool_name, "TaskGet") or std.mem.eql(u8, tool_name, "send_message") or
        std.mem.eql(u8, tool_name, "todo_write") or std.mem.eql(u8, tool_name, "TodoWrite"))
    {
        return .task;
    }
    return .unknown;
}

/// 规范工具名（供 `describe` / `riskLevelOf` / 审计共用）。
pub fn canonicalToolName(tool_name: []const u8) []const u8 {
    return canonicalOf(tool_name).wireName();
}

/// ★ 工具级风险等级（`tool_risk_level` 那一轴）。**未登记的工具按写类 fail-closed。**
pub fn riskLevelOf(tool_name: []const u8) common.perm.RiskLevel {
    return switch (canonicalOf(tool_name)) {
        .read, .glob, .grep, .lsp => .read_only,
        // ★ Bash / PowerShell 恒为 HIGH（wire 名），不管命令是不是只读。
        .bash, .powershell => .high,
        .write, .edit => .modifies_files,
        .task => .agent_control,
        .mcp => .mcp_tool,
        // fail-closed：读授权绝不能因为一个没登记的名字静默升级成写授权。
        .unknown => .write,
    };
}

/// 分类器给出的稳定原因标识（`Outcome.reason` 同时是人类可读文案）。
pub const Reason = struct {
    pub const read_only_tool = "tool is declared read-only";
    pub const destructive_tool = "tool self-assessment marked the input destructive";
    pub const shell = "shell command safety classification";
    pub const shell_write_class = "unknown tool label treated as write-class (fail-closed)";
    pub const known_write_tool = "tool writes to the workspace";
    pub const agent_control = "tool controls agents/tasks";
    pub const mcp_tool = "MCP tool call";
};

/// ★ L3 确定性分类器（全局，输入是工具自陈的 `read_only` / `destructive`）。
///
/// 返回 `deferred` 表示「本层不反对，交给 L4」——**只有 `defer` 才继续**。
/// `Bash` / `PowerShell` 在这里拿到**命令级**风险（`command_risk_level`），
/// 同时把工具级 `risk_level` 保持为 `.high`（两条轴分开写）。
pub fn deterministicClassify(in: SafetyInput) common.perm.Outcome {
    const tool_risk = riskLevelOf(in.tool_name);
    const canon = canonicalOf(in.tool_name);

    // 工具自陈只读：仍然交 L4（缓存 / 规则），但先记一个明确的 reason。
    if (in.is_read_only) {
        var out = common.perm.Outcome.deferred(Reason.read_only_tool, .read_only);
        out.trace = null; // trace 由 `Checker` 统一附加（§10.3：所有判定都要带 provenance）
        return out;
    }

    if (canon == .bash or canon == .powershell) {
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const command = shell.commandFromInputArena(arena, in.input) orelse {
            var out = common.perm.Outcome.ask("shell input has no command", .high);
            out.command_risk_level = .review;
            return out;
        };
        const assessment = shell.assess(command);
        return switch (assessment.verdict) {
            // 22 条危险模式命中 → DENY HIGH（命令轴）。
            .deny => common.perm.Outcome.deny(assessment.reason, tool_risk, .policy),
            // ask / allow / defer 都往下走（L4 决策），但命令级风险已经拿到了。
            .ask, .allow, .deferred => blk: {
                var out = common.perm.Outcome.deferred(Reason.shell, tool_risk);
                out.command_risk_level = assessment.risk_level;
                break :blk out;
            },
        };
    }

    if (in.is_destructive) {
        return common.perm.Outcome.deferred(Reason.destructive_tool, .write);
    }

    return switch (canon) {
        .write, .edit => common.perm.Outcome.deferred(Reason.known_write_tool, .modifies_files),
        .task => common.perm.Outcome.deferred(Reason.agent_control, .agent_control),
        .mcp => common.perm.Outcome.deferred(Reason.mcp_tool, .mcp_tool),
        // fail-closed：未登记 label 走写类。
        .unknown => common.perm.Outcome.deferred(Reason.shell_write_class, .write),
        .read, .glob, .grep, .lsp => common.perm.Outcome.deferred(Reason.read_only_tool, .read_only),
        .bash, .powershell => unreachable, // 上面已分支
    };
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "classify: 未登记 label → 写类 fail-closed" {
    const out = deterministicClassify(.{ .tool_name = "SomeFutureTool", .input = "{}", .is_read_only = false, .is_destructive = false });
    try testing.expectEqual(common.perm.Verdict.deferred, out.verdict);
    try testing.expectEqual(common.perm.RiskLevel.write, out.risk_level);
    try testing.expectEqual(common.perm.RiskLevel.write, riskLevelOf("SomeFutureTool"));
    try testing.expect(!common.perm.OperationLabel.fromToolName("SomeFutureTool").isReadOnly());
}

test "classify: 工具级风险 —— Bash 恒 HIGH（连 ls 也一样）" {
    try testing.expectEqual(common.perm.RiskLevel.high, riskLevelOf("Bash"));
    try testing.expectEqual(common.perm.RiskLevel.high, riskLevelOf("bash"));
    try testing.expectEqual(common.perm.RiskLevel.high, riskLevelOf("PowerShell"));
    try testing.expectEqual(common.perm.RiskLevel.read_only, riskLevelOf("Read"));
    try testing.expectEqual(common.perm.RiskLevel.read_only, riskLevelOf("read_file"));
    try testing.expectEqual(common.perm.RiskLevel.modifies_files, riskLevelOf("Write"));
    try testing.expectEqual(common.perm.RiskLevel.mcp_tool, riskLevelOf("mcp__srv__tool"));
    try testing.expectEqual(common.perm.RiskLevel.agent_control, riskLevelOf("Task"));
}

test "classify: 两条风险轴分开 —— ls 也是工具 HIGH + 命令 READ_ONLY" {
    const out = deterministicClassify(.{
        .tool_name = "Bash",
        .input = "{\"command\":\"ls -la\"}",
        .is_read_only = false,
        .is_destructive = false,
    });
    try testing.expectEqual(common.perm.RiskLevel.high, out.risk_level);
    try testing.expectEqual(common.perm.RiskLevel.read_only, out.command_risk_level.?);
}

test "classify: 危险命令在 L3 直接 DENY" {
    const out = deterministicClassify(.{
        .tool_name = "Bash",
        .input = "{\"command\":\"rm -rf /tmp/x\"}",
        .is_read_only = false,
        .is_destructive = true,
    });
    try testing.expectEqual(common.perm.Verdict.deny, out.verdict);
    try testing.expectEqual(common.perm.RiskLevel.high, out.risk_level);
    try testing.expectEqual(common.perm.DenialReason.policy, out.denial_reason.?);
}

test "classify: 只读工具自陈时不升级写类" {
    const out = deterministicClassify(.{ .tool_name = "Read", .input = "{\"file_path\":\"/a\"}", .is_read_only = true, .is_destructive = false });
    try testing.expectEqual(common.perm.Verdict.deferred, out.verdict);
    try testing.expectEqual(common.perm.RiskLevel.read_only, out.risk_level);
}
