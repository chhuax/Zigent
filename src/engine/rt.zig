//! `engine.Rt` —— **运行时上下文，唯一的依赖注入点**（文档 11 §4）。
//!
//! 由 `main.zig` 构造一次，显式向下传递。**禁止全局单例**：
//! 全局态会让测试无法替换、多会话互相污染（这正是被反推出来的铁律之一）。
//!
//! 判定口诀（文档 11 §4.1）：
//!   **能只要 `io` 就不要 `rt`；能什么也不要就什么也不要。** 依赖越窄越好测。

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const util = @import("util");
const config = @import("config");

pub const Rt = struct {
    /// 内存分配器。生命周期与整个进程一致。
    gpa: Allocator,
    /// IO 与并发基座。**按值传递**（两个字段，零成本）。
    io: std.Io,
    /// 环境变量（`std` 已把它收进 `Environ`；**不要用全局 getenv**）。
    env: *const std.process.Environ.Map,
    /// 进程启动时的 cwd。
    cwd: []const u8,
    /// 用户家目录。
    home: []const u8,
    /// 分层合并后的配置快照。只读。
    settings: *const config.Settings,
    /// 落盘路径的唯一出口。
    paths: *const config.Paths,
    /// 会话 id（每次 run 可能不同）。
    session_id: []const u8,
    /// 取消令牌（会话级）。**用原子变量而不是锁** —— 工具在长循环里轮询它。
    cancel: *std.atomic.Value(bool),
    /// 日志（只走 stderr）。
    logger: util.log.Logger,

    pub fn cancelled(self: *const Rt) bool {
        return self.cancel.load(.acquire);
    }

    pub fn requestCancel(self: *Rt) void {
        self.cancel.store(true, .release);
    }

    /// 派生一个子 Rt（会话 id 不同，共享 cancel 之外的其它一切）。
    pub fn withSession(self: *const Rt, session_id: []const u8) Rt {
        var r = self.*;
        r.session_id = session_id;
        return r;
    }

    pub fn iso8601(self: *const Rt, buf: []u8) []const u8 {
        return util.io.formatIso8601(buf, util.io.epochMillis(self.io));
    }
};

const testing = std.testing;

test "rt: 取消令牌" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    const env = std.process.Environ.Map.init(testing.allocator);
    var settings = config.Settings{};
    var paths = config.Paths{ .home = "/home/u", .cwd = "/repo" };
    var rt = Rt{
        .gpa = testing.allocator,
        .io = threaded.io(),
        .env = &env,
        .cwd = "/repo",
        .home = "/home/u",
        .settings = &settings,
        .paths = &paths,
        .session_id = "s1",
        .cancel = &cancel,
        .logger = .{ .io = threaded.io() },
    };
    try testing.expect(!rt.cancelled());
    rt.requestCancel();
    try testing.expect(rt.cancelled());

    const child = rt.withSession("s2");
    try testing.expectEqualStrings("s2", child.session_id);
    try testing.expect(child.cancelled());
}
