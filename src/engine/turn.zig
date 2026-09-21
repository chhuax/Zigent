//! `engine.Turn` —— **配对不变量的类型化载体**（文档 04 §9 / 03 §11.4）。
//!
//! ## 不变量原文
//!
//! > assistant 消息中的每个 `tool_use`，必须在**紧邻的下一条** user 消息里集齐应答；
//! > 反向，任何 `tool_result` 必须能对上前一条 assistant 的 `tool_use`。
//!
//! 注意是「紧邻」，不是「存在即可」。
//!
//! ## 为什么这是整个项目里"用类型消灭 bug 类"最有价值的一处
//!
//! 朴素实现里同一个不变量被写成 **6 处独立运行期修补 + 3 套不同文案**：
//! 入转录前消毒 / 截断探测 / 请求前守卫 / load 侧守卫 / 持久化失败后修复 / 补发缺失
//! result ×2。这里让违反**在结构上不可表示**：唯一构造入口会校验，构造不出来就没有 Turn。
//!
//! ## 四类破坏窗口（全部被堵死）
//!
//! | 窗口 | 解法 |
//! |---|---|
//! | assistant 已落盘、result 未落盘 | `appendTo` **一次写两条**，不存在中间态 |
//! | 流式中断后两步非原子 | `finishInterrupted` → **同一个** `init` |
//! | 压缩改写前缀后产生孤儿 | 压缩**只接受/产出 `[]Turn`** |
//! | 取消时"真结果"与"合成终态"混写 | `finishInterrupted` 显式区分并各记 metadata |

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");

pub const Message = common.Message;
pub const ContentBlock = common.ContentBlock;
pub const ToolUseBlock = common.ToolUseBlock;
pub const ToolResultBlock = common.ToolResultBlock;

pub const PairingError = error{
    /// tool_use 与 result 数量不一致
    CountMismatch,
    /// 第 i 个 result 的 toolUseId 对不上第 i 个 tool_use
    IdMismatch,
    /// tool_result 出现在非 user 消息里
    WrongRole,
    /// assistant 消息里没有 tool_use，却给了 result
    UnexpectedResults,
};

pub const Turn = struct {
    /// 含 0..n 个 `tool_use`
    assistant: Message,
    /// 与 `assistant` 里的 `tool_use` **一一对应、同序**
    results: []const ToolResultBlock,
    /// 本轮是否由中断合成（用于 transcript metadata）
    interrupted: bool = false,

    /// **唯一的构造入口 —— 配对在这里被强制校验。**
    /// 纯逻辑：给两个容器比对 id，不需要 IO、不需要配置（文档 11 §4.2）。
    pub fn init(
        gpa: Allocator,
        assistant: Message,
        results: []const ToolResultBlock,
    ) (PairingError || Allocator.Error)!Turn {
        if (assistant.role != .assistant) return PairingError.WrongRole;

        var expected: usize = 0;
        for (assistant.content) |b| {
            if (b == .tool_use) expected += 1;
        }
        if (expected != results.len) return PairingError.CountMismatch;

        var i: usize = 0;
        for (assistant.content) |b| {
            const tu = b.asToolUse() orelse continue;
            if (!std.mem.eql(u8, tu.tool_use_id, results[i].tool_use_id)) {
                return PairingError.IdMismatch;
            }
            i += 1;
        }
        return .{
            .assistant = assistant,
            .results = try gpa.dupe(ToolResultBlock, results),
        };
    }

    /// 无工具调用的普通轮（assistant 只有文本）。
    pub fn plain(gpa: Allocator, assistant: Message) (PairingError || Allocator.Error)!Turn {
        return init(gpa, assistant, &.{});
    }

    /// 中断路径：已完成的结果保留，**未完成的补合成 error result**，
    /// 然后走**同一个** `init` → 配对不可能被破坏。
    ///
    /// `completed` 里的 result 按 `tool_use_id` 匹配；没匹配上的 `tool_use`
    /// 合成一条 `is_error = true` 的结果（文案固定，客户端可依赖 —— 协议 §3.3(c)）。
    pub fn finishInterrupted(
        gpa: Allocator,
        assistant: Message,
        completed: []const ToolResultBlock,
        cancel_message: []const u8,
    ) !Turn {
        var out = std.ArrayListUnmanaged(ToolResultBlock).empty;
        errdefer out.deinit(gpa);

        for (assistant.content) |b| {
            const tu = b.asToolUse() orelse continue;
            var found: ?ToolResultBlock = null;
            for (completed) |r| {
                if (std.mem.eql(u8, r.tool_use_id, tu.tool_use_id)) {
                    found = r;
                    break;
                }
            }
            if (found) |r| {
                try out.append(gpa, r);
            } else {
                try out.append(gpa, .{
                    .tool_use_id = tu.tool_use_id,
                    .output = cancel_message,
                    .is_error = true,
                });
            }
        }

        var turn = try init(gpa, assistant, out.items);
        out.deinit(gpa);
        turn.interrupted = true;
        return turn;
    }

    pub fn toolUseCount(self: Turn) usize {
        return self.results.len;
    }

    pub fn hasToolCalls(self: Turn) bool {
        return self.results.len > 0;
    }

    /// 与 tool_use 同序取出 (id, name, input) —— 执行器用。
    pub fn toolUses(self: Turn, gpa: Allocator) Allocator.Error![]ToolUseBlock {
        var out = std.ArrayListUnmanaged(ToolUseBlock).empty;
        errdefer out.deinit(gpa);
        for (self.assistant.content) |b| {
            if (b.asToolUse()) |tu| try out.append(gpa, tu);
        }
        return out.toOwnedSlice(gpa);
    }

    /// 把结果组装成**紧邻的那条 user 消息**（I3：tool_result 只能出现在 user 轮）。
    ///
    /// Anthropic 要求连续的 tool_result 合并进**一个** user 轮 —— 这里天然满足。
    pub fn resultMessage(self: Turn, gpa: Allocator) Allocator.Error!Message {
        const blocks = try gpa.alloc(ContentBlock, self.results.len);
        for (self.results, 0..) |r, i| blocks[i] = .{ .tool_result = r };
        return .{ .role = .user, .content = blocks };
    }

    /// 校验：`init` 的静态版（用于从 transcript 重建时的守卫）。
    pub fn validate(assistant: Message, results: []const ToolResultBlock) PairingError!void {
        var expected: usize = 0;
        for (assistant.content) |b| {
            if (b == .tool_use) expected += 1;
        }
        if (expected != results.len) return PairingError.CountMismatch;
        var i: usize = 0;
        for (assistant.content) |b| {
            const tu = b.asToolUse() orelse continue;
            if (!std.mem.eql(u8, tu.tool_use_id, results[i].tool_use_id)) return PairingError.IdMismatch;
            i += 1;
        }
    }
};

