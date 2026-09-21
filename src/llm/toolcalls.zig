//! tool_call 参数增量拼接 —— 三家 provider 三套完全不同的语义（雷区 §B）。
//!
//! | | OpenAI Chat | Anthropic Messages | OpenAI Responses |
//! |---|---|---|---|
//! |累积键| `tool_calls[].index`（整型） | `content_block` 的 `index` | `item_id`（字符串） |
//! |参数| `function.arguments` JSON 字符串分片 | `delta.partial_json` 分片 | `function_call_arguments.delta` |
//! |id/name| 可能后续帧才补齐 | `content_block_start` 一次给全 | item 上带 |
//! |收口| 整轮结束 | `content_block_stop` | 三条路径 + 去重 |
//!
//! **三条铁律**：
//! 1. `arguments` 绝不能 `parse` 再 `re-serialize` —— 直接字符串拼接
//!    （否则丢 key 顺序 / 丢空格 / 破坏大数字精度）。
//! 2. `id` / `name` 用「**非空才覆盖**」语义；兼容网关常在中间帧发空串。
//! 3. `partialArguments` 曾同时承载两种语义 —— 这里拆成
//!    `arguments_snapshot`（OpenAI Chat：**累积全量**）与
//!    `arguments_delta`（Responses：**本帧增量**）两个字段。

const std = @import("std");
const Allocator = std.mem.Allocator;

/// 拼接完成的一个工具调用。
pub const Complete = struct {
    index: u32,
    id: []const u8,
    name: []const u8,
    /// 原始 JSON 字符串（未解析）。空参数时为 `"{}"`。
    arguments: []const u8,
};

/// 拼接失败的原因（对应终局校验）。
pub const Error = error{
    /// OpenAI：参数已收口但 id 为空 —— 视为协议错误
    MissingToolCallId,
    /// 收到 index 但从未见过 start / 帧乱序
    UnexpectedDelta,
    OutOfMemory,
};

/// 一次增量更新的**显式**语义载体（铁律 3）。
///
/// - OpenAI Chat 侧只填 `arguments_snapshot`（累积全量）；
/// - Responses 侧只填 `arguments_delta`（本帧增量）。
///
/// 两个字段**永不混用**，由测试断言。
pub const Partial = struct {
    index: u32 = 0,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    /// ★ OpenAI Chat：累积后的**全量快照**
    arguments_snapshot: ?[]const u8 = null,
    /// ★ OpenAI Responses：**本次增量 delta**
    arguments_delta: ?[]const u8 = null,
};

/// 只在 incoming 非空时覆盖 target —— 铁律 2。
fn overwriteIfNonEmpty(target: *std.ArrayListUnmanaged(u8), gpa: Allocator, incoming: []const u8) !void {
    if (incoming.len == 0) return;
    target.clearRetainingCapacity();
    try target.appendSlice(gpa, incoming);
}

// ─────────────────────────────────────────────────────────────────────────────
// OpenAI Chat Completions：按 index 累积
// ─────────────────────────────────────────────────────────────────────────────

