//! `ext/agent_spec.zig` —— 子代理的**参数形状**（首期不执行，只固化契约）。
//!
//! 固化的理由：`agent` 工具的 JSON Schema 与 `AgentSpawnedEvent` 的字段
//! 是一份**对外契约**，事后改字段名是破坏性变更。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Isolation = enum {
    /// 共享当前工作目录（默认）
    none,
    /// 独立 git worktree
    worktree,
    /// 独立临时目录
    sandbox,

    pub fn wireName(self: Isolation) []const u8 {
        return switch (self) {
            .none => "none",
            .worktree => "worktree",
            .sandbox => "sandbox",
        };
    }

    pub fn fromWire(s: []const u8) ?Isolation {
        inline for (@typeInfo(Isolation).@"enum".fields) |f| {
            const v: Isolation = @enumFromInt(f.value);
            if (std.mem.eql(u8, s, v.wireName())) return v;
        }
        return null;
    }
};

/// ⚠️ `isolation` 的**文案与 defaUlt 必须与 Schema 单一真源一致**：
/// 朴素实现曾出现「模型面向的 agent 与运行期 buildSchema 的 isolation 文案互相矛盾 4 天」。
pub const AgentSpec = struct {
    description: []const u8,
    prompt: []const u8,
    agent_type: []const u8 = "general-purpose",
    isolation: Isolation = .none,
    background: bool = false,
    /// 子代理的轮次上限（**远小于主循环的 200**）
    max_turns: u32 = 10,

    pub const DEFAULT_MAX_TURNS: u32 = 10;
};

const testing = std.testing;

test "agent_spec: isolation wire 往返" {
    inline for (@typeInfo(Isolation).@"enum".fields) |f| {
        const v: Isolation = @enumFromInt(f.value);
        try testing.expectEqual(v, Isolation.fromWire(v.wireName()).?);
    }
    try testing.expect(Isolation.fromWire("future") == null);
}

test "agent_spec: 子代理轮次上限远小于主循环" {
    try testing.expect(AgentSpec.DEFAULT_MAX_TURNS < 200);
}
