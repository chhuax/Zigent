//! `util/log.zig` —— 日志**只走 stderr**。
//!
//! ⚠️ 桌面壳交付契约 #7（文档 03 §12.3）：**stdout 只走协议、日志走 stderr**。
//! 壳要解析 stdout 的第一行拿端口 —— 任何一行日志混进去都会让壳解析失败。

const std = @import("std");
const Io = std.Io;
const io_mod = @import("io.zig");

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn name(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }

    pub fn fromWire(s: []const u8) Level {
        if (std.ascii.eqlIgnoreCase(s, "debug")) return .debug;
        if (std.ascii.eqlIgnoreCase(s, "warn") or std.ascii.eqlIgnoreCase(s, "warning")) return .warn;
        if (std.ascii.eqlIgnoreCase(s, "error") or std.ascii.eqlIgnoreCase(s, "err")) return .err;
        return .info;
    }
};

/// 日志器（**显式传递，不做全局单例**）。
pub const Logger = struct {
    io: Io,
    min_level: Level = .info,
    /// 前缀（如 "zigent"）
    tag: []const u8 = "zigent",

    pub fn log(self: Logger, level: Level, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(self.min_level)) return;
        var buf: [4096]u8 = undefined;
        const msg = renderMessage(&buf, fmt, args);
        var line: [4600]u8 = undefined;
        const ts = io_mod.epochMillis(self.io);
        var tsbuf: [64]u8 = undefined;
        const rendered = std.fmt.bufPrint(&line, "[{s}] {s} {s}: {s}\n", .{
            formatIso(tsbuf[0..], ts),
            level.name(),
            self.tag,
            msg,
        }) catch return;
        io_mod.writeStderr(self.io, rendered);
    }

    pub fn debug(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }
    pub fn info(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }
    pub fn warn(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }
    pub fn err(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }
};

fn formatIso(buf: []u8, ms: i64) []const u8 {
    return io_mod.formatIso8601(buf, ms);
}

/// 消息放不下缓冲区时的替代文本。
pub const truncated_marker = "<log message truncated>";

/// 把 `fmt`/`args` 渲染进 `buf`；放不下就返回 `truncated_marker`。
///
/// 📌 **绝对不能回退成 `buf[0..]`**（这里原来就是这么写的）：
/// `bufPrint` 失败时**不保证** `buf` 被写满 —— 未写入的部分仍然是 `undefined`。
/// Zig 的 `undefined` **不是零值**，而是"读它属于未定义行为"的标记，实际内容
/// 就是这段栈内存上一次被别的调用留下的残留。把整个缓冲区发出去，既让日志变成
/// 乱码，也等于**把未初始化的栈内存泄露到 stderr**。
///
/// 拆成独立函数是为了可测试：`log()` 直接写 stderr，测不到这个分支。
fn renderMessage(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch truncated_marker;
}

const testing = std.testing;

test "log: 级别名与解析" {
    try testing.expectEqualStrings("DEBUG", Level.debug.name());
    try testing.expectEqual(Level.warn, Level.fromWire("warning"));
    try testing.expectEqual(Level.err, Level.fromWire("ERROR"));
    try testing.expectEqual(Level.info, Level.fromWire("nonsense"));
}

test "log: 超长消息回退成固定标记，不吐未初始化栈内存" {
    // 回归测试：曾经这里 `catch break :blk buf[0..]`，会把整个缓冲区（含 undefined
    // 的未写入部分）当成消息发出去。用一个必然放不下的小 buf 触发失败分支。
    var small: [8]u8 = undefined;
    const msg = renderMessage(&small, "{s}", .{"这条消息远远超过八个字节"});
    try testing.expectEqualStrings(truncated_marker, msg);

    // 放得下时必须正常渲染，别把正常路径也一起"修"坏了。
    var big: [128]u8 = undefined;
    try testing.expectEqualStrings("ok 42", renderMessage(&big, "ok {d}", .{42}));
}

test "log: 低于门槛不输出（不会 panic）" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const lg = Logger{ .io = threaded.io(), .min_level = .err };
    lg.info("这条不该出现 {d}", .{1});
    lg.err("这条会出现", .{});
}
