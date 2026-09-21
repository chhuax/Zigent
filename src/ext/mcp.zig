//! `ext/mcp.zig` —— MCP 的**协议常量与命名**（首期不做传输）。
//!
//! 三个必须原样保留的常量（雷区 H）：
//!   - 协议版本硬编码 `2024-11-05`
//!   - 工具名 `mcp__<server>__<tool>`
//!   - 默认 **deferred**（即需要用户批准）

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PROTOCOL_VERSION = "2024-11-05";
pub const TOOL_PREFIX = "mcp__";
pub const SEPARATOR = "__";

pub const Server = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    /// 默认 **deferred**：MCP 工具默认要问用户
    deferred: bool = true,
};

/// `mcp__<server>__<tool>`
pub fn toolName(gpa: Allocator, server: []const u8, tool: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}{s}{s}", .{ TOOL_PREFIX, server, SEPARATOR, tool });
}

/// 反向拆分（`split("__", 3)`）。
pub fn parseToolName(name: []const u8) ?struct { server: []const u8, tool: []const u8 } {
    if (!std.mem.startsWith(u8, name, TOOL_PREFIX)) return null;
    const rest = name[TOOL_PREFIX.len..];
    const i = std.mem.indexOf(u8, rest, SEPARATOR) orelse return null;
    return .{ .server = rest[0..i], .tool = rest[i + SEPARATOR.len ..] };
}

/// 这是不是 MCP 工具（权限层据此归到 `.mcp_tool` 风险）。
pub fn isMcpTool(name: []const u8) bool {
    return std.mem.startsWith(u8, name, TOOL_PREFIX);
}

const testing = std.testing;

test "mcp: 协议版本硬编码" {
    try testing.expectEqualStrings("2024-11-05", PROTOCOL_VERSION);
}

test "mcp: 工具名往返" {
    const n = try toolName(testing.allocator, "github", "create_issue");
    defer testing.allocator.free(n);
    try testing.expectEqualStrings("mcp__github__create_issue", n);
    const p = parseToolName(n).?;
    try testing.expectEqualStrings("github", p.server);
    try testing.expectEqualStrings("create_issue", p.tool);
    try testing.expect(isMcpTool(n));
    try testing.expect(!isMcpTool("Read"));
}

test "mcp: 默认 deferred" {
    const s = Server{ .name = "x", .command = "y" };
    try testing.expect(s.deferred);
}
