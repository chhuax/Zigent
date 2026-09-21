//! `engine/compact.zig` —— 压缩**三层**（首期只做三层：覆盖 95% 场景）。
//!
//! ## 结构上的安全保证
//!
//! 压缩**只接受、只产出 `[]Turn`** → 结构上不可能产生孤儿 `tool_result`
//! （这是 6 处运行期修补里的第 3 类破坏窗口）。
//!
//! ## 梯度而非"超限就摘要一下"
//!
//! 先用零成本手段（截断旧工具结果 → 丢弃最旧轮），都不够才花一次 LLM 调用。
//!
//! ## ★ 成功判据
//!
//! **最终 provider 上下文（含回注的续接消息）确实缩小**。
//! 曾有 bug「净增 22k 却记录为释放 0」—— 所以 `actuallyShrank()` 是判据，
//! 不是"策略报告释放了多少"。

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const Turn = @import("turn.zig").Turn;
const budget_mod = @import("budget.zig");

pub const Kind = enum {
    /// 第一层：截断/清空旧的工具结果（零成本）
    truncate_tool_results,
    /// 第二层：丢弃最旧的轮次（保留最近 N 轮）
    drop_old_turns,
    /// 第三层：对丢弃的前缀做一次 LLM 摘要
    summarize,

    pub fn wireName(self: Kind) []const u8 {
        return switch (self) {
            .truncate_tool_results => "truncate_tool_results",
            .drop_old_turns => "drop_old_turns",
            .summarize => "summarize",
        };
    }
};

pub const Options = struct {
    /// 至少保留最近多少轮完整内容
    keep_recent_turns: usize = 4,
    /// 第一层：旧工具结果截断到多少 code point
    tool_result_keep_chars: usize = 2_000,
    /// 压缩目标（wire token）
    target_tokens: i64 = 0,
    /// 送给摘要器的最大输入字符数
    max_summary_input_chars: usize = 120_000,
    /// 摘要器不可用时是否允许降级到前两层
    allow_layer12_only: bool = true,
};

pub const Summarizer = struct {
    ctx: *anyopaque,
    /// 输入待摘要文本，输出摘要文本（调用方拥有返回内存）。
    summarize: *const fn (ctx: *anyopaque, gpa: Allocator, io: std.Io, text: []const u8) anyerror![]u8,

    pub fn run(self: Summarizer, gpa: Allocator, io: std.Io, text: []const u8) ![]u8 {
        return self.summarize(self.ctx, gpa, io, text);
    }
};

pub const Result = struct {
    turns: []const Turn,
    kind: Kind,
    tokens_before: i64,
    tokens_after: i64,
    before_turns: usize,
    after_turns: usize,
    /// 压缩续接文本（第三层的产出）。调用方以 `.compact_continuation` 元信息注入。
    summary_text: ?[]const u8 = null,

    pub fn released(self: Result) i64 {
        return self.tokens_before - self.tokens_after;
    }

    /// ★ 成功判据：真实缩小，而不是"策略声称释放了多少"。
    pub fn actuallyShrank(self: Result) bool {
        return self.tokens_after < self.tokens_before;
    }
};

/// 把轮次序列摊平成消息序列（assistant + 紧邻 user(result)）。
pub fn turnMessages(gpa: Allocator, turns: []const Turn) Allocator.Error![]common.Message {
    var out = std.ArrayListUnmanaged(common.Message).empty;
    errdefer out.deinit(gpa);
    for (turns) |t| {
        try out.append(gpa, t.assistant);
        if (t.results.len > 0) {
            try out.append(gpa, try t.resultMessage(gpa));
        }
    }
    return out.toOwnedSlice(gpa);
}

pub fn estimateTurns(turns: []const Turn) i64 {
    var total: i64 = 0;
    for (turns) |t| {
        total += budget_mod.estimateMessages(&.{t.assistant});
        for (t.results) |r| total += common.usage.estimateTokens(r.output) + 8;
    }
    return total;
}

