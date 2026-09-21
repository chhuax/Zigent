//! `util/watch.zig` —— 文件监听**接口**（首期只给 polling 实现）。
//!
//! 为什么做成接口（文档 03 §4.5）：将来要支持 WSL（`/mnt/c` 上 inotify 不工作，
//! Zed 专门加了 PollWatcher fallback）。**形状先留好，实现可以后置。**
//!
//! 首期实现是 polling：简单、跨平台、无平台特判；macOS/Linux 的原生实现
//! （FSEvents / inotify）作为后续替换项 —— 替换点仅此文件。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const io_mod = @import("io.zig");
const fsio = @import("fsio.zig");

pub const Event = struct {
    path: []const u8,
    kind: Kind,

    pub const Kind = enum { created, modified, deleted };
};

/// 监听器接口（vtable）—— 消费方只依赖这个。
pub const Watcher = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 返回自上次调用以来发生的事件（可能为空）。调用方拥有返回切片及其中字符串。
        poll: *const fn (ptr: *anyopaque, gpa: Allocator) anyerror![]Event,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn poll(self: Watcher, gpa: Allocator) ![]Event {
        return self.vtable.poll(self.ptr, gpa);
    }

    pub fn deinit(self: Watcher) void {
        self.vtable.deinit(self.ptr);
    }
};

