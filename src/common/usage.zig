//! `Usage` —— 6 个字段，藏着四家 provider 的口径差异（文档 04 §5）。
//!
//! ★ 互斥不变量：**总量 = input + output + cacheRead + cacheCreation**。
//!   `input_tokens` 与 `cache_read_tokens` **互斥**（input 不含 cache read）。
//!   违反它 = 重复计数 = 静默虚高，且直接影响压缩阈值判定。
//!
//! ★ 为什么用 `i64` 而不是 `u64`：网关会返回负值/缺字段；
//!   `u64` 下溢会变成天文数字，**比有符号实现危险得多**。减法前一律 `@max(0, ...)`。

const std = @import("std");
const json = @import("json.zig");

pub const Usage = struct {
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    cache_read_tokens: i64 = 0,
    cache_creation_tokens: i64 = 0,
    cache_creation_input_tokens_5m: i64 = 0,
    cache_creation_input_tokens_1h: i64 = 0,

    pub const zero: Usage = .{};

    pub fn total(self: Usage) i64 {
        return self.input_tokens + self.output_tokens +
            self.cache_read_tokens + self.cache_creation_tokens;
    }

    /// 送进 provider 的上下文规模（不含输出）。
    pub fn contextTokens(self: Usage) i64 {
        return self.input_tokens + self.cache_read_tokens + self.cache_creation_tokens;
    }

    pub fn add(a: Usage, b: Usage) Usage {
        return .{
            .input_tokens = a.input_tokens + b.input_tokens,
            .output_tokens = a.output_tokens + b.output_tokens,
            .cache_read_tokens = a.cache_read_tokens + b.cache_read_tokens,
            .cache_creation_tokens = a.cache_creation_tokens + b.cache_creation_tokens,
            .cache_creation_input_tokens_5m = a.cache_creation_input_tokens_5m + b.cache_creation_input_tokens_5m,
            .cache_creation_input_tokens_1h = a.cache_creation_input_tokens_1h + b.cache_creation_input_tokens_1h,
        };
    }

    // ── 四家归一化 ──────────────────────────────────────────────────────────

    /// OpenAI Chat Completions：`prompt_tokens` **已包含** `cached_tokens`。
    pub fn normalizeOpenAi(prompt_tokens: i64, cached_tokens: i64, completion_tokens: i64) Usage {
        return .{
            .input_tokens = @max(0, prompt_tokens - @max(0, cached_tokens)),
            .output_tokens = @max(0, completion_tokens),
            .cache_read_tokens = @max(0, cached_tokens),
        };
    }

    /// DeepSeek：缓存命中在**顶层** `prompt_cache_hit_tokens`，
    /// 而 `prompt_tokens` 同样是**包含**它的口径。
    pub fn normalizeDeepSeek(prompt_tokens: i64, cache_hit: i64, completion_tokens: i64) Usage {
        return normalizeOpenAi(prompt_tokens, cache_hit, completion_tokens);
    }

    /// Anthropic Messages：
    ///   - 原生 Claude：`input_tokens` **不含** cache read → 不相减；
    ///   - 兼容网关：常返回包含 cache read 的 inclusive 值 → 必须相减。
    /// 判据由调用方按 `model.contains("claude")` 给出。
    pub fn normalizeAnthropic(
        model: []const u8,
        input_tokens: i64,
        cache_read: i64,
        cache_creation: i64,
        output_tokens: i64,
    ) Usage {
        const is_claude = std.mem.indexOf(u8, model, "claude") != null;
        const input = if (is_claude)
            @max(0, input_tokens)
        else
            @max(0, input_tokens - @max(0, cache_read));
        return .{
            .input_tokens = input,
            .output_tokens = @max(0, output_tokens),
            .cache_read_tokens = @max(0, cache_read),
            .cache_creation_tokens = @max(0, cache_creation),
        };
    }

    /// 归一化守卫：把任何来源拼出来的 Usage 修正到互斥口径（幂等）。
    pub fn normalized(self: Usage) Usage {
        return .{
            .input_tokens = @max(0, self.input_tokens),
            .output_tokens = @max(0, self.output_tokens),
            .cache_read_tokens = @max(0, self.cache_read_tokens),
            .cache_creation_tokens = @max(0, self.cache_creation_tokens),
            .cache_creation_input_tokens_5m = @max(0, self.cache_creation_input_tokens_5m),
            .cache_creation_input_tokens_1h = @max(0, self.cache_creation_input_tokens_1h),
        };
    }

    // ── 序列化 ──────────────────────────────────────────────────────────────

    pub fn toJson(self: Usage, e: *json.Encoder) !void {
        try e.beginObject();
        try e.intField("inputTokens", self.input_tokens);
        try e.intField("outputTokens", self.output_tokens);
        try e.intField("cacheReadTokens", self.cache_read_tokens);
        try e.intField("cacheCreationTokens", self.cache_creation_tokens);
        try e.intField("cacheCreationInputTokens5m", self.cache_creation_input_tokens_5m);
        try e.intField("cacheCreationInputTokens1h", self.cache_creation_input_tokens_1h);
        try e.endObject();
    }

    pub fn fromJson(v: json.Value) Usage {
        return .{
            .input_tokens = v.getInt("inputTokens") orelse v.getInt("input_tokens") orelse 0,
            .output_tokens = v.getInt("outputTokens") orelse v.getInt("output_tokens") orelse 0,
            .cache_read_tokens = v.getInt("cacheReadTokens") orelse v.getInt("cache_read_input_tokens") orelse 0,
            .cache_creation_tokens = v.getInt("cacheCreationTokens") orelse v.getInt("cache_creation_input_tokens") orelse 0,
            .cache_creation_input_tokens_5m = v.getInt("cacheCreationInputTokens5m") orelse 0,
            .cache_creation_input_tokens_1h = v.getInt("cacheCreationInputTokens1h") orelse 0,
        };
    }
};

