//! `engine/budget.zig` —— token 预算与输出预留。
//!
//! ## ★ 这是"三重换算"，不是一次比较（文档 03 §11.5(a)）
//!
//! 1. **触发规模** = `anchor.wireTokens + max(0, rawEst − anchor.rawEstTokens)`
//!    —— 不是全量重估。锚点之后的增量才用启发式估算。
//! 2. **阈值**：配了 `compactWindow` 则**原值即线**；
//!    否则 `effectiveCeiling − min(40_000, ceiling × 0.25)`。
//! 3. **ratio 非对称更新**：**分母必须是原始估算**，
//!    否则不动点落在 `ratio²`，收敛到 √1.3 并**持续低估**。
//!
//! ⚠️ `AUTOCOMPACT_BUFFER_TOKENS` 是 **40_000**，不是 13_000（旧文档说法已实测过期）。

const std = @import("std");
const common = @import("common");

/// 余量（见文件头 ⚠️）。
pub const AUTOCOMPACT_BUFFER_TOKENS: i64 = 40_000;
/// 输出上限升级的续写次数。
pub const MAX_OUTPUT_TOKEN_CONTINUATIONS: u32 = 3;
/// 流式空闲看门狗（秒）。
pub const STREAM_IDLE_TIMEOUT_SECONDS: u64 = 90;

pub const Budget = struct {
    /// 模型上下文上限
    effective_ceiling: i64,
    /// 显式配置的压缩窗口（配了就**原值即线**）
    compact_window: ?i64 = null,
    /// 上一次 provider 报的 wire token（锚点）
    anchor_wire_tokens: i64 = 0,
    /// 锚点时刻的**原始估算**
    anchor_raw_estimate: i64 = 0,
    /// 估算校准系数（wire / raw）
    ratio: f64 = 1.0,
    /// 为输出预留的 token
    output_reserve: i64 = 8192,
    /// 已用输出续写次数
    output_continuations: u32 = 0,

    pub fn init(ceiling: i64, output_reserve: i64) Budget {
        return .{ .effective_ceiling = ceiling, .output_reserve = output_reserve };
    }

    /// 压缩阈值。
    pub fn threshold(self: Budget) i64 {
        if (self.compact_window) |w| return w;
        return self.effective_ceiling - @min(AUTOCOMPACT_BUFFER_TOKENS, @divTrunc(self.effective_ceiling, 4));
    }

    /// 触发规模（锚点 + 增量）。`raw_estimate` 是当前消息序列的启发式估算。
    pub fn triggerScale(self: Budget, raw_estimate: i64) i64 {
        const delta = raw_estimate - self.anchor_raw_estimate;
        return self.anchor_wire_tokens + @max(0, delta);
    }

    pub fn shouldCompact(self: Budget, raw_estimate: i64) bool {
        const scale = self.triggerScale(raw_estimate);
        const usable = self.threshold() - self.output_reserve;
        return scale >= usable;
    }

    /// 用一次真实 usage 校准（**非对称更新**：只在低估时快点追、高估时慢点退）。
    ///
    /// 分母用**原始估算**（不是 `ratio × raw`）—— 见文件头第 3 条。
    pub fn observe(self: *Budget, wire_tokens: i64, raw_estimate: i64) void {
        self.anchor_wire_tokens = wire_tokens;
        self.anchor_raw_estimate = raw_estimate;
        if (raw_estimate <= 0) return;
        const observed: f64 = @as(f64, @floatFromInt(wire_tokens)) / @as(f64, @floatFromInt(raw_estimate));
        // 低估 → 快速上调（0.5 权重）；高估 → 缓慢下调（0.1 权重）
        const weight: f64 = if (observed > self.ratio) 0.5 else 0.1;
        self.ratio = self.ratio * (1.0 - weight) + observed * weight;
        if (self.ratio < 0.1) self.ratio = 0.1;
        if (self.ratio > 10.0) self.ratio = 10.0;
    }

    /// 当前估算的 wire token。
    pub fn wireEstimate(self: Budget, raw_estimate: i64) i64 {
        const delta = raw_estimate - self.anchor_raw_estimate;
        const scaled: f64 = @as(f64, @floatFromInt(@max(0, delta))) * self.ratio;
        return self.anchor_wire_tokens + @as(i64, @intFromFloat(scaled));
    }

    /// 输出上限升级：`max(64_000, 2 × baseline)`。
    pub fn escalatedMaxTokens(_: Budget, baseline: i64) i64 {
        return @max(64_000, 2 * baseline);
    }

    /// 还能不能再续写一次。
    pub fn canContinueOutput(self: *Budget) bool {
        if (self.output_continuations >= MAX_OUTPUT_TOKEN_CONTINUATIONS) return false;
        self.output_continuations += 1;
        return true;
    }

    /// 剩余可用输入预算。
    pub fn remaining(self: Budget, raw_estimate: i64) i64 {
        return self.threshold() - self.wireEstimate(raw_estimate);
    }
};