/// polling 实现：记录 (path, mtime, size) 快照，poll 时比对。
pub const PollingWatcher = struct {
    gpa: Allocator,
    io: Io,
    root: []const u8,
    interval_ms: u64 = 500,
    last_poll_ms: i64 = 0,
    snapshot: std.StringHashMapUnmanaged(Stamp) = .empty,

    /// 文件指纹。
    ///
    /// 📌 **mtime 用纳秒而不是毫秒**（这里原来是 `mtime_ms: i64`）：
    /// 截断到毫秒后，同一毫秒内被改写、且大小不变的文件，前后两次快照完全相同，
    /// 修改会被静默漏报。构建工具和编辑器在一毫秒内连写同一文件很常见。
    /// `Io.Timestamp.nanoseconds` 是 `i96`，直接用原始精度。
    const Stamp = struct { mtime_ns: i96, size: u64 };

    pub fn init(gpa: Allocator, io: Io, root: []const u8) !*PollingWatcher {
        const self = try gpa.create(PollingWatcher);
        self.* = .{ .gpa = gpa, .io = io, .root = try gpa.dupe(u8, root) };
        try self.refresh();
        return self;
    }

    pub fn watcher(self: *PollingWatcher) Watcher {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Watcher.VTable{
        .poll = pollErased,
        .deinit = deinitErased,
    };

    fn pollErased(ptr: *anyopaque, gpa: Allocator) anyerror![]Event {
        const self: *PollingWatcher = @ptrCast(@alignCast(ptr));
        return self.poll(gpa);
    }

    fn deinitErased(ptr: *anyopaque) void {
        const self: *PollingWatcher = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    /// 节流：未到间隔直接返回空。
    ///
    /// ⚠️ **两个分配器各司其职，不能合并**：
    ///   - `gpa`（调用方传入）只用于**返还给调用方**的东西：`events` 及其 `path`。
    ///     调用方可能传 arena，用完即 reset —— 这是合法用法。
    ///   - `self.gpa` 用于 `snapshot`：它在 poll 返回后**继续存活**到下一轮比对。
    /// 曾经这里用 `gpa` 分配 `current` 再赋给 `self.snapshot`，调用方一旦传 arena，
    /// 下一轮 `self.snapshot.get()` 就是 use-after-free。
    pub fn poll(self: *PollingWatcher, gpa: Allocator) ![]Event {
        const now = io_mod.monotonicMillis(self.io);
        if (now - self.last_poll_ms < @as(i64, @intCast(self.interval_ms))) return &.{};
        self.last_poll_ms = now;

        var events = std.ArrayListUnmanaged(Event).empty;
        // 出错时 path 也要逐个释放，只 deinit 数组会漏掉已 append 的字符串。
        errdefer {
            for (events.items) |e| gpa.free(e.path);
            events.deinit(gpa);
        }

        // 快照属于 watcher 自身状态 —— 必须 self.gpa。
        var current = std.StringHashMapUnmanaged(Stamp).empty;
        defer {
            var it = current.iterator();
            while (it.next()) |e| self.gpa.free(e.key_ptr.*);
            current.deinit(self.gpa);
        }

        const walk = try fsio.collectFiles(self.io, gpa, self.root, .{});
        defer fsio.freePaths(gpa, walk.paths);

        // 遍历被 max_entries 截断 → 这一轮的"全量列表"其实不全，拿它去 diff
        // 会把没看到的文件全判成 deleted、下一轮再全判成 created。
        // walk 顺序不稳定，所以这种假事件会持续来。宁可这轮不报，也不要报错的。
        // 注意：快照保持不变，等目录规模回到阈值内自然恢复。
        if (walk.truncated) return &.{};

        for (walk.paths) |p| {
            const stamp = self.stampOf(p) orelse continue;
            const key = try self.gpa.dupe(u8, p);
            // 只在 put 失败时释放 key；put 成功后所有权归 current，
            // 由上面的 defer 统一回收 —— 这里再加 errdefer 会变成双重释放。
            current.put(self.gpa, key, stamp) catch |err| {
                self.gpa.free(key);
                return err;
            };
            if (self.snapshot.get(p)) |old| {
                if (old.mtime_ns != stamp.mtime_ns or old.size != stamp.size) {
                    try events.append(gpa, .{ .path = try gpa.dupe(u8, p), .kind = .modified });
                }
            } else {
                try events.append(gpa, .{ .path = try gpa.dupe(u8, p), .kind = .created });
            }
        }

        var it = self.snapshot.iterator();
        while (it.next()) |e| {
            if (!current.contains(e.key_ptr.*)) {
                try events.append(gpa, .{ .path = try gpa.dupe(u8, e.key_ptr.*), .kind = .deleted });
            }
        }

        // 交换快照
        var old_it = self.snapshot.iterator();
        while (old_it.next()) |e| self.gpa.free(e.key_ptr.*);
        self.snapshot.deinit(self.gpa);
        self.snapshot = current;
        current = .empty;

        return events.toOwnedSlice(gpa);
    }

    fn stampOf(self: *PollingWatcher, path: []const u8) ?Stamp {
        const file = std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch return null;
        defer file.close(self.io);
        const st = std.Io.File.stat(file, self.io) catch return null;
        return .{ .mtime_ns = st.mtime.nanoseconds, .size = st.size };
    }

    /// 建立初始快照。这里**不需要**管 `truncated`：初始快照不完整只会让
    /// 第一轮 poll 多报几个 created，不会像 poll 里那样产生反复抖动的假事件。
    fn refresh(self: *PollingWatcher) !void {
        const walk = try fsio.collectFiles(self.io, self.gpa, self.root, .{});
        defer fsio.freePaths(self.gpa, walk.paths);
        for (walk.paths) |p| {
            if (self.stampOf(p)) |s| {
                const key = try self.gpa.dupe(u8, p);
                // 同 poll：只守 put 失败这个窗口，成功后所有权归 snapshot。
                self.snapshot.put(self.gpa, key, s) catch |err| {
                    self.gpa.free(key);
                    return err;
                };
            }
        }
    }

    pub fn deinit(self: *PollingWatcher) void {
        var it = self.snapshot.iterator();
        while (it.next()) |e| self.gpa.free(e.key_ptr.*);
        self.snapshot.deinit(self.gpa);
        self.gpa.free(self.root);
        self.gpa.destroy(self);
    }
};

pub fn freeEvents(gpa: Allocator, events: []Event) void {
    for (events) |e| gpa.free(e.path);
    gpa.free(events);
}

const testing = std.testing;

test "watch: polling 能观测到新增文件" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rnd = try io_mod.randomHex(io, testing.allocator, 6);
    defer testing.allocator.free(rnd);
    const dir = try std.fmt.allocPrint(testing.allocator, "/tmp/zigent-watch-test-{s}", .{rnd});
    defer testing.allocator.free(dir);
    defer io_mod.removeTree(io, dir) catch {};
    try io_mod.mkdirp(io, dir);

    const w = try PollingWatcher.init(testing.allocator, io, dir);
    const erased = w.watcher();
    defer erased.deinit();

    const f = try std.fmt.allocPrint(testing.allocator, "{s}/new.txt", .{dir});
    defer testing.allocator.free(f);
    try io_mod.writeFile(io, f, "hi");

    // 首轮不受节流限制（last_poll_ms 初始为 0）
    const events = try erased.poll(testing.allocator);
    defer freeEvents(testing.allocator, events);
    try testing.expect(events.len >= 1);
    var saw_created = false;
    for (events) |e| {
        if (e.kind == .created and std.mem.endsWith(u8, e.path, "new.txt")) saw_created = true;
    }
    try testing.expect(saw_created);
}

test "watch: 调用方传 arena 时快照不被连带释放" {
    // 回归测试（跨分配器 use-after-free）：
    // poll 曾经用**调用方传入的 gpa** 分配 snapshot 的 key，然后把它存进
    // self.snapshot（长生命周期）。调用方用 arena 是合法用法 —— 接口文档写明
    // "调用方拥有返回切片" —— 但 arena 一 deinit，snapshot 的 key 就全悬垂了。
    //
    // 断言方式不靠"是否崩溃"（UAF 不保证崩），而是看**语义**：
    // 第二轮 poll 只应该报新建的那一个文件。若 snapshot 已损坏，
    // 查不到旧文件就会把它再报一次 created。
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rnd = try io_mod.randomHex(io, testing.allocator, 6);
    defer testing.allocator.free(rnd);
    const dir = try std.fmt.allocPrint(testing.allocator, "/tmp/zigent-arena-{s}", .{rnd});
    defer testing.allocator.free(dir);
    defer io_mod.removeTree(io, dir) catch {};
    try io_mod.mkdirp(io, dir);

    const old_f = try std.fmt.allocPrint(testing.allocator, "{s}/old.txt", .{dir});
    defer testing.allocator.free(old_f);
    try io_mod.writeFile(io, old_f, "1");

    const w = try PollingWatcher.init(testing.allocator, io, dir);
    const erased = w.watcher();
    defer erased.deinit();
    w.interval_ms = 0; // 关掉节流，否则第二轮会被 500ms 挡掉

    // 第一轮：用 arena 当调用方分配器，然后**整个释放掉**。
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const evs = try erased.poll(arena.allocator());
        _ = evs; // 内容不重要，重要的是这批内存马上就没了
    }

    // 第二轮：只有 new.txt 是新的。
    const new_f = try std.fmt.allocPrint(testing.allocator, "{s}/new.txt", .{dir});
    defer testing.allocator.free(new_f);
    try io_mod.writeFile(io, new_f, "2");

    const evs2 = try erased.poll(testing.allocator);
    defer freeEvents(testing.allocator, evs2);

    var created_old = false;
    var created_new = false;
    for (evs2) |e| {
        if (e.kind != .created) continue;
        if (std.mem.endsWith(u8, e.path, "old.txt")) created_old = true;
        if (std.mem.endsWith(u8, e.path, "new.txt")) created_new = true;
    }
    try testing.expect(created_new);
    // 关键断言：old.txt 在第一轮就进快照了，不该被再报一次。
    try testing.expect(!created_old);
}

