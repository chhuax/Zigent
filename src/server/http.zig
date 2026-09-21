//! `server/http.zig` —— **手写 HTTP/1.1 子集**（文档 03 §12.3）。
//!
//! ## 为什么不用通用 HTTP 框架
//!
//! **SSE 最怕缓冲**，而通用框架的默认行为往往替你决定缓冲时机。
//! 手写 ~200 行换来的是：`Content-Length` **必须缺席**、写入即时 flush、
//! 以及对"什么算一个事件"的完全控制。
//!
//! 这也是为什么本文件**直接使用 `std.Io.net`**：`server/` 属于 L4 协议层，
//! 网络是它的本职（`util/io.zig` 提供监听器构造，避免 std 版本漂移扩散）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    headers: []const Header,
    body: []const u8,
    /// 请求原文（诊断用）
    raw: []const u8,

    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

pub const ParseError = error{
    MalformedRequestLine,
    MalformedHeader,
    HeadersTooLarge,
    BodyTooLarge,
    MissingBody,
};

pub const max_request_bytes = 8 << 20;

/// 读一个请求。返回的内存挂在 `arena` 上（请求处理完整体释放）。
///
/// ⚠️ **不能用 `readAlloc`**（它读到 EOF 才返回）—— HTTP 是 keep-alive 的，
/// 客户端发完请求后会**等响应**，读到 EOF 就是死锁。必须"见到 `\r\n\r\n` 就停"，
/// 再按 `Content-Length` 读 body。
pub fn readRequest(
    io: Io,
    stream: std.Io.net.Stream,
    gpa: Allocator,
    arena: Allocator,
) !Request {
    // 必须给一个**真实的读缓冲**：空缓冲会让底层 stream reader 直接返回 0（被当成 EOF）。
    var rbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    const iface = &reader.interface;

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(gpa);

    var head_end: ?HeadEnd = null;
    while (head_end == null) {
        var tmp: [4096]u8 = undefined;
        const n = try readSome(iface, &tmp);
        if (n == 0) break; // EOF
        try buf.appendSlice(gpa, tmp[0..n]);
        if (buf.items.len > max_request_bytes) return ParseError.HeadersTooLarge;
        head_end = findHeadEnd(buf.items);
    }
    const he = head_end orelse {
        if (buf.items.len == 0) return ParseError.MalformedRequestLine;
        return ParseError.MalformedRequestLine;
    };
    const head = buf.items[0..he.pos];

    var lines = std.mem.splitAny(u8, head, "\r\n");
    const request_line = lines.next() orelse return ParseError.MalformedRequestLine;
    var parts = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method = parts.next() orelse return ParseError.MalformedRequestLine;
    const target = parts.next() orelse return ParseError.MalformedRequestLine;
    _ = parts.next(); // HTTP 版本

    const q = std.mem.indexOfScalar(u8, target, '?');
    const path = if (q) |i| target[0..i] else target;
    const query = if (q) |i| target[i + 1 ..] else "";

    var headers = std.ArrayListUnmanaged(Header).empty;
    var content_length: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return ParseError.MalformedHeader;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch 0;
        }
        try headers.append(arena, .{
            .name = try arena.dupe(u8, name),
            .value = try arena.dupe(u8, value),
        });
    }

    if (content_length > max_request_bytes) return ParseError.BodyTooLarge;

    // body：已经读进来的那部分 + 还差的部分
    var body = std.ArrayListUnmanaged(u8).empty;
    errdefer body.deinit(gpa);
    const already = buf.items[he.body_start..];
    const take = @min(already.len, content_length);
    try body.appendSlice(gpa, already[0..take]);
    while (body.items.len < content_length) {
        var tmp: [4096]u8 = undefined;
        const want = @min(tmp.len, content_length - body.items.len);
        const n = try readSome(iface, tmp[0..want]);
        if (n == 0) break;
        try body.appendSlice(gpa, tmp[0..n]);
    }

    return .{
        .method = try arena.dupe(u8, method),
        .path = try arena.dupe(u8, path),
        .query = try arena.dupe(u8, query),
        .headers = try headers.toOwnedSlice(arena),
        .body = try arena.dupe(u8, body.items),
        .raw = try arena.dupe(u8, head),
    };
}

