//! SSE **写出侧** —— 与 `sse.zig`（读入侧）互为镜像。E3 用。
//!
//! 三条与读入侧对应的规则：
//! W1 多行 data 必须拆成**多个 `data:` 行**（不能塞进一行带 `\n`，
//! 否则客户端只会看到第一行）——这是 reader 侧 A2 的镜像。
//! W2 帧结束必须是**空行**（`\n\n`）。
//! W3 心跳用**注释帧**（`: ping\n\n`），客户端会忽略但能重置中间层的超时。
//!
//! ⚠️ 最容易翻车的是**缓冲**：任何一层缓冲（Writer、gzip、中间件）都会让
//! 「逐字输出」变成「等全部完成再一次性吐出」。所以本文件只做「构造字节」，
//! 由调用方**立即 write + flush**，不经任何缓冲抽象。
//!
//! 同样刻意不用 `std.Io.Writer`：0.15 起 Writer 参数化改动大，
//! 这里只需要往固定 buffer 里拼字节，手写 Sink 反而跨版本稳定。

const std = @import("std");

/// 单帧上限。工具结果超过这个量级应当走「外置落盘 + 引用」（见移植雷区 §H）。
pub const MAX_FRAME = 256 * 1024;

/// 心跳间隔。中间层（反代/负载均衡）通常在 60s 无数据时断连，取 15s 留余量。
pub const HEARTBEAT_MILLIS = 15_000;

/// 极简、零依赖的字节拼接器。
pub const Sink = struct {
 buf: []u8,
 pos: usize = 0,

 pub fn init(buf: []u8) Sink {
 return .{ .buf = buf };
 }

 pub fn write(self: *Sink, bytes: []const u8) !void {
 if (self.pos + bytes.len > self.buf.len) return error.NoSpaceLeft;
 @memcpy(self.buf[self.pos..][0..bytes.len], bytes);
 self.pos += bytes.len;
 }

 pub fn print(self: *Sink, comptime fmt: []const u8, args: anytype) !void {
 const s = try std.fmt.bufPrint(self.buf[self.pos..], fmt, args);
 self.pos += s.len;
 }

 pub fn result(self: *const Sink) []const u8 {
 return self.buf[0..self.pos];
 }
};

/// W1 + W2：构造一个 `event:` + 多行 `data:` 的事件帧。
///
/// `name` 为空时不写 `event:` 行（与读入侧「无 event 名」对称）。
pub fn buildEvent(buf: []u8, name: []const u8, data: []const u8) ![]const u8 {
 var s = Sink.init(buf);
 if (name.len > 0) {
 // 事件名不能含换行（否则会伪造出额外的字段行）
 if (std.mem.indexOfAny(u8, name, "\r\n") != null) return error.InvalidEventName;
 try s.write("event: ");
 try s.write(name);
 try s.write("\n");
 }
 // W1：按 '\n' 拆行，每行一个 data:
 var it = std.mem.splitScalar(u8, data, '\n');
 while (it.next()) |line| {
 // 行内的 '\r' 也要挡掉，否则 CR 会被下游当作行终止符
 if (std.mem.indexOfScalar(u8, line, '\r') != null) return error.InvalidData;
 try s.write("data: ");
 try s.write(line);
 try s.write("\n");
 }
 try s.write("\n"); // W2
 return s.result();
}

/// W3：注释帧 / 心跳。客户端忽略内容，但连接活跃。
pub fn buildComment(buf: []u8, text: []const u8) ![]const u8 {
 if (std.mem.indexOfAny(u8, text, "\r\n") != null) return error.InvalidData;
 var s = Sink.init(buf);
 try s.write(": ");
 try s.write(text);
 try s.write("\n\n");
 return s.result();
}

/// `retry:` 字段 —— 告诉客户端断连后多久重连。
pub fn buildRetry(buf: []u8, millis: u32) ![]const u8 {
 var s = Sink.init(buf);
 try s.print("retry: {d}\n\n", .{millis});
 return s.result();
}

/// 响应头。**注意这四条是 SSE 能被正确流式消费的关键**：
/// - `Content-Type: text/event-stream`
/// - `Cache-Control: no-cache`（并显式 `no-transform`，防代理压缩改写）
/// - `Connection: keep-alive`
/// - **不设 `Content-Length`**（长度未知，设了就变成"攒完再发"）
pub fn buildSseHeaders(buf: []u8) ![]const u8 {
 return std.fmt.bufPrint(
 buf,
 "HTTP/1.1 200 OK\r\n" ++
 "Content-Type: text/event-stream; charset=utf-8\r\n" ++
 "Cache-Control: no-cache, no-transform\r\n" ++
 "Connection: keep-alive\r\n" ++
 "X-Accel-Buffering: no\r\n" ++ // nginx 专用：显式关闭缓冲
 "\r\n",
 .{},
 );
}

/// 普通 JSON 响应（REST 端点用）。
pub fn buildJsonHeaders(buf: []u8, body_len: usize) ![]const u8 {
 return std.fmt.bufPrint(
 buf,
 "HTTP/1.1 200 OK\r\n" ++
 "Content-Type: application/json; charset=utf-8\r\n" ++
 "Content-Length: {d}\r\n" ++
 "Cache-Control: no-store\r\n" ++
 "\r\n",
 .{body_len},
 );
}

