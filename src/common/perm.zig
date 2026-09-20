//! `common/perm.zig` —— 权限契约层（零内部依赖，文档 07 §2.3 / §10 / §11.2）。
//!
//! ⚠️ 命名裁决（文档 04 §13）：**枚举叫 `Verdict`，完整结果叫 `Outcome`**。
//!   `Decision` 这个名字被三个不同枚举占用过，本仓库一律不再使用。
//!
//! 四级深度防御（**真实顺序**，顺序错会多弹卡片或漏拦）：
//!   L1 `planGate`（Plan 只读闸门，**在 checkPermissions 之前**）
//!   L2 工具自判（默认 `defer`）
//!   L3 确定性分类器
//!   L4 规则 + 缓存 + 用户提示

const std = @import("std");
const json = @import("json.zig");

/// 判定链的统一返回值。**没有第四种「继续」之外的状态**。
pub const Verdict = enum {
    /// 本层不反对，但**不等于放行**（enter_plan_mode 这类 ALLOW 后仍要落审计）。
    allow,
    /// 终态拒绝，带原因。
    deny,
    /// 需要用户裁决（没有交互通道时退化为 deny）。
    ask,
    /// **只有工具自判层（L2）可以返回它** —— "交给后面的通用机制"。
    /// （`defer` 是 Zig 关键字，故命名 `deferred`；**wire 名仍是 `defer`**）
    deferred,

    pub fn wireName(self: Verdict) []const u8 {
        return switch (self) {
            .allow => "allow",
            .deny => "deny",
            .ask => "ask",
            .deferred => "defer",
        };
    }
};

/// 风险等级（权限卡片是跨版本契约，**wire 名必须与既有行为一致**）。
pub const RiskLevel = enum {
    safe,
    read_only,
    review,
    write,
    network,
    high,
    modifies_files,
    filesystem_access,
    agent_control,
    mcp_tool,

    pub fn wireName(self: RiskLevel) []const u8 {
        return switch (self) {
            .safe => "SAFE",
            .read_only => "READ_ONLY",
            .review => "REVIEW",
            .write => "WRITE",
            .network => "NETWORK",
            .high => "HIGH",
            .modifies_files => "MODIFIES_FILES",
            .filesystem_access => "FILESYSTEM_ACCESS",
            .agent_control => "AGENT_CONTROL",
            .mcp_tool => "MCP_TOOL",
        };
    }

    pub fn fromWire(s: []const u8) ?RiskLevel {
        inline for (@typeInfo(RiskLevel).@"enum".fields) |f| {
            const v: RiskLevel = @enumFromInt(f.value);
            if (std.mem.eql(u8, s, v.wireName())) return v;
        }
        return null;
    }
};

pub const DenialReason = enum {
    policy,
    user_denied,
    timed_out,
    cancelled,
    unavailable,

    pub fn wireName(self: DenialReason) []const u8 {
        return switch (self) {
            .policy => "POLICY",
            .user_denied => "USER_DENIED",
            .timed_out => "TIMED_OUT",
            .cancelled => "CANCELLED",
            .unavailable => "UNAVAILABLE",
        };
    }
};

/// 配置来源（审计落盘要用稳定名）。
pub const Source = enum {
    policy,
    managed,
    flag,
    project,
    local,
    user,
    plugin,
    cli,
    sdk,
    session,
    builtin,

    pub fn wireName(self: Source) []const u8 {
        return switch (self) {
            .policy => "POLICY",
            .managed => "MANAGED",
            .flag => "FLAG",
            .project => "PROJECT",
            .local => "LOCAL",
            .user => "USER",
            .plugin => "PLUGIN",
            .cli => "CLI",
            .sdk => "SDK",
            .session => "SESSION",
            .builtin => "BUILTIN",
        };
    }
};

/// P5：判定必须可回放。**所有**判定都带 provenance（成本是一次函数签名）。
pub const Provenance = struct {
    source: Source,
    /// 例如 "shell-analyzer" / "explicit-tools" / 规则 id / hook id
    source_id: []const u8,
    /// 配置来源文件的绝对路径（朴素实现恒 null —— 这里填上）。
    path: ?[]const u8 = null,
    /// 命中的 key / 模式 / 工具名
    key: []const u8,
    plugin_id: ?[]const u8 = null,
    /// 越小越优先（DENY=0x, ASK=1x, ALLOW=2x）
    priority: i32,
    captured_at_ms: i64,

    pub fn toJson(self: Provenance, e: *json.Encoder) !void {
        try e.beginObject();
        try e.stringField("source", self.source.wireName());
        try e.stringField("sourceId", self.source_id);
        try e.optStringField("path", self.path);
        try e.stringField("key", self.key);
        try e.optStringField("pluginId", self.plugin_id);
        try e.intField("priority", self.priority);
        try e.intField("capturedAtMs", self.captured_at_ms);
        try e.endObject();
    }
};

