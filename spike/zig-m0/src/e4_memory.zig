//! E4：内存与所有权模型探针。
//!
//! 要回答：无 GC 下，「多轮长会话的消息树 + 压缩重建 + resume」的所有权模型
//! 是否可控？峰值内存是否有界？
//!
//! ## 三档策略
//! A. **全 arena + 压缩时整体重建**（推荐）—— 与既有实现侧 `messages` 重建语义一致
//! B. 消息级引用计数 —— 灵活但原子操作开销大、易漏
//! C. per-turn arena + 会话级容器 —— 折中
//!
//! 本文件实现 A（推荐）与 C（对比），B 只给结构示意。
//!
//! ## 为什么"压缩时整体重建"是正确的
//! 既有实现侧压缩成功后是 `messages = summary + preserved`（重建列表）。Zig 里
//! 最自然的对应就是**丢掉旧 arena、建新 arena** —— 一次性释放所有碎片，
//! 不需要逐块回收。这也让"取消/重试"的内存语义变得简单（丢掉整个 arena）。

const std = @import("std");

// ---------------------------------------------------------------------------
// 计数分配器：度量 live / peak / 总分配，替代不好移植的 RSS 读取
// ---------------------------------------------------------------------------

pub const Counting = struct {
 parent: std.mem.Allocator,
 live: usize = 0,
 peak: usize = 0,
 total: usize = 0,
 count: usize = 0,

 pub fn allocator(self: *Counting) std.mem.Allocator {
 return .{ .ptr = self, .vtable = &vtable };
 }

 const vtable = std.mem.Allocator.VTable{
 .alloc = alloc,
 .resize = resize,
 .remap = remap, // 0.16 起 VTable 新增了 remap 字段
 .free = free,
 };

 fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
 const self: *Counting = @ptrCast(@alignCast(ctx));
 // 转发给父分配器的 remap（0.16 没有 rawRemap，直接走 vtable）
 const p = self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ra) orelse return null;
 if (new_len >= memory.len) {
 const delta = new_len - memory.len;
 self.live += delta;
 self.total += delta;
 if (self.live > self.peak) self.peak = self.live;
 } else {
 self.live -= (memory.len - new_len);
 }
 return p;
 }

 fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
 const self: *Counting = @ptrCast(@alignCast(ctx));
 const mem = self.parent.rawAlloc(len, alignment, ra) orelse return null;
 self.live += len;
 self.total += len;
 self.count += 1;
 if (self.live > self.peak) self.peak = self.live;
 return mem;
 }

 fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
 const self: *Counting = @ptrCast(@alignCast(ctx));
 const ok = self.parent.rawResize(memory, alignment, new_len, ra);
 if (ok) {
 if (new_len >= memory.len) {
 const delta = new_len - memory.len;
 self.live += delta;
 self.total += delta;
 if (self.live > self.peak) self.peak = self.live;
 } else {
 self.live -= (memory.len - new_len);
 }
 }
 return ok;
 }

 fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
 const self: *Counting = @ptrCast(@alignCast(ctx));
 self.live -= memory.len;
 self.parent.rawFree(memory, alignment, ra);
 }
};

// ---------------------------------------------------------------------------
// 最小消息模型（与契约一致：ContentBlock 是 tagged union，不是 sealed interface）
// ---------------------------------------------------------------------------

pub const Block = union(enum) {
 text: []const u8,
 tool_use: struct { id: []const u8, name: []const u8, args: []const u8 },
 tool_result: struct { tool_use_id: []const u8, output: []const u8, is_error: bool },
};

pub const Role = enum { user, assistant };

pub const Message = struct {
 role: Role,
 blocks: []Block,
};

fn dup(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
 return alloc.dupe(u8, s);
}

fn dupBlock(alloc: std.mem.Allocator, b: Block) !Block {
 return switch (b) {
 .text => |t| Block{ .text = try dup(alloc, t) },
 .tool_use => |tu| Block{ .tool_use = .{
 .id = try dup(alloc, tu.id),
 .name = try dup(alloc, tu.name),
 .args = try dup(alloc, tu.args),
 } },
 .tool_result => |tr| Block{ .tool_result = .{
 .tool_use_id = try dup(alloc, tr.tool_use_id),
 .output = try dup(alloc, tr.output),
 .is_error = tr.is_error,
 } },
 };
}

fn dupMessage(alloc: std.mem.Allocator, m: Message) !Message {
 const blocks = try alloc.alloc(Block, m.blocks.len);
 for (m.blocks, 0..) |b, i| blocks[i] = try dupBlock(alloc, b);
 return .{ .role = m.role, .blocks = blocks };
}

// ---------------------------------------------------------------------------
// 策略 A：全 arena + 压缩时整体重建
// ---------------------------------------------------------------------------

