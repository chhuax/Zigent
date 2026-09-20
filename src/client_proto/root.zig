//! client_proto/ —— L4 协议
//!
//! stream-json · ACP
//!
//! 允许的依赖（由 `build.zig` 声明；**别的模块 import 不进来**）：
//!   ← common
//!   ← engine
//!   ← util

const std = @import("std");
const common = @import("common");
const engine = @import("engine");
const util = @import("util");

pub const stream_json = @import("stream_json.zig");
pub const acp = @import("acp.zig");
pub const PROTOCOL_VERSION = stream_json.PROTOCOL_VERSION;

/// 模块自述 —— 也用来**强制引用每个声明的依赖**：
/// 没有下面这段 comptime 触碰，Zig 的惰性编译会让 `build.zig` 的声明形同虚设。
pub const module_info = .{
    .name = "client_proto",
    .layer = "L4 协议",
    .deps = &[_][]const u8{ "common", "engine", "util" },
};

comptime {
    _ = common.module_info.name;
    _ = engine.module_info.name;
    _ = util.module_info.name;
}

test "client_proto: 依赖链可解析" {
    try std.testing.expectEqualStrings("client_proto", module_info.name);
}

test {
    std.testing.refAllDecls(@This());
}