/// 估算一段文本的 token（启发式，**刻意不引入 BPE**）。
pub fn estimateText(text: []const u8) i64 {
    return common.usage.estimateTokens(text);
}

/// 估算整个消息序列（含角色/结构开销的粗估）。
pub fn estimateMessages(messages: []const common.Message) i64 {
    var total: i64 = 0;
    for (messages) |m| {
        total += 4; // 角色/结构开销
        for (m.content) |b| {
            total += switch (b) {
                .text => |t| estimateText(t.text),
                .tool_use => |t| estimateText(t.tool_name) + estimateText(t.input) + 8,
                .tool_result => |t| estimateText(t.output) + 8,
                .image => |i| 1600 + @as(i64, @intCast(i.width / 8)),
            };
        }
    }
    return total;
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "budget: 阈值公式（无 compactWindow）" {
    var b = Budget.init(200_000, 8192);
    // 200_000 - min(40_000, 50_000) = 160_000
    try testing.expectEqual(@as(i64, 160_000), b.threshold());

    var small = Budget.init(100_000, 8192);
    // 100_000 - min(40_000, 25_000) = 75_000
    try testing.expectEqual(@as(i64, 75_000), small.threshold());
}

test "budget: compactWindow 配了就是原值即线" {
    var b = Budget.init(200_000, 8192);
    b.compact_window = 120_000;
    try testing.expectEqual(@as(i64, 120_000), b.threshold());
}

test "budget: 触发规模 = 锚点 + 增量（不是全量重估）" {
    var b = Budget.init(200_000, 0);
    b.observe(50_000, 40_000);
    // 原始估算涨到 60_000 → 增量 20_000 → 触发规模 70_000
    try testing.expectEqual(@as(i64, 70_000), b.triggerScale(60_000));
    // 原始估算非但不涨还降 → 增量取 0
    try testing.expectEqual(@as(i64, 50_000), b.triggerScale(10_000));
}

test "budget: ratio 更新分母是原始估算（不会收敛到 sqrt 并持续低估）" {
    var b = Budget.init(1_000_000, 0);
    // 真实 wire 是 raw 的 2 倍
    b.observe(20_000, 10_000);
    try testing.expect(b.ratio > 1.0 and b.ratio <= 2.0);
    // 反复观测同一比例，ratio 应收敛到 2 而不是 sqrt(2)
    var i: usize = 0;
    while (i < 50) : (i += 1) b.observe(20_000, 10_000);
    try testing.expect(b.ratio > 1.9 and b.ratio <= 2.0);
}

test "budget: 低估快速上调、高估缓慢下调" {
    var up = Budget.init(1_000_000, 0);
    up.observe(4000, 1000); // 观测 4.0
    const up_ratio = up.ratio;

    var down = Budget.init(1_000_000, 0);
    down.observe(250, 1000); // 观测 0.25
    const down_ratio = down.ratio;

    // 上调幅度应大于下调幅度（相对 1.0）
    try testing.expect((up_ratio - 1.0) > (1.0 - down_ratio));
}

test "budget: shouldCompact 与输出预留" {
    var b = Budget.init(200_000, 8192);
    b.observe(0, 0);
    try testing.expect(!b.shouldCompact(100_000));
    try testing.expect(b.shouldCompact(200_000));
}

test "budget: 输出上限升级与续写次数" {
    var b = Budget.init(200_000, 8192);
    try testing.expectEqual(@as(i64, 64_000), b.escalatedMaxTokens(8192));
    try testing.expectEqual(@as(i64, 130_000), b.escalatedMaxTokens(65_000));
    try testing.expect(b.canContinueOutput());
    try testing.expect(b.canContinueOutput());
    try testing.expect(b.canContinueOutput());
    try testing.expect(!b.canContinueOutput());
}

test "budget: 消息估算对 CJK 不按字节虚高" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try common.Message.user(a, "中文内容");
    const est = estimateMessages(&.{m});
    // 4 个汉字 → 估算应该在个位数到十几之间，绝不等于 12 字节推导出的量级
    try testing.expect(est > 0 and est < 20);
}
