//! E3：本地 HTTP/SSE 服务原型 —— 桌面壳的交付契约验证。
//!
//! ## 为什么手写 HTTP/1.1 而不用 `std.http.Server`
//!
//! 这是 E3 要给出的结论之一。理由：
//! 1. `std.http.Server` 的 API 在 0.15/0.16 一直随 `std.Io` 改造而变动
//! （"Writergate" 的 Writer/Reader 参数化），**0.17 又重写了 build system**；
//! 2. 我们需要的是**极小的协议子集**：解析请求行 + 几个头、返回 200/401、
//! 以及**完全控制 flush 时机**的 SSE；
//! 3. **第三方 HTTP 框架的最大风险正是「它替你决定缓冲」** —— 而 SSE 最怕缓冲。
//!
//! 手写约 250 行就能覆盖本地 API 所需的全部子集，且零版本依赖。
//!
//! ⚠️ 若本文件在当前 Zig 版本下编译失败，优先按报错改 `std.posix.*` 的调用签名；
//! 若 `std.posix` 变动过大，退路是链接 C 库（civetweb/llhttp）——
//! 但那会**引入 C 依赖，影响交叉编译与静态链接**（见方案 §7.3 的收益项）。
//!
//! ## 7 条交付契约的落点
//! #1 端口 0 + 回报 → `Listener.init` / `run` 里 `buildListeningLine`
//! #2 `/health` 免 token → `isPublicPath`
//! #3 一次性 token → `handshake.extractToken` + `tokenMatches`
//! #4 优雅关闭 → `POST /internal/shutdown` → `ctx.shutdown`
//! #5 `--version` → main.zig
//! #6 不留孤儿 → `handshake.orphanStrategyForOs`（真机验证）
//! #7 stdout 只有协议 → `run` 里 stdout 只写 listening 行，日志走 stderr

const std = @import("std");
const handshake = @import("handshake.zig");
const sse_writer = @import("sse_writer.zig");

pub const VERSION = "0.1.0-spike";

/// stdout 只有协议（契约 #7）；所有日志走 stderr。
fn log(comptime fmt: []const u8, args: anytype) void {
 std.debug.print("[zig-m0] " ++ fmt ++ "\n", args); // std.debug 走 stderr
}

// ---------------------------------------------------------------------------
// Listener：绑 127.0.0.1:0，取回 OS 分配的真实端口（契约 #1）
// ---------------------------------------------------------------------------

pub const Listener = struct {
 fd: std.posix.socket_t,
 port: u16,

 pub fn init() !Listener {
 // ⚠️ 版本敏感：std.posix.socket / bind / listen / getsockname 的签名
 const addr = try std.net.Address.parseIp("127.0.0.1", 0); // 端口 0 = 让 OS 分配
 const fd = try std.posix.socket(
 addr.any.family,
 std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
 std.posix.IPPROTO.TCP,
 );
 errdefer std.posix.close(fd);

 // 便于快速重启（TIME_WAIT 不阻塞）
 const one: c_int = 1;
 std.posix.setsockopt(
 fd,
 std.posix.SOL.SOCKET,
 std.posix.SO.REUSEADDR,
 &std.mem.toBytes(one),
 ) catch {};

 try std.posix.bind(fd, &addr.any, addr.getOsSockLen());
 try std.posix.listen(fd, 128);

 // 读回 OS 实际分配的端口
 var bound: std.net.Address = undefined;
 var len: std.posix.socklen_t = @sizeOf(std.net.Address);
 try std.posix.getsockname(fd, &bound.any, &len);

 return .{ .fd = fd, .port = bound.getPort() };
 }

 pub fn deinit(self: *Listener) void {
 std.posix.close(self.fd);
 }
};

// ---------------------------------------------------------------------------
// 服务上下文
// ---------------------------------------------------------------------------

pub const Context = struct {
 token: handshake.Token,
 listener: *Listener,
 /// 置位后 accept 循环退出（契约 #4）
 shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
 /// 每连接一次，用于标记 SSE 连接以便关闭时唤醒（spike 里简化为不跟踪）
 gpa: std.mem.Allocator,

 pub fn requestShutdown(self: *Context) void {
 self.shutdown.store(true, .release);
 // 自连接一次，唤醒阻塞中的 accept()
 const addr = std.net.Address.parseIp("127.0.0.1", self.listener.port) catch return;
 const fd = std.posix.socket(addr.any.family, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP) catch return;
 defer std.posix.close(fd);
 std.posix.connect(fd, &addr.any, addr.getOsSockLen()) catch return;
 }
};

// ---------------------------------------------------------------------------
// 请求解析（最小子集）
// ---------------------------------------------------------------------------

pub const Method = enum { GET, POST, other };

pub const Request = struct {
 method: Method = .other,
 path: []const u8 = "",
 query: []const u8 = "",
 authorization: ?[]const u8 = null,
};

pub const MAX_HEAD = 16 * 1024;