pub const ArenaSession = struct {
 backing: std.mem.Allocator,
 arena: std.heap.ArenaAllocator,
 messages: std.ArrayListUnmanaged(Message) = .empty,
 /// 统计：压缩次数与累计释放（用于观察 churn）
 compactions: usize = 0,

 pub fn init(backing: std.mem.Allocator) ArenaSession {
 return .{ .backing = backing, .arena = std.heap.ArenaAllocator.init(backing) };
 }

 pub fn deinit(self: *ArenaSession) void {
 self.arena.deinit();
 }

 /// 追加一轮：一条 assistant（含 tool_use）+ 一条 user（含 tool_result）。
 pub fn appendTurn(self: *ArenaSession, text: []const u8, tool_output: []const u8) !void {
 const a = self.arena.allocator();

 const asst_blocks = try a.alloc(Block, 2);
 asst_blocks[0] = .{ .text = try dup(a, text) };
 asst_blocks[1] = .{ .tool_use = .{
 .id = try dup(a, "tu_1"),
 .name = try dup(a, "Read"),
 .args = try dup(a, "{\"path\":\"/x\"}"),
 } };
 try self.messages.append(a, .{ .role = .assistant, .blocks = asst_blocks });

 const user_blocks = try a.alloc(Block, 1);
 user_blocks[0] = .{ .tool_result = .{
 .tool_use_id = try dup(a, "tu_1"),
 .output = try dup(a, tool_output),
 .is_error = false,
 } };
 try self.messages.append(a, .{ .role = .user, .blocks = user_blocks });
 }

 /// 压缩：**整体重建** —— 复制幸存者到新 arena，丢掉旧 arena。
 /// 这是既有实现「messages = summary + preserved」的 Zig 对应物。
 pub fn compact(self: *ArenaSession, keep_last: usize) !void {
 const start = if (self.messages.items.len > keep_last)
 self.messages.items.len - keep_last
 else
 0;

 var new_arena = std.heap.ArenaAllocator.init(self.backing);
 errdefer new_arena.deinit();
 const na = new_arena.allocator();

 var new_msgs: std.ArrayListUnmanaged(Message) = .empty;
 try new_msgs.ensureTotalCapacity(na, self.messages.items.len - start);
 for (self.messages.items[start..]) |m| {
 new_msgs.appendAssumeCapacity(try dupMessage(na, m));
 }

 // 原子替换：旧内容一次性释放
 self.arena.deinit();
 self.arena = new_arena;
 self.messages = new_msgs;
 self.compactions += 1;
 }

 pub fn messageCount(self: *const ArenaSession) usize {
 return self.messages.items.len;
 }
};

// ---------------------------------------------------------------------------
// 策略 C：per-turn arena + 会话级长期容器
// ---------------------------------------------------------------------------

pub const TurnArenaSession = struct {
 backing: std.mem.Allocator,
 /// 会话级：只放"要长期保留"的消息（已复制出来的）
 messages: std.ArrayListUnmanaged(Message) = .empty,
 compactions: usize = 0,

 pub fn init(backing: std.mem.Allocator) TurnArenaSession {
 return .{ .backing = backing };
 }

 pub fn deinit(self: *TurnArenaSession) void {
 for (self.messages.items) |m| {
 for (m.blocks) |b| freeBlock(self.backing, b);
 self.backing.free(m.blocks);
 }
 self.messages.deinit(self.backing);
 }

 pub fn appendTurn(self: *TurnArenaSession, text: []const u8, tool_output: []const u8) !void {
 // 一轮一个 turn arena：请求内的临时对象都在这里，轮末释放
 var turn_arena = std.heap.ArenaAllocator.init(self.backing);
 defer turn_arena.deinit();
 const ta = turn_arena.allocator();

 // turn arena 里先构造，再把"要留下的"复制到会话级 allocator
 const tmp_blocks = try ta.alloc(Block, 2);
 tmp_blocks[0] = .{ .text = try dup(ta, text) };
 tmp_blocks[1] = .{ .tool_use = .{
 .id = try dup(ta, "tu_1"),
 .name = try dup(ta, "Read"),
 .args = try dup(ta, "{\"path\":\"/x\"}"),
 } };
 const tmp_result = Block{ .tool_result = .{
 .tool_use_id = try dup(ta, "tu_1"),
 .output = try dup(ta, tool_output),
 .is_error = false,
 } };

 try self.messages.append(self.backing, try dupMessage(self.backing, .{ .role = .assistant, .blocks = tmp_blocks }));
 const one = try self.backing.alloc(Block, 1);
 one[0] = try dupBlock(self.backing, tmp_result);
 try self.messages.append(self.backing, .{ .role = .user, .blocks = one });
 }

 /// 策略 C 的压缩必须逐个释放被淘汰的消息（没有整体释放的便利）。
 pub fn compact(self: *TurnArenaSession, keep_last: usize) !void {
 const start = if (self.messages.items.len > keep_last)
 self.messages.items.len - keep_last
 else
 0;
 var i: usize = 0;
 while (i < start) : (i += 1) {
 const m = self.messages.items[i];
 for (m.blocks) |b| freeBlock(self.backing, b);
 self.backing.free(m.blocks);
 }
 // 移除前 start 条
 const remaining = self.messages.items.len - start;
 std.mem.copyForwards(Message, self.messages.items[0..remaining], self.messages.items[start..]);
 self.messages.shrinkRetainingCapacity(remaining);
 self.compactions += 1;
 }

 pub fn messageCount(self: *const TurnArenaSession) usize {
 return self.messages.items.len;
 }
};