pub const Trace = struct {
    /// "permission:<toolName>"
    subject: []const u8,
    decision: Verdict,
    allowed: bool,
    provenance: Provenance,
    reason: []const u8,
    metadata: json.Map = .{},

    pub fn toJson(self: Trace, e: *json.Encoder) !void {
        try e.beginObject();
        try e.stringField("subject", self.subject);
        try e.stringField("decision", self.decision.wireName());
        try e.boolField("allowed", self.allowed);
        try e.key("provenance");
        try self.provenance.toJson(e);
        try e.stringField("reason", self.reason);
        try e.field("metadata", .{ .object = self.metadata });
        try e.endObject();
    }
};

/// 一次判定的完整结果 —— 所有层都返回它，不只是布尔。
pub const Outcome = struct {
    verdict: Verdict,
    /// 人类可读原因；进权限卡片与 tool_result。
    reason: []const u8,
    risk_level: RiskLevel,
    /// 命令级风险（非 shell 工具为 null）—— 与 `risk_level` 是**两条独立轴**。
    command_risk_level: ?RiskLevel = null,
    denial_reason: ?DenialReason = null,
    trace: ?Trace = null,

    pub fn allow(reason: []const u8, risk: RiskLevel) Outcome {
        return .{ .verdict = .allow, .reason = reason, .risk_level = risk };
    }

    pub fn deny(reason: []const u8, risk: RiskLevel, why: DenialReason) Outcome {
        return .{
            .verdict = .deny,
            .reason = reason,
            .risk_level = risk,
            .denial_reason = why,
        };
    }

    pub fn deferred(reason: []const u8, risk: RiskLevel) Outcome {
        return .{ .verdict = .deferred, .reason = reason, .risk_level = risk };
    }

    pub fn ask(reason: []const u8, risk: RiskLevel) Outcome {
        return .{ .verdict = .ask, .reason = reason, .risk_level = risk };
    }

    pub fn isAllowed(self: Outcome) bool {
        return self.verdict == .allow;
    }
};

/// 权限模式 —— **只有 4 个**（`AUTO`/`ALLOW_ALL`/`DENY_ALL` 在代码里不存在）。
pub const Mode = enum {
    ask,
    accept_edits,
    bypass_permissions,
    plan,

    pub fn wireName(self: Mode) []const u8 {
        return switch (self) {
            .ask => "ASK",
            .accept_edits => "ACCEPT_EDITS",
            .bypass_permissions => "BYPASS_PERMISSIONS",
            .plan => "PLAN",
        };
    }

    pub fn fromWire(s: []const u8) ?Mode {
        if (std.ascii.eqlIgnoreCase(s, "ASK")) return .ask;
        if (std.ascii.eqlIgnoreCase(s, "ACCEPT_EDITS")) return .accept_edits;
        if (std.ascii.eqlIgnoreCase(s, "BYPASS_PERMISSIONS")) return .bypass_permissions;
        if (std.ascii.eqlIgnoreCase(s, "PLAN")) return .plan;
        return null;
    }
};

/// 7 个 operation label —— **未登记的一律按写类 fail-closed**
/// （读授权静默升级成写授权 = 上线才炸的漏洞）。
pub const OperationLabel = enum {
    read,
    glob,
    grep,
    lsp,
    write,
    edit,
    bash,

    pub fn wireName(self: OperationLabel) []const u8 {
        return switch (self) {
            .read => "read",
            .glob => "glob",
            .grep => "grep",
            .lsp => "lsp",
            .write => "write",
            .edit => "edit",
            .bash => "bash",
        };
    }

    /// 未登记的 label → 一律按写类处理（fail-closed）。
    pub fn fromToolName(tool_name: []const u8) OperationLabel {
        if (std.mem.eql(u8, tool_name, "Read") or std.mem.eql(u8, tool_name, "read_file")) return .read;
        if (std.mem.eql(u8, tool_name, "Glob") or std.mem.eql(u8, tool_name, "glob")) return .glob;
        if (std.mem.eql(u8, tool_name, "Grep") or std.mem.eql(u8, tool_name, "grep")) return .grep;
        if (std.mem.eql(u8, tool_name, "Lsp")) return .lsp;
        if (std.mem.eql(u8, tool_name, "Write") or std.mem.eql(u8, tool_name, "write_file")) return .write;
        if (std.mem.eql(u8, tool_name, "Edit") or std.mem.eql(u8, tool_name, "edit_file")) return .edit;
        if (std.mem.eql(u8, tool_name, "Bash") or std.mem.eql(u8, tool_name, "bash")) return .bash;
        return .write; // fail-closed
    }

    /// 只有这三个 label 可以吃只读授权缓存。
    pub fn isReadOnly(self: OperationLabel) bool {
        return switch (self) {
            .read, .glob, .grep, .lsp => true,
            else => false,
        };
    }
};

