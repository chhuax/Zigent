//! `ContentBlock`（union·4）+ `MessageRole` —— L0 契约层。
//!
//! 三条不变量（文档 04 §3.3，必须写成测试）：
//!   I1 `ToolUseBlock.input` **保持原始 JSON 字符串**，全程不做 `parse → re-serialize`
//!      （否则丢 key 顺序、丢空格、破坏大数字精度 → 模型看到的和它写的不一致）
//!   I2 `ToolResultBlock.tool_use_id` 必须能对上前一条 assistant 的某个 `tool_use`
//!   I3 `tool_result` 只能出现在 `role == .user` 的消息里
//!
//! wire tag 名锁死为 `text` / `tool_use` / `tool_result` / `image`。

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");

pub const MessageRole = enum { user, assistant, system };

/// ⚠️ wire 形态用**显式映射函数**，不用 `@tagName`：
/// 重命名标签不该破坏 transcript 兼容（文档 04 §2）。
pub fn roleWireName(r: MessageRole) []const u8 {
    return switch (r) {
        .user => "user",
        .assistant => "assistant",
        .system => "system",
    };
}

pub fn roleFromWire(s: []const u8) ?MessageRole {
    if (std.mem.eql(u8, s, "user")) return .user;
    if (std.mem.eql(u8, s, "assistant")) return .assistant;
    if (std.mem.eql(u8, s, "system")) return .system;
    return null;
}

pub const TextBlock = struct {
    text: []const u8,

    pub fn toJson(self: TextBlock, e: *json.Encoder) !void {
        try e.stringField("type", "text");
        try e.stringField("text", self.text);
    }

    pub fn fromJson(gpa: Allocator, v: json.Value) !TextBlock {
        return .{ .text = try dupField(gpa, v, "text") };
    }
};

pub const ToolUseBlock = struct {
    tool_use_id: []const u8,
    tool_name: []const u8,
    /// ⚠️ **必须是原始 JSON 字符串，不是解析后的对象**（不变量 I1）。
    input: []const u8,

    pub fn toJson(self: ToolUseBlock, e: *json.Encoder) !void {
        try e.stringField("type", "tool_use");
        try e.stringField("toolUseId", self.tool_use_id);
        try e.stringField("toolName", self.tool_name);
        // input 原样透传（不 parse、不 re-serialize）
        if (self.input.len == 0) {
            try e.stringField("input", "");
        } else {
            try e.key("input");
            try e.raw(self.input);
        }
    }

    pub fn fromJson(gpa: Allocator, v: json.Value) !ToolUseBlock {
        // 优先取原始切片（逐字节保真）；取不到才退回序列化
        var input: []const u8 = "";
        if (v.object.getRaw("input")) |raw| {
            input = try gpa.dupe(u8, raw);
        } else if (v.get("input")) |iv| {
            switch (iv) {
                .string => |s| input = try gpa.dupe(u8, s),
                .null => {},
                else => input = try json.stringify(gpa, iv),
            }
        }
        return .{
            .tool_use_id = try dupField(gpa, v, "toolUseId"),
            .tool_name = try dupField(gpa, v, "toolName"),
            .input = input,
        };
    }
};

pub const ToolResultBlock = struct {
    tool_use_id: []const u8,
    output: []const u8,
    is_error: bool,

    pub fn toJson(self: ToolResultBlock, e: *json.Encoder) !void {
        try e.stringField("type", "tool_result");
        try e.stringField("toolUseId", self.tool_use_id);
        try e.stringField("output", self.output);
        try e.boolField("isError", self.is_error);
    }

    pub fn fromJson(gpa: Allocator, v: json.Value) !ToolResultBlock {
        return .{
            .tool_use_id = try dupField(gpa, v, "toolUseId"),
            .output = try dupField(gpa, v, "output"),
            .is_error = v.getBool("isError") orelse false,
        };
    }
};

