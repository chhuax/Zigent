//! E1：IO / 并发模型探针。
//!
//! 要回答：Zig 0.17 的 `std.Io` 能不能作为内核 IO 基座？还是该退回
//! 「OS 线程 + 通道 + 原子取消」？
//!
//! 本文件实现**方案 B（线程 + 队列 + 原子取消）**作为基线 —— 它不依赖任何
//! 版本敏感的 IO 抽象，因此是"一定能跑通"的那条路。方案 A（`std.Io`）应在
//! 同一组测试下跑一遍对比；在 `std.Io` API 冻结前，**默认选 B**。
//!
//! ## 为什么取消语义是 E1 的核心
//!
//! 既有实现侧有 `Thread.interrupt` + `CompletableFuture.cancel(true)` + 三档
//! `InterruptBehavior{BLOCK,CANCEL}`。Zig **没有线程中断**，所以取消必须
//! 完全重设计为「协作式 flag + 显式唤醒」。本探针验证这套能否稳定工作：
//! - 取消后队列不再增长；
//! - 等待中的消费者能被唤醒（不是等到超时）；
//! - 并发压力下无数据竞争（`-fsanitize-thread`）。

const std = @import("std");

/// 协作式取消令牌 —— 对应既有实现的 `CancellationToken`。
pub const CancellationToken = struct {
 flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

 pub fn cancel(self: *CancellationToken) void {
 self.flag.store(true, .release);
 }

 pub fn isCancelled(self: *const CancellationToken) bool {
 return self.flag.load(.acquire);
 }

 /// 协作检查点 —— 每个可能长时间运行的循环都要调用它。
 pub fn check(self: *const CancellationToken) error{Cancelled}!void {
 if (self.isCancelled()) return error.Cancelled;
 }
};

/// 事件队列 —— 模拟「SSE 读者线程 → 主循环」这条路径。
pub const EventQueue = struct {
 gpa: std.mem.Allocator,
 /// ⚠️ 0.16 起并发原语也要 Io 实例 —— 见文件头说明
 io: std.Io,
 items: std.ArrayListUnmanaged(u64) = .empty,
 mutex: std.Io.Mutex = .init,
 cond: std.Io.Condition = .init,
 closed: bool = false,

 pub fn init(gpa: std.mem.Allocator, io: std.Io) EventQueue {
 return .{ .gpa = gpa, .io = io };
 }

 pub fn deinit(self: *EventQueue) void {
 self.items.deinit(self.gpa);
 }

 pub fn push(self: *EventQueue, v: u64) !void {
 self.mutex.lock(self.io) catch return error.Cancelled;
 defer self.mutex.unlock();
 if (self.closed) return error.Closed;
 try self.items.append(self.gpa, v);
 self.cond.signal(self.io);
 }

 /// 阻塞取一个；队列关闭且空时返回 null。
 /// ⚠️ 取消时必须能被**唤醒**而不是等超时 —— 这就是 `cond.broadcast()` 存在的理由。
 pub fn pop(self: *EventQueue) ?u64 {
 self.mutex.lock(self.io) catch return null;
 defer self.mutex.unlock();
 while (self.items.items.len == 0) {
 if (self.closed) return null;
 self.cond.wait(self.io, &self.mutex) catch return null;
 }
 return self.items.orderedRemove(0);
 }

 /// 关闭并唤醒所有等待者（取消路径必须调用它，否则消费者永久阻塞）。
 pub fn close(self: *EventQueue) void {
 self.mutex.lock(self.io) catch return;
 self.closed = true;
 self.mutex.unlock();
 self.cond.broadcast(self.io);
 }

 pub fn len(self: *EventQueue) usize {
 self.mutex.lock(self.io) catch return 0;
 defer self.mutex.unlock();
 return self.items.items.len;
 }
};

/// 生产者：模拟 SSE 读者线程。收到取消即停。
const Producer = struct {
 const Stats = struct { produced: u64 };

 fn run(q: *EventQueue, tok: *const CancellationToken, limit: u64, stats: *Stats) void {
 var i: u64 = 0;
 while (i < limit) : (i += 1) {
 if (tok.isCancelled()) break;
 q.push(i) catch break;
 // 模拟网络 IO 的等待点
 std.Thread.sleep(50 * std.time.us_per_s);
 }
 stats.produced = i;
 }
};