/// 从已读入的头部字节里解析出请求行与关心的头。
/// 返回消耗的字节数（头结束位置），若头未读完返回 null。
pub fn parseHead(raw: []const u8) ?struct { req: Request, head_len: usize } {
 const end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return null;
 const head = raw[0..end];
 const head_len = end + 4;

 var lines = std.mem.splitSequence(u8, head, "\r\n");
 const first = lines.next() orelse return null;
 var parts = std.mem.splitScalar(u8, first, ' ');
 const method_s = parts.next() orelse return null;
 const target = parts.next() orelse return null;

 var req = Request{};
 req.method = if (std.mem.eql(u8, method_s, "GET"))
 .GET
 else if (std.mem.eql(u8, method_s, "POST"))
 .POST
 else
 .other;

 if (std.mem.indexOfScalar(u8, target, '?')) |q| {
 req.path = target[0..q];
 req.query = target[q + 1 ..];
 } else {
 req.path = target;
 }

 while (lines.next()) |line| {
 if (line.len == 0) continue;
 const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
 const name = std.mem.trim(u8, line[0..colon], " \t");
 const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
 if (std.ascii.eqlIgnoreCase(name, "authorization")) req.authorization = value;
 }
 return .{ .req = req, .head_len = head_len };
}

// ---------------------------------------------------------------------------
// 路由
// ---------------------------------------------------------------------------

const Route = enum { health, events, create_session, prompt, permission, shutdown, not_found };

fn route(req: Request) Route {
 if (std.mem.eql(u8, req.path, "/health")) return .health;
 if (std.mem.eql(u8, req.path, "/api/events")) return .events;
 if (std.mem.eql(u8, req.path, "/api/session")) return .create_session;
 if (std.mem.eql(u8, req.path, handshake.SHUTDOWN_PATH)) return .shutdown;
 if (std.mem.indexOf(u8, req.path, "/api/session/") != null) {
 if (std.mem.indexOf(u8, req.path, "/prompt") != null) return .prompt;
 if (std.mem.indexOf(u8, req.path, "/permission/") != null) return .permission;
 }
 return .not_found;
}

// ---------------------------------------------------------------------------
// 响应写出（每次都直接 write syscall —— 不经任何缓冲）
// ---------------------------------------------------------------------------

fn rawWrite(fd: std.posix.socket_t, bytes: []const u8) !void {
 var off: usize = 0;
 while (off < bytes.len) {
 const n = try std.posix.write(fd, bytes[off..]);
 if (n == 0) return error.BrokenPipe;
 off += n;
 }
}

fn sendUnauthorized(fd: std.posix.socket_t) void {
 var buf: [512]u8 = undefined;
 const r = sse_writer.buildUnauthorized(&buf) catch return;
 rawWrite(fd, r) catch {};
}

fn sendJson(fd: std.posix.socket_t, body: []const u8) void {
 var hbuf: [512]u8 = undefined;
 const h = sse_writer.buildJsonHeaders(&hbuf, body.len) catch return;
 rawWrite(fd, h) catch return;
 rawWrite(fd, body) catch {};
}

/// SSE 处理器 —— **证明真流式**（E3 第 5 项）。
/// spike 阶段用假事件：5 个文本增量 + 心跳，证明客户端能实时收到。
fn handleSse(fd: std.posix.socket_t) void {
 var hbuf: [512]u8 = undefined;
 const headers = sse_writer.buildSseHeaders(&hbuf) catch return;
 rawWrite(fd, headers) catch return; // 头立即发出，不攒

 var fbuf: [sse_writer.MAX_FRAME]u8 = undefined;

 // retry 提示（断连后 1s 重连）
 const retry = sse_writer.buildRetry(&fbuf, 1000) catch return;
 rawWrite(fd, retry) catch return;

 const chunks = [_][]const u8{
 "Hello",
 ", this",
 " is a",
 " streamed",
 " reply.\nSecond line proves W1 works.",
 };

 for (chunks, 0..) |chunk, i| {
 // 每帧独立 write + 短延时 —— 若客户端是"等连接关闭才收到"，
 // 就说明链路上有缓冲（这是本项的核心判据）。
 const frame = sse_writer.buildEvent(&fbuf, "agent_message_chunk", chunk) catch return;
 rawWrite(fd, frame) catch return;
 std.Thread.sleep(200 * std.time.ns_per_ms);

 if (i == 2) {
 // 中途插一个心跳，验证注释帧不影响客户端解析
 const hb = sse_writer.buildComment(&fbuf, "ping") catch return;
 rawWrite(fd, hb) catch return;
 }
 }

 const done = sse_writer.buildEvent(&fbuf, "turn_complete", "{\"stopReason\":\"end_turn\"}") catch return;
 rawWrite(fd, done) catch return;
 // 不关连接（真实 SSE 会保持），spike 里直接返回让连接关闭即可
}

// ---------------------------------------------------------------------------
// 连接处理
// ---------------------------------------------------------------------------

