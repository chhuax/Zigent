//! `server/app.zig` —— 本地 HTTP + SSE 服务（**对 Web 的门**）。
//!
//! 七个必做端点（文档 03 §12.3）：
//!
//! | 端点 | 作用 |
//! |---|---|
//! | `GET /health` | 就绪探测（**免 token**，返回 `zigent-ready`） |
//! | `POST /api/session` | 建会话 |
//! | `GET /api/sessions` | 列会话 |
//! | `POST /api/session/{id}/prompt` | 提交输入 |
//! | `GET /api/session/{id}/events` | **SSE 事件流**（真流式、不缓冲） |
//! | `POST /api/session/{id}/permission/{rid}` | 权限应答 |
//! | `POST /internal/shutdown` | 优雅关闭 |
//!
//! 桌面壳交付契约 7 条见 `docs/analysis/2026-09-19-03-架构详解.md` §12.3；
//! 本文件负责 #1（真实端口回报在 `cli/`）、#2、#3、#4、#7。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const common = @import("common");
const engine = @import("engine");
const llm = @import("llm");
const util = @import("util");
const config = @import("config");

const http = @import("http.zig");
const sse = @import("sse.zig");
const token_mod = @import("token.zig");
const queue_mod = @import("queue.zig");
const static_files = @import("static.zig");

pub const VERSION = "0.1.0";
pub const HEALTH_MARKER = "zigent-ready";

/// 权限应答的默认超时（**内核按拒绝处理** —— 恰好一次语义）。
/// ⚠️ 文档 06 §4.3 的 `timeout_ms` 必须与实际一致（历史上三处不一致）。
pub const PERMISSION_TIMEOUT_MS: u64 = 60_000;

pub const ClientFactory = struct {
    ctx: *anyopaque,
    create: *const fn (ctx: *anyopaque, gpa: Allocator, io: Io, rt: *const engine.Rt) anyerror!llm.Client,
};

/// 一个待答的权限卡片。
const Pending = struct {
    used: bool = false,
    request_id: []const u8 = "",
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    response: ?common.perm.Response = null,
};

pub const SessionEntry = struct {
    id: []u8,
    queue: *queue_mod.EventQueue,
    cancel: *std.atomic.Value(bool),
    session: ?*engine.Session = null,
    /// 权限卡片槽（**固定大小**，避免生命周期问题）
    pending: [8]Pending = [_]Pending{.{}} ** 8,
    prompt_running: bool = false,

    fn allocPending(self: *SessionEntry, request_id: []const u8, gpa: Allocator) ?*Pending {
        for (&self.pending) |*p| {
            if (!p.used) {
                p.used = true;
                p.request_id = gpa.dupe(u8, request_id) catch return null;
                p.response = null;
                return p;
            }
        }
        return null;
    }

    fn answer(self: *SessionEntry, io: Io, request_id: []const u8, resp: common.perm.Response) bool {
        for (&self.pending) |*p| {
            if (p.used and std.mem.eql(u8, p.request_id, request_id)) {
                p.mutex.lock(io) catch return false;
                p.response = resp;
                p.mutex.unlock(io);
                p.cond.broadcast(io);
                return true;
            }
        }
        return false;
    }
};