pub const OpenAiAccumulator = struct {
    gpa: Allocator,
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    last: ?Partial = null,

    pub const Slot = struct {
        index: u32,
        id: std.ArrayListUnmanaged(u8) = .empty,
        name: std.ArrayListUnmanaged(u8) = .empty,
        /// 原始分片直接拼接 —— 铁律 1
        args: std.ArrayListUnmanaged(u8) = .empty,
        started: bool = false,
    };

    pub fn init(gpa: Allocator) OpenAiAccumulator {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *OpenAiAccumulator) void {
        for (self.slots.items) |*s| {
            s.id.deinit(self.gpa);
            s.name.deinit(self.gpa);
            s.args.deinit(self.gpa);
        }
        self.slots.deinit(self.gpa);
        self.* = undefined;
    }

    fn slotFor(self: *OpenAiAccumulator, index: u32) !*Slot {
        for (self.slots.items) |*s| {
            if (s.index == index) return s;
        }
        try self.slots.append(self.gpa, .{ .index = index });
        return &self.slots.items[self.slots.items.len - 1];
    }

    /// 喂一个 `delta.tool_calls[]` 元素。三个字段都可能缺省或为空。
    pub fn onDelta(
        self: *OpenAiAccumulator,
        index: u32,
        id: ?[]const u8,
        name: ?[]const u8,
        args_fragment: ?[]const u8,
    ) !void {
        const s = try self.slotFor(index);
        s.started = true;
        if (id) |v| try overwriteIfNonEmpty(&s.id, self.gpa, v);
        if (name) |v| try overwriteIfNonEmpty(&s.name, self.gpa, v);
        // 铁律 1：原样拼接，不做任何解析
        if (args_fragment) |v| try s.args.appendSlice(self.gpa, v);
        // 铁律 3：Chat 侧给出的是**累积快照**
        self.last = .{
            .index = index,
            .id = if (s.id.items.len == 0) null else s.id.items,
            .name = if (s.name.items.len == 0) null else s.name.items,
            .arguments_snapshot = s.args.items,
            .arguments_delta = null,
        };
    }

    /// 最近一次增量（`arguments_snapshot` 为累积全量）。
    pub fn lastPartial(self: *const OpenAiAccumulator) ?Partial {
        return self.last;
    }

    /// 整轮结束时的收口：按 index 升序产出，并做 id 非空校验。
    /// 切片指向内部缓冲 —— 调用方须在 deinit 前消费完。
    pub fn finish(self: *OpenAiAccumulator, out: *std.ArrayListUnmanaged(Complete)) !void {
        // index 升序 —— 顺序稳定性是契约（结果 future 下标必须对应 toolCalls 下标）
        std.mem.sort(Slot, self.slots.items, {}, struct {
            fn lt(_: void, a: Slot, b: Slot) bool {
                return a.index < b.index;
            }
        }.lt);

        for (self.slots.items) |*s| {
            // 终局校验：id 必须非空
            if (s.id.items.len == 0) return Error.MissingToolCallId;
            try out.append(self.gpa, .{
                .index = s.index,
                .id = s.id.items,
                .name = s.name.items,
                // 参数为空时补 "{}"（与 Anthropic 侧同构）
                .arguments = if (s.args.items.len == 0) "{}" else s.args.items,
            });
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Anthropic Messages：按 content_block index 累积
// ─────────────────────────────────────────────────────────────────────────────

pub const AnthropicAccumulator = struct {
    gpa: Allocator,
    slots: std.ArrayListUnmanaged(Slot) = .empty,

    pub const Slot = struct {
        index: u32,
        id: std.ArrayListUnmanaged(u8) = .empty,
        name: std.ArrayListUnmanaged(u8) = .empty,
        args: std.ArrayListUnmanaged(u8) = .empty,
        is_tool_use: bool = false,
        open: bool = false,
    };

    pub fn init(gpa: Allocator) AnthropicAccumulator {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *AnthropicAccumulator) void {
        for (self.slots.items) |*s| {
            s.id.deinit(self.gpa);
            s.name.deinit(self.gpa);
            s.args.deinit(self.gpa);
        }
        self.slots.deinit(self.gpa);
        self.* = undefined;
    }

    fn slotFor(self: *AnthropicAccumulator, index: u32) !*Slot {
        for (self.slots.items) |*s| {
            if (s.index == index) return s;
        }
        try self.slots.append(self.gpa, .{ .index = index });
        return &self.slots.items[self.slots.items.len - 1];
    }

    /// 查询某个 index 上已累积的 id / name / 参数（流式 tool_call 早交付用）。
    pub fn slotAt(self: *const AnthropicAccumulator, index: u32) ?Complete {
        for (self.slots.items) |*s| {
            if (s.index == index and s.is_tool_use) {
                return .{
                    .index = s.index,
                    .id = s.id.items,
                    .name = s.name.items,
                    .arguments = if (s.args.items.len == 0) "{}" else s.args.items,
                };
            }
        }
        return null;
    }

    /// `content_block_start`：只有 `type == "tool_use"` 的块才登记。
    pub fn onBlockStart(
        self: *AnthropicAccumulator,
        index: u32,
        block_type: []const u8,
        id: ?[]const u8,
        name: ?[]const u8,
    ) !void {
        if (!std.mem.eql(u8, block_type, "tool_use")) return;
        const s = try self.slotFor(index);
        s.is_tool_use = true;
        s.open = true;
        if (id) |v| try overwriteIfNonEmpty(&s.id, self.gpa, v);
        if (name) |v| try overwriteIfNonEmpty(&s.name, self.gpa, v);
    }

    /// `content_block_delta` 中 `delta.type == "input_json_delta"` 的 `partial_json`。
    pub fn onInputJsonDelta(self: *AnthropicAccumulator, index: u32, partial_json: []const u8) !void {
        const s = try self.slotFor(index);
        if (!s.is_tool_use) return; // 非 tool_use 块（如 thinking/text）忽略
        try s.args.appendSlice(self.gpa, partial_json); // 铁律 1
    }

    /// `content_block_stop`。
    pub fn onBlockStop(self: *AnthropicAccumulator, index: u32) !void {
        const s = try self.slotFor(index);
        s.open = false;
    }

    pub fn finish(self: *AnthropicAccumulator, out: *std.ArrayListUnmanaged(Complete)) !void {
        std.mem.sort(Slot, self.slots.items, {}, struct {
            fn lt(_: void, a: Slot, b: Slot) bool {
                return a.index < b.index;
            }
        }.lt);

        for (self.slots.items) |*s| {
            if (!s.is_tool_use) continue;
            try out.append(self.gpa, .{
                .index = s.index,
                .id = s.id.items,
                .name = s.name.items,
                // 空参数补 "{}"
                .arguments = if (s.args.items.len == 0) "{}" else s.args.items,
            });
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// OpenAI Responses：按 item_id 累积（不是 index）
// ─────────────────────────────────────────────────────────────────────────────

pub const ResponsesAccumulator = struct {
    gpa: Allocator,
    items: std.ArrayListUnmanaged(Item) = .empty,
    /// 防重复交付（三条收口路径都会给完整参数）
    completed: std.ArrayListUnmanaged([]const u8) = .empty,
    next_index: u32 = 0,
    last: ?Partial = null,

    pub const Item = struct {
        item_id: []u8,
        call_id: std.ArrayListUnmanaged(u8) = .empty,
        name: std.ArrayListUnmanaged(u8) = .empty,
        args: std.ArrayListUnmanaged(u8) = .empty,
        output_index: u32 = 0,
    };

    pub fn init(gpa: Allocator) ResponsesAccumulator {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *ResponsesAccumulator) void {
        for (self.items.items) |*it| {
            self.gpa.free(it.item_id);
            it.call_id.deinit(self.gpa);
            it.name.deinit(self.gpa);
            it.args.deinit(self.gpa);
        }
        self.items.deinit(self.gpa);
        for (self.completed.items) |c| self.gpa.free(c);
        self.completed.deinit(self.gpa);
        self.* = undefined;
    }

    fn itemFor(self: *ResponsesAccumulator, item_id: []const u8) !*Item {
        for (self.items.items) |*it| {
            if (std.mem.eql(u8, it.item_id, item_id)) return it;
        }
        try self.items.append(self.gpa, .{
            .item_id = try self.gpa.dupe(u8, item_id),
            .output_index = self.next_index,
        });
        self.next_index += 1;
        return &self.items.items[self.items.items.len - 1];
    }

    /// `response.output_item.added`：拿到 id / call_id / name。
    pub fn onItemAdded(
        self: *ResponsesAccumulator,
        item_id: []const u8,
        call_id: ?[]const u8,
        name: ?[]const u8,
        output_index: ?u32,
    ) !void {
        const it = try self.itemFor(item_id);
        if (call_id) |v| try overwriteIfNonEmpty(&it.call_id, self.gpa, v);
        if (name) |v| try overwriteIfNonEmpty(&it.name, self.gpa, v);
        if (output_index) |v| it.output_index = v;
    }

    /// `response.function_call_arguments.delta` —— 本帧**增量**。
    pub fn onArgsDelta(self: *ResponsesAccumulator, item_id: []const u8, delta: []const u8) !void {
        const it = try self.itemFor(item_id);
        try it.args.appendSlice(self.gpa, delta);
        // 铁律 3：Responses 侧给出的是**本帧 delta**，绝不填 snapshot
        self.last = .{
            .index = it.output_index,
            .id = if (it.call_id.items.len == 0) null else it.call_id.items,
            .name = if (it.name.items.len == 0) null else it.name.items,
            .arguments_snapshot = null,
            .arguments_delta = delta,
        };
    }

    /// 最近一次增量（`arguments_delta` 为本帧增量）。
    pub fn lastPartial(self: *const ResponsesAccumulator) ?Partial {
        return self.last;
    }

    /// `response.function_call_arguments.done` / `output_item.done` / 终态快照
    /// —— 三条路径都可能给完整参数，用 `completed` 去重。
    pub fn onArgsDone(self: *ResponsesAccumulator, item_id: []const u8, full: []const u8) !void {
        const it = try self.itemFor(item_id);
        for (self.completed.items) |c| {
            if (std.mem.eql(u8, c, item_id)) return; // 已交付
        }
        // 终态快照视为权威，覆盖累积结果
        try overwriteIfNonEmpty(&it.args, self.gpa, full);
        try self.completed.append(self.gpa, try self.gpa.dupe(u8, item_id));
    }

    pub fn finish(self: *ResponsesAccumulator, out: *std.ArrayListUnmanaged(Complete)) !void {
        // 按 output_index 排序
        std.mem.sort(Item, self.items.items, {}, struct {
            fn lt(_: void, a: Item, b: Item) bool {
                return a.output_index < b.output_index;
            }
        }.lt);
        for (self.items.items) |*it| {
            try out.append(self.gpa, .{
                .index = it.output_index,
                .id = it.call_id.items,
                .name = it.name.items,
                .arguments = if (it.args.items.len == 0) "{}" else it.args.items,
            });
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

const H = struct {
    fn expectArg(complete: Complete, want_idx: u32, want_name: []const u8, want_id: []const u8, want_args: []const u8) !void {
        try testing.expectEqual(want_idx, complete.index);
        try testing.expectEqualStrings(want_name, complete.name);
        try testing.expectEqualStrings(want_id, complete.id);
        try testing.expectEqualStrings(want_args, complete.arguments);
    }
};

test "OpenAI: 分片拼接必须逐字保留（铁律 1 —— 不能 parse 再序列化）" {
    const gpa = testing.allocator;
    var acc = OpenAiAccumulator.init(gpa);
    defer acc.deinit();

    // 故意带空格、key 顺序、大数字 —— 任何 re-serialize 都会破坏
    try acc.onDelta(0, "call_1", "Bash", "{\"command\":");
    try acc.onDelta(0, null, null, " \"ls -la\" , ");
    try acc.onDelta(0, null, null, "\"timeout\": 12345678901234567890}");
    try acc.onDelta(0, null, null, "");

    var out: std.ArrayListUnmanaged(Complete) = .empty;
    defer out.deinit(gpa);
    try acc.finish(&out);

    try testing.expectEqual(@as(usize, 1), out.items.len);
    try H.expectArg(out.items[0], 0, "Bash", "call_1", "{\"command\": \"ls -la\" , \"timeout\": 12345678901234567890}");
}

test "OpenAI: id 只在非空时覆盖（铁律 2 —— 兼容网关会发空串）" {
    const gpa = testing.allocator;
    var acc = OpenAiAccumulator.init(gpa);
    defer acc.deinit();

    try acc.onDelta(0, "", "", "{");
    try acc.onDelta(0, null, "Read", "\"path\":");
    try acc.onDelta(0, "call_x", null, "\"/tmp/a\"}");

    var out: std.ArrayListUnmanaged(Complete) = .empty;
    defer out.deinit(gpa);
    try acc.finish(&out);
    try H.expectArg(out.items[0], 0, "Read", "call_x", "{\"path\":\"/tmp/a\"}");
}

test "OpenAI: 参数已收口但 id 为空 → 协议错误" {
    const gpa = testing.allocator;
    var acc = OpenAiAccumulator.init(gpa);
    defer acc.deinit();
    try acc.onDelta(0, "", "Bash", "{}");
    var out: std.ArrayListUnmanaged(Complete) = .empty;
    defer out.deinit(gpa);
    try testing.expectError(Error.MissingToolCallId, acc.finish(&out));
}

test "OpenAI: 多工具按 index 升序产出（顺序稳定性是契约）" {
    const gpa = testing.allocator;
    var acc = OpenAiAccumulator.init(gpa);
    defer acc.deinit();

    // 故意乱序到达
    try acc.onDelta(2, "c2", "Third", "{}");
    try acc.onDelta(0, "c0", "First", "{}");
    try acc.onDelta(1, "c1", "Second", "{}");

    var out: std.ArrayListUnmanaged(Complete) = .empty;
    defer out.deinit(gpa);
    try acc.finish(&out);

    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("First", out.items[0].name);
    try testing.expectEqualStrings("Second", out.items[1].name);
    try testing.expectEqualStrings("Third", out.items[2].name);
}

test "OpenAI: 空参数补 {}" {
    const gpa = testing.allocator;
    var acc = OpenAiAccumulator.init(gpa);
    defer acc.deinit();
    try acc.onDelta(0, "c", "NoArgs", null);
    var out: std.ArrayListUnmanaged(Complete) = .empty;
    defer out.deinit(gpa);
    try acc.finish(&out);
    try testing.expectEqualStrings("{}", out.items[0].arguments);
}

test "Anthropic: start/delta/stop 生命周期，非 tool_use 块忽略" {
    const gpa = testing.allocator;
    var acc = AnthropicAccumulator.init(gpa);
    defer acc.deinit();

    // 第 0 块是 text，不该产生工具
    try acc.onBlockStart(0, "text", null, null);
    try acc.onInputJsonDelta(0, "should-be-ignored");
    try acc.onBlockStop(0);

    // 第 1 块是 thinking，也不该产生工具
    try acc.onBlockStart(1, "thinking", null, null);

    // 第 2 块是 tool_use
    try acc.onBlockStart(2, "tool_use", "toolu_1", "Edit");
    try acc.onInputJsonDelta(2, "{\"file_path\":");
    try acc.onInputJsonDelta(2, "\"/a/b\"}");
    try acc.onBlockStop(2);

    var out: std.ArrayListUnmanaged(Complete) = .empty;
    defer out.deinit(gpa);
    try acc.finish(&out);

    try testing.expectEqual(@as(usize, 1), out.items.len);
    try H.expectArg(out.items[0], 2, "Edit", "toolu_1", "{\"file_path\":\"/a/b\"}");
}

test "Anthropic: 参数为空时补 {}" {
    const gpa = testing.allocator;
    var acc = AnthropicAccumulator.init(gpa);
    defer acc.deinit();
    try acc.onBlockStart(0, "tool_use", "toolu_x", "Noop");
    try acc.onBlockStop(0);
    var out: std.ArrayListUnmanaged(Complete) = .empty;
    defer out.deinit(gpa);
    try acc.finish(&out);
    try testing.expectEqualStrings("{}", out.items[0].arguments);
}

test "Responses: 按 item_id 累积，且 done 去重（同一 item 只交付一次）" {
    const gpa = testing.allocator;
    var acc = ResponsesAccumulator.init(gpa);
    defer acc.deinit();

    try acc.onItemAdded("item_a", "call_a", "Bash", 0);
    try acc.onArgsDelta("item_a", "{\"cmd\":\"");
    try acc.onArgsDelta("item_a", "ls\"}");
    try acc.onArgsDone("item_a", "{\"cmd\":\"ls\"}");
    // 重复的终态事件（output_item.done + response.completed 都会给）
    try acc.onArgsDone("item_a", "{\"cmd\":\"ls\"}");

    var out: std.ArrayListUnmanaged(Complete) = .empty;
    defer out.deinit(gpa);
    try acc.finish(&out);

    try testing.expectEqual(@as(usize, 1), out.items.len);
    try H.expectArg(out.items[0], 0, "Bash", "call_a", "{\"cmd\":\"ls\"}");
}

test "Responses: 终态快照覆盖累积结果（快照是权威）" {
    const gpa = testing.allocator;
    var acc = ResponsesAccumulator.init(gpa);
    defer acc.deinit();
    try acc.onItemAdded("item_b", "call_b", "Read", 0);
    try acc.onArgsDelta("item_b", "{\"partial\":true}");
    try acc.onArgsDone("item_b", "{\"file_path\":\"/x\"}");
    var out: std.ArrayListUnmanaged(Complete) = .empty;
    defer out.deinit(gpa);
    try acc.finish(&out);
    try testing.expectEqualStrings("{\"file_path\":\"/x\"}", out.items[0].arguments);
}

test "toolcalls: id 后到 / 空 id 不覆盖（三家都不能覆盖）" {
    const gpa = testing.allocator;

    // OpenAI：id 在第 3 帧才到
    {
        var acc = OpenAiAccumulator.init(gpa);
        defer acc.deinit();
        try acc.onDelta(0, "", null, "{");
        try acc.onDelta(0, null, null, "}");
        try acc.onDelta(0, "late_id", null, null);
        var out: std.ArrayListUnmanaged(Complete) = .empty;
        defer out.deinit(gpa);
        try acc.finish(&out);
        try testing.expectEqualStrings("late_id", out.items[0].id);
        try testing.expectEqualStrings("{}", out.items[0].arguments);
    }

    // Anthropic：start 给全后再发空串也不能清空
    {
        var acc = AnthropicAccumulator.init(gpa);
        defer acc.deinit();
        try acc.onBlockStart(0, "tool_use", "toolu_keep", "Keep");
        try acc.onBlockStart(0, "tool_use", "", "");
        var out: std.ArrayListUnmanaged(Complete) = .empty;
        defer out.deinit(gpa);
        try acc.finish(&out);
        try testing.expectEqualStrings("toolu_keep", out.items[0].id);
        try testing.expectEqualStrings("Keep", out.items[0].name);
    }

    // Responses：空 call_id 不覆盖已有的
    {
        var acc = ResponsesAccumulator.init(gpa);
        defer acc.deinit();
        try acc.onItemAdded("i", "call_real", "Read", 0);
        try acc.onItemAdded("i", "", "", null);
        var out: std.ArrayListUnmanaged(Complete) = .empty;
        defer out.deinit(gpa);
        try acc.finish(&out);
        try testing.expectEqualStrings("call_real", out.items[0].id);
    }
}

test "toolcalls: partialArguments 的两种语义必须是两个不同字段（铁律 3）" {
    const gpa = testing.allocator;

    // OpenAI Chat → 只填 arguments_snapshot（累积全量）
    {
        var acc = OpenAiAccumulator.init(gpa);
        defer acc.deinit();
        try acc.onDelta(0, "c", "Bash", "{\"a\":");
        const p1 = acc.lastPartial().?;
        try testing.expectEqualStrings("{\"a\":", p1.arguments_snapshot.?);
        try testing.expect(p1.arguments_delta == null);

        try acc.onDelta(0, null, null, "1}");
        const p2 = acc.lastPartial().?;
        // 全量，不是 "1}"
        try testing.expectEqualStrings("{\"a\":1}", p2.arguments_snapshot.?);
        try testing.expect(p2.arguments_delta == null);
    }

    // Responses → 只填 arguments_delta（本帧增量）
    {
        var acc = ResponsesAccumulator.init(gpa);
        defer acc.deinit();
        try acc.onItemAdded("i", "c", "Bash", 0);
        try acc.onArgsDelta("i", "{\"a\":");
        try acc.onArgsDelta("i", "1}");
        const p = acc.lastPartial().?;
        try testing.expectEqualStrings("1}", p.arguments_delta.?);
        try testing.expect(p.arguments_snapshot == null);
    }
}
