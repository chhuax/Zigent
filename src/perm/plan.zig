//! `perm/plan.zig` —— L1：Plan 只读闸门（**唯一出口**）。
//!
//! 设计依据：`docs/analysis/2026-09-19-07-权限与安全设计.md` §2.1 / §2.2。
//!
//! ★ **顺序是安全边界，不是实现细节**：朴素实现里 Plan 闸门在 `ToolExecutor`
//! 的 **L565**，早于工具自判的 **L577**。任务书写的「工具自判 → 分类器 → 规则 →
//! Plan 闸门」是**错的**，会造成「plan 模式下 Write 先弹一张本不该弹的卡片」：
//!
//!   * 顺序 A（错误）：Write → `checkPermissions`（默认 `defer`）→ 分类器
//!     （destructive → `ask`）→ 规则 → **多弹一张卡**；
//!   * 顺序 B（本实现）：Write → 闸门直接 `deny`，**不弹卡片**。
//!
//! 另外一个必须记的点：朴素实现有**两条互相独立的 Plan 通路**
//! （运行时 `PlanModeState` 只被 executor 闸门读、`PermissionMode.PLAN` 只被 checker 读），
//! 两者可以不一致。Zig 按 §2.2 的决策**合并成这一条 `planGate`**：执行器与 checker
//! 都读它，杜绝双轨。

const std = @import("std");
const common = @import("common");

/// Plan 状态。`allowed_tools` 对应「策略.isPlanAllowedTool」——
/// 显式允许在 plan 模式下使用的**非只读**工具（空表示没有任何例外）。
pub const PlanState = struct {
    active: bool = false,
    allowed_tools: []const []const u8 = &.{},

    /// 闸门是否处于「限制」态。
    pub fn restricting(self: PlanState) bool {
        return self.active;
    }

    /// 该工具是否在 plan 允许集里（大小写敏感，与工具名一一对应）。
    pub fn isAllowedTool(self: PlanState, tool_name: []const u8) bool {
        for (self.allowed_tools) |t| {
            if (std.mem.eql(u8, t, tool_name)) return true;
        }
        return false;
    }
};

/// Plan 闸门拒绝时的稳定原因（进 trace 与 tool_result）。
pub const PLAN_MODE_BLOCKED_REASON =
    "Plan mode is active: only read-only tools are allowed until the plan is approved";

/// ★ L1：**在 `Checker.evaluate` 的四级之前**（顺序错会多弹卡片或漏拦）。
///
/// 契约签名（`INTERFACES-v1.md` §4.3，逐字）：
/// 只有「plan 未激活」或「工具是只读的」才返回 `allow`，其余一律 `deny`。
pub fn planGate(p: *const PlanState, tool_name: []const u8, read_only: bool) common.perm.Verdict {
    return planGateWithAllowed(p, tool_name, read_only);
}

/// 显式把允许集传进来的形态（引擎在 plan 模式下若配置了例外工具用它）。
/// `planGate` 就是它 + `p.allowed_tools`。
pub fn planGateWithAllowed(p: *const PlanState, tool_name: []const u8, read_only: bool) common.perm.Verdict {
    if (!p.restricting()) return .allow;
    if (read_only) return .allow;
    if (p.isAllowedTool(tool_name)) return .allow;
    return .deny;
}

/// `planGate` 的 Outcome 形态（`Checker` 用它，保证 trace 一定被附上）。
pub fn planGateOutcome(p: *const PlanState, tool_name: []const u8, read_only: bool) common.perm.Outcome {
    const verdict = planGateWithAllowed(p, tool_name, read_only);
    return switch (verdict) {
        .allow => common.perm.Outcome.allow("plan mode allows read-only tools", .read_only),
        .deny => common.perm.Outcome.deny(PLAN_MODE_BLOCKED_REASON, .write, .policy),
        // `planGate` 只可能返回 allow / deny；其余变体保持显式，改签名时编译期就能发现。
        .ask => common.perm.Outcome.ask(PLAN_MODE_BLOCKED_REASON, .write),
        .deferred => common.perm.Outcome.deferred("plan gate defers", .write),
    };
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "plan: 未激活时一律放行（含写类）" {
    const p = PlanState{ .active = false };
    try testing.expectEqual(common.perm.Verdict.allow, planGate(&p, "Write", false));
    try testing.expectEqual(common.perm.Verdict.allow, planGate(&p, "Bash", false));
}

test "plan: 激活时只读放行、写类 DENY" {
    const p = PlanState{ .active = true };
    try testing.expectEqual(common.perm.Verdict.allow, planGate(&p, "Read", true));
    try testing.expectEqual(common.perm.Verdict.allow, planGate(&p, "Grep", true));
    try testing.expectEqual(common.perm.Verdict.deny, planGate(&p, "Write", false));
    try testing.expectEqual(common.perm.Verdict.deny, planGate(&p, "Bash", false));
    try testing.expectEqual(common.perm.Verdict.deny, planGate(&p, "UnknownFutureTool", false));
}

test "plan: 允许集里的非只读工具放行（唯一的例外通道）" {
    const allowed = [_][]const u8{"TodoWrite"};
    const p = PlanState{ .active = true, .allowed_tools = &allowed };
    try testing.expectEqual(common.perm.Verdict.allow, planGate(&p, "TodoWrite", false));
    try testing.expectEqual(common.perm.Verdict.deny, planGate(&p, "Write", false));
}