/// 401 —— ⚠️ 鉴权失败时**不返回任何细节**（不区分"没带 token"与"token 错"）。
pub fn buildUnauthorized(buf: []u8) ![]const u8 {
 const body = "{\"error\":\"unauthorized\"}";
 return std.fmt.bufPrint(
 buf,
 "HTTP/1.1 401 Unauthorized\r\n" ++
 "Content-Type: application/json\r\n" ++
 "Content-Length: {d}\r\n" ++
 "Connection: close\r\n" ++
 "\r\n" ++ "{s}",
 .{ body.len, body },
 );
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "W1: 多行 data 拆成多个 data: 行（reader 侧 A2 的镜像）" {
 var buf: [1024]u8 = undefined;
 const frame = try buildEvent(&buf, "agent_message_chunk", "line1\nline2\nline3");

 try std.testing.expectEqualStrings(
 "event: agent_message_chunk\n" ++
 "data: line1\n" ++
 "data: line2\n" ++
 "data: line3\n" ++
 "\n",
 frame,
 );
}

test "W2: 帧以空行结束" {
 var buf: [256]u8 = undefined;
 const frame = try buildEvent(&buf, "status", "ok");
 try std.testing.expect(std.mem.endsWith(u8, frame, "\n\n"));
}

test "空事件名不写 event: 行" {
 var buf: [256]u8 = undefined;
 const frame = try buildEvent(&buf, "", "bare");
 try std.testing.expectEqualStrings("data: bare\n\n", frame);
}

test "拒绝能伪造字段行的输入（注入防护）" {
 var buf: [256]u8 = undefined;
 // 事件名带换行 → 可以伪造额外的 SSE 字段
 try std.testing.expectError(error.InvalidEventName, buildEvent(&buf, "a\nevent: forged", "x"));
 // data 里带 CR → 下游可能当作行终止符
 try std.testing.expectError(error.InvalidData, buildEvent(&buf, "n", "a\rb"));
 try std.testing.expectError(error.InvalidData, buildComment(&buf, "a\nb"));
}

test "容量不足时报错而不是截断（截断会产生半个帧）" {
 var small: [8]u8 = undefined;
 try std.testing.expectError(error.NoSpaceLeft, buildEvent(&small, "name", "0123456789"));
}

test "W3: 心跳是注释帧" {
 var buf: [64]u8 = undefined;
 try std.testing.expectEqualStrings(": ping\n\n", try buildComment(&buf, "ping"));
}

test "SSE 响应头：不设 Content-Length 且显式防缓冲" {
 var buf: [512]u8 = undefined;
 const h = try buildSseHeaders(&buf);
 try std.testing.expect(std.mem.indexOf(u8, h, "Content-Type: text/event-stream") != null);
 try std.testing.expect(std.mem.indexOf(u8, h, "no-transform") != null);
 try std.testing.expect(std.mem.indexOf(u8, h, "Connection: keep-alive") != null);
 try std.testing.expect(std.mem.indexOf(u8, h, "X-Accel-Buffering: no") != null);
 // 关键：不能有 Content-Length，否则会变成"攒完再发"
 try std.testing.expect(std.mem.indexOf(u8, h, "Content-Length") == null);
 // 头以空行结束
 try std.testing.expect(std.mem.endsWith(u8, h, "\r\n\r\n"));
}

test "retry 帧" {
 var buf: [64]u8 = undefined;
 try std.testing.expectEqualStrings("retry: 3000\n\n", try buildRetry(&buf, 3000));
}

test "401 不泄漏任何区分信息" {
 var buf: [512]u8 = undefined;
 const r = try buildUnauthorized(&buf);
 try std.testing.expect(std.mem.indexOf(u8, r, "401") != null);
 // 不能出现 "missing" / "expired" / "invalid" 这类可区分的措辞
 try std.testing.expect(std.mem.indexOf(u8, r, "missing") == null);
 try std.testing.expect(std.mem.indexOf(u8, r, "expired") == null);
 try std.testing.expect(std.mem.indexOf(u8, r, "invalid") == null);
}

test "读写对称：写出的帧能被读入侧解析回来（端到端不变量）" {
 const gpa = std.testing.allocator;
 const sse = @import("sse.zig");

 var buf: [1024]u8 = undefined;
 const frame = try buildEvent(&buf, "tool_call", "{\"a\":1}\n{\"b\":2}");

 var p = sse.Parser.init(gpa);
 defer p.deinit();

 const Collected = struct {
 gpa: std.mem.Allocator,
 name: []u8 = &.{},
 data: []u8 = &.{},
 fn emit(self: *@This(), ev: sse.Event) !void {
 if (self.name.len > 0) self.gpa.free(self.name);
 if (self.data.len > 0) self.gpa.free(self.data);
 self.name = try self.gpa.dupe(u8, ev.name);
 self.data = try self.gpa.dupe(u8, ev.data);
 }
 };
 var got = Collected{ .gpa = gpa };
 defer {
 if (got.name.len > 0) gpa.free(got.name);
 if (got.data.len > 0) gpa.free(got.data);
 }

 try p.feed(frame, &got);
 try p.finish(&got);

 try std.testing.expectEqualStrings("tool_call", got.name);
 try std.testing.expectEqualStrings("{\"a\":1}\n{\"b\":2}", got.data);
}
