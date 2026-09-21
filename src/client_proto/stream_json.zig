//! `client_proto/stream_json.zig` —— 传输 A：`stream-json`（**NDJSON**）。
//!
//! 面向 TUI / Agent SDK / CI。字段面最全，与 `claude` 的 stream-json 对齐。
//!
//! 启动后**第一行必为 `system/init`**，含 `protocol_version`；
//! 客户端应在收到 init 前不发送任何请求（文档 06 §2）。
//!
//! 输入行形态（文档 06 §4.2）：
//! ```json
//! {"type":"user","message":{"role":"user","content":"…"}}
//! ```
//! 控制请求：
//! ```json
//! {"type":"control_request","subtype":"interrupt"}
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");

pub const PROTOCOL_VERSION: i32 = 1;

/// 编码一行 NDJSON（**带结尾换行**，NDJSON 的"行"就是帧）。
pub fn encodeLine(gpa: Allocator, env: common.Envelope) Allocator.Error![]u8 {
    var e = common.json.Encoder.init(gpa);
    errdefer e.deinit();
    try env.toJson(&e);
    try e.out.append(gpa, '\n');
    return e.toOwnedSlice();
}

/// `system/init` 首行。
pub fn initLine(
    gpa: Allocator,
    session_id: []const u8,
    cwd: []const u8,
    model: []const u8,
    tools: []const []const u8,
) Allocator.Error![]u8 {
    var e = common.json.Encoder.init(gpa);
    errdefer e.deinit();
    try e.beginObject();
    try e.stringField("type", "system");
    try e.stringField("subtype", "init");
    try e.intField("protocol_version", PROTOCOL_VERSION);
    try e.stringField("session_id", session_id);
    try e.stringField("cwd", cwd);
    try e.stringField("model", model);
    try e.key("tools");
    try e.beginArray();
    for (tools) |t| try e.string(t);
    try e.endArray();
    try e.stringField("permission_mode", "ASK");
    try e.endObject();
    try e.out.append(gpa, '\n');
    return e.toOwnedSlice();
}

pub const InputKind = enum { user_message, control_request, permission_response, unknown };

pub const Input = struct {
    kind: InputKind,
    /// user_message 的文本
    text: []const u8 = "",
    /// control_request 的 subtype（interrupt / set_permission_mode / set_model / set_config_option）
    subtype: []const u8 = "",
    /// permission_response 的字段
    request_id: []const u8 = "",
    option_id: []const u8 = "",

    pub fn isInterrupt(self: Input) bool {
        return self.kind == .control_request and std.mem.eql(u8, self.subtype, "interrupt");
    }
};

/// 解析一行输入（**未知 type 不报错** —— 前向兼容）。
pub fn parseInput(arena: Allocator, line: []const u8) !Input {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return .{ .kind = .unknown };
    const v = common.json.parse(arena, trimmed) catch return .{ .kind = .unknown };
    const t = v.getString("type") orelse return .{ .kind = .unknown };

    if (std.mem.eql(u8, t, "user")) {
        var text: []const u8 = "";
        if (v.get("message")) |m| {
            if (m.getString("content")) |c| {
                text = c;
            } else if (m.get("content")) |c| {
                if (c == .array) {
                    // 多块内容：拼 text 块
                    var out = std.ArrayListUnmanaged(u8).empty;
                    for (c.array) |blk| {
                        if (blk.getString("text")) |x| try out.appendSlice(arena, x);
                    }
                    text = try out.toOwnedSlice(arena);
                }
            }
        } else if (v.getString("content")) |c| {
            text = c;
        }
        return .{ .kind = .user_message, .text = try arena.dupe(u8, text) };
    }
    if (std.mem.eql(u8, t, "control_request")) {
        return .{ .kind = .control_request, .subtype = try arena.dupe(u8, v.getString("subtype") orelse "") };
    }
    if (std.mem.eql(u8, t, "permission_response") or std.mem.eql(u8, t, "control_response")) {
        return .{
            .kind = .permission_response,
            .request_id = try arena.dupe(u8, v.getString("request_id") orelse ""),
            .option_id = try arena.dupe(u8, v.getString("option_id") orelse ""),
        };
    }
    return .{ .kind = .unknown };
}

/// `stopReason` 取值（契约，文档 06 §4.2）。
pub fn stopReasonWire(r: common.StopReason) []const u8 {
    return r.wireName();
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "stream_json: init 首行含协议版本" {
    const line = try initLine(testing.allocator, "s1", "/repo", "claude-sonnet-4", &.{ "Read", "Bash" });
    defer testing.allocator.free(line);
    try testing.expect(std.mem.endsWith(u8, line, "\n"));
    try testing.expect(std.mem.indexOf(u8, line, "\"protocol_version\":1") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"subtype\":\"init\"") != null);
}

test "stream_json: 解析用户消息（字符串内容）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const in = try parseInput(arena.allocator(), "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"你好\"}}");
    try testing.expectEqual(InputKind.user_message, in.kind);
    try testing.expectEqualStrings("你好", in.text);
}

test "stream_json: 解析用户消息（内容块数组）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const in = try parseInput(arena.allocator(), "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"a\"},{\"type\":\"text\",\"text\":\"b\"}]}}");
    try testing.expectEqualStrings("ab", in.text);
}

test "stream_json: 中断控制请求" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const in = try parseInput(arena.allocator(), "{\"type\":\"control_request\",\"subtype\":\"interrupt\"}");
    try testing.expect(in.isInterrupt());
}

test "stream_json: 未知 type 不报错" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const in = try parseInput(arena.allocator(), "{\"type\":\"future_thing\"}");
    try testing.expectEqual(InputKind.unknown, in.kind);
    const bad = try parseInput(arena.allocator(), "not json");
    try testing.expectEqual(InputKind.unknown, bad.kind);
}

test "stream_json: 编码一行是合法 NDJSON（以换行结尾）" {
    const env = common.Envelope{
        .uuid = "u1",
        .session_id = "s1",
        .timestamp = "T",
        .event = .{ .text_delta = .{ .text = "hi" } },
    };
    const line = try encodeLine(testing.allocator, env);
    defer testing.allocator.free(line);
    try testing.expect(std.mem.endsWith(u8, line, "\n"));
    try testing.expect(std.mem.indexOf(u8, line, "\"type\":\"text_delta\"") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
}

test "stream_json: stopReason 取值与契约一致" {
    try testing.expectEqualStrings("end_turn", stopReasonWire(.end_turn));
    try testing.expectEqualStrings("cancelled", stopReasonWire(.cancelled));
    try testing.expectEqualStrings("max_turn_requests", stopReasonWire(.max_turn_requests));
    try testing.expectEqualStrings("refusal", stopReasonWire(.refusal));
    try testing.expectEqualStrings("tool_repeated_failure", stopReasonWire(.tool_repeated_failure));
}