/// 本地 token 估算启发式 —— **刻意不引入 BPE**（`char/4 × 4/3`，见雷区 D）。
pub fn estimateTokens(text: []const u8) i64 {
    const chars: i64 = @intCast(text.len);
    return @divTrunc(@divTrunc(chars, 4) * 4, 3) + 1;
}

/// 按 **code point** 计长度（文档 04 §8 决策：CJK 在 BMP 内 UTF-16 == code point）。
pub fn countCodePoints(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        i += @max(len, 1);
        n += 1;
    }
    return n;
}

/// 截断到 `max_cp` 个 code point（不切断 UTF-8 序列）。
pub fn truncateCodePoints(text: []const u8, max_cp: usize) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (n + 1 > max_cp) break;
        i += @max(len, 1);
        n += 1;
    }
    return text[0..@min(i, text.len)];
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "usage: OpenAI 已含 cache → 必须相减" {
    const u = Usage.normalizeOpenAi(1000, 800, 50);
    try testing.expectEqual(@as(i64, 200), u.input_tokens);
    try testing.expectEqual(@as(i64, 800), u.cache_read_tokens);
    try testing.expectEqual(@as(i64, 1050), u.total());
}

test "usage: OpenAI 异常值不下溢" {
    const u = Usage.normalizeOpenAi(100, 300, -5);
    try testing.expectEqual(@as(i64, 0), u.input_tokens);
    try testing.expectEqual(@as(i64, 0), u.output_tokens);
    try testing.expect(u.total() >= 0);
}

test "usage: DeepSeek 顶层 cache 命中" {
    const u = Usage.normalizeDeepSeek(500, 400, 20);
    try testing.expectEqual(@as(i64, 100), u.input_tokens);
    try testing.expectEqual(@as(i64, 400), u.cache_read_tokens);
}

test "usage: Anthropic 原生 claude 不相减，网关相减" {
    const native = Usage.normalizeAnthropic("claude-sonnet-4", 1000, 800, 0, 10);
    try testing.expectEqual(@as(i64, 1000), native.input_tokens);
    try testing.expectEqual(@as(i64, 800), native.cache_read_tokens);

    const gw = Usage.normalizeAnthropic("glm-4.6", 1000, 800, 0, 10);
    try testing.expectEqual(@as(i64, 200), gw.input_tokens);
}

test "usage: 互斥口径总量守恒" {
    const u = Usage.normalizeOpenAi(700, 500, 100);
    // 总量 = prompt + completion（cache 已被拆出，不重复计）
    try testing.expectEqual(@as(i64, 800), u.total());
}

test "usage: code point 长度 —— 中文与 UTF-16 一致，emoji 更宽松" {
    try testing.expectEqual(@as(usize, 5), countCodePoints("你好世界a"));
    try testing.expectEqual(@as(usize, 1), countCodePoints("😀"));
    try testing.expectEqual(@as(usize, 1), countCodePoints("中"));
}

test "usage: 截断不切断 UTF-8" {
    const s = "你好世界";
    const t = truncateCodePoints(s, 2);
    try testing.expectEqualStrings("你好", t);
    try testing.expect(std.unicode.utf8ValidateSlice(t));
}

test "usage: JSON 往返" {
    var e = json.Encoder.init(testing.allocator);
    defer e.deinit();
    const u = Usage{ .input_tokens = 1, .output_tokens = 2, .cache_read_tokens = 3 };
    try u.toJson(&e);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try json.parse(arena.allocator(), e.text());
    const back = Usage.fromJson(v);
    try testing.expectEqual(@as(i64, 1), back.input_tokens);
    try testing.expectEqual(@as(i64, 3), back.cache_read_tokens);
}

test "usage: estimateTokens 启发式" {
    try testing.expect(estimateTokens("") >= 0);
    try testing.expect(estimateTokens("abcdefgh") > 0);
}
