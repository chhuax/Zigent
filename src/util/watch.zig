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

    const Stamp = struct { mtime_ms: i64, size: u64 };

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
    pub fn poll(self: *PollingWatcher, gpa: Allocator) ![]Event {
        const now = io_mod.monotonicMillis(self.io);
        if (now - self.last_poll_ms < @as(i64, @intCast(self.interval_ms))) return &.{};
        self.last_poll_ms = now;

        var events = std.ArrayListUnmanaged(Event).empty;
        errdefer events.deinit(gpa);

        var current = std.StringHashMapUnmanaged(Stamp).empty;
        defer {
            var it = current.iterator();
            while (it.next()) |e| gpa.free(e.key_ptr.*);
            current.deinit(gpa);
        }

        const paths = try fsio.collectFiles(self.io, gpa, self.root, .{});
        defer fsio.freePaths(gpa, paths);

        for (paths) |p| {
            const stamp = self.stampOf(p) orelse continue;
            const key = try gpa.dupe(u8, p);
            try current.put(gpa, key, stamp);
            if (self.snapshot.get(p)) |old| {
                if (old.mtime_ms != stamp.mtime_ms or old.size != stamp.size) {
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
        const mtime_ms: i64 = st.mtime.toMilliseconds();
        return .{ .mtime_ms = mtime_ms, .size = st.size };
    }

    fn refresh(self: *PollingWatcher) !void {
        const paths = try fsio.collectFiles(self.io, self.gpa, self.root, .{});
        defer fsio.freePaths(self.gpa, paths);
        for (paths) |p| {
            if (self.stampOf(p)) |s| {
                try self.snapshot.put(self.gpa, try self.gpa.dupe(u8, p), s);
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
