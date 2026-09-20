//! ext/ —— 扩展（**首期只给接口形状**）
//!
//! 子代理 / Skills / MCP —— 只准依赖 `tools`（+ `common` 的契约类型）。
//!
//! ## 首期范围声明（**这是主动决策，不是遗漏**）
//!
//! | 能力 | 首期 | 理由 |
//! |---|---|---|
//! | 子代理（`agent` 工具） | ❌ 不做 | 需要独立的会话生命周期与进程管理；内核先跑通单会话闭环 |
//! | Skills（`skills/*.md` 发现 + 注入） | ⚠️ 只做**发现与预算**，不做执行 | 注入路径已在 `memory/instructions` 打通 |
//! | MCP（stdio 传输） | ❌ 不做 | 协议版本硬编码 `2024-11-05`、工具名 `mcp__<server>__<tool>`、默认 deferred —— 形状先留 |
//!
//! **形状先留**的价值：将来加这些能力时，`engine` 的调用点不用改。

const std = @import("std");
const common = @import("common");
const tools = @import("tools");

pub const agent_spec = @import("agent_spec.zig");
pub const skills = @import("skills.zig");
pub const mcp = @import("mcp.zig");

pub const Isolation = agent_spec.Isolation;
pub const AgentSpec = agent_spec.AgentSpec;
pub const Skill = skills.Skill;
pub const McpServer = mcp.Server;

/// 模块自述 —— 也用来**强制引用每个声明的依赖**：
/// 没有下面这段 comptime 触碰，Zig 的惰性编译会让 `build.zig` 的声明形同虚设。
pub const module_info = .{
    .name = "ext",
    .layer = "扩展",
    .deps = &[_][]const u8{ "tools", "common" },
};

comptime {
    _ = tools.module_info.name;
    _ = common.module_info.name;
}

test "ext: 依赖链可解析" {
    try std.testing.expectEqualStrings("ext", module_info.name);
}

test {
    std.testing.refAllDecls(@This());
}
