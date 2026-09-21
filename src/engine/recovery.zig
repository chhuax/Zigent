//! `engine/recovery.zig` —— 错误恢复三态 + 退避（文档 03 §11.5(b)(c)）。
//!
//! ## ★ 两个计数必须彻底分离（历史事故的直接教训）
//!
//! 朴素实现里熔断抛出的异常穿透到通用错误分类 → 被归为 `UNKNOWN`→`RETRY`，
//! 于是重试阶梯**永远从零开始**、`turnCount--` **无界执行**，
//! 实测失控到 **401 turn**，`maxTurns=6` 与 `12` 行为完全相同。
//!
//! 因此 Zig 里：
//!   1. **turn 计数（不可回退的预算）与 retry 计数（可回退的阶梯）是两个字段**；
//!   2. 熔断走**不经错误分类的专用出口**（`circuitBreak`，直接产出 abort）。
//!
//! ## 恢复三态 + 修饰器（取代 16 × 13 全矩阵）
//!
//! 全矩阵里大量分支**永远不会触发**。三态 + 少量修饰器足够覆盖首期。

const std = @import("std");
const common = @import("common");
const budget = @import("budget.zig");

pub const Action = enum {
    /// 原样重发
    retry,
    /// 压缩后重发
    compact_and_retry,
    /// 修复配对/请求形状后重发
    repair_and_retry,
    /// 收敛 `max_tokens` 后重发
    clamp_max_tokens_and_retry,
    /// 切到 fallback 模型（**唯一 owner 在这里**）
    fallback_model,
    /// 终态
    abort,

    pub fn wireName(self: Action) []const u8 {
        return switch (self) {
            .retry => "RETRY",
            .compact_and_retry => "COMPACT_AND_RETRY",
            .repair_and_retry => "REPAIR_AND_RETRY",
            .clamp_max_tokens_and_retry => "CLAMP_MAX_TOKENS_AND_RETRY",
            .fallback_model => "FALLBACK_MODEL",
            .abort => "ABORT",
        };
    }
};

/// 拉式状态机的三态。
pub const State = enum { idle, start_turn, recovering, done };

/// 生产口径（文档 03 §7.6：「重试策略应该可配置」是误解 —— 定义了但从不使用的
/// `ROBUST`/`PERSISTENT` 是死配置，别做）。
pub const DEFAULT_MAX_API_RETRIES: u32 = 3;
pub const DEFAULT_BACKOFF_INITIAL_MS: i64 = 1_000;
pub const DEFAULT_BACKOFF_FACTOR: f64 = 2.0;
pub const DEFAULT_BACKOFF_CAP_MS: i64 = 30_000;
pub const DEFAULT_JITTER: f64 = 0.0;
pub const DEFAULT_MAX_TURNS: u32 = 200;
pub const SUBAGENT_MAX_TURNS: u32 = 10;
pub const DEFAULT_MAX_COMPACTIONS: u32 = 3;

/// 熔断：专用错误，**必须绕过通用错误分类**。
pub const CircuitBreaker = error{ToolRepeatedFailure};