/// 两级授权缓存**刻意不合并**（文档 07 §5.1）：
/// 运行时主动披露给模型的 root **不能**授权 write/edit。
pub const ALLOWED_ROOTS_KEY = "allowedFileRoots";
pub const READ_ONLY_ROOTS_KEY = "readOnlyFileRoots";

/// 对所有客户端可见的权限请求（字段名与 ACP 对齐）。
pub const Request = struct {
    session_id: []const u8,
    /// 发起工具调用的 agent（主代理为空串；子代理为其 id）
    agent_id: []const u8,
    tool_use_id: []const u8,
    tool_name: []const u8,
    tool_risk_level: RiskLevel,
    command_risk_level: ?RiskLevel = null,
    risk_flags: []const []const u8 = &.{},
    /// ★ 人类可读摘要 —— **由内核生成**，客户端不得自行拼。
    input_summary: []const u8,
    raw_input: ?[]const u8 = null,
    cwd: []const u8,
    reason: []const u8,
    options: []const Option = &default_options,
    trace: ?Trace = null,
    timeout_ms: u64 = 60_000,

    pub const Option = struct {
        option_id: []const u8,
        kind: []const u8,
        name: []const u8,
    };

    /// **默认三选项，顺序已冻结。**
    pub const default_options = [_]Option{
        .{ .option_id = "allow_once", .kind = "allow_once", .name = "Allow once" },
        .{ .option_id = "allow_always", .kind = "allow_always", .name = "Allow always" },
        .{ .option_id = "reject_once", .kind = "reject_once", .name = "Deny" },
    };

    pub fn toJson(self: Request, e: *json.Encoder) !void {
        try e.beginObject();
        try e.stringField("session_id", self.session_id);
        try e.stringField("agent_id", self.agent_id);
        try e.stringField("tool_use_id", self.tool_use_id);
        try e.stringField("tool_name", self.tool_name);
        try e.stringField("risk_level", self.tool_risk_level.wireName());
        try e.stringField("tool_risk_level", self.tool_risk_level.wireName());
        if (self.command_risk_level) |c| try e.stringField("command_risk_level", c.wireName());
        try e.key("risk_flags");
        try e.beginArray();
        for (self.risk_flags) |f| try e.string(f);
        try e.endArray();
        try e.stringField("input_summary", self.input_summary);
        try e.optStringField("raw_input", self.raw_input);
        try e.stringField("cwd", self.cwd);
        try e.stringField("reason", self.reason);
        try e.key("options");
        try e.beginArray();
        for (self.options) |o| {
            try e.beginObject();
            try e.stringField("option_id", o.option_id);
            try e.stringField("kind", o.kind);
            try e.stringField("label", o.name);
            try e.endObject();
        }
        try e.endArray();
        try e.key("timeout_ms");
        try e.uint(self.timeout_ms);
        try e.endObject();
    }
};

/// 客户端应答（唯一形状）。
pub const Response = struct {
    agent_id: []const u8 = "",
    tool_use_id: []const u8 = "",
    allowed: bool,
    /// true ⇒ 内核把这次判定写入规则/路径缓存（"Allow always"）
    cache_decision: bool = false,
    message: []const u8 = "",
    denial_reason: ?DenialReason = null,

    pub fn denyByUser(message: []const u8) Response {
        return .{ .allowed = false, .message = message, .denial_reason = .user_denied };
    }

    pub fn unavailable(message: []const u8) Response {
        return .{ .allowed = false, .message = message, .denial_reason = .unavailable };
    }

    /// 取消与拒绝的**文案必须区分**：
    /// 「Permission denied」会让模型读成"这条路不通" → 换条路继续干（子代理绕过事故）；
    /// 取消要说清"整轮被中断，不要重试也不要绕过"。
    pub const MSG_CANCELLED = "Interrupted by user: the turn was cancelled, do not retry or work around this";
    pub const MSG_DENIED = "Permission denied by client";
    pub const MSG_TIMEOUT = "Permission request timed out";

    /// 身份校验：不一致 → unavailable（否则并发子代理会互相回答对方的卡片）。
    pub fn matchesIdentity(self: Response, req: Request) bool {
        if (req.agent_id.len != 0 and !std.mem.eql(u8, self.agent_id, req.agent_id)) return false;
        if (req.tool_use_id.len != 0 and !std.mem.eql(u8, self.tool_use_id, req.tool_use_id)) return false;
        return true;
    }
};