/// 消费者：模拟主循环拉动事件流。取消时必须立刻返回（靠 close 唤醒）。
const Consumer = struct {
 const Stats = struct { consumed: u64, saw_cancel: bool = false };

 fn run(q: *EventQueue, tok: *const CancellationToken, stats: *Stats) void {
 while (true) {
 if (tok.isCancelled()) {
 stats.saw_cancel = true;
 return;
 }
 if (q.pop()) |_| {
 stats.consumed += 1;
 } else {
 return; // 队列关闭
 }
 }
 }
};

/// 探针结果。
pub const ProbeResult = struct {
 produced: u64,
 consumed: u64,
 cancelled: bool,
};

/// 探针主入口。`run_millis` 是取消前先跑多久 —— 测试里调小以保持测试套件快。
pub fn probeFor(gpa: std.mem.Allocator, run_millis: u64) !ProbeResult {
 var q = EventQueue.init(gpa);
 defer q.deinit();

 var tok = CancellationToken{};
 var p_stats = Producer.Stats{ .produced = 0 };
 var c_stats = Consumer.Stats{ .consumed = 0 };

 const producer = try std.Thread.spawn(.{}, Producer.run, .{ &q, &tok, 100_000, &p_stats });
 const consumer = try std.Thread.spawn(.{}, Consumer.run, .{ &q, &tok, &c_stats });

 // 跑一小会儿再取消 —— 模拟用户 Ctrl+C
 std.Thread.sleep(run_millis * std.time.ns_per_ms);
 tok.cancel();
 // 关键：关闭队列 → broadcast → 唤醒阻塞中的消费者
 q.close();

 consumer.join();
 producer.join();

 return .{
 .produced = p_stats.produced,
 .consumed = c_stats.consumed,
 .cancelled = c_stats.saw_cancel,
 };
}

/// 手动跑时的默认时长（`zig build run -- e1`）。
pub fn probe(gpa: std.mem.Allocator) !ProbeResult {
 return probeFor(gpa, 5_000);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "取消令牌：置位后 check 返回 Cancelled" {
 var tok = CancellationToken{};
 try tok.check();
 tok.cancel();
 try std.testing.expect(tok.isCancelled());
 try std.testing.expectError(error.Cancelled, tok.check());
}

test "队列：close 必须唤醒阻塞中的消费者（取消语义的核心）" {
 const gpa = std.testing.allocator;
 var q = EventQueue.init(gpa);
 defer q.deinit();

 const Waiter = struct {
 fn run(queue: *EventQueue, woke: *std.atomic.Value(bool)) void {
 _ = queue.pop();
 woke.store(true, .release);
 }
 };
 var woke = std.atomic.Value(bool).init(false);
 const t = try std.Thread.spawn(.{}, Waiter.run, .{ &q, &woke });

 // 消费者此刻阻塞在 pop() 里
 std.Thread.sleep(20 * std.time.ms_per_s);
 try std.testing.expect(!woke.load(.acquire));

 q.close(); // 必须 broadcast，而不是"等下次超时"
 t.join();
 try std.testing.expect(woke.load(.acquire));
}

test "队列：关闭后 push 报错而不是静默丢弃" {
 const gpa = std.testing.allocator;
 var q = EventQueue.init(gpa);
 defer q.deinit();
 q.close();
 try std.testing.expectError(error.Closed, q.push(1));
}

test "E1 探针：取消后生产者停止，消费者干净退出（并发压力）" {
 const gpa = std.testing.allocator;
 const r = try probeFor(gpa, 100); // 测试里只跑 100ms，保持套件快
 // 取消点之前应该有产出（100ms / 50us 理论上很多，但不做精确断言）
 try std.testing.expect(r.produced > 0);
 try std.testing.expect(r.cancelled);
 // 消费数不可能超过生产数（顺序与可见性）
 try std.testing.expect(r.consumed <= r.produced);
}

test "E1: 多轮探针不泄漏（GPA 会在这里报 leak）" {
 const gpa = std.testing.allocator;
 var i: usize = 0;
 while (i < 3) : (i += 1) {
 const r = try probeFor(gpa, 30);
 try std.testing.expect(r.cancelled);
 }
}