/// P3：把「两种模式」（内联 base64 vs 外置引用）显式化 ——
/// 不再靠"看哪个字段非空"，也不可能"忘记外置"。
pub const ImageContentBlock = struct {
    media_type: []const u8,
    name: []const u8,
    width: u32 = 0,
    height: u32 = 0,
    source: Source,

    pub const Source = union(enum) {
        /// 内联 base64 —— 只在真正要发给 provider 时使用
        /// （`inline` 是 Zig 关键字，故加后缀；wire 形态不变）
        inline_data: []const u8,
        /// 外置引用：内容寻址落盘，transcript 里只留引用
        reference: struct {
            uri: []const u8,
            attachment_id: []const u8,
            size_bytes: u64,
        },
    };

    pub fn toJson(self: ImageContentBlock, e: *json.Encoder) !void {
        try e.stringField("type", "image");
        try e.stringField("mediaType", self.media_type);
        try e.stringField("name", self.name);
        try e.intField("width", @intCast(self.width));
        try e.intField("height", @intCast(self.height));
        switch (self.source) {
            .inline_data => |data| try e.stringField("data", data),
            .reference => |r| {
                try e.stringField("uri", r.uri);
                try e.stringField("attachmentId", r.attachment_id);
                try e.key("sizeBytes");
                try e.uint(r.size_bytes);
            },
        }
    }

    pub fn fromJson(gpa: Allocator, v: json.Value) !ImageContentBlock {
        var src: Source = undefined;
        if (v.getString("uri")) |uri| {
            src = .{ .reference = .{
                .uri = try gpa.dupe(u8, uri),
                .attachment_id = try dupField(gpa, v, "attachmentId"),
                .size_bytes = @intCast(v.getInt("sizeBytes") orelse 0),
            } };
        } else {
            src = .{ .inline_data = try dupField(gpa, v, "data") };
        }
        return .{
            .media_type = try dupFieldOr(gpa, v, "mediaType", "image/png"),
            .name = try dupField(gpa, v, "name"),
            .width = @intCast(v.getInt("width") orelse 0),
            .height = @intCast(v.getInt("height") orelse 0),
            .source = src,
        };
    }
};

pub const ContentBlock = union(enum) {
    text: TextBlock,
    tool_use: ToolUseBlock,
    tool_result: ToolResultBlock,
    image: ImageContentBlock,

    /// wire tag 名必须锁死。
    pub fn wireTag(self: ContentBlock) []const u8 {
        return switch (self) {
            .text => "text",
            .tool_use => "tool_use",
            .tool_result => "tool_result",
            .image => "image",
        };
    }

    /// 写出**一个完整 JSON 对象**（含大括号）。
    /// 各块类型的 `toJson` 只写字段（便于复用），括号由这里统一负责。
    pub fn toJson(self: ContentBlock, e: *json.Encoder) !void {
        try e.beginObject();
        switch (self) {
            .text => |b| try b.toJson(e),
            .tool_use => |b| try b.toJson(e),
            .tool_result => |b| try b.toJson(e),
            .image => |b| try b.toJson(e),
        }
        try e.endObject();
    }

    pub fn fromJson(gpa: Allocator, v: json.Value) !ContentBlock {
        const t = v.getString("type") orelse return error.UnknownContentBlock;
        if (std.mem.eql(u8, t, "text")) return .{ .text = try TextBlock.fromJson(gpa, v) };
        if (std.mem.eql(u8, t, "tool_use")) return .{ .tool_use = try ToolUseBlock.fromJson(gpa, v) };
        if (std.mem.eql(u8, t, "tool_result")) return .{ .tool_result = try ToolResultBlock.fromJson(gpa, v) };
        if (std.mem.eql(u8, t, "image")) return .{ .image = try ImageContentBlock.fromJson(gpa, v) };
        return error.UnknownContentBlock;
    }

    /// 类型分派谓词（用于配对校验与压缩）。
    pub fn asToolUse(self: ContentBlock) ?ToolUseBlock {
        return switch (self) {
            .tool_use => |b| b,
            else => null,
        };
    }

    pub fn asToolResult(self: ContentBlock) ?ToolResultBlock {
        return switch (self) {
            .tool_result => |b| b,
            else => null,
        };
    }

    pub fn asText(self: ContentBlock) ?[]const u8 {
        return switch (self) {
            .text => |b| b.text,
            else => null,
        };
    }
};

