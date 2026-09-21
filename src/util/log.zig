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
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
            break :blk buf[0..];
        };
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

const testing = std.testing;

test "log: 级别名与解析" {
    try testing.expectEqualStrings("DEBUG", Level.debug.name());
    try testing.expectEqual(Level.warn, Level.fromWire("warning"));
    try testing.expectEqual(Level.err, Level.fromWire("ERROR"));
    try testing.expectEqual(Level.info, Level.fromWire("nonsense"));
}

test "log: 低于门槛不输出（不会 panic）" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const lg = Logger{ .io = threaded.io(), .min_level = .err };
    lg.info("这条不该出现 {d}", .{1});
    lg.err("这条会出现", .{});
}
