//! tool_call 参数增量拼接 —— M0 spike E2 里**最容易翻车**的一块。
//!
//! 三家 provider 三套完全不同的语义（见 ../移植雷区.md §B）：
//!
//! | | OpenAI Chat | Anthropic Messages | OpenAI Responses |
//! |累积键| tool_calls[].index (int) | content_block index (int) | item_id (string) |
//! |参数| function.arguments = JSON 字符串分片 | delta.partial_json 分片 | function_call_arguments.delta |
//! |id/name| 可能后续帧才补齐 | content_block_start 一次给全 | item 上带 |
//! |收口| 整轮结束 | content_block_stop | 三条路径 + 去重 |
//!
//! **三条铁律**：
//! 1. `arguments` 绝不能 parse 再 re-serialize —— 直接字符串拼接。
//! （否则丢 key 顺序 / 丢空格 / 破坏大数字精度）
//! 2. `id` / `name` 用「非空才覆盖」语义，不能直接赋值。
//! 3. 既有实现里 `partialArguments` 同时承担两种语义（OpenAI=累积全量，
//! Responses=本次 delta）—— 这里必须拆成两个不同字段。

const std = @import("std");

/// 拼接完成的一个工具调用。
pub const Complete = struct {
 index: u32,
 id: []const u8,
 name: []const u8,
 /// 原始 JSON 字符串（未解析）。空参数时为 "{}"。
 arguments: []const u8,
};

/// 拼接失败的原因（对应既有实现侧的终局校验）。
pub const Error = error{
 /// OpenAI：参数已收口但 id 为空 —— 视为协议错误
 MissingToolCallId,
 /// 收到 index 但从未见过 start（Anthropic） / 帧乱序
 UnexpectedDelta,
 OutOfMemory,
};

/// 只在 incoming 非空时覆盖 target —— 铁律 2。
fn overwriteIfNonEmpty(target: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, incoming: []const u8) !void {
 if (incoming.len == 0) return;
 target.clearRetainingCapacity();
 try target.appendSlice(gpa, incoming);
}

// ---------------------------------------------------------------------------
// OpenAI Chat Completions：按 index 累积
// ---------------------------------------------------------------------------

pub const OpenAiAccumulator = struct {
 gpa: std.mem.Allocator,
 slots: std.ArrayListUnmanaged(Slot) = .empty,

 pub const Slot = struct {
 index: u32,
 id: std.ArrayListUnmanaged(u8) = .empty,
 name: std.ArrayListUnmanaged(u8) = .empty,
 /// 原始分片直接拼接 —— 铁律 1
 args: std.ArrayListUnmanaged(u8) = .empty,
 started: bool = false,
 };

 pub fn init(gpa: std.mem.Allocator) OpenAiAccumulator {
 return .{ .gpa = gpa };
 }

 pub fn deinit(self: *OpenAiAccumulator) void {
 for (self.slots.items) |*s| {
 s.id.deinit(self.gpa);
 s.name.deinit(self.gpa);
 s.args.deinit(self.gpa);
 }
 self.slots.deinit(self.gpa);
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
 }

 /// 整轮结束时的收口：按 index 升序产出，并做 id 非空校验。
 /// 调用方负责在 out 里消费完再 deinit（切片指向内部缓冲）。
 pub fn finish(self: *OpenAiAccumulator, out: *std.ArrayListUnmanaged(Complete)) !void {
 // index 升序 —— 顺序稳定性是契约（结果 future 下标必须对应 toolCalls 下标）
 std.mem.sort(Slot, self.slots.items, {}, struct {
 fn lt(_: void, a: Slot, b: Slot) bool {
 return a.index < b.index;
 }
 }.lt);

 for (self.slots.items) |*s| {
 // 终局校验：id 必须非空（出处见 docs/internal/）
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

// ---------------------------------------------------------------------------
// Anthropic Messages：可精确知道每次 content_block 的类型
// ---------------------------------------------------------------------------

pub const AnthropicAccumulator = struct {
 gpa: std.mem.Allocator,
 slots: std.ArrayListUnmanaged(Slot) = .empty,

 pub const Slot = struct {
 index: u32,
 id: std.ArrayListUnmanaged(u8) = .empty,
 name: std.ArrayListUnmanaged(u8) = .empty,
 args: std.ArrayListUnmanaged(u8) = .empty,
 is_tool_use: bool = false,
 open: bool = false,
 };

 pub fn init(gpa: std.mem.Allocator) AnthropicAccumulator {
 return .{ .gpa = gpa };
 }

 pub fn deinit(self: *AnthropicAccumulator) void {
 for (self.slots.items) |*s| {
 s.id.deinit(self.gpa);
 s.name.deinit(self.gpa);
 s.args.deinit(self.gpa);
 }
 self.slots.deinit(self.gpa);
 }

 fn slotFor(self: *AnthropicAccumulator, index: u32) !*Slot {
 for (self.slots.items) |*s| {
 if (s.index == index) return s;
 }
 try self.slots.append(self.gpa, .{ .index = index });
 return &self.slots.items[self.slots.items.len - 1];
 }

 /// `content_block_start`：只有 type == "tool_use" 的块才登记。
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
 // 空参数补 "{}"（既有实现: DefaultAnthropicClient L390-399 在参数为 "{}" 时补发）
 .arguments = if (s.args.items.len == 0) "{}" else s.args.items,
 });
 }
 }
};

