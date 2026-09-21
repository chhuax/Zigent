//! `client_proto/acp.zig` —— 传输 B：ACP（Agent Client Protocol）。
//!
//! ## 两条最容易做错的契约
//!
//! 1. **帧格式是 NDJSON，不是 LSP 的 `Content-Length` 头。**（雷区 H）
//! 2. **`session/load` 的 transcript 回放通知必须先于 load 响应** ——
//!    否则客户端会把回放当成实时 update 二次入库。
//!
//! `session/update` 的子类型里，**某些事件映射为 null 表示"不发通知"**
//! （不能改成发空对象）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");

pub const PROTOCOL_VERSION: i32 = 1;
pub const JSONRPC = "2.0";

/// 方法名（**已注册的 12 个**，不是旧文档说的 15 个 —— 雷区 L）。
pub const Method = enum {
    initialize,
    @"session/new",
    @"session/list",
    @"session/load",
    @"session/resume",
    @"session/fork",
    @"session/prompt",
    @"session/cancel",
    @"session/close",
    @"session/set_mode",
    @"session/set_model",
    @"session/set_config_option",

    pub fn wireName(self: Method) []const u8 {
        return switch (self) {
            .initialize => "initialize",
            .@"session/new" => "session/new",
            .@"session/list" => "session/list",
            .@"session/load" => "session/load",
            .@"session/resume" => "session/resume",
            .@"session/fork" => "session/fork",
            .@"session/prompt" => "session/prompt",
            .@"session/cancel" => "session/cancel",
            .@"session/close" => "session/close",
            .@"session/set_mode" => "session/set_mode",
            .@"session/set_model" => "session/set_model",
            .@"session/set_config_option" => "session/set_config_option",
        };
    }

    pub fn fromWire(s: []const u8) ?Method {
        inline for (@typeInfo(Method).@"enum".fields) |f| {
            const v: Method = @enumFromInt(f.value);
            if (std.mem.eql(u8, s, v.wireName())) return v;
        }
        return null;
    }
};

pub const Message = union(enum) {
    request: Request,
    notification: Notification,
    response: Response,
    /// 不认识的一律忽略（前向兼容）
    unknown,

    pub const Request = struct {
        id: []const u8,
        method: []const u8,
        params_json: []const u8,
    };
    pub const Notification = struct {
        method: []const u8,
        params_json: []const u8,
    };
    pub const Response = struct {
        id: []const u8,
        result_json: []const u8,
        error_code: ?i64 = null,
        error_message: ?[]const u8 = null,
    };
};

/// 解析一行 NDJSON。
pub fn parseMessage(arena: Allocator, line: []const u8) !Message {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return .unknown;
    const v = common.json.parse(arena, trimmed) catch return .unknown;

    // id 可以是数字或字符串 → 统一成字符串
    var id: []const u8 = "";
    var has_id = false;
    if (v.get("id")) |iv| {
        has_id = true;
        id = switch (iv) {
            .string => |s| try arena.dupe(u8, s),
            .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
            else => "",
        };
    }

    if (v.getString("method")) |method| {
        const params = if (v.object.getRaw("params")) |raw| try arena.dupe(u8, raw) else "{}";
        if (has_id) {
            return .{ .request = .{ .id = id, .method = try arena.dupe(u8, method), .params_json = params } };
        }
        return .{ .notification = .{ .method = try arena.dupe(u8, method), .params_json = params } };
    }

    if (v.get("result") != null or v.get("error") != null) {
        const result = if (v.object.getRaw("result")) |raw| try arena.dupe(u8, raw) else "null";
        var code: ?i64 = null;
        var msg: ?[]const u8 = null;
        if (v.get("error")) |e| {
            code = e.getInt("code");
            if (e.getString("message")) |m| msg = try arena.dupe(u8, m);
        }
        return .{ .response = .{ .id = id, .result_json = result, .error_code = code, .error_message = msg } };
    }
    return .unknown;
}

pub fn encodeRequest(gpa: Allocator, id: []const u8, method: []const u8, params_json: []const u8) Allocator.Error![]u8 {
    var e = common.json.Encoder.init(gpa);
    errdefer e.deinit();
    try e.beginObject();
    try e.stringField("jsonrpc", JSONRPC);
    try e.stringField("id", id);
    try e.stringField("method", method);
    try e.key("params");
    try e.raw(params_json);
    try e.endObject();
    try e.out.append(gpa, '\n');
    return e.toOwnedSlice();
}

pub fn encodeNotification(gpa: Allocator, method: []const u8, params_json: []const u8) Allocator.Error![]u8 {
    var e = common.json.Encoder.init(gpa);
    errdefer e.deinit();
    try e.beginObject();
    try e.stringField("jsonrpc", JSONRPC);
    try e.stringField("method", method);
    try e.key("params");
    try e.raw(params_json);
    try e.endObject();
    try e.out.append(gpa, '\n');
    return e.toOwnedSlice();
}

pub fn encodeResult(gpa: Allocator, id: []const u8, result_json: []const u8) Allocator.Error![]u8 {
    var e = common.json.Encoder.init(gpa);
    errdefer e.deinit();
    try e.beginObject();
    try e.stringField("jsonrpc", JSONRPC);
    try e.stringField("id", id);
    try e.key("result");
    try e.raw(result_json);
    try e.endObject();
    try e.out.append(gpa, '\n');
    return e.toOwnedSlice();
}

pub fn encodeError(gpa: Allocator, id: []const u8, code: i64, message: []const u8) Allocator.Error![]u8 {
    var e = common.json.Encoder.init(gpa);
    errdefer e.deinit();
    try e.beginObject();
    try e.stringField("jsonrpc", JSONRPC);
    try e.stringField("id", id);
    try e.key("error");
    try e.beginObject();
    try e.intField("code", code);
    try e.stringField("message", message);
    try e.endObject();
    try e.endObject();
    try e.out.append(gpa, '\n');
    return e.toOwnedSlice();
}