/// `repairMessages` —— 从任意消息序列里**剔除孤儿 tool_result**
/// （保证送进模型的历史永远配对）。
///
/// 这是 load 侧的守卫：transcript 可能被外部工具改写，读回来必须过一遍。
/// **注意**：它只做"删除孤儿"，绝不"补造"内容 —— 补造走 `finishInterrupted`。
pub fn repairMessages(gpa: Allocator, messages: []const Message) Allocator.Error![]Message {
    var out = std.ArrayListUnmanaged(Message).empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (i < messages.len) {
        const m = messages[i];

        // ── 非 assistant：只剔除**孤儿** tool_result ──
        if (m.role != .assistant) {
            var kept = std.ArrayListUnmanaged(ContentBlock).empty;
            for (m.content) |b| {
                if (b == .tool_result) continue; // 前面不是 assistant ⇒ 孤儿
                try kept.append(gpa, b);
            }
            if (kept.items.len == 0 and m.content.len > 0) {
                kept.deinit(gpa);
                i += 1;
                continue;
            }
            var copy = m;
            copy.content = try kept.toOwnedSlice(gpa);
            try out.append(gpa, copy);
            i += 1;
            continue;
        }

        // ── assistant：无 tool_use 直接保留 ──
        var id_buf: [64][]const u8 = undefined;
        const needed = collectToolUseIds(m, &id_buf);
        if (needed.len == 0) {
            try out.append(gpa, m);
            i += 1;
            continue;
        }

        // ── 有 tool_use：必须有**紧邻的下一条 user** 且集齐全部应答 ──
        if (i + 1 >= messages.len or messages[i + 1].role != .user) {
            i += 1; // 孤儿轮：整轮丢弃（比送一个残缺轮给 provider 更安全）
            continue;
        }
        const next = messages[i + 1];
        var kept = std.ArrayListUnmanaged(ContentBlock).empty;
        var found: usize = 0;
        for (next.content) |b| {
            if (b.asToolResult()) |r| {
                var known = false;
                for (needed) |id| {
                    if (std.mem.eql(u8, id, r.tool_use_id)) known = true;
                }
                if (!known) continue; // 对不上任何一个 tool_use ⇒ 孤儿
                found += 1;
            }
            try kept.append(gpa, b);
        }
        if (found != needed.len) {
            kept.deinit(gpa);
            i += 1; // 应答不全 ⇒ 整轮丢弃
            continue;
        }
        var copy = next;
        copy.content = try kept.toOwnedSlice(gpa);
        try out.append(gpa, m);
        try out.append(gpa, copy);
        i += 2;
    }
    return out.toOwnedSlice(gpa);
}