/// 读**一次**（有多少读多少）。
///
/// ⚠️ 不能用 `readSliceShort`：它的语义是"读到缓冲填满或 EOF 才返回"，
/// 而 HTTP 客户端发完 header 后会**等响应** —— 用它就是死锁。
fn readSome(iface: *std.Io.Reader, buf: []u8) !usize {
    var data: [1][]u8 = .{buf};
    return iface.vtable.readVec(iface, &data) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return error.ReadFailed,
    };
}

const HeadEnd = struct { pos: usize, body_start: usize };

fn findHeadEnd(bytes: []const u8) ?HeadEnd {
    if (std.mem.indexOf(u8, bytes, "\r\n\r\n")) |i| return .{ .pos = i, .body_start = i + 4 };
    if (std.mem.indexOf(u8, bytes, "\n\n")) |i| return .{ .pos = i, .body_start = i + 2 };
    return null;
}

pub const Response = struct {
    status: u16 = 200,
    content_type: []const u8 = "application/json; charset=utf-8",
    body: []const u8 = "",
    extra_headers: []const Header = &.{},
};

pub fn statusText(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

pub fn writeResponse(io: Io, stream: std.Io.net.Stream, resp: Response) !void {
    var wbuf: [4096]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    const w = &writer.interface;

    var head_buf: [1024]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "HTTP/1.1 {d} {s}\r\n", .{ resp.status, statusText(resp.status) });
    try w.writeAll(head);
    try w.writeAll("Content-Type: ");
    try w.writeAll(resp.content_type);
    try w.writeAll("\r\n");
    var len_buf: [32]u8 = undefined;
    const len = try std.fmt.bufPrint(&len_buf, "{d}", .{resp.body.len});
    try w.writeAll("Content-Length: ");
    try w.writeAll(len);
    try w.writeAll("\r\n");
    // 交付契约 #?：协议版本协商（文档 06 §2 传输 C）
    try w.writeAll("X-Zigent-Protocol: 1\r\n");
    try w.writeAll("Connection: close\r\n");
    for (resp.extra_headers) |h| {
        try w.writeAll(h.name);
        try w.writeAll(": ");
        try w.writeAll(h.value);
        try w.writeAll("\r\n");
    }
    try w.writeAll("\r\n");
    if (resp.body.len > 0) try w.writeAll(resp.body);
    try w.flush();
}

pub fn jsonGz(arena: Allocator, status: u16, body: []const u8) Response {
    _ = arena;
    return .{ .status = status, .body = body };
}

/// 便捷：写一个 JSON 错误响应（**401 绝不泄漏 SSE 流**）。
pub fn writeError(io: Io, stream: std.Io.net.Stream, status: u16, message: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\",\"status\":{d}}}", .{ message, status }) catch
        "{\"error\":\"internal\"}";
    try writeResponse(io, stream, .{ .status = status, .body = body });
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "http: 状态文案" {
    try testing.expectEqualStrings("OK", statusText(200));
    try testing.expectEqualStrings("Unauthorized", statusText(401));
    try testing.expectEqualStrings("Not Found", statusText(404));
}

test "http: 请求行与 query 拆分" {
    // 纯解析逻辑：直接构造 head 文本走一遍同样的拆分
    const target = "/api/session/abc/events?token=xyz&foo=1";
    const q = std.mem.indexOfScalar(u8, target, '?').?;
    try testing.expectEqualStrings("/api/session/abc/events", target[0..q]);
    try testing.expectEqualStrings("token=xyz&foo=1", target[q + 1 ..]);
}