// ---------------------------------------------------------------------------
// OpenAI Responses：按 item_id 累积（不是 index）
// ---------------------------------------------------------------------------

/// ⚠️ 铁律 3 的落点：这里 `delta_fragment` 是**本次增量**，
/// 而上面 OpenAI Chat 的 `args_fragment` 是**分片**（两者都是追加，语义一致）；
/// 但既有实现侧对外暴露的 `partialArguments` 字段在两侧含义不同（一侧累积全量、一侧 delta），
/// Zig 里用不同的方法名把这件事显式化。
pub const ResponsesAccumulator = struct {
 gpa: std.mem.Allocator,
 items: std.ArrayListUnmanaged(Item) = .empty,
 /// 防重复交付（出处见 docs/internal/）
 completed: std.ArrayListUnmanaged([]const u8) = .empty,
 next_index: u32 = 0,

 pub const Item = struct {
 item_id: []u8,
 call_id: std.ArrayListUnmanaged(u8) = .empty,
 name: std.ArrayListUnmanaged(u8) = .empty,
 args: std.ArrayListUnmanaged(u8) = .empty,
 output_index: u32 = 0,
 };

 pub fn init(gpa: std.mem.Allocator) ResponsesAccumulator {
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

 /// `response.output_item.added`：拿到 id / call_id / name
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

 /// `response.function_call_arguments.delta`
 pub fn onArgsDelta(self: *ResponsesAccumulator, item_id: []const u8, delta: []const u8) !void {
 const it = try self.itemFor(item_id);
 try it.args.appendSlice(self.gpa, delta);
 }

 /// `response.function_call_arguments.done` / `output_item.done` / 终态快照
 /// —— 三条路径都可能给完整参数，用 completed 去重（既有实现: L193-202）。
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
 // 按 output_index 排序（既有实现: index 由 output_index 另行映射）
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

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const H = struct {
 fn expectArg(complete: Complete, want_idx: u32, want_name: []const u8, want_id: []const u8, want_args: []const u8) !void {
 try std.testing.expectEqual(want_idx, complete.index);
 try std.testing.expectEqualStrings(want_name, complete.name);
 try std.testing.expectEqualStrings(want_id, complete.id);
 try std.testing.expectEqualStrings(want_args, complete.arguments);
 }
};

test "OpenAI: 分片拼接必须逐字保留（铁律 1 —— 不能 parse 再序列化）" {
 const gpa = std.testing.allocator;
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

 try std.testing.expectEqual(@as(usize, 1), out.items.len);
 try H.expectArg(out.items[0], 0, "Bash", "call_1",
 "{\"command\": \"ls -la\" , \"timeout\": 12345678901234567890}");
}

test "OpenAI: id 只在非空时覆盖（铁律 2 —— 兼容网关会发空串）" {
 const gpa = std.testing.allocator;
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
 const gpa = std.testing.allocator;
 var acc = OpenAiAccumulator.init(gpa);
 defer acc.deinit();
 try acc.onDelta(0, "", "Bash", "{}");
 var out: std.ArrayListUnmanaged(Complete) = .empty;
 defer out.deinit(gpa);
 try std.testing.expectError(Error.MissingToolCallId, acc.finish(&out));
}

test "OpenAI: 多工具按 index 升序产出（顺序稳定性是契约）" {
 const gpa = std.testing.allocator;
 var acc = OpenAiAccumulator.init(gpa);
 defer acc.deinit();

 // 故意乱序到达
 try acc.onDelta(2, "c2", "Third", "{}");
 try acc.onDelta(0, "c0", "First", "{}");
 try acc.onDelta(1, "c1", "Second", "{}");

 var out: std.ArrayListUnmanaged(Complete) = .empty;
 defer out.deinit(gpa);
 try acc.finish(&out);

 try std.testing.expectEqual(@as(usize, 3), out.items.len);
 try std.testing.expectEqualStrings("First", out.items[0].name);
 try std.testing.expectEqualStrings("Second", out.items[1].name);
 try std.testing.expectEqualStrings("Third", out.items[2].name);
}

test "OpenAI: 空参数补 {}" {
 const gpa = std.testing.allocator;
 var acc = OpenAiAccumulator.init(gpa);
 defer acc.deinit();
 try acc.onDelta(0, "c", "NoArgs", null);
 var out: std.ArrayListUnmanaged(Complete) = .empty;
 defer out.deinit(gpa);
 try acc.finish(&out);
 try std.testing.expectEqualStrings("{}", out.items[0].arguments);
}

test "Anthropic: start/delta/stop 生命周期，非 tool_use 块忽略" {
 const gpa = std.testing.allocator;
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

 try std.testing.expectEqual(@as(usize, 1), out.items.len);
 try H.expectArg(out.items[0], 2, "Edit", "toolu_1", "{\"file_path\":\"/a/b\"}");
}

test "Anthropic: 参数为空时补 {}（既有实现侧会补发一次 PartialToolCall）" {
 const gpa = std.testing.allocator;
 var acc = AnthropicAccumulator.init(gpa);
 defer acc.deinit();
 try acc.onBlockStart(0, "tool_use", "toolu_x", "Noop");
 try acc.onBlockStop(0);
 var out: std.ArrayListUnmanaged(Complete) = .empty;
 defer out.deinit(gpa);
 try acc.finish(&out);
 try std.testing.expectEqualStrings("{}", out.items[0].arguments);
}

test "Responses: 按 item_id 累积，且 done 去重（同一 item 只交付一次）" {
 const gpa = std.testing.allocator;
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

 try std.testing.expectEqual(@as(usize, 1), out.items.len);
 try H.expectArg(out.items[0], 0, "Bash", "call_a", "{\"cmd\":\"ls\"}");
}

test "Responses: 终态快照覆盖累积结果（快照是权威）" {
 const gpa = std.testing.allocator;
 var acc = ResponsesAccumulator.init(gpa);
 defer acc.deinit();
 try acc.onItemAdded("item_b", "call_b", "Read", 0);
 try acc.onArgsDelta("item_b", "{\"partial\":true}");
 try acc.onArgsDone("item_b", "{\"file_path\":\"/x\"}");
 var out: std.ArrayListUnmanaged(Complete) = .empty;
 defer out.deinit(gpa);
 try acc.finish(&out);
 try std.testing.expectEqualStrings("{\"file_path\":\"/x\"}", out.items[0].arguments);
}
