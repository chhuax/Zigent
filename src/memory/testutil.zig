//! `memory/testutil.zig` —— **测试专用**沙箱。
//!
//! 只在各文件的 `test` 块里被引用，因此**非测试编译单元不会分析它**
//! （`build.zig` 只为每个模块建一个测试产物；engine 依赖 `memory` 时看不到它）。
//!
//! 这里唯一"靠近系统"的东西是 `std.Io.Threaded.init` —— 它只是**构造一个 `Io`
//! 实例**（`util/io.zig` 自己的测试也是这么做的），不是文件系统原语；
//! 真正的读/写/建目录/删树仍然全部走 `util.io`。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const util = @import("util");

/// 每个文件系统测试各自一个 `/tmp/zigent-memory-test-<随机 hex>`，
/// `deinit` 里用 `util.io.removeTree` 递归删除。
///
/// `init` 必须传 `*TestDir`（不能返回值）—— `Io` 的 `userdata` 指向 `Threaded`
/// 自身，结构体一旦被搬移，缓存的 `Io` 就悬空。
pub const TestDir = struct {
    threaded: std.Io.Threaded,
    path: []u8,

    pub fn init(self: *TestDir) !void {
        const gpa = std.testing.allocator;
        self.threaded = std.Io.Threaded.init(gpa, .{});
        errdefer self.threaded.deinit();

        const handle = self.threaded.io();
        const rnd = try util.io.randomHex(handle, gpa, 8);
        defer gpa.free(rnd);
        self.path = try std.fmt.allocPrint(gpa, "/tmp/zigent-memory-test-{s}", .{rnd});
        errdefer gpa.free(self.path);
        try util.io.mkdirp(handle, self.path);
    }

    pub fn io(self: *TestDir) Io {
        return self.threaded.io();
    }

    pub fn deinit(self: *TestDir) void {
        const gpa = std.testing.allocator;
        util.io.removeTree(self.threaded.io(), self.path) catch {};
        gpa.free(self.path);
        self.threaded.deinit();
    }
};

/// 在 `base/<rel>` 写文件，自动建中间目录。
pub fn writeAt(io: Io, gpa: Allocator, base: []const u8, rel: []const u8, content: []const u8) !void {
    const p = try std.fs.path.join(gpa, &.{ base, rel });
    defer gpa.free(p);
    if (std.fs.path.dirname(p)) |d| try util.io.mkdirp(io, d);
    try util.io.writeFile(io, p, content);
}