/// 取出某条 assistant 消息里全部 `tool_use` 的 id（写进调用方的栈缓冲，**不分配、无全局**）。
fn collectToolUseIds(m: Message, buf: [][]const u8) []const []const u8 {
    var n: usize = 0;
    for (m.content) |b| {
        const tu = b.asToolUse() orelse continue;
        if (n >= buf.len) break;
        buf[n] = tu.tool_use_id;
        n += 1;
    }
    return buf[0..n];
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn assistantWithToolUse(gpa: Allocator, id: []const u8) !Message {
    const blocks = try gpa.alloc(ContentBlock, 1);
    blocks[0] = .{ .tool_use = .{ .tool_use_id = id, .tool_name = "Read", .input = "{}" } };
    return .{ .role = .assistant, .content = blocks };
}

fn result(id: []const u8, ok: bool) ToolResultBlock {
    return .{ .tool_use_id = id, .output = if (ok) "ok" else "err", .is_error = !ok };
}

test "turn: 数量不匹配 → CountMismatch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try assistantWithToolUse(a, "t1");
    try testing.expectError(PairingError.CountMismatch, Turn.init(a, m, &.{}));
}

test "turn: id 对不上 → IdMismatch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try assistantWithToolUse(a, "t1");
    try testing.expectError(PairingError.IdMismatch, Turn.init(a, m, &.{result("t2", true)}));
}

test "turn: 角色不对 → WrongRole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try Message.user(a, "hi");
    try testing.expectError(PairingError.WrongRole, Turn.init(a, m, &.{}));
}

test "turn: 合法配对构造成功且顺序一致" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blocks = try a.alloc(ContentBlock, 2);
    blocks[0] = .{ .tool_use = .{ .tool_use_id = "a", .tool_name = "Read", .input = "{}" } };
    blocks[1] = .{ .text = .{ .text = "中间文本" } };
    blocks[1] = .{ .tool_use = .{ .tool_use_id = "b", .tool_name = "Bash", .input = "{}" } };
    const m = Message{ .role = .assistant, .content = blocks };
    const t = try Turn.init(a, m, &.{ result("a", true), result("b", false) });
    try testing.expectEqual(@as(usize, 2), t.toolUseCount());
}

test "turn: 中断补齐合成 error result（真结果保留）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blocks = try a.alloc(ContentBlock, 2);
    blocks[0] = .{ .tool_use = .{ .tool_use_id = "a", .tool_name = "Read", .input = "{}" } };
    blocks[1] = .{ .tool_use = .{ .tool_use_id = "b", .tool_name = "Bash", .input = "{}" } };
    const m = Message{ .role = .assistant, .content = blocks };

    const t = try Turn.finishInterrupted(a, m, &.{result("a", true)}, "用户中断");
    try testing.expect(t.interrupted);
    try testing.expectEqual(@as(usize, 2), t.results.len);
    try testing.expectEqualStrings("a", t.results[0].tool_use_id);
    try testing.expect(!t.results[0].is_error);
    try testing.expectEqualStrings("b", t.results[1].tool_use_id);
    try testing.expect(t.results[1].is_error);
    try testing.expectEqualStrings("用户中断", t.results[1].output);
    // 仍然满足配对
    try Turn.validate(m, t.results);
}

test "turn: resultMessage 产出一条 user 消息（I3）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try assistantWithToolUse(a, "t1");
    const t = try Turn.init(a, m, &.{result("t1", true)});
    const rm = try t.resultMessage(a);
    try testing.expectEqual(common.MessageRole.user, rm.role);
    try testing.expectEqual(@as(usize, 1), rm.content.len);
    try testing.expect(rm.content[0].tool_result.is_error == false);
}

test "turn: repairMessages 剔除孤儿 tool_result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const orphan_blocks = try a.alloc(ContentBlock, 1);
    orphan_blocks[0] = .{ .tool_result = result("ghost", true) };
    const orphan = Message{ .role = .user, .content = orphan_blocks };

    const msgs = [_]Message{ orphan, try Message.user(a, "真实输入") };
    const repaired = try repairMessages(a, &msgs);
    try testing.expectEqual(@as(usize, 1), repaired.len);
    try testing.expectEqualStrings("真实输入", repaired[0].content[0].asText().?);
}

test "turn: repairMessages 丢弃没有紧邻 result 的 assistant tool_use 轮" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = [_]Message{
        try assistantWithToolUse(a, "t1"),
        try Message.user(a, "下一条不是 result 而是普通输入"),
    };
    const repaired = try repairMessages(a, &msgs);
    // assistant 轮被丢弃，只剩 user
    try testing.expectEqual(@as(usize, 1), repaired.len);
    try testing.expectEqual(common.MessageRole.user, repaired[0].role);
}

test "turn: 合法的 assistant+紧邻 user(result) 原样保留" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const asst = try assistantWithToolUse(a, "t1");
    const t = try Turn.init(a, asst, &.{result("t1", true)});
    const rm = try t.resultMessage(a);
    const msgs = [_]Message{ asst, rm };
    const repaired = try repairMessages(a, &msgs);
    try testing.expectEqual(@as(usize, 2), repaired.len);
}