pub const Recovery = struct {
    /// 可回退的重试阶梯
    api_attempts: u32 = 0,
    compactions: u32 = 0,
    /// **不可回退**的轮次预算
    turns_used: u32 = 0,
    max_api_retries: u32 = DEFAULT_MAX_API_RETRIES,
    max_compactions: u32 = DEFAULT_MAX_COMPACTIONS,
    max_turns: u32 = DEFAULT_MAX_TURNS,
    /// 是否允许模型回退（fallback 的**唯一 owner**）
    fallback_model: ?[]const u8 = null,
    used_fallback: bool = false,
    /// 上一次 `max_output_tokens` 的基线
    output_baseline: i64 = 8192,

    pub fn init(max_turns: u32) Recovery {
        return .{ .max_turns = max_turns };
    }

    /// **进入新的一轮** —— 这是唯一推进 turnBudget 的地方，只能前进不能后退。
    pub fn beginTurn(self: *Recovery) error{MaxTurnsExceeded}!u32 {
        if (self.turns_used >= self.max_turns) return error.MaxTurnsExceeded;
        self.turns_used += 1;
        // 新的一轮把「可回退的阶梯」重置，但**不动** turns_used
        self.api_attempts = 0;
        return self.turns_used;
    }

    /// 熔断专用出口：**不经过 `classify`**，直接终态。
    pub fn circuitBreak(self: *Recovery) Action {
        _ = self;
        return .abort;
    }

    /// 通用错误分类（三态 + 修饰器）。
    pub fn classify(self: *Recovery, code: common.ErrorCode) Action {
        switch (code) {
            .cancelled, .authentication, .quota_exceeded, .invalid_model => {
                // `invalid_model` 若配了 fallback 可以再试一次（唯一 owner 在这里）
                if (code == .invalid_model and self.fallback_model != null and !self.used_fallback) {
                    return .fallback_model;
                }
                return .abort;
            },
            .prompt_too_long => {
                if (self.compactions >= self.max_compactions) return .abort;
                return .compact_and_retry;
            },
            .max_output_tokens => {
                if (self.api_attempts >= self.max_api_retries) return .abort;
                return .clamp_max_tokens_and_retry;
            },
            .malformed_tool_input, .tool_use_mismatch => return .repair_and_retry,
            .rate_limited, .model_overloaded, .transient, .stale_connection => {
                // ⚠️ 这些**必须有上限**，否则配合无界循环会永不终止
                if (self.api_attempts >= self.max_api_retries) return .abort;
                if (code == .model_overloaded and self.fallback_model != null and !self.used_fallback) {
                    return .fallback_model;
                }
                return .retry;
            },
            .unknown => {
                if (self.api_attempts >= self.max_api_retries) return .abort;
                return .retry;
            },
        }
    }

    /// 记录一次尝试（**推进可回退的阶梯**）。
    pub fn noteAttempt(self: *Recovery, action: Action) void {
        switch (action) {
            .compact_and_retry => self.compactions += 1,
            .fallback_model => self.used_fallback = true,
            .retry, .repair_and_retry, .clamp_max_tokens_and_retry => self.api_attempts += 1,
            .abort => {},
        }
    }

    /// 退避：`Retry-After` 响应头 > 异常携带 > 本地策略。
    pub fn backoffMs(self: *Recovery, retry_after_ms: ?i64, error_hint_ms: ?i64) i64 {
        if (retry_after_ms) |v| return @max(0, v);
        if (error_hint_ms) |v| return @max(0, v);
        return localBackoff(self.api_attempts);
    }

    /// 输出上限升级（配合 `clamp_max_tokens_and_retry`）。
    pub fn clampMaxTokens(self: *Recovery, current: i64) i64 {
        const escalated = @max(64_000, 2 * self.output_baseline);
        return @min(current, escalated);
    }

    pub fn budgetHint(self: *Recovery) budget.Budget {
        var b = budget.Budget.init(200_000, 8192);
        b.output_reserve = self.output_baseline;
        return b;
    }
};