pub const App = struct {
    gpa: Allocator,
    io: Io,
    rt: engine.Rt,
    token: token_mod.Token,
    listener: *util.io.Listener,
    factory: ClientFactory,
    /// UI 静态资源目录（`--web-root`，默认 `<cwd>/web`）。
    /// `null` 或目录不存在 → 只有内嵌占位页（`/` 仍不 404）。
    web_root: ?[]const u8 = null,
    sessions: std.StringHashMapUnmanaged(*SessionEntry) = .empty,
    sessions_mutex: std.Io.Mutex = .init,
    shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    session_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(
        gpa: Allocator,
        io: Io,
        rt: engine.Rt,
        tok: token_mod.Token,
        listener: *util.io.Listener,
        factory: ClientFactory,
        web_root: ?[]const u8,
    ) App {
        return .{
            .gpa = gpa,
            .io = io,
            .rt = rt,
            .token = tok,
            .listener = listener,
            .factory = factory,
            .web_root = web_root,
        };
    }

    pub fn deinit(self: *App) void {
        self.sessions_mutex.lock(self.io) catch {};
        var it = self.sessions.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.queue.close();
            e.value_ptr.*.queue.deinit();
            self.gpa.destroy(e.value_ptr.*.queue);
            if (e.value_ptr.*.session) |s| {
                s.deinit();
                self.gpa.destroy(s);
            }
            self.gpa.free(e.value_ptr.*.id);
            self.gpa.destroy(e.value_ptr.*);
        }
        self.sessions.deinit(self.gpa);
        self.sessions_mutex.unlock(self.io);
    }

    /// 接受连接的主循环。
    ///
    /// ⚠️ **每个连接必须独立线程处理**：SSE 是长连接，若在 accept 循环里同步处理，
    /// 一条 SSE 流会把整个服务堵死（后续 `POST /prompt` 只能排队等它结束）。
    pub fn run(self: *App) !void {
        while (!self.shutting_down.load(.acquire)) {
            var stream = self.listener.accept(self.io) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            const job = self.gpa.create(ConnJob) catch {
                stream.close(self.io);
                continue;
            };
            job.* = .{ .app = self, .stream = stream };
            const t = std.Thread.spawn(.{}, connThread, .{job}) catch {
                // 线程资源耗尽时退化为同步处理（不丢连接）
                self.gpa.destroy(job);
                self.handleConnection(stream);
                stream.close(self.io);
                continue;
            };
            t.detach();
        }
    }

    const ConnJob = struct { app: *App, stream: std.Io.net.Stream };

    fn connThread(job: *ConnJob) void {
        const app = job.app;
        const stream = job.stream;
        app.handleConnection(stream);
        stream.close(app.io);
        app.gpa.destroy(job);
    }

    fn handleConnection(self: *App, stream: std.Io.net.Stream) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const req = http.readRequest(self.io, stream, self.gpa, arena.allocator()) catch {
            http.writeError(self.io, stream, 400, "bad request") catch {};
            return;
        };
        self.dispatch(stream, req, arena.allocator()) catch |err| {
            http.writeError(self.io, stream, 500, @errorName(err)) catch {};
        };
    }

    fn dispatch(self: *App, stream: std.Io.net.Stream, req: http.Request, arena: Allocator) !void {
        // ── 契约 #2：/health 免 token ──
        if (std.mem.eql(u8, req.path, "/health")) {
            var buf: [256]u8 = undefined;
            const body = try std.fmt.bufPrint(&buf, "{{\"status\":\"{s}\",\"version\":\"{s}\"}}", .{ HEALTH_MARKER, VERSION });
            return http.writeResponse(self.io, stream, .{ .status = 200, .body = body });
        }

        // ── UI 静态资源：**与 /health 一样免 token** ──
        //    为什么免：UI 本身不含数据；数据端点仍然要 token。
        //    否则浏览器没法用 URL 打开页面（`<script src>` 带不了 Authorization 头）。
        //    `/api/*` 与 `/internal/*` 永远不走静态分支，避免"静态覆盖 API"。
        if (std.mem.eql(u8, req.method, "GET") and
            !std.mem.startsWith(u8, req.path, "/api/") and
            !std.mem.startsWith(u8, req.path, "/internal/"))
        {
            if (try static_files.resolve(self.io, self.gpa, self.web_root, req.path)) |asset| {
                defer asset.deinit(self.gpa);
                return http.writeResponse(self.io, stream, .{
                    .status = 200,
                    .content_type = asset.content_type,
                    .body = asset.body,
                    .extra_headers = &.{.{ .name = "Cache-Control", .value = asset.cache_control }},
                });
            }
            // 非 API 的 GET 只可能是静态资源。找不到就 **404**，
            // 不要"掉进 token 检查变成 401" —— 那会让浏览器无法区分
            // "路径写错了" 和 "没带凭据"。同时也顺带不泄漏目录结构。
            return http.writeError(self.io, stream, 404, "not found");
        }

        // ── 契约 #3：其余全部要 token（**401 绝不先写 SSE 头**）──
        const presented = token_mod.extract(req.headers, req.query);
        if (presented == null or !self.token.matches(presented.?)) {
            return http.writeError(self.io, stream, 401, "unauthorized");
        }

        // 交付契约 3b：`GET /api/session` 也要能用（壳启动后先探一次）
        if (std.mem.eql(u8, req.path, "/api/session") and
            (std.mem.eql(u8, req.method, "POST") or std.mem.eql(u8, req.method, "GET")))
        {
            return self.createSession(stream, arena);
        }
        if (std.mem.eql(u8, req.path, "/api/sessions") and std.mem.eql(u8, req.method, "GET")) {
            return self.listSessions(stream, arena);
        }
        if (std.mem.eql(u8, req.path, "/internal/shutdown") and std.mem.eql(u8, req.method, "POST")) {
            self.shutting_down.store(true, .release);
            // 关闭监听让 accept 返回 —— 用一个自连接唤醒
            self.wakeAccept();
            return http.writeResponse(self.io, stream, .{ .status = 200, .body = "{\"shuttingDown\":true}" });
        }
        if (std.mem.eql(u8, req.path, "/api/system/info")) {
            return http.writeResponse(self.io, stream, .{ .status = 200, .body =
                "{\"backendName\":\"zigent-cli\",\"version\":\"" ++ VERSION ++ "\"}" });
        }

        // 路径参数路由
        // ⚠️ 必须做**前缀**匹配，不能用 `trimStart` —— 它按"字符集合"剥离，
        //    会把 `/api/session/sess-1` 削成 `-1`（sid 里全是集合内字符时尤其明显）。
        const prefix = "/api/session/";
        if (std.mem.startsWith(u8, req.path, prefix)) {
            const rest = req.path[prefix.len..];
            if (self.routeSessionPath(stream, req, arena, rest)) |_| return;
        }
        return http.writeError(self.io, stream, 404, "not found");
    }

    fn wakeAccept(self: *App) void {
        // 连一次自己，让 accept 返回一行然后循环看到 shutting_down
        const addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(self.listener.port) };
        if (std.Io.net.IpAddress.connect(&addr, self.io, .{ .mode = .stream })) |s| {
            var st = s;
            st.close(self.io);
        } else |_| {}
    }

    fn routeSessionPath(
        self: *App,
        stream: std.Io.net.Stream,
        req: http.Request,
        arena: Allocator,
        rest: []const u8,
    ) ?void {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse {
            // 只有 /api/session/{id}
            if (std.mem.eql(u8, req.method, "GET")) {
                self.getSession(stream, rest) catch {};
                return {};
            }
            return null;
        };
        const sid = rest[0..slash];
        const tail = rest[slash + 1 ..];

        if (std.mem.eql(u8, tail, "prompt") and std.mem.eql(u8, req.method, "POST")) {
            self.startPrompt(stream, sid, req, arena) catch {};
            return {};
        }
        if (std.mem.eql(u8, tail, "events") and std.mem.eql(u8, req.method, "GET")) {
            self.streamEvents(stream, sid) catch {};
            return {};
        }
        if (std.mem.eql(u8, tail, "cancel") and std.mem.eql(u8, req.method, "POST")) {
            self.cancelSession(stream, sid) catch {};
            return {};
        }
        if (std.mem.startsWith(u8, tail, "permission/") and std.mem.eql(u8, req.method, "POST")) {
            const rid = tail["permission/".len..];
            self.answerPermission(stream, sid, rid, req) catch {};
            return {};
        }
        return null;
    }

    // ── 会话管理 ────────────────────────────────────────────────────────────

    fn lookup(self: *App, sid: []const u8) ?*SessionEntry {
        self.sessions_mutex.lock(self.io) catch return null;
        defer self.sessions_mutex.unlock(self.io);
        return self.sessions.get(sid);
    }

    fn createSession(self: *App, stream: std.Io.net.Stream, arena: Allocator) !void {
        const n = self.session_counter.fetchAdd(1, .monotonic) + 1;
        const id = try std.fmt.allocPrint(self.gpa, "sess-{d}-{s}", .{
            n,
            try util.io.randomHex(self.io, arena, 4),
        });

        const q = try self.gpa.create(queue_mod.EventQueue);
        q.* = queue_mod.EventQueue.init(self.io, self.gpa);
        const cancel = try self.gpa.create(std.atomic.Value(bool));
        cancel.* = std.atomic.Value(bool).init(false);
        const entry = try self.gpa.create(SessionEntry);
        entry.* = .{ .id = id, .queue = q, .cancel = cancel };

        self.sessions_mutex.lock(self.io) catch {};
        try self.sessions.put(self.gpa, id, entry);
        self.sessions_mutex.unlock(self.io);

        var buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "{{\"sessionId\":\"{s}\",\"protocolVersion\":1}}", .{id});
        try http.writeResponse(self.io, stream, .{ .status = 200, .body = body });
    }

    fn listSessions(self: *App, stream: std.Io.net.Stream, arena: Allocator) !void {
        var out = std.ArrayListUnmanaged(u8).empty;
        defer out.deinit(arena);
        try out.appendSlice(arena, "{\"sessions\":[");
        self.sessions_mutex.lock(self.io) catch {};
        var it = self.sessions.iterator();
        var first = true;
        while (it.next()) |e| {
            if (!first) try out.append(arena, ',');
            first = false;
            try out.print(arena, "\"{s}\"", .{e.value_ptr.*.id});
        }
        self.sessions_mutex.unlock(self.io);
        try out.appendSlice(arena, "]}");
        try http.writeResponse(self.io, stream, .{ .status = 200, .body = out.items });
    }

    fn getSession(self: *App, stream: std.Io.net.Stream, sid: []const u8) !void {
        const entry = self.lookup(sid) orelse
            return http.writeError(self.io, stream, 404, "no such session");
        var buf: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "{{\"sessionId\":\"{s}\",\"running\":{s}}}", .{
            entry.id,
            if (entry.prompt_running) "true" else "false",
        });
        try http.writeResponse(self.io, stream, .{ .status = 200, .body = body });
    }

    fn cancelSession(self: *App, stream: std.Io.net.Stream, sid: []const u8) !void {
        const entry = self.lookup(sid) orelse
            return http.writeError(self.io, stream, 404, "no such session");
        entry.cancel.store(true, .release);
        try http.writeResponse(self.io, stream, .{ .status = 200, .body = "{\"cancelled\":true}" });
    }

    // ── 事件流（真流式）────────────────────────────────────────────────────

    fn streamEvents(self: *App, stream: std.Io.net.Stream, sid: []const u8) !void {
        const entry = self.lookup(sid) orelse
            return http.writeError(self.io, stream, 404, "no such session");
        var sse_buf: [8192]u8 = undefined;
        var writer = try sse.SseWriter.begin(self.io, stream, &sse_buf);
        // 先补一条 status，让客户端立即知道连接建立（避免"连接后一片空白"）
        try writer.send("status", "{\"message\":\"connected\"}");
        while (!self.shutting_down.load(.acquire)) {
            if (entry.queue.tryPop()) |line| {
                defer self.gpa.free(line);
                try writer.send("message", line);
                continue;
            }
            if (entry.queue.isClosed()) break;
            // 心跳：15s 注释帧（不算事件）
            var i: usize = 0;
            while (i < sse.HEARTBEAT_MS / 250) : (i += 1) {
                if (entry.queue.tryPop()) |line| {
                    defer self.gpa.free(line);
                    try writer.send("message", line);
                    break;
                }
                if (self.shutting_down.load(.acquire)) break;
                util.io.sleep(self.io, 250) catch {};
            }
            if (entry.queue.tryPop() == null) try writer.ping();
        }
        writer.end();
    }

    // ── 提交 prompt（后台线程跑主循环）──────────────────────────────────────

    const PromptJob = struct {
        app: *App,
        entry: *SessionEntry,
        prompt: []u8,
    };

    fn startPrompt(
        self: *App,
        stream: std.Io.net.Stream,
        sid: []const u8,
        req: http.Request,
        arena: Allocator,
    ) !void {
        const entry = self.lookup(sid) orelse
            return http.writeError(self.io, stream, 404, "no such session");
        if (entry.prompt_running) {
            return http.writeError(self.io, stream, 409, "a prompt is already running");
        }
        const prompt = try extractPrompt(arena, req.body);
        const job = try self.gpa.create(PromptJob);
        job.* = .{
            .app = self,
            .entry = entry,
            .prompt = try self.gpa.dupe(u8, prompt),
        };
        entry.prompt_running = true;
        const t = std.Thread.spawn(.{}, runPromptJob, .{job}) catch |err| {
            self.gpa.free(job.prompt);
            self.gpa.destroy(job);
            return err;
        };
        t.detach();
        try http.writeResponse(self.io, stream, .{ .status = 200, .body = "{\"accepted\":true}" });
    }

    fn runPromptJob(job: *PromptJob) void {
        const self = job.app;
        defer {
            self.gpa.free(job.prompt);
            job.entry.prompt_running = false;
            self.gpa.destroy(job);
        }
        self.runPrompt(job.entry, job.prompt) catch |err| {
            self.pushRaw(job.entry, "error", @errorName(err));
        };
    }

    fn runPrompt(self: *App, entry: *SessionEntry, prompt: []const u8) !void {
        // 每个会话一个 Rt（独立 session_id 与 cancel 令牌）
        var rt = self.rt.withSession(entry.id);
        rt.cancel = entry.cancel;

        const session = try self.gpa.create(engine.Session);
        errdefer self.gpa.destroy(session);

        var sink_ctx = SinkContext{ .app = self, .entry = entry };
        const client = try self.factory.create(self.factory.ctx, self.gpa, self.io, &rt);

        session.* = try engine.Session.init(self.gpa, rt, .{
            .ctx = &sink_ctx,
            .emit_fn = SinkContext.emit,
        }, client, .{
            .permission_broker = .{ .ctx = &sink_ctx, .request = SinkContext.requestPermission },
        });
        entry.session = session;
        defer {
            session.deinit();
            self.gpa.destroy(session);
            entry.session = null;
        }

        _ = try session.submitMessage(prompt);
        entry.queue.push(try self.gpa.dupe(u8, "{\"type\":\"turn_idle\"}")) catch {};
    }

    fn pushRaw(self: *App, entry: *SessionEntry, event: []const u8, message: []const u8) void {
        const line = std.fmt.allocPrint(
            self.gpa,
            "{{\"type\":\"{s}\",\"message\":\"{s}\"}}",
            .{ event, message },
        ) catch return;
        entry.queue.push(line) catch self.gpa.free(line);
    }

    fn answerPermission(
        self: *App,
        stream: std.Io.net.Stream,
        sid: []const u8,
        rid: []const u8,
        req: http.Request,
    ) !void {
        const entry = self.lookup(sid) orelse
            return http.writeError(self.io, stream, 404, "no such session");
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const option_id = try extractOptionId(arena.allocator(), req.body);
        const resp = common.perm.responseForOption(option_id);
        if (!entry.answer(self.io, rid, resp)) {
            return http.writeError(self.io, stream, 404, "no such permission request");
        }
        try http.writeResponse(self.io, stream, .{ .status = 200, .body = "{\"ok\":true}" });
    }
};

