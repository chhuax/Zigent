//! `perm/sandbox.zig` —— 沙箱判定：**刻意的存根（deliberate stub）**。
//!
//! 设计依据：`docs/analysis/2026-09-19-07-权限与安全设计.md` §8（尤其 §8.3/§8.4）
//! 与 §12 的「首期不做」表第 1 条。
//!
//! ## 为什么首期不做沙箱
//! 朴素实现里的 `SandboxPolicy.runtimeAvailable` 是一个**恒 false 的存根**，
//! 也就是说那套策略 + 分类器（约 501 行）从来没有真正生效过；而一旦把
//! `enabled` 打开，它会把**全部命令**拒掉。沙箱的真正难点是先定执行机制
//! （macOS `sandbox-exec` / Linux `bubblewrap` / `landlock`），不是先写分类器。
//! 首期没有足够信息把这个机制选对，所以：
//!
//!   * **不移植**那 501 行；
//!   * 只保留**接口形状**（本文件），让 `Checker` 的判定链有一个明确的挂载点；
//!   * `evaluate` **恒返回 `allow`**，并在 `metadata` 里写死
//!     `sandboxEnabled: false` —— 这是**诚实的信号**：调用方（权限卡片/审计）
//!     能看出「这条放行不是因为沙箱隔离了，而是因为首期没有沙箱」，
//!     不会被一个恒 allow 的函数误导。
//!
//! ⚠️ **恒 allow 的安全前提**：沙箱从不作为唯一防线。真正的防线是四级判定链
//! （Plan 闸门 / 工具自判 / 确定性分类器 / 规则 + 缓存 + 用户裁决），
//! 也就是 `checker.evaluate` 里那条路径。沙箱在二期是**叠加**在它之上的
//! 第 5 层，不是替代品。

const std = @import("std");
const common = @import("common");

/// 沙箱执行机制。首期一个都没有 —— 枚举留位是为了二期在这里加分支时
/// `switch` 会强制作者显式选择，而不是默默落进 `else`。
pub const Mechanism = enum {
    /// 首期：没有可用的隔离机制（对应朴素实现里恒 false 的 `runtimeAvailable`）。
    none,
    /// 二期候选：macOS `sandbox-exec` / Linux `bubblewrap` / `landlock`。
    sandbox_exec,
    bubblewrap,
    landlock,

    pub fn wireName(self: Mechanism) []const u8 {
        return switch (self) {
            .none => "NONE",
            .sandbox_exec => "SANDBOX_EXEC",
            .bubblewrap => "BUBBLEWRAP",
            .landlock => "LANDLOCK",
        };
    }
};

/// 沙箱判定结果。形状与 `common.perm.Outcome` 对齐，方便二期无缝接进判定链。
pub const SandboxOutcome = struct {
    verdict: common.perm.Verdict,
    reason: []const u8,
    mechanism: Mechanism = .none,
    /// ★ 恒为 false。**这是本存根最重要的一个字段**：它让「恒 allow」
    /// 无法被误读成「已经隔离」。
    enabled: bool = false,
};

/// 接口形状：二期接 `sandbox-exec` / `bubblewrap` 时在这里判。
/// 首期恒 `allow`，理由见文件头。
pub fn evaluate(mechanism: Mechanism, command: []const u8) SandboxOutcome {
    _ = mechanism;
    _ = command;
    return .{
        .verdict = .allow,
        .reason = "sandbox is not implemented in v1 (stub, never the only defence)",
        .mechanism = .none,
        .enabled = false,
    };
}

/// `Checker` 侧用的形态：返回 `Outcome` 并带上 `{sandboxEnabled:false}` 元数据。
/// `metadata` 归 `gpa`（或调用方给的 arena）；`now_ms` 由调用方注入（引擎传 `util.io` 的
/// `epochMillis`，测试可传固定值），避免本模块自己去碰系统时钟。
pub fn evaluateOutcome(
    gpa: std.mem.Allocator,
    now_ms: i64,
    command: ?[]const u8,
) !common.perm.Outcome {
    var metadata = common.json.Map{};
    try metadata.put(gpa, "sandboxEnabled", .{ .boolean = false });
    try metadata.put(gpa, "sandboxMechanism", .{ .string = Mechanism.none.wireName() });
    if (command) |c| {
        try metadata.put(gpa, "command", .{ .string = c });
    }
    var out = common.perm.Outcome.allow("sandbox stub: allow with sandboxEnabled=false", .safe);
    out.trace = .{
        .subject = "permission:sandbox",
        .decision = .allow,
        .allowed = true,
        .provenance = .{
            .source = .builtin,
            .source_id = "sandbox-stub",
            .key = "sandboxEnabled",
            .priority = 0x20,
            .captured_at_ms = now_ms,
        },
        .reason = out.reason,
        .metadata = metadata,
    };
    return out;
}

/// 沙箱是否可用（首期恒 false，与朴素实现的 `runtimeAvailable` 一致，
/// 但这里**明确标注它是个存根**而不是一个会误导人的真实判定）。
pub fn runtimeAvailable() bool {
    return false;
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "sandbox: 存根恒 allow 且显式声明 not enabled" {
    const out = evaluate(.none, "rm -rf /");
    try testing.expectEqual(common.perm.Verdict.allow, out.verdict);
    try testing.expect(!out.enabled);
    try testing.expectEqual(Mechanism.none, out.mechanism);
    try testing.expect(!runtimeAvailable());
}

test "sandbox: metadata 里写死 sandboxEnabled=false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try evaluateOutcome(arena.allocator(), 1_700_000_000_000, "ls");
    const t = out.trace orelse return error.MissingTrace;
    const v = t.metadata.get("sandboxEnabled") orelse return error.MissingKey;
    try testing.expectEqual(false, v.boolean);
    try testing.expectEqual(common.perm.Verdict.allow, out.verdict);
}