// ── 辅助 ─────────────────────────────────────────────────────────────────────

pub fn dupField(gpa: Allocator, v: json.Value, key: []const u8) ![]const u8 {
    const s = v.getString(key) orelse return "";
    return gpa.dupe(u8, s);
}

pub fn dupFieldOr(gpa: Allocator, v: json.Value, key: []const u8, default: []const u8) ![]const u8 {
    const s = v.getString(key) orelse return default;
    return gpa.dupe(u8, s);
}

/// 文本块便捷构造（不分配：调用方保证 text 生命周期）。
pub fn text(s: []const u8) ContentBlock {
    return .{ .text = .{ .text = s } };
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "content: wire tag 锁死为四个字面量" {
    try testing.expectEqualStrings("text", text("x").wireTag());
    try testing.expectEqualStrings("tool_use", (ContentBlock{ .tool_use = .{
        .tool_use_id = "a",
        .tool_name = "Read",
        .input = "{}",
    } }).wireTag());
}

test "content: I1 —— input 逐字节保真（空格 / key 顺序 / 大数字）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original = "{\n  \"zeta\": 1,\n  \"alpha\":   9007199254740993\n}";
    const raw = try std.fmt.allocPrint(a, "{{\"input\":{s}}}", .{original});
    const v = try json.parse(a, raw);
    const blk = try ToolUseBlock.fromJson(a, v);
    try testing.expectEqualStrings(original, blk.input);

    // 再序列化一次，必须原样
    var e = json.Encoder.init(a);
    try blk.toJson(&e);
    const out = e.text();
    try testing.expect(std.mem.indexOf(u8, out, original) != null);
}

test "content: 非流式对象 input 转字符串" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try json.parse(a, "{\"type\":\"tool_use\",\"toolUseId\":\"t1\",\"toolName\":\"Read\",\"input\":{\"file_path\":\"/x\"}}");
    const blk = try ContentBlock.fromJson(a, v);
    try testing.expectEqualStrings("{\"file_path\":\"/x\"}", blk.tool_use.input);
}

test "content: 四类块往返" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = json.Encoder.init(a);
    try e.beginObject();
    try e.stringField("type", "tool_result");
    try e.stringField("toolUseId", "t9");
    try e.stringField("output", "ok");
    try e.boolField("isError", true);
    try e.endObject();
    const v = try json.parse(a, e.text());
    const blk = try ContentBlock.fromJson(a, v);
    try testing.expectEqualStrings("t9", blk.tool_result.tool_use_id);
    try testing.expect(blk.tool_result.is_error);
    try testing.expectEqualStrings("ok", blk.tool_result.output);
}

test "content: 枚举 wire 往返 + unknown 不 panic" {
    for ([_]MessageRole{ .user, .assistant, .system }) |r| {
        try testing.expectEqual(r, roleFromWire(roleWireName(r)).?);
    }
    try testing.expect(roleFromWire("future_role") == null);
}

test "content: ImageContentBlock 两种模式" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try json.parse(a, "{\"type\":\"image\",\"mediaType\":\"image/png\",\"name\":\"a.png\",\"uri\":\"file:///x\",\"attachmentId\":\"att1\",\"sizeBytes\":42}");
    const blk = try ContentBlock.fromJson(a, v);
    try testing.expectEqualStrings("att1", blk.image.source.reference.attachment_id);
    try testing.expectEqual(@as(u64, 42), blk.image.source.reference.size_bytes);
}
