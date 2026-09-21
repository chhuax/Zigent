//! 错误码与停止原因 —— 对外契约（文档 06 §5 / §4.2）。
//!
//! ⚠️ 这些字符串是**契约**：客户端按它们做重试/终态判断，改名 = 破坏性变更。

const std = @import("std");

pub const ErrorCode = enum {
    authentication,
    quota_exceeded,
    invalid_model,
    prompt_too_long,
    max_output_tokens,
    rate_limited,
    model_overloaded,
    transient,
    stale_connection,
    malformed_tool_input,
    tool_use_mismatch,
    cancelled,
    unknown,

    pub fn wireName(self: ErrorCode) []const u8 {
        return switch (self) {
            .authentication => "authentication",
            .quota_exceeded => "quota_exceeded",
            .invalid_model => "invalid_model",
            .prompt_too_long => "prompt_too_long",
            .max_output_tokens => "max_output_tokens",
            .rate_limited => "rate_limited",
            .model_overloaded => "model_overloaded",
            .transient => "transient",
            .stale_connection => "stale_connection",
            .malformed_tool_input => "malformed_tool_input",
            .tool_use_mismatch => "tool_use_mismatch",
            .cancelled => "cancelled",
            .unknown => "unknown",
        };
    }

    pub fn fromWire(s: []const u8) ?ErrorCode {
        inline for (@typeInfo(ErrorCode).@"enum".fields) |f| {
            const v: ErrorCode = @enumFromInt(f.value);
            if (std.mem.eql(u8, s, v.wireName())) return v;
        }
        return null;
    }

    /// 可重试？（文档 06 §5 的表）
    pub fn retryable(self: ErrorCode) bool {
        return switch (self) {
            .prompt_too_long,
            .max_output_tokens,
            .rate_limited,
            .model_overloaded,
            .transient,
            .stale_connection,
            .malformed_tool_input,
            .tool_use_mismatch,
            => true,
            .authentication, .quota_exceeded, .invalid_model, .cancelled, .unknown => false,
        };
    }
};

pub const StopReason = enum {
    end_turn,
    cancelled,
    max_turn_requests,
    refusal,
    tool_repeated_failure,

    pub fn wireName(self: StopReason) []const u8 {
        return switch (self) {
            .end_turn => "end_turn",
            .cancelled => "cancelled",
            .max_turn_requests => "max_turn_requests",
            .refusal => "refusal",
            .tool_repeated_failure => "tool_repeated_failure",
        };
    }

    pub fn fromWire(s: []const u8) ?StopReason {
        inline for (@typeInfo(StopReason).@"enum".fields) |f| {
            const v: StopReason = @enumFromInt(f.value);
            if (std.mem.eql(u8, s, v.wireName())) return v;
        }
        return null;
    }
};

/// 错误来源（文档 04 §6.2）。
pub const ErrorSource = enum {
    model,
    execution,

    pub fn wireName(self: ErrorSource) []const u8 {
        return switch (self) {
            .model => "MODEL",
            .execution => "EXECUTION",
        };
    }
};

/// 轨迹结局（文档 04 §6.2）。
pub const TrajectoryOutcome = enum {
    success,
    partial,
    cancelled,
    failure,

    pub fn wireName(self: TrajectoryOutcome) []const u8 {
        return switch (self) {
            .success => "success",
            .partial => "partial",
            .cancelled => "cancelled",
            .failure => "failure",
        };
    }
};

/// 从 provider HTTP 状态码 + 文案归类到错误码（llm/recovery 共用）。
pub fn classifyHttp(status: u16, message: []const u8) ErrorCode {
    switch (status) {
        401, 403 => return .authentication,
        402 => return .quota_exceeded,
        404 => return .invalid_model,
        408, 504 => return .stale_connection,
        413 => return .prompt_too_long,
        429 => {
            if (std.mem.indexOf(u8, message, "quota") != null) return .quota_exceeded;
            return .rate_limited;
        },
        529, 503 => return .model_overloaded,
        else => {},
    }
    if (status >= 500) return .transient;
    if (std.mem.indexOf(u8, message, "prompt is too long") != null) return .prompt_too_long;
    if (std.mem.indexOf(u8, message, "max_output_tokens") != null) return .max_output_tokens;
    if (std.mem.indexOf(u8, message, "rate limit") != null) return .rate_limited;
    if (std.mem.indexOf(u8, message, "overloaded") != null) return .model_overloaded;
    return .unknown;
}

const testing = std.testing;

test "error_code: wire 往返" {
    inline for (@typeInfo(ErrorCode).@"enum".fields) |f| {
        const v: ErrorCode = @enumFromInt(f.value);
        try testing.expectEqual(v, ErrorCode.fromWire(v.wireName()).?);
    }
}

test "error_code: 可重试口径" {
    try testing.expect(ErrorCode.rate_limited.retryable());
    try testing.expect(ErrorCode.prompt_too_long.retryable());
    try testing.expect(!ErrorCode.authentication.retryable());
    try testing.expect(!ErrorCode.cancelled.retryable());
}

test "error_code: HTTP 归类" {
    try testing.expectEqual(ErrorCode.authentication, classifyHttp(401, ""));
    try testing.expectEqual(ErrorCode.rate_limited, classifyHttp(429, "slow down"));
    try testing.expectEqual(ErrorCode.quota_exceeded, classifyHttp(429, "quota exceeded"));
    try testing.expectEqual(ErrorCode.model_overloaded, classifyHttp(529, ""));
    try testing.expectEqual(ErrorCode.prompt_too_long, classifyHttp(200, "prompt is too long"));
}

test "error_code: StopReason wire 往返" {
    inline for (@typeInfo(StopReason).@"enum".fields) |f| {
        const v: StopReason = @enumFromInt(f.value);
        try testing.expectEqual(v, StopReason.fromWire(v.wireName()).?);
    }
}