/// `initialize` 的版本协商：返回 `min(client, supported)`。
pub fn negotiateVersion(client_version: i32) i32 {
    return @min(client_version, PROTOCOL_VERSION);
}

/// `session/load` 的**回放顺序**保证。
///
/// 契约：所有 transcript 回放通知必须先于 load 响应。
/// 这里用一个小的有序写入器把这件事变成**结构性**的，而不是靠调用顺序的记忆。
pub const LoadSequencer = struct {
    gpa: Allocator,
    replay_lines: std.ArrayListUnmanaged([]u8) = .empty,
    /// 是否已经写过响应
    responded: bool = false,
    pub fn init(gpa: Allocator) LoadSequencer {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *LoadSequencer) void {
        for (self.replay_lines.items) |l| self.gpa.free(l);
        self.replay_lines.deinit(self.gpa);
    }
    /// 记录一条回放通知（**必须在 respond 之前调用**）。
    pub fn replay(self: *LoadSequencer, line: []u8) !void {
        std.debug.assert(!self.responded); // 违反顺序 = 契约破坏
        try self.replay_lines.append(self.gpa, line);
    }
    /// 产出完整的写出序列：先全部回放，再响应。
    pub fn finish(self: *LoadSequencer, result_json: []const u8) ![]u8 {
        self.responded = true;
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(self.gpa);
        for (self.replay_lines.items) |l| try out.appendSlice(self.gpa, l);
        const resp = try encodeResult(self.gpa, "load", result_json);
        defer self.gpa.free(resp);
        try out.appendSlice(self.gpa, resp);
        return out.toOwnedSlice(self.gpa);
    }
};

/// `session/update` 子类型 → 要不要发通知。
/// **映射为 null 表示"不发通知"**，不能改成发空对象。
pub fn updateSubtypeFor(ev: common.StreamEvent) ?[]const u8 {
    return switch (ev) {
        .text_delta => "agent_message_chunk",
        .reasoning_delta => "agent_thought_chunk",
        .tool_call => "tool_call",
        .tool_progress => "tool_call_update",
        .tool_result => "tool_call_update",
        // 心跳/内部事件在 ACP 下**刻意不发通知**
        .status => null,
        .incremental_usage => null,
        .cache_invalidation => null,
        else => "session_info_update",
    };
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "acp: 12 个已注册方法" {
    try testing.expectEqual(@as(usize, 12), @typeInfo(Method).@"enum".fields.len);
    try testing.expectEqual(Method.@"session/load", Method.fromWire("session/load").?);
}

test "acp: 解析 request / notification / response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const req = try parseMessage(a, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"session/new\",\"params\":{\"cwd\":\"/repo\"}}");
    try testing.expectEqualStrings("7", req.request.id);
    try testing.expectEqualStrings("session/new", req.request.method);
    try testing.expect(std.mem.indexOf(u8, req.request.params_json, "/repo") != null);

    const notif = try parseMessage(a, "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{}}");
    try testing.expectEqualStrings("session/cancel", notif.notification.method);

    const resp = try parseMessage(a, "{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"result\":{\"ok\":true}}");
    try testing.expectEqualStrings("x", resp.response.id);
    try testing.expect(std.mem.indexOf(u8, resp.response.result_json, "ok") != null);
}

test "acp: 错误响应带 code 与 message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = try parseMessage(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"method not found\"}}");
    try testing.expectEqual(@as(i64, -32601), m.response.error_code.?);
    try testing.expectEqualStrings("method not found", m.response.error_message.?);
}

test "acp: 帧格式是 NDJSON（不带 Content-Length）" {
    const line = try encodeRequest(testing.allocator, "1", "initialize", "{\"protocolVersion\":1}");
    defer testing.allocator.free(line);
    try testing.expect(std.mem.endsWith(u8, line, "\n"));
    try testing.expect(std.mem.indexOf(u8, line, "Content-Length") == null);
    try testing.expect(std.mem.indexOf(u8, line, "\"jsonrpc\":\"2.0\"") != null);
}

test "acp: 版本协商取 min" {
    try testing.expectEqual(@as(i32, 1), negotiateVersion(1));
    try testing.expectEqual(@as(i32, 1), negotiateVersion(9));
    try testing.expectEqual(@as(i32, 0), negotiateVersion(0));
}

test "acp: session/load 回放必须先于响应" {
    var seq = LoadSequencer.init(testing.allocator);
    defer seq.deinit();
    try seq.replay(try testing.allocator.dupe(u8, "{\"method\":\"session/update\",\"params\":{\"n\":1}}\n"));
    try seq.replay(try testing.allocator.dupe(u8, "{\"method\":\"session/update\",\"params\":{\"n\":2}}\n"));
    const out = try seq.finish("{\"sessionId\":\"s\"}");
    defer testing.allocator.free(out);
    const idx1 = std.mem.indexOf(u8, out, "\"n\":1").?;
    const idx2 = std.mem.indexOf(u8, out, "\"n\":2").?;
    const iresp = std.mem.indexOf(u8, out, "\"result\"").?;
    try testing.expect(idx1 < idx2);
    try testing.expect(idx2 < iresp);
}

test "acp: 某些 session/update 子类型刻意不发通知（null）" {
    const ev: common.StreamEvent = .{ .status = .{ .message = "x" } };
    try testing.expect(updateSubtypeFor(ev) == null);
    const text: common.StreamEvent = .{ .text_delta = .{ .text = "x" } };
    try testing.expectEqualStrings("agent_message_chunk", updateSubtypeFor(text).?);
}