/// 从 option_id 映射到应答（顺序已冻结）。
pub fn responseForOption(option_id: []const u8) Response {
    if (std.mem.eql(u8, option_id, "allow_once")) {
        return .{ .allowed = true, .cache_decision = false };
    }
    if (std.mem.eql(u8, option_id, "allow_always")) {
        return .{ .allowed = true, .cache_decision = true };
    }
    if (std.mem.eql(u8, option_id, "cancelled")) {
        return .{ .allowed = false, .message = Response.MSG_CANCELLED, .denial_reason = .cancelled };
    }
    return denyByUserDefault();
}

fn denyByUserDefault() Response {
    return .{ .allowed = false, .message = Response.MSG_DENIED, .denial_reason = .user_denied };
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "perm: 只有四个权限模式" {
    const fields = @typeInfo(Mode).@"enum".fields;
    try testing.expectEqual(@as(usize, 4), fields.len);
}

test "perm: 未登记 operation label 按写类 fail-closed" {
    try testing.expectEqual(OperationLabel.write, OperationLabel.fromToolName("SomeFutureTool"));
    try testing.expect(!OperationLabel.fromToolName("SomeFutureTool").isReadOnly());
}

test "perm: 读类 label 判定" {
    try testing.expectEqual(OperationLabel.read, OperationLabel.fromToolName("Read"));
    try testing.expect(OperationLabel.fromToolName("Read").isReadOnly());
    try testing.expect(OperationLabel.fromToolName("Grep").isReadOnly());
    try testing.expect(!OperationLabel.fromToolName("Write").isReadOnly());
    try testing.expect(!OperationLabel.fromToolName("Bash").isReadOnly());
}

test "perm: RiskLevel wire 往返" {
    inline for (@typeInfo(RiskLevel).@"enum".fields) |f| {
        const v: RiskLevel = @enumFromInt(f.value);
        try testing.expectEqual(v, RiskLevel.fromWire(v.wireName()).?);
    }
}

test "perm: Disallowed 名字不存在（Verdict 四个变体）" {
    const fields = @typeInfo(Verdict).@"enum".fields;
    try testing.expectEqual(@as(usize, 4), fields.len);
}

test "perm: 取消与拒绝文案不同" {
    try testing.expect(!std.mem.eql(u8, Response.MSG_CANCELLED, Response.MSG_DENIED));
    const cancelled = responseForOption("cancelled");
    try testing.expectEqual(DenialReason.cancelled, cancelled.denial_reason.?);
    const denied = responseForOption("nonsense");
    try testing.expectEqual(DenialReason.user_denied, denied.denial_reason.?);
}

test "perm: 身份不一致 → 视为不可用" {
    const req = Request{
        .session_id = "s",
        .agent_id = "agent-1",
        .tool_use_id = "t1",
        .tool_name = "Bash",
        .tool_risk_level = .high,
        .input_summary = "x",
        .cwd = "/",
        .reason = "y",
    };
    const ok = Response{ .agent_id = "agent-1", .tool_use_id = "t1", .allowed = true };
    try testing.expect(ok.matchesIdentity(req));
    const bad = Response{ .agent_id = "agent-2", .tool_use_id = "t1", .allowed = true };
    try testing.expect(!bad.matchesIdentity(req));
}

test "perm: Request wire 含三个冻结选项" {
    const req = Request{
        .session_id = "s",
        .agent_id = "",
        .tool_use_id = "t1",
        .tool_name = "Bash",
        .tool_risk_level = .high,
        .input_summary = "rm -rf /",
        .cwd = "/repo",
        .reason = "destructive",
    };
    var e = json.Encoder.init(testing.allocator);
    defer e.deinit();
    try req.toJson(&e);
    const out = e.text();
    try testing.expect(std.mem.indexOf(u8, out, "allow_once") != null);
    try testing.expect(std.mem.indexOf(u8, out, "allow_always") != null);
    try testing.expect(std.mem.indexOf(u8, out, "reject_once") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"risk_level\":\"HIGH\"") != null);
}

test "perm: Outcome 三态与拒绝原因" {
    try testing.expect(Outcome.allow("ok", .safe).isAllowed());
    const d = Outcome.deny("no", .high, .policy);
    try testing.expectEqual(Verdict.deny, d.verdict);
    try testing.expectEqual(DenialReason.policy, d.denial_reason.?);
}
