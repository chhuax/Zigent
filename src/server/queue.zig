//! `server/queue.zig` —— 会话事件队列（**生产者/消费者跨线程**）。
//!
//! ★ 契约（spike E1 实测）：**`close()` 必须 broadcast 唤醒所有等待者**。
//! 否则关闭流时消费者永远挂在 `wait` 上 —— 这是最常见的挂死形态。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const EventQueue = struct {
    io: Io,
    gpa: Allocator,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    closed: bool = false,
    /// 已序列化的事件行（**JSON 文本**，避免跨线程所有权问题）
    items: std.ArrayListUnmanaged([]u8) = .empty,
    max_items: usize = 4096,
    dropped: usize = 0,

    pub fn init(io: Io, gpa: Allocator) EventQueue {
        return .{ .io = io, .gpa = gpa };
    }

    pub fn deinit(self: *EventQueue) void {
        for (self.items.items) |it| self.gpa.free(it);
        self.items.deinit(self.gpa);
    }

    /// 入队（**接管 `line` 的所有权**）。
    pub fn push(self: *EventQueue, line: []u8) !void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        if (self.closed) {
            self.gpa.free(line);
            return;
        }
        if (self.items.items.len >= self.max_items) {
            // 背压：丢最旧的（客户端重连后以服务端状态为准 —— 协议 §6.5）
            const old = self.items.orderedRemove(0);
            self.gpa.free(old);
            self.dropped += 1;
        }
        try self.items.append(self.gpa, line);
        self.cond.broadcast(self.io);
    }

    /// 取一条（阻塞直到有数据或队列关闭）。返回 null = 队列已关闭且排空。
    pub fn pop(self: *EventQueue) ?[]u8 {
        self.mutex.lock(self.io) catch return null;
        defer self.mutex.unlock(self.io);
        while (self.items.items.len == 0) {
            if (self.closed) return null;
            self.cond.wait(self.io, &self.mutex) catch return null;
        }
        return self.items.orderedRemove(0);
    }

    /// 非阻塞取一条。
    pub fn tryPop(self: *EventQueue) ?[]u8 {
        self.mutex.lock(self.io) catch return null;
        defer self.mutex.unlock(self.io);
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    /// ★ 关闭并**唤醒所有等待者**。
    pub fn close(self: *EventQueue) void {
        self.mutex.lock(self.io) catch return;
        self.closed = true;
        self.mutex.unlock(self.io);
        self.cond.broadcast(self.io);
    }

    pub fn isClosed(self: *EventQueue) bool {
        self.mutex.lock(self.io) catch return true;
        defer self.mutex.unlock(self.io);
        return self.closed;
    }
};

const testing = std.testing;

test "queue: 入队出队" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var q = EventQueue.init(threaded.io(), testing.allocator);
    defer q.deinit();
    try q.push(try testing.allocator.dupe(u8, "a"));
    try q.push(try testing.allocator.dupe(u8, "b"));
    const first = q.pop().?;
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("a", first);
    const second = q.tryPop().?;
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("b", second);
    try testing.expect(q.tryPop() == null);
}

test "queue: close 之后 pop 立即返回 null（不挂死）" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var q = EventQueue.init(threaded.io(), testing.allocator);
    defer q.deinit();
    q.close();
    try testing.expect(q.pop() == null);
    try testing.expect(q.isClosed());
}

test "queue: close 唤醒阻塞中的消费者" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Ctx = struct {
        q: *EventQueue,
        got_null: bool = false,
        fn run(self: *@This()) void {
            const item = self.q.pop();
            if (item == null) self.got_null = true;
        }
    };
    var q = EventQueue.init(io, testing.allocator);
    defer q.deinit();
    var ctx = Ctx{ .q = &q };

    const t = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    try std.Io.sleep(io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake);
    q.close();
    t.join();
    try testing.expect(ctx.got_null);
}

test "queue: 超过上限丢最旧（背压）" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var q = EventQueue.init(threaded.io(), testing.allocator);
    defer q.deinit();
    q.max_items = 2;
    try q.push(try testing.allocator.dupe(u8, "a"));
    try q.push(try testing.allocator.dupe(u8, "b"));
    try q.push(try testing.allocator.dupe(u8, "c"));
    const first = q.pop().?;
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("b", first);
    try testing.expectEqual(@as(usize, 1), q.dropped);
}