test "watch: 同毫秒内同尺寸改写不会漏报" {
    // 回归测试：Stamp 曾把 mtime 截断到毫秒，同一毫秒内被改写且大小不变的文件
    // 前后快照完全相同，modified 被静默吞掉。
    // 这里连续两次写入等长内容，中间不 sleep —— 正是会落在同一毫秒的场景。
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rnd = try io_mod.randomHex(io, testing.allocator, 6);
    defer testing.allocator.free(rnd);
    const dir = try std.fmt.allocPrint(testing.allocator, "/tmp/zigent-ns-{s}", .{rnd});
    defer testing.allocator.free(dir);
    defer io_mod.removeTree(io, dir) catch {};
    try io_mod.mkdirp(io, dir);

    const f = try std.fmt.allocPrint(testing.allocator, "{s}/a.txt", .{dir});
    defer testing.allocator.free(f);
    try io_mod.writeFile(io, f, "AAAA");

    const w = try PollingWatcher.init(testing.allocator, io, dir);
    const erased = w.watcher();
    defer erased.deinit();
    w.interval_ms = 0;

    // 等长改写，紧接着 poll —— 文件系统若支持亚毫秒精度，mtime_ns 必然不同
    try io_mod.writeFile(io, f, "BBBB");

    const evs = try erased.poll(testing.allocator);
    defer freeEvents(testing.allocator, evs);
    var saw_modified = false;
    for (evs) |e| {
        if (e.kind == .modified and std.mem.endsWith(u8, e.path, "a.txt")) saw_modified = true;
    }
    try testing.expect(saw_modified);
}