fn freeBlock(alloc: std.mem.Allocator, b: Block) void {
 switch (b) {
 .text => |t| alloc.free(t),
 .tool_use => |tu| {
 alloc.free(tu.id);
 alloc.free(tu.name);
 alloc.free(tu.args);
 },
 .tool_result => |tr| {
 alloc.free(tr.tool_use_id);
 alloc.free(tr.output);
 },
 }
}

// ---------------------------------------------------------------------------
// 负载模拟：200 轮 + 3 次压缩
// ---------------------------------------------------------------------------

pub const SimResult = struct {
 peak_live: usize,
 live_at_end: usize,
 total_alloc: usize,
 alloc_count: usize,
 messages: usize,
 compactions: usize,
};

/// 每轮正文大小（模拟 2–10KB 的模型输出 + 工具结果）。
fn turnSize(i: usize) usize {
 return 2_000 + (i % 5) * 2_000;
}

/// 压缩策略：消息数超过 `high` 就压到 `keep`。
/// **这个门控位置很关键** —— 真实的 `CompactService` 也是"按量触发"，
/// 而不是"每 N 轮触发"。若按固定轮次触发，峰值会随 N 线性增长。
const COMPACT_HIGH = 20;
const COMPACT_KEEP = 12;

fn fill(buf: []u8, c: u8) void {
 @memset(buf, c);
}

pub fn simulateArena(gpa: std.mem.Allocator, turns: usize) !SimResult {
 var counting = Counting{ .parent = gpa };
 var s = ArenaSession.init(counting.allocator());
 defer s.deinit();

 // 复用一个临时 buffer 生成内容，避免把 gpa 的临时分配算进统计
 var scratch: [24_000]u8 = undefined;

 var i: usize = 0;
 while (i < turns) : (i += 1) {
 const n = turnSize(i);
 const text = scratch[0..n];
 fill(text, 'a');
 const out = scratch[0 .. n * 2];
 fill(out, 'b');

 try s.appendTurn(text, out);
 if (s.messageCount() > COMPACT_HIGH) try s.compact(COMPACT_KEEP);
 }

 return .{
 .peak_live = counting.peak,
 .live_at_end = counting.live,
 .total_alloc = counting.total,
 .alloc_count = counting.count,
 .messages = s.messageCount(),
 .compactions = s.compactions,
 };
}