/// 三层压缩。
///
/// **所有权**：返回的 `Result.turns` 永远是 `gpa` 上**独立拥有**的切片
/// （不是输入切片的子区间），调用方负责 `gpa.free(result.turns)`。
pub fn compactTurns(
    gpa: Allocator,
    io: std.Io,
    turns: []const Turn,
    opts: Options,
    summarizer: ?Summarizer,
) !Result {
    const before = estimateTurns(turns);
    const target = if (opts.target_tokens > 0) opts.target_tokens else @divTrunc(before * 3, 4);

    // ── 第一层：截断旧工具结果（零成本）──
    var owned: []Turn = try truncateOldToolResults(gpa, turns, opts);
    var after = estimateTurns(owned);

    if (after <= target) {
        return .{
            .turns = owned,
            .kind = .truncate_tool_results,
            .tokens_before = before,
            .tokens_after = after,
            .before_turns = turns.len,
            .after_turns = owned.len,
        };
    }

    // ── 第二层：丢弃最旧的轮次（保留最近 N 轮）──
    const keep = @max(1, opts.keep_recent_turns);
    var dropped = std.ArrayListUnmanaged(Turn).empty;
    defer dropped.deinit(gpa);
    if (owned.len > keep) {
        try dropped.appendSlice(gpa, owned[0 .. owned.len - keep]);
        const kept = try gpa.alloc(Turn, keep);
        @memcpy(kept, owned[owned.len - keep ..]);
        gpa.free(owned);
        owned = kept;
    }
    after = estimateTurns(owned);

    if (after <= target or summarizer == null) {
        return .{
            .turns = owned,
            .kind = .drop_old_turns,
            .tokens_before = before,
            .tokens_after = after,
            .before_turns = turns.len,
            .after_turns = owned.len,
        };
    }

    // ── 第三层：对丢弃的前缀做一次摘要 ──
    if (dropped.items.len > 0) {
        const text = try renderForSummary(gpa, dropped.items, opts.max_summary_input_chars);
        defer gpa.free(text);
        const summary = summarizer.?.run(gpa, io, text) catch {
            // 摘要失败 → 降级到第二层结果（**不假装成功**）
            return .{
                .turns = owned,
                .kind = .drop_old_turns,
                .tokens_before = before,
                .tokens_after = after,
                .before_turns = turns.len,
                .after_turns = owned.len,
            };
        };
        const continuation = try std.fmt.allocPrint(
            gpa,
            "<compact-continuation>\n以下是更早对话的摘要，用于保持上下文连续性：\n{s}\n</compact-continuation>",
            .{summary},
        );
        const after3 = after + common.usage.estimateTokens(continuation);
        return .{
            .turns = owned,
            .kind = .summarize,
            .tokens_before = before,
            .tokens_after = after3,
            .before_turns = turns.len,
            .after_turns = owned.len,
            .summary_text = continuation,
        };
    }

    return .{
        .turns = owned,
        .kind = .drop_old_turns,
        .tokens_before = before,
        .tokens_after = after,
        .before_turns = turns.len,
        .after_turns = owned.len,
    };
}

fn truncateOldToolResults(gpa: Allocator, turns: []const Turn, opts: Options) ![]Turn {
    const keep = @max(1, opts.keep_recent_turns);
    var out = try gpa.alloc(Turn, turns.len);
    const cutoff = if (turns.len > keep) turns.len - keep else 0;
    for (turns, 0..) |t, i| {
        if (i >= cutoff) {
            out[i] = t;
            continue;
        }
        // 旧轮：截断结果
        const results = try gpa.alloc(common.ToolResultBlock, t.results.len);
        for (t.results, 0..) |r, j| {
            const short = common.usage.truncateCodePoints(r.output, opts.tool_result_keep_chars);
            if (short.len == r.output.len) {
                results[j] = r;
            } else {
                results[j] = .{
                    .tool_use_id = r.tool_use_id,
                    .output = try std.fmt.allocPrint(
                        gpa,
                        "{s}\n…[已压缩：省略 {d} 字符]",
                        .{ short, common.usage.countCodePoints(r.output) - opts.tool_result_keep_chars },
                    ),
                    .is_error = r.is_error,
                };
            }
        }
        out[i] = .{ .assistant = t.assistant, .results = results, .interrupted = t.interrupted };
    }
    return out;
}

fn renderForSummary(gpa: Allocator, turns: []const Turn, max_chars: usize) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(gpa);
    for (turns) |t| {
        if (out.items.len >= max_chars) break;
        for (t.assistant.content) |b| {
            switch (b) {
                .text => |x| try out.appendSlice(gpa, x.text),
                .tool_use => |x| try out.print(gpa, "工具调用: {s} {s}\n", .{ x.tool_name, x.input }),
                .tool_result => |x| try out.print(gpa, "工具结果: {s}\n", .{x.output}),
                .image => try out.appendSlice(gpa, "[图片]\n"),
            }
        }
        for (t.results) |r| {
            try out.print(gpa, "结果({s}): {s}\n", .{
                if (r.is_error) "错误" else "成功",
                common.usage.truncateCodePoints(r.output, 2000),
            });
        }
        if (out.items.len > max_chars) break;
    }
    if (out.items.len > max_chars) {
        const cut = common.usage.truncateCodePoints(out.items, max_chars);
        out.shrinkRetainingCapacity(cut.len);
    }
    return out.toOwnedSlice(gpa);
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const content = common.content;

fn mkTurn(gpa: Allocator, id: []const u8, text_len: usize) !Turn {
    const blocks = try gpa.alloc(common.ContentBlock, 2);
    blocks[0] = content.text("让我读个文件");
    blocks[1] = .{ .tool_use = .{ .tool_use_id = id, .tool_name = "Read", .input = "{}" } };
    const asst = common.Message{ .role = .assistant, .content = blocks };
    const big = try gpa.alloc(u8, text_len);
    @memset(big, 'x');
    return Turn.init(gpa, asst, &.{.{
        .tool_use_id = id,
        .output = big,
        .is_error = false,
    }});
}