/// 把 engine 的事件流转成 SSE 行，并实现权限卡片往返。
pub const SinkContext = struct {
    app: *App,
    entry: *SessionEntry,

    fn emit(ctx: *anyopaque, ev: common.StreamEvent) anyerror!void {
        const self: *SinkContext = @ptrCast(@alignCast(ctx));
        const app = self.app;

        const uuid = try util.io.randomHex(app.io, app.gpa, 8);
        defer app.gpa.free(uuid);
        var tsbuf: [64]u8 = undefined;
        const ts = util.io.formatIso8601(&tsbuf, util.io.epochMillis(app.io));

        var e = common.json.Encoder.init(app.gpa);
        defer e.deinit();
        try (common.Envelope{
            .uuid = uuid,
            .session_id = self.entry.id,
            .timestamp = ts,
            .event = ev,
        }).toJson(&e);
        const line = try app.gpa.dupe(u8, e.text());
        self.entry.queue.push(line) catch app.gpa.free(line);
    }

    fn requestPermission(ctx: *anyopaque, req: common.perm.Request) anyerror!common.perm.Response {
        const self: *SinkContext = @ptrCast(@alignCast(ctx));
        const app = self.app;

        const rid = try util.io.randomHex(app.io, app.gpa, 8);
        defer app.gpa.free(rid);
        const slot = self.entry.allocPending(rid, app.gpa) orelse
            return common.perm.Response.unavailable("too many pending permission requests");

        // 推一张卡片到事件流
        var e = common.json.Encoder.init(app.gpa);
        defer e.deinit();
        try e.beginObject();
        try e.stringField("type", "permission_request");
        try e.stringField("request_id", rid);
        try e.stringField("tool_name", req.tool_name);
        try e.stringField("tool_use_id", req.tool_use_id);
        try e.stringField("cwd", req.cwd);
        try e.stringField("risk_level", req.tool_risk_level.wireName());
        try e.stringField("reason", req.reason);
        try e.stringField("input_summary", req.input_summary);
        try e.key("options");
        try e.beginArray();
        for (common.perm.Request.default_options) |o| {
            try e.beginObject();
            try e.stringField("option_id", o.option_id);
            try e.stringField("label", o.name);
            try e.stringField("kind", o.kind);
            try e.endObject();
        }
        try e.endArray();
        try e.key("timeout_ms");
        try e.uint(PERMISSION_TIMEOUT_MS);
        try e.endObject();
        const line = try app.gpa.dupe(u8, e.text());
        self.entry.queue.push(line) catch app.gpa.free(line);

        // 等待应答（超时 → 拒绝，且**原因必须是 TIMED_OUT**）
        const deadline = util.io.monotonicMillis(app.io) + @as(i64, @intCast(PERMISSION_TIMEOUT_MS));
        while (util.io.monotonicMillis(app.io) < deadline) {
            slot.mutex.lock(app.io) catch break;
            const got = slot.response;
            slot.mutex.unlock(app.io);
            if (got) |r| return r;
            util.io.sleep(app.io, 50) catch {};
        }
        return .{
            .allowed = false,
            .message = common.perm.Response.MSG_TIMEOUT,
            .denial_reason = .timed_out,
        };
    }
};