pub fn simulateTurnArena(gpa: std.mem.Allocator, turns: usize) !SimResult {
 var counting = Counting{ .parent = gpa };
 var s = TurnArenaSession.init(counting.allocator());
 defer s.deinit();

 var scratch: [24_000]u8 = undefined;

 var i: usize = 0;
 while (i < turns) : (i += 1) {
 const n = turnSize(i);
 const text = scratch[0..n];
 fill(text, 'a');
 const out = scratch[0 .. n * 2];
 fill(out, 'b');

 try s.appendTurn(text, out);
 if (s.messageCount() > COMPACT_HIGH) try s.compact(COMPACT_KEEP);
 }

 return .{
 .peak_live = counting.peak,
 .live_at_end = counting.live,
 .total_alloc = counting.total,
 .alloc_count = counting.count,
 .messages = s.messageCount(),
 .compactions = s.compactions,
 };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "计数分配器：live 归零、peak 有记录" {
 const gpa = std.testing.allocator;
 var c = Counting{ .parent = gpa };
 const a = c.allocator();
 const p1 = try a.alloc(u8, 1000);
 const p2 = try a.alloc(u8, 2000);
 try std.testing.expectEqual(@as(usize, 3000), c.live);
 try std.testing.expectEqual(@as(usize, 3000), c.peak);
 a.free(p1);
 try std.testing.expectEqual(@as(usize, 2000), c.live);
 a.free(p2);
 try std.testing.expectEqual(@as(usize, 0), c.live);
 try std.testing.expectEqual(@as(usize, 3000), c.peak);
}

test "策略 A：追加轮次后消息数与内容正确" {
 const gpa = std.testing.allocator;
 var s = ArenaSession.init(gpa);
 defer s.deinit();

 try s.appendTurn("hello", "tool output 1");
 try s.appendTurn("world", "tool output 2");
 try std.testing.expectEqual(@as(usize, 4), s.messageCount());
 try std.testing.expectEqualStrings("hello", s.messages.items[0].blocks[0].text);
 try std.testing.expectEqualStrings("tool output 2", s.messages.items[3].blocks[0].tool_result.output);
}

test "策略 A：压缩是整体重建，幸存者内容不丢" {
 const gpa = std.testing.allocator;
 var s = ArenaSession.init(gpa);
 defer s.deinit();

 var i: usize = 0;
 while (i < 20) : (i += 1) {
 var buf: [32]u8 = undefined;
 const t = try std.fmt.bufPrint(&buf, "turn-{d}", .{i});
 try s.appendTurn(t, "out");
 }
 try std.testing.expectEqual(@as(usize, 40), s.messageCount());

 try s.compact(6);
 try std.testing.expectEqual(@as(usize, 6), s.messageCount());
 try std.testing.expectEqual(@as(usize, 1), s.compactions);
 // 保留的是最后 3 轮（6 条消息）→ 第 17 轮的文本
 try std.testing.expectEqualStrings("turn-17", s.messages.items[0].blocks[0].text);
}

test "策略 A：压缩后仍可继续追加（arena 替换后不悬垂）" {
 const gpa = std.testing.allocator;
 var s = ArenaSession.init(gpa);
 defer s.deinit();

 var i: usize = 0;
 while (i < 10) : (i += 1) try s.appendTurn("x", "y");
 try s.compact(4);
 // 关键：旧 arena 已释放，新追加必须落在新 arena 上
 try s.appendTurn("after-compact", "still-works");
 try std.testing.expectEqual(@as(usize, 6), s.messageCount());
 try std.testing.expectEqualStrings("after-compact", s.messages.items[4].blocks[0].text);
}

test "E4 主判据：峰值内存有界 —— 200 轮后不随轮次线性增长" {
 const gpa = std.testing.allocator;
 const r = try simulateArena(gpa, 200);

 // 压缩按"消息数超阈值"触发 → 200 轮里必然发生多次
 try std.testing.expect(r.compactions > 0);
 // 消息数被压在阈值附近，远小于 400（200 轮 × 2 条）
 try std.testing.expect(r.messages <= COMPACT_HIGH);
 // **核心断言：峰值必须是"十几条消息的量级"，而不是"200 轮累计"。**
 // 无压缩时 200 轮 ≈ 3.6MB；按量压缩后应远低于 1MB。
 try std.testing.expect(r.peak_live < 1_000_000);
 // live 必须在结束时归零（GPA 会另外报 leak）
 try std.testing.expectEqual(@as(usize, 0), r.live_at_end);
 // 总分配量 >> 峰值，正说明"重建式释放"在起作用
 try std.testing.expect(r.total_alloc > r.peak_live);
}

test "E4 对照：不压缩的话峰值会线性增长（证明上面的断言有意义）" {
 const gpa = std.testing.allocator;
 // 直接构造一个"从不压缩"的会话，量一下 200 轮的真实规模
 var counting = Counting{ .parent = gpa };
 var s = ArenaSession.init(counting.allocator());
 defer s.deinit();

 var scratch: [24_000]u8 = undefined;
 var i: usize = 0;
 while (i < 200) : (i += 1) {
 const n = turnSize(i);
 const text = scratch[0..n];
 @memset(text, 'a');
 const out = scratch[0 .. n * 2];
 @memset(out, 'b');
 try s.appendTurn(text, out);
 }
 // 400 条消息，峰值应达到 MB 量级 —— 与压缩版的 <1MB 形成对比
 try std.testing.expectEqual(@as(usize, 400), s.messageCount());
 try std.testing.expect(counting.peak > 2_000_000);
}

test "策略 C 对比：峰值同样有界，但分配次数更多（无整体释放的便利）" {
 const gpa = std.testing.allocator;
 const a = try simulateArena(gpa, 200);
 const c = try simulateTurnArena(gpa, 200);

 // 两者都应有界
 try std.testing.expect(a.peak_live < 1_000_000);
 try std.testing.expect(c.peak_live < 1_000_000);
 // 两者 live 都归零
 try std.testing.expectEqual(@as(usize, 0), a.live_at_end);
 try std.testing.expectEqual(@as(usize, 0), c.live_at_end);
 // C 必须逐块释放 → 分配次数更多
 try std.testing.expect(c.alloc_count > a.alloc_count);
}
