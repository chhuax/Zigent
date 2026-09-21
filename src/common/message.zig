//! `Message` + `Message.Meta` —— L0 契约层。
//!
//! P3：把 8 个隐式魔法字符串（`isMeta` / `type` / `invoked_skills` / `task_ledger` /
//! `compact_continuation` / `user_skill_slash` / `recovery_hint` / `critical_reminder` /
//! `user_interrupt`）**变成一个 tagged union**：
//!   - 少一个字母 → 编译错误（而不是恢复路径静默失效）；
//!   - `switch (msg.meta)` 必须穷尽 → 新增注入类型时所有消费点被编译器强制更新。
//!
//! ⚠️ 但 **wire 上的 `isMeta` / `type` 键名必须原样保留**（transcript 靠它们重建）。
//! 这是「内部现代化 + 外部逐字节兼容」的分界点。

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const content = @import("content.zig");

pub const MessageRole = content.MessageRole;
pub const ContentBlock = content.ContentBlock;
pub const TextBlock = content.TextBlock;
pub const ToolUseBlock = content.ToolUseBlock;
pub const ToolResultBlock = content.ToolResultBlock;

/// wire 键名常量（**不能改名**，见文件头）。
pub const KEY_IS_META = "isMeta";
pub const KEY_TYPE = "type";
pub const KEY_INVOKED_SKILLS = "invoked_skills";
pub const KEY_TASK_LEDGER = "task_ledger";
pub const KEY_COMPACT_CONTINUATION = "compact_continuation";
pub const KEY_USER_SKILL_SLASH = "user_skill_slash";
pub const KEY_RECOVERY_HINT = "recovery_hint";
pub const KEY_CRITICAL_REMINDER = "critical_reminder";
pub const KEY_USER_INTERRUPT = "user_interrupt";