/// 从 JSON body 里取 `prompt` 或 `message.content`。
pub fn extractPrompt(arena: Allocator, body: []const u8) ![]const u8 {
    var a = std.heap.ArenaAllocator.init(arena);
    defer a.deinit();
    const v = common.json.parse(a.allocator(), body) catch return error.BadBody;
    if (v.getString("prompt")) |p| return arena.dupe(u8, p);
    if (v.get("message")) |m| {
        if (m.getString("content")) |c| return arena.dupe(u8, c);
    }
    return error.BadBody;
}

pub fn extractOptionId(arena: Allocator, body: []const u8) ![]const u8 {
    var a = std.heap.ArenaAllocator.init(arena);
    defer a.deinit();
    const v = common.json.parse(a.allocator(), body) catch return "reject_once";
    if (v.getString("option_id")) |o| return arena.dupe(u8, o);
    if (v.getString("optionId")) |o| return arena.dupe(u8, o);
    return "reject_once";
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "app: health 标记与版本" {
    try testing.expectEqualStrings("zigent-ready", HEALTH_MARKER);
}

test "app: 提取 prompt 的两种形态" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const p1 = try extractPrompt(arena.allocator(), "{\"prompt\":\"你好\"}");
    try testing.expectEqualStrings("你好", p1);
    const p2 = try extractPrompt(arena.allocator(), "{\"message\":{\"role\":\"user\",\"content\":\"hi\"}}");
    try testing.expectEqualStrings("hi", p2);
    try testing.expectError(error.BadBody, extractPrompt(arena.allocator(), "{}"));
}

test "app: 权限 option_id 映射（默认拒绝）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const o = try extractOptionId(arena.allocator(), "{\"option_id\":\"allow_always\"}");
    try testing.expectEqualStrings("allow_always", o);
    const d = try extractOptionId(arena.allocator(), "{}");
    try testing.expectEqualStrings("reject_once", d);
    const resp = common.perm.responseForOption(d);
    try testing.expect(!resp.allowed);
}

test "app: 权限超时原因必须是 TIMED_OUT（不是 USER_DENIED）" {
    const timeout = common.perm.Response{
        .allowed = false,
        .message = common.perm.Response.MSG_TIMEOUT,
        .denial_reason = .timed_out,
    };
    try testing.expectEqual(common.perm.DenialReason.timed_out, timeout.denial_reason.?);
    try testing.expect(!std.mem.eql(u8, timeout.message, common.perm.Response.MSG_DENIED));
}

test "app: 提取 prompt 对坏 JSON 报错而不是崩溃" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.BadBody, extractPrompt(arena.allocator(), "not json"));
}
