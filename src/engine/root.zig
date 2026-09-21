//! engine/ —— L3 内核（**唯一有会话状态的地方**）
//!
//! 主循环 · 配对 · 压缩 · 恢复 —— 绝不 import cli
//!
//! 允许的依赖（由 `build.zig` 声明；**别的模块 import 不进来**）：
//!   ← common
//!   ← llm
//!   ← tools
//!   ← perm
//!   ← memory
//!   ← config
//!   ← util

const std = @import("std");
const common = @import("common");
const llm = @import("llm");
const tools = @import("tools");
const perm = @import("perm");
const memory = @import("memory");
const config = @import("config");
const util = @import("util");

pub const rt = @import("rt.zig");
pub const turn = @import("turn.zig");
pub const prompt = @import("prompt.zig");
pub const tool_exec = @import("tool_exec.zig");
pub const host = @import("host.zig");
pub const sink = @import("sink.zig");

/// ★ 配对不变量的类型化载体（文档 04 §13 命名裁决：`engine.Turn`）
pub const Turn = turn.Turn;
pub const PairingError = turn.PairingError;
pub const repairMessages = turn.repairMessages;
pub const Rt = rt.Rt;
pub const EventSink = sink.EventSink;
pub const CollectingSink = sink.CollectingSink;
pub const DiscardingSink = sink.DiscardingSink;
pub const HostImpl = host.HostImpl;
pub const PermissionBroker = host.PermissionBroker;
pub const InteractionBroker = host.InteractionBroker;

/// 模块自述 —— 也用来**强制引用每个声明的依赖**：
/// 没有下面这段 comptime 触碰，Zig 的惰性编译会让 `build.zig` 的声明形同虚设。
pub const module_info = .{
    .name = "engine",
    .layer = "L3 内核",
    .deps = &[_][]const u8{ "common", "llm", "tools", "perm", "memory", "config", "util" },
};

comptime {
    _ = common.module_info.name;
    _ = llm.module_info.name;
    _ = tools.module_info.name;
    _ = perm.module_info.name;
    _ = memory.module_info.name;
    _ = config.module_info.name;
    _ = util.module_info.name;
}

test "engine: 依赖链可解析" {
    try std.testing.expectEqualStrings("engine", module_info.name);
}

test {
    std.testing.refAllDecls(@This());
}
