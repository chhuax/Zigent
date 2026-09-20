//! common/ —— L0 契约层（零内部依赖）
//!
//! Message · StreamEvent · Tool · ContentBlock —— **全系统的地基**。
//!
//! 只放**类型与纯函数**：不放业务逻辑，不放 IO（唯一例外：`tool.zig` 的宿主总线）。
//! 判定标准：**至少两个模块需要，才放进来**。
//!
//! 允许的依赖（由 `build.zig` 声明；**别的模块 import 不进来**）：
//!   （无 —— L0 禁止依赖任何内部模块）

const std = @import("std");

pub const json = @import("json.zig");
pub const content = @import("content.zig");
pub const message = @import("message.zig");
pub const usage = @import("usage.zig");
pub const event = @import("event.zig");
pub const perm = @import("perm.zig");
pub const schema = @import("schema.zig");
pub const tool = @import("tool.zig");
pub const error_code = @import("error_code.zig");

// ── 最常用类型的直达 re-export（消费点不必写两级路径）──
pub const MessageRole = content.MessageRole;
pub const ContentBlock = content.ContentBlock;
pub const TextBlock = content.TextBlock;
pub const ToolUseBlock = content.ToolUseBlock;
pub const ToolResultBlock = content.ToolResultBlock;
pub const ImageContentBlock = content.ImageContentBlock;
pub const Message = message.Message;
pub const Usage = usage.Usage;
pub const StreamEvent = event.StreamEvent;
pub const Envelope = event.Envelope;
pub const Tool = tool.Tool;
pub const ToolResult = tool.ToolResult;
pub const ToolContext = tool.ToolContext;
pub const JsonValue = json.Value;
pub const JsonMap = json.Map;
pub const ErrorCode = error_code.ErrorCode;
pub const StopReason = error_code.StopReason;

/// 模块自述 —— 也用来**强制引用每个声明的依赖**：
/// 没有下面这段 comptime 触碰，Zig 的惰性编译会让 `build.zig` 的声明形同虚设。
pub const module_info = .{
    .name = "common",
    .layer = "L0 契约层",
    .deps = &[_][]const u8{},
};

comptime {
    // 零依赖：没有任何内部 @import
    _ = json;
    _ = content;
    _ = message;
    _ = usage;
    _ = event;
    _ = perm;
    _ = schema;
    _ = tool;
    _ = error_code;
}

test "common: 依赖链可解析" {
    try std.testing.expectEqualStrings("common", module_info.name);
}

test {
    std.testing.refAllDecls(@This());
}