test "compact: 输出仍然是 []Turn（结构上无孤儿）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const turns = [_]Turn{
        try mkTurn(a, "t1", 50_000),
        try mkTurn(a, "t2", 50_000),
        try mkTurn(a, "t3", 100),
        try mkTurn(a, "t4", 100),
    };
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const r = try compactTurns(a, threaded.io(), &turns, .{ .keep_recent_turns = 2 }, null);
    try testing.expect(r.turns.len >= 1);
    // 每个保留下来的轮的配对仍然成立
    for (r.turns) |t| {
        try Turn.validate(t.assistant, t.results);
    }
}

test "compact: 第一层截断旧工具结果就够时不丢轮次" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const turns = [_]Turn{
        try mkTurn(a, "t1", 20_000),
        try mkTurn(a, "t2", 20_000),
        try mkTurn(a, "t3", 50),
        try mkTurn(a, "t4", 50),
    };
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const r = try compactTurns(a, threaded.io(), &turns, .{
        .keep_recent_turns = 2,
        .target_tokens = 5_000,
        .tool_result_keep_chars = 100,
    }, null);
    try testing.expectEqual(Kind.truncate_tool_results, r.kind);
    try testing.expectEqual(@as(usize, 4), r.turns.len);
    try testing.expect(r.actuallyShrank());
}

test "compact: 第二层丢最旧轮次并保留最近 N 轮" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var list = std.ArrayListUnmanaged(Turn).empty;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const id = try std.fmt.allocPrint(a, "t{d}", .{i});
        try list.append(a, try mkTurn(a, id, 40_000));
    }
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const r = try compactTurns(a, threaded.io(), list.items, .{
        .keep_recent_turns = 3,
        .target_tokens = 1_000,
        .tool_result_keep_chars = 10_000,
    }, null);
    try testing.expectEqual(Kind.drop_old_turns, r.kind);
    try testing.expectEqual(@as(usize, 3), r.turns.len);
    try testing.expect(r.actuallyShrank());
}

test "compact: 第三层摘要产出续接文本" {
    const S = struct {
        fn sum(_: *anyopaque, gpa: Allocator, _: std.Io, _: []const u8) anyerror![]u8 {
            return gpa.dupe(u8, "之前用户要求读文件并修 bug。");
        }
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var list = std.ArrayListUnmanaged(Turn).empty;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const id = try std.fmt.allocPrint(a, "t{d}", .{i});
        try list.append(a, try mkTurn(a, id, 40_000));
    }
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const r = try compactTurns(a, threaded.io(), list.items, .{
        .keep_recent_turns = 2,
        .target_tokens = 1_000,
        .tool_result_keep_chars = 10_000,
    }, .{ .ctx = undefined, .summarize = S.sum });
    try testing.expectEqual(Kind.summarize, r.kind);
    try testing.expect(r.summary_text != null);
    try testing.expect(std.mem.indexOf(u8, r.summary_text.?, "compact-continuation") != null);
}

test "compact: 摘要失败 → 降级到第二层，不假装成功" {
    const S = struct {
        fn boom(_: *anyopaque, _: Allocator, _: std.Io, _: []const u8) anyerror![]u8 {
            return error.OutOfMemory;
        }
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var list = std.ArrayListUnmanaged(Turn).empty;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const id = try std.fmt.allocPrint(a, "t{d}", .{i});
        try list.append(a, try mkTurn(a, id, 40_000));
    }
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const r = try compactTurns(a, threaded.io(), list.items, .{
        .keep_recent_turns = 2,
        .target_tokens = 1_000,
        .tool_result_keep_chars = 10_000,
    }, .{ .ctx = undefined, .summarize = S.boom });
    try testing.expectEqual(Kind.drop_old_turns, r.kind);
    try testing.expect(r.summary_text == null);
}

test "compact: 已经很小的时候不动它" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const turns = [_]Turn{ try mkTurn(a, "t1", 10), try mkTurn(a, "t2", 10) };
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const r = try compactTurns(a, threaded.io(), &turns, .{ .target_tokens = 100_000 }, null);
    try testing.expectEqual(@as(usize, 2), r.turns.len);
}

test "compact: turnMessages 产出 assistant + 紧邻 user(result)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const turns = [_]Turn{try mkTurn(a, "t1", 10)};
    const msgs = try turnMessages(a, &turns);
    try testing.expectEqual(@as(usize, 2), msgs.len);
    try testing.expectEqual(common.MessageRole.assistant, msgs[0].role);
    try testing.expectEqual(common.MessageRole.user, msgs[1].role);
    try testing.expect(msgs[1].content[0] == .tool_result);
}