fn handleConnection(ctx: *Context, fd: std.posix.socket_t) void {
 defer std.posix.close(fd);

 var buf: [MAX_HEAD]u8 = undefined;
 var n: usize = 0;
 // 只读头（spike 里不处理请求体；真实实现要按 Content-Length 继续读）
 while (n < buf.len) {
 const got = std.posix.read(fd, buf[n..]) catch return;
 if (got == 0) return;
 n += got;
 if (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n") != null) break;
 }

 const parsed = parseHead(buf[0..n]) orelse {
 // 头不完整 —— 直接断开（真实实现应回 400）
 return;
 };
 const req = parsed.req;
 const r = route(req);

 // ---- 契约 #2：/health 免 token ----
 if (r == .health) {
 var body_buf: [128]u8 = undefined;
 const body = std.fmt.bufPrint(
 &body_buf,
 "{{\"status\":\"{s}\",\"version\":\"{s}\"}}",
 .{ handshake.HEALTH_MARKER, VERSION },
 ) catch return;
 sendJson(fd, body);
 return;
 }

 // ---- 契约 #3：其余全部校验 token（REST 与 SSE 一视同仁）----
 const extracted = handshake.extractToken(
 if (req.query.len > 0) req.query else null,
 req.authorization,
 );
 const ok = if (extracted.value) |v| handshake.tokenMatches(&ctx.token, v) else false;
 if (!ok) {
 log("401 {s} (source={s})", .{ req.path, @tagName(extracted.source) });
 sendUnauthorized(fd);
 return;
 }

 switch (r) {
 .health => unreachable,
 .events => handleSse(fd),
 .create_session => sendJson(fd, "{\"sessionId\":\"spike-session-1\"}"),
 .prompt => sendJson(fd, "{\"accepted\":true}"),
 .permission => sendJson(fd, "{\"accepted\":true}"),
 .shutdown => {
 // ---- 契约 #4：优雅关闭 ----
 sendJson(fd, "{\"shuttingDown\":true}");
 ctx.requestShutdown();
 },
 .not_found => {
 var body_buf: [256]u8 = undefined;
 const body = std.fmt.bufPrint(&body_buf, "{{\"error\":\"not_found\",\"path\":\"{s}\"}}", .{req.path}) catch "{\"error\":\"not_found\"}";
 sendJson(fd, body);
 },
 }
}

fn connThread(ctx: *Context, fd: std.posix.socket_t) void {
 handleConnection(ctx, fd);
}

// ---------------------------------------------------------------------------
// 主循环
// ---------------------------------------------------------------------------

pub fn run(gpa: std.mem.Allocator, token: handshake.Token) !void {
 var listener = try Listener.init();
 defer listener.deinit();

 var ctx = Context{ .token = token, .listener = &listener, .gpa = gpa };

 // ---- 契约 #1：把实际端口写到 stdout（stdout 只有协议）----
 var line_buf: [handshake.MAX_LISTENING_LINE]u8 = undefined;
 const line = try handshake.buildListeningLine(&line_buf, listener.port, currentPid(), VERSION);
 _ = try std.posix.write(std.posix.STDOUT_FILENO, line);

 log("listening on 127.0.0.1:{d} (pid {d})", .{ listener.port, currentPid() });
 log("health: curl http://127.0.0.1:{d}/health", .{listener.port});
 log("stream: curl -N 'http://127.0.0.1:{d}/api/events?token={s}'", .{ listener.port, token.slice() });
 log("shutdown: curl -X POST 'http://127.0.0.1:{d}{s}?token={s}'", .{ listener.port, handshake.SHUTDOWN_PATH, token.slice() });

 // ---- 契约 #6：不留孤儿的策略选择（真机验证见 README）----
 switch (handshake.orphanStrategyForOs()) {
 .pdeathsig => log("orphan strategy: PR_SET_PDEATHSIG (linux)", .{}),
 .reparent_poll => log("orphan strategy: reparent poll (macOS/其它)", .{}),
 }

 while (!ctx.shutdown.load(.acquire)) {
 var peer: std.net.Address = undefined;
 var peer_len: std.posix.socklen_t = @sizeOf(std.net.Address);
 const fd = std.posix.accept(listener.fd, &peer.any, &peer_len, 0) catch |err| {
 if (ctx.shutdown.load(.acquire)) break;
 log("accept failed: {s}", .{@errorName(err)});
 continue;
 };

 // 并发处理：SSE 连接会长时间占用线程，不能串行。
 // spike 用「线程/连接」；生产应改为线程池 + 事件循环（步 S10）。
 const t = std.Thread.spawn(.{}, connThread, .{ &ctx, fd }) catch {
 std.posix.close(fd);
 continue;
 };
 t.detach();
 }

 log("shutdown complete", .{});
}

/// 跨平台取 pid：用 C 库（Zig 在 POSIX 目标上默认链接 libc 的 getpid）。
/// 若不想依赖 libc，可在 Linux 用 std.os.linux.getpid()、macOS 用
/// std.c.getpid() —— 但那样就要写 OS 分支；这里直接用 std.c 保持单一实现。
extern "c" fn getpid() c_int;

fn currentPid() i32 {
 return @intCast(getpid());
}
