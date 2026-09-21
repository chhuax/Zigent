//! util/ —— L0′ 基座（零内部依赖）
//!
//! io · proc · fsio · log · watch —— **项目的唯一 OS 边界**。
//!
//! 允许的依赖（由 `build.zig` 声明；**别的模块 import 不进来**）：
//!   （无 —— L0 禁止依赖任何内部模块）

const std = @import("std");

pub const io = @import("io.zig");
pub const fsio = @import("fsio.zig");
pub const proc = @import("proc.zig");
pub const log = @import("log.zig");
pub const watch = @import("watch.zig");

pub const module_info = .{
    .name = "util",
    .layer = "L0′ 基座",
    .deps = &[_][]const u8{},
};

comptime {
    _ = io;
    _ = fsio;
    _ = proc;
    _ = log;
    _ = watch;
}

test "util: 依赖链可解析" {
    try std.testing.expectEqualStrings("util", module_info.name);
}

test {
    std.testing.refAllDecls(@This());
}