pub const InjectedKind = enum {
    agent_notification,
    shell_completion,
    goal_continuation,
    plan_mode,
    /// 后台任务/子代理回流的通用通知
    background_result,
    /// 系统提醒（时间、目录变更）
    system_reminder,

    pub fn wireName(self: InjectedKind) []const u8 {
        return switch (self) {
            .agent_notification => "agent_notification",
            .shell_completion => "shell_completion",
            .goal_continuation => "goal_continuation",
            .plan_mode => "plan_mode",
            .background_result => "background_result",
            .system_reminder => "system_reminder",
        };
    }

    pub fn fromWire(s: []const u8) ?InjectedKind {
        inline for (@typeInfo(InjectedKind).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const SkillRef = struct { name: []const u8, loaded_from: []const u8 };

pub const Message = struct {
    role: MessageRole,
    content: []const ContentBlock,
    meta: Meta = .none,
    /// 未知字段留底（前向兼容：新版写入的字段，旧版读一遍不应丢）。
    extra: json.Object = .{},

    pub const Meta = union(enum) {
        none,
        /// 引擎注入（wire: `isMeta=true` + `type=<kind>`）
        engine_injected: InjectedKind,
        /// 已加载技能（压缩后需重放）
        invoked_skills: []const SkillRef,
        /// 任务账本
        task_ledger: []const u8,
        /// 压缩续接
        compact_continuation: []const u8,
        /// 用户 /skill 触发
        user_skill_slash: []const u8,
        /// 恢复提示（request-only，不进 transcript 链）
        recovery_hint: []const u8,
        /// 关键提醒（request-only）
        critical_reminder: []const u8,
        /// 用户中断
        user_interrupt: []const u8,

        /// 该 meta 是否只用于构造本次请求（不写入 transcript 链）。
        pub fn isRequestOnly(self: Meta) bool {
            return switch (self) {
                .recovery_hint, .critical_reminder => true,
                else => false,
            };
        }
    };

    // ── 静态工厂（文档 04 §4.3）─────────────────────────────────────────────

    // ⚠️ 工厂全部需要 `gpa`：`&.{block}` 会返回**悬垂指针**
    //    （匿名数组字面量是栈上临时量）。消息的 content 必须由调用方持有。
    pub fn user(gpa: Allocator, text: []const u8) Allocator.Error!Message {
        return .{ .role = .user, .content = try oneBlock(gpa, text) };
    }

    pub fn assistant(gpa: Allocator, blocks: []const ContentBlock) Allocator.Error!Message {
        return .{ .role = .assistant, .content = try gpa.dupe(ContentBlock, blocks) };
    }

    pub fn system(gpa: Allocator, text: []const u8) Allocator.Error!Message {
        return .{ .role = .system, .content = try oneBlock(gpa, text) };
    }

    /// role = USER + meta 标记
    pub fn engineInjected(gpa: Allocator, text: []const u8, kind: InjectedKind) Allocator.Error!Message {
        return .{
            .role = .user,
            .content = try oneBlock(gpa, text),
            .meta = .{ .engine_injected = kind },
        };
    }

    /// role = SYSTEM + meta 标记
    pub fn systemEvent(gpa: Allocator, text: []const u8, kind: InjectedKind) Allocator.Error!Message {
        return .{
            .role = .system,
            .content = try oneBlock(gpa, text),
            .meta = .{ .engine_injected = kind },
        };
    }

    /// role = USER + `compact_continuation` 标记 —— 压缩第三层的续接消息。
    ///
    /// 单独一个工厂（而不是复用 `engineInjected`）是因为 **meta 变体不同**：
    /// `engineInjected` 走 `.engine_injected`，本条走 `.compact_continuation`。
    ///
    /// 文档 08 §4.4 特意强调必须标记：这条消息是引擎替用户「起头」的，
    /// 不标记的话每次 auto-compact 之后它就成了「最后一条 user 消息」，
    /// preload 会把它当成用户请求。
    ///
    /// 调用方负责把它**插在保留段之前**（不是追加到末尾）。
    pub fn compactContinuation(gpa: Allocator, text: []const u8) Allocator.Error!Message {
        return .{
            .role = .user,
            .content = try oneBlock(gpa, text),
            .meta = .{ .compact_continuation = text },
        };
    }

    fn oneBlock(gpa: Allocator, text: []const u8) Allocator.Error![]const ContentBlock {
        const blocks = try gpa.alloc(ContentBlock, 1);
        blocks[0] = content.text(text);
        return blocks;
    }

    pub fn isEngineInjected(self: Message) bool {
        return self.meta != .none;
    }

    // ── 便捷读取 ────────────────────────────────────────────────────────────

    /// 拼接所有 text 块。
    pub fn textContent(self: Message, gpa: Allocator) Allocator.Error![]u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(gpa);
        for (self.content) |b| {
            if (b.asText()) |t| try out.appendSlice(gpa, t);
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn countToolUses(self: Message) usize {
        var n: usize = 0;
        for (self.content) |b| {
            if (b == .tool_use) n += 1;
        }
        return n;
    }

    pub fn firstToolUse(self: Message) ?ToolUseBlock {
        for (self.content) |b| {
            if (b.asToolUse()) |tu| return tu;
        }
        return null;
    }

    // ── 序列化（P2 手写）────────────────────────────────────────────────────

    pub fn toJson(self: Message, e: *json.Encoder) !void {
        try e.beginObject();
        try e.stringField("role", content.roleWireName(self.role));
        try e.key("content");
        try e.beginArray();
        for (self.content) |b| try b.toJson(e);
        try e.endArray();
        try self.metaToJson(e);
        // 未知字段写回（前向兼容）
        for (self.extra.entries.items) |entry| {
            try e.field(entry.key, entry.value);
        }
        try e.endObject();
    }

    fn metaToJson(self: Message, e: *json.Encoder) !void {
        switch (self.meta) {
            .none => {},
            .engine_injected => |k| {
                try e.boolField(KEY_IS_META, true);
                try e.stringField(KEY_TYPE, k.wireName());
            },
            .invoked_skills => |refs| {
                try e.boolField(KEY_IS_META, true);
                try e.stringField(KEY_TYPE, KEY_INVOKED_SKILLS);
                try e.key(KEY_INVOKED_SKILLS);
                try e.beginArray();
                for (refs) |r| {
                    try e.beginObject();
                    try e.stringField("name", r.name);
                    try e.stringField("loadedFrom", r.loaded_from);
                    try e.endObject();
                }
                try e.endArray();
            },
            .task_ledger => |v| {
                try e.boolField(KEY_IS_META, true);
                try e.stringField(KEY_TYPE, KEY_TASK_LEDGER);
                try e.stringField(KEY_TASK_LEDGER, v);
            },
            .compact_continuation => |v| {
                try e.boolField(KEY_IS_META, true);
                try e.stringField(KEY_TYPE, KEY_COMPACT_CONTINUATION);
                try e.stringField(KEY_COMPACT_CONTINUATION, v);
            },
            .user_skill_slash => |v| {
                try e.boolField(KEY_IS_META, true);
                try e.stringField(KEY_TYPE, KEY_USER_SKILL_SLASH);
                try e.stringField(KEY_USER_SKILL_SLASH, v);
            },
            .recovery_hint => |v| {
                try e.boolField(KEY_IS_META, true);
                try e.stringField(KEY_TYPE, KEY_RECOVERY_HINT);
                try e.stringField(KEY_RECOVERY_HINT, v);
            },
            .critical_reminder => |v| {
                try e.boolField(KEY_IS_META, true);
                try e.stringField(KEY_TYPE, KEY_CRITICAL_REMINDER);
                try e.stringField(KEY_CRITICAL_REMINDER, v);
            },
            .user_interrupt => |v| {
                try e.boolField(KEY_IS_META, true);
                try e.stringField(KEY_TYPE, KEY_USER_INTERRUPT);
                try e.stringField(KEY_USER_INTERRUPT, v);
            },
        }
    }

    pub fn fromJson(gpa: Allocator, v: json.Value) !Message {
        const role_str = v.getString("role") orelse return error.MissingRole;
        const role = content.roleFromWire(role_str) orelse return error.UnknownRole;

        var blocks = std.ArrayListUnmanaged(ContentBlock).empty;
        if (v.get("content")) |cv| {
            switch (cv) {
                .array => |arr| {
                    for (arr) |item| {
                        try blocks.append(gpa, try ContentBlock.fromJson(gpa, item));
                    }
                },
                .string => |s| {
                    // 兼容：content 直接是字符串的历史形态
                    try blocks.append(gpa, content.text(try gpa.dupe(u8, s)));
                },
                else => {},
            }
        }

        var extra = json.Object{};
        const known = [_][]const u8{
            "role",       "content",          KEY_IS_META,      KEY_TYPE,
            KEY_INVOKED_SKILLS, KEY_TASK_LEDGER, KEY_COMPACT_CONTINUATION,
            KEY_USER_SKILL_SLASH, KEY_RECOVERY_HINT, KEY_CRITICAL_REMINDER,
            KEY_USER_INTERRUPT,
        };
        for (v.object.entries.items) |entry| {
            var is_known = false;
            for (known) |k| {
                if (std.mem.eql(u8, entry.key, k)) {
                    is_known = true;
                    break;
                }
            }
            if (!is_known) {
                try extra.put(gpa, try gpa.dupe(u8, entry.key), entry.value);
            }
        }

        return .{
            .role = role,
            .content = try blocks.toOwnedSlice(gpa),
            .meta = try metaFromJson(gpa, v),
            .extra = extra,
        };
    }

    fn metaFromJson(gpa: Allocator, v: json.Value) !Meta {
        const is_meta = v.getBool(KEY_IS_META) orelse false;
        const type_str = v.getString(KEY_TYPE) orelse "";
        if (!is_meta and type_str.len == 0) return .none;

        if (std.mem.eql(u8, type_str, KEY_INVOKED_SKILLS)) {
            var refs = std.ArrayListUnmanaged(SkillRef).empty;
            if (v.getArray(KEY_INVOKED_SKILLS)) |arr| {
                for (arr) |item| {
                    try refs.append(gpa, .{
                        .name = try content.dupField(gpa, item, "name"),
                        .loaded_from = try content.dupFieldOr(gpa, item, "loadedFrom", ""),
                    });
                }
            }
            return .{ .invoked_skills = try refs.toOwnedSlice(gpa) };
        }
        if (std.mem.eql(u8, type_str, KEY_TASK_LEDGER))
            return .{ .task_ledger = try content.dupField(gpa, v, KEY_TASK_LEDGER) };
        if (std.mem.eql(u8, type_str, KEY_COMPACT_CONTINUATION))
            return .{ .compact_continuation = try content.dupField(gpa, v, KEY_COMPACT_CONTINUATION) };
        if (std.mem.eql(u8, type_str, KEY_USER_SKILL_SLASH))
            return .{ .user_skill_slash = try content.dupField(gpa, v, KEY_USER_SKILL_SLASH) };
        if (std.mem.eql(u8, type_str, KEY_RECOVERY_HINT))
            return .{ .recovery_hint = try content.dupField(gpa, v, KEY_RECOVERY_HINT) };
        if (std.mem.eql(u8, type_str, KEY_CRITICAL_REMINDER))
            return .{ .critical_reminder = try content.dupField(gpa, v, KEY_CRITICAL_REMINDER) };
        if (std.mem.eql(u8, type_str, KEY_USER_INTERRUPT))
            return .{ .user_interrupt = try content.dupField(gpa, v, KEY_USER_INTERRUPT) };

        if (InjectedKind.fromWire(type_str)) |kind| {
            return .{ .engine_injected = kind };
        }
        // 未知 type：保留为 none（不 panic，前向兼容）
        return .none;
    }
};

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn roundTrip(gpa: Allocator, m: Message) ![]u8 {
    var e = json.Encoder.init(gpa);
    defer e.deinit();
    try m.toJson(&e);
    return gpa.dupe(u8, e.text());
}

test "message: 普通用户消息往返" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try roundTrip(a, try Message.user(a, "你好"));
    const v = try json.parse(a, s);
    const m = try Message.fromJson(a, v);
    try testing.expectEqual(MessageRole.user, m.role);
    try testing.expectEqualStrings("你好", m.content[0].asText().?);
}

test "message: isMeta / type 键名原样保留" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try Message.engineInjected(a, "通知", .agent_notification);
    const s = try roundTrip(a, m);
    try testing.expect(std.mem.indexOf(u8, s, "\"isMeta\":true") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"type\":\"agent_notification\"") != null);

    const v = try json.parse(a, s);
    const back = try Message.fromJson(a, v);
    try testing.expectEqual(InjectedKind.agent_notification, back.meta.engine_injected);
    try testing.expect(back.isEngineInjected());
}

test "message: invoked_skills 往返" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try Message.user(a, "x");
    m.meta = .{ .invoked_skills = &.{.{ .name = "writing", .loaded_from = "/skills/writing" }} };
    const s = try roundTrip(a, m);
    const back = try Message.fromJson(a, try json.parse(a, s));
    try testing.expectEqualStrings("writing", back.meta.invoked_skills[0].name);
}

test "message: 未知字段保留" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"futureKey\":{\"a\":1}}";
    const m = try Message.fromJson(a, try json.parse(a, src));
    const s = try roundTrip(a, m);
    try testing.expect(std.mem.indexOf(u8, s, "futureKey") != null);
}

test "message: request-only 标记" {
    try testing.expect((Message.Meta{ .recovery_hint = "x" }).isRequestOnly());
    try testing.expect(!(Message.Meta{ .task_ledger = "x" }).isRequestOnly());
}

test "message: Meta switch 穷尽性守卫" {
    // 这个测试的价值在于：新增 Meta 变体时，下面的 switch 会编译失败。
    const m = try Message.user(testing.allocator, "x");
    defer testing.allocator.free(m.content);
    const n: u32 = switch (m.meta) {
        .none => 0,
        .engine_injected => 1,
        .invoked_skills => 2,
        .task_ledger => 3,
        .compact_continuation => 4,
        .user_skill_slash => 5,
        .recovery_hint => 6,
        .critical_reminder => 7,
        .user_interrupt => 8,
    };
    try testing.expectEqual(@as(u32, 0), n);
}
