//! `server/sse.zig` —— SSE **写出侧**（契约见 spike `sse_writer.zig` 的 10 个测试）。
//!
//! 四条硬约束：
//!   1. **`Content-Length` 必须缺席** —— 有它就无法真流式（浏览器会等满）；
//!   2. 多行 data **必须拆成多个 `data:` 行**（一个 `data:` 里的裸换行会破坏分帧）；
//!   3. 心跳用**注释帧** `: ping`（客户端解析器天然忽略，且不算一次事件）；
//!   4. **鉴权失败绝不能先写 SSE 头** —— 否则客户端拿到 200 空流而无法诊断。
//!
//! 心跳周期：**15 秒**（文档 06 §8）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const common = @import("common");

pub const HEARTBEAT_MS: u64 = 15_000;
pub const CONTENT_TYPE = "text/event-stream; charset=utf-8";

/// 把一段文本按 SSE 规则写成 `data:` 行（多行拆分；每行一个 `data:`）。
pub fn writeDataLines(out: *std.ArrayListUnmanaged(u8), gpa: Allocator, text: []const u8) Allocator.Error!void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        try out.appendSlice(gpa, "data: ");
        try out.appendSlice(gpa, trimmed);
        try out.appendSlice(gpa, "\n");
    }
}

/// 组装一个完整的 SSE 事件帧（含结尾空行 = 提交）。
pub fn encodeEvent(
    gpa: Allocator,
    event_name: ?[]const u8,
    data: []const u8,
) Allocator.Error![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(gpa);
    if (event_name) |n| {
        try out.appendSlice(gpa, "event: ");
        try out.appendSlice(gpa, n);
        try out.append(gpa, '\n');
    }
    try writeDataLines(&out, gpa, data);
    try out.append(gpa, '\n');
    return out.toOwnedSlice(gpa);
}

/// 注释帧（心跳）—— **不算一次事件**。
pub fn encodeComment(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, ": {s}\n\n", .{text});
}

pub fn encodePing(gpa: Allocator) Allocator.Error![]u8 {
    return encodeComment(gpa, "ping");
}

pub const SseWriter = struct {
    io: Io,
    stream: std.Io.net.Stream,
    writer: std.Io.net.Stream.Writer,

    /// 写 SSE 响应头。**Content-Length 刻意缺席。**
    ///
    /// `buf` 必须是调用方持有的缓冲，且**生命周期覆盖整个 `SseWriter`**
    /// （Writer 内部只保存这个切片的指针）。
    pub fn begin(io: Io, stream: std.Io.net.Stream, buf: []u8) !SseWriter {
        var self = SseWriter{
            .io = io,
            .stream = stream,
            .writer = stream.writer(io, buf),
        };
        const w = &self.writer.interface;
        try w.writeAll("HTTP/1.1 200 OK\r\n");
        try w.writeAll("Content-Type: " ++ CONTENT_TYPE ++ "\r\n");
        try w.writeAll("Cache-Control: no-cache, no-transform\r\n");
        try w.writeAll("Connection: keep-alive\r\n");
        try w.writeAll("X-Accel-Buffering: no\r\n");
        try w.writeAll("X-Zigent-Protocol: 1\r\n");
        // ⚠️ 这里绝不写 Content-Length
        try w.writeAll("\r\n");
        try w.flush();
        return self;
    }

    pub fn send(self: *SseWriter, event_name: ?[]const u8, data: []const u8) !void {
        var buf: [64 << 10]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const frame = encodeEvent(fba.allocator(), event_name, data) catch {
            // 超大帧：分块发（仍然保持分帧正确性由 sendChunked 保证）
            return self.sendLarge(event_name, data);
        };
        try self.writer.interface.writeAll(frame);
        try self.writer.interface.flush();
    }

    fn sendLarge(self: *SseWriter, event_name: ?[]const u8, data: []const u8) !void {
        const w = &self.writer.interface;
        if (event_name) |n| {
            try w.writeAll("event: ");
            try w.writeAll(n);
            try w.writeAll("\n");
        }
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            try w.writeAll("data: ");
            try w.writeAll(std.mem.trimEnd(u8, line, "\r"));
            try w.writeAll("\n");
        }
        try w.writeAll("\n");
        try w.flush();
    }

    /// 心跳注释帧。
    pub fn ping(self: *SseWriter) !void {
        try self.writer.interface.writeAll(": ping\n\n");
        try self.writer.interface.flush();
    }

    /// 发一个 `common.Envelope`（**三种传输共用同一事件模型**）。
    pub fn sendEnvelope(self: *SseWriter, gpa: Allocator, env: common.Envelope) !void {
        var e = common.json.Encoder.init(gpa);
        defer e.deinit();
        try env.toJson(&e);
        try self.send("message", e.text());
    }

    pub fn end(self: *SseWriter) void {
        self.stream.close(self.io);
    }
};

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "sse: 多行 data 被拆成多行" {
    const frame = try encodeEvent(testing.allocator, "message", "line1\nline2");
    defer testing.allocator.free(frame);
    try testing.expectEqualStrings("event: message\ndata: line1\ndata: line2\n\n", frame);
}

test "sse: 单行事件以空行提交" {
    const frame = try encodeEvent(testing.allocator, null, "hello");
    defer testing.allocator.free(frame);
    try testing.expectEqualStrings("data: hello\n\n", frame);
}

test "sse: CRLF 行尾不产生多余 \\r" {
    const frame = try encodeEvent(testing.allocator, null, "a\r\nb");
    defer testing.allocator.free(frame);
    try testing.expectEqualStrings("data: a\ndata: b\n\n", frame);
}

test "sse: 心跳是注释帧且不算事件" {
    const ping = try encodePing(testing.allocator);
    defer testing.allocator.free(ping);
    try testing.expectEqualStrings(": ping\n\n", ping);
    try testing.expect(std.mem.startsWith(u8, ping, ":"));
}

test "sse: 心跳周期是 15 秒" {
    try testing.expectEqual(@as(u64, 15_000), HEARTBEAT_MS);
}

test "sse: 空文本也发一个合法帧" {
    const frame = try encodeEvent(testing.allocator, null, "");
    defer testing.allocator.free(frame);
    try testing.expectEqualStrings("data: \n\n", frame);
}

test "sse: content type 正确" {
    try testing.expect(std.mem.startsWith(u8, CONTENT_TYPE, "text/event-stream"));
}
