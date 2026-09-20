//! server/ —— L4 协议（对 Web 的门）
//!
//! 本地 HTTP + SSE
//!
//! 允许的依赖（由 `build.zig` 声明；**别的模块 import 不进来**）：
//!   ← common
//!   ← engine
//!   ← config
//!   ← util

const std = @import("std");
const common = @import("common");
const engine = @import("engine");
const config = @import("config");
const util = @import("util");

pub const http = @import("http.zig");
pub const sse = @import("sse.zig");
pub const token = @import("token.zig");
pub const queue = @import("queue.zig");
pub const app = @import("app.zig");
pub const static = @import("static.zig");

pub const App = app.App;
pub const ClientFactory = app.ClientFactory;
pub const VERSION = app.VERSION;

pub const module_info = .{
    .name = "server",
    .layer = "L4 协议",
    .deps = &[_][]const u8{ "common", "engine", "config", "util" },
};

comptime {
    _ = common.module_info.name;
    _ = engine.module_info.name;
    _ = config.module_info.name;
    _ = util.module_info.name;
}

test "server: 依赖链可解析" {
    try std.testing.expectEqualStrings("server", module_info.name);
}

test {
    std.testing.refAllDecls(@This());
}