/// 本地退避：3 次 / 1s 起步 / ×2 / cap 30s / jitter 0。
pub fn localBackoff(attempt: u32) i64 {
    var ms: f64 = @floatFromInt(DEFAULT_BACKOFF_INITIAL_MS);
    var i: u32 = 0;
    while (i < attempt) : (i += 1) {
        ms *= DEFAULT_BACKOFF_FACTOR;
        if (ms >= @as(f64, @floatFromInt(DEFAULT_BACKOFF_CAP_MS))) {
            ms = @floatFromInt(DEFAULT_BACKOFF_CAP_MS);
            break;
        }
    }
    _ = DEFAULT_JITTER;
    return @intFromFloat(ms);
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "recovery: turn 预算不可回退" {
    var r = Recovery.init(3);
    _ = try r.beginTurn();
    _ = try r.beginTurn();
    _ = try r.beginTurn();
    try testing.expectError(error.MaxTurnsExceeded, r.beginTurn());
    try testing.expectEqual(@as(u32, 3), r.turns_used);
}

test "recovery: 重试阶梯可回退，turn 预算不受影响" {
    var r = Recovery.init(5);
    _ = try r.beginTurn();
    r.noteAttempt(.retry);
    r.noteAttempt(.retry);
    const before = r.turns_used;
    _ = try r.beginTurn();
    try testing.expectEqual(@as(u32, 0), r.api_attempts); // 阶梯清零
    try testing.expectEqual(before + 1, r.turns_used); // 预算只前进
}

test "recovery: 熔断走专用出口，不经过分类" {
    var r = Recovery.init(200);
    _ = try r.beginTurn();
    // 即便 api_attempts 还有余额，熔断也必须直接终态
    try testing.expectEqual(Action.abort, r.circuitBreak());
}

test "recovery: rate_limited 有上限（不会无界循环）" {
    var r = Recovery.init(200);
    r.max_api_retries = 2;
    try testing.expectEqual(Action.retry, r.classify(.rate_limited));
    r.noteAttempt(.retry);
    try testing.expectEqual(Action.retry, r.classify(.rate_limited));
    r.noteAttempt(.retry);
    try testing.expectEqual(Action.abort, r.classify(.rate_limited));
}

test "recovery: prompt_too_long → 压缩重试，次数用尽则 abort" {
    var r = Recovery.init(200);
    r.max_compactions = 1;
    try testing.expectEqual(Action.compact_and_retry, r.classify(.prompt_too_long));
    r.noteAttempt(.compact_and_retry);
    try testing.expectEqual(Action.abort, r.classify(.prompt_too_long));
}

test "recovery: 认证/取消/额度 → 立即终态" {
    var r = Recovery.init(200);
    try testing.expectEqual(Action.abort, r.classify(.authentication));
    try testing.expectEqual(Action.abort, r.classify(.cancelled));
    try testing.expectEqual(Action.abort, r.classify(.quota_exceeded));
}

test "recovery: 配对类错误走修复重试" {
    var r = Recovery.init(200);
    try testing.expectEqual(Action.repair_and_retry, r.classify(.tool_use_mismatch));
    try testing.expectEqual(Action.repair_and_retry, r.classify(.malformed_tool_input));
}

test "recovery: fallback 只切一次（唯一 owner）" {
    var r = Recovery.init(200);
    r.fallback_model = "claude-haiku";
    try testing.expectEqual(Action.fallback_model, r.classify(.invalid_model));
    r.noteAttempt(.fallback_model);
    try testing.expectEqual(Action.abort, r.classify(.invalid_model));
}

test "recovery: 退避优先级 Retry-After > 异常提示 > 本地" {
    var r = Recovery.init(200);
    try testing.expectEqual(@as(i64, 5000), r.backoffMs(5000, 9999));
    try testing.expectEqual(@as(i64, 9999), r.backoffMs(null, 9999));
    try testing.expectEqual(@as(i64, 1000), r.backoffMs(null, null));
    r.noteAttempt(.retry);
    try testing.expectEqual(@as(i64, 2000), r.backoffMs(null, null));
    r.noteAttempt(.retry);
    try testing.expectEqual(@as(i64, 4000), r.backoffMs(null, null));
}

test "recovery: 本地退避有 cap" {
    try testing.expectEqual(@as(i64, 30_000), localBackoff(20));
    try testing.expectEqual(@as(i64, 1_000), localBackoff(0));
}

test "recovery: 子代理 maxTurns 更小" {
    try testing.expect(SUBAGENT_MAX_TURNS < DEFAULT_MAX_TURNS);
}

test "recovery: 输出上限升级" {
    var r = Recovery.init(200);
    r.output_baseline = 8192;
    try testing.expectEqual(@as(i64, 64_000), r.clampMaxTokens(100_000));
}
