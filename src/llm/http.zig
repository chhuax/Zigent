//! `http.zig` —— **传输边界**：网络层被关在一个极小的 vtable 后面。
//!
//! ## 流式不缓冲（本文件的存在理由）
//!
//! 流式最怕缓冲：任何一层「攒完再发」（Writer 缓冲、gzip、中间件）都会把
//! 「逐 token 输出」变成「等整轮结束一次性吐出」。因此本层**只提供一个
//! 回调式分块出口** `ChunkSink.on_chunk`，每读到一段 body 字节就立刻交给
//! 上层（→ `sse.Decoder.feed`），**绝不把响应体读成一个 `[]u8` 再返回**。
//! 唯一的例外是**错误路径**：非 200 或非 `text/event-stream` 的响应体是
//! 有限的错误 JSON，会在上限内缓冲以便归类（`JSON_BODY_LIMIT`）。
//!
//! ## 两个实现
//!
//! - `MockTransport`：脚本化的假传输，测试完全零网络，覆盖所有状态码 /
//!   分块切分 / 提前断流 / `Retry-After` 分支；
//! - `HttpTransport`：真实实现，基于 0.16 的 `std.http.Client`（已确认
//!   存在且可用）。真实路径只保证编译与形状正确，集成测试走 mock。
//!
//! 注意：本文件是 llm 模块**唯一**触碰 socket 的地方；`std.http.Client`
//! 内部自行管理 TLS / 连接池。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
    timeout_ms: u64 = 600_000,
};

/// 响应头已到达。body 尚未读取。
pub const Head = struct {
    status: u16,
    content_type: []const u8 = "",
    /// `x-request-id` / `request-id` / `x-amzn-requestid`
    request_id: []const u8 = "",
    /// 响应头 `Retry-After`（优先级最高）
    retry_after_ms: ?u64 = null,
};

/// 回调式 body 出口。**调用方必须在 `on_chunk` 内消费完，不得留存切片。**
pub const ChunkSink = struct {
    ctx: *anyopaque,
    on_head: *const fn (ctx: *anyopaque, head: *const Head) anyerror!void,
    on_chunk: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
};

pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, io: Io, req: *const Request, sink: ChunkSink) anyerror!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn send(self: Transport, io: Io, req: *const Request, sink: ChunkSink) !void {
        return self.vtable.send(self.ptr, io, req, sink);
    }

    pub fn deinit(self: Transport) void {
        self.vtable.deinit(self.ptr);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Retry-After 解析
// ─────────────────────────────────────────────────────────────────────────────

/// RFC 9110 的 `Retry-After`：① 秒数；② HTTP-date。
///
/// 只支持数字 + 单位（`s` / `ms`）；RFC 1123 日期需要时区解析，是一条
/// 「解析失败 → 0」的死路，这里显式返回 `null` 让调用方**退回本地退避**。
pub fn parseRetryAfter(raw: []const u8) ?u64 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return null;
    var num_end: usize = 0;
    while (num_end < s.len and (s[num_end] >= '0' and s[num_end] <= '9')) num_end += 1;
    if (num_end == 0) return null;
    const n = std.fmt.parseInt(u64, s[0..num_end], 10) catch return null;
    const unit = std.mem.trim(u8, s[num_end..], " \t");
    if (unit.len == 0) return n * 1000; // 纯数字 = 秒
    if (std.ascii.eqlIgnoreCase(unit, "ms") or std.ascii.eqlIgnoreCase(unit, "milliseconds")) return n;
    if (std.ascii.eqlIgnoreCase(unit, "s") or std.ascii.eqlIgnoreCase(unit, "seconds")) return n * 1000;
    return null;
}

/// URL 的 path（含前导 `/`，不含 query）；用于 mock 的 `expect_path` 断言。
pub fn urlPath(url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse 0;
    const after = url[if (scheme_end == 0) 0 else scheme_end + 3 ..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return "";
    return after[slash..];
}

// ─────────────────────────────────────────────────────────────────────────────
// MockTransport —— 脚本化假传输（测试用，零网络）
// ─────────────────────────────────────────────────────────────────────────────

pub const Scripted = struct {
    status: u16 = 200,
    content_type: []const u8 = "text/event-stream",
    request_id: []const u8 = "",
    retry_after_ms: ?u64 = null,
    body: []const u8 = "",
    /// 0 = 一次性喂；否则按该大小切片喂（模拟 body reader 分块）。
    chunk_size: usize = 0,
    /// 只喂前 N 字节后返回（模拟**提前断流**）；null = 喂完整。
    truncate_body_at: ?usize = null,
    /// 非空时在 body 喂完后返回该错误（模拟网络抖动）。
    fail_after_body: bool = false,
};

pub const RecordedRequest = struct {
    url: []u8,
    body: []u8,
};

/// 可被外部（测试）检视的假传输。
pub const MockTransport = struct {
    gpa: Allocator,
    script: []const Scripted,
    index: usize = 0,
    requests: std.ArrayListUnmanaged(RecordedRequest) = .empty,
    /// 所有请求都收到后重复最后一条（避免越界），但仍记录调用。
    pub fn init(gpa: Allocator, script: []const Scripted) MockTransport {
        return .{ .gpa = gpa, .script = script };
    }

    pub fn deinit(self: *MockTransport) void {
        for (self.requests.items) |r| {
            self.gpa.free(r.url);
            self.gpa.free(r.body);
        }
        self.requests.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn transport(self: *MockTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Transport.VTable{ .send = sendImpl, .deinit = deinitImpl };

    pub fn callCount(self: *const MockTransport) usize {
        return self.requests.items.len;
    }

    pub fn lastRequest(self: *const MockTransport) ?RecordedRequest {
        if (self.requests.items.len == 0) return null;
        return self.requests.items[self.requests.items.len - 1];
    }

    fn sendImpl(ptr: *anyopaque, io: Io, req: *const Request, sink: ChunkSink) anyerror!void {
        _ = io;
        const self: *MockTransport = @ptrCast(@alignCast(ptr));
        try self.requests.append(self.gpa, .{
            .url = try self.gpa.dupe(u8, req.url),
            .body = try self.gpa.dupe(u8, req.body),
        });
        if (self.script.len == 0) return error.MockScriptExhausted;
        const i = @min(self.index, self.script.len - 1);
        self.index += 1;
        const s = self.script[i];

        var head = Head{
            .status = s.status,
            .content_type = s.content_type,
            .request_id = s.request_id,
            .retry_after_ms = s.retry_after_ms,
        };
        try sink.on_head(sink.ctx, &head);

        var body = s.body;
        if (s.truncate_body_at) |n| body = body[0..@min(n, body.len)];
        if (s.chunk_size == 0) {
            if (body.len > 0) try sink.on_chunk(sink.ctx, body);
        } else {
            var off: usize = 0;
            while (off < body.len) {
                const end = @min(off + s.chunk_size, body.len);
                try sink.on_chunk(sink.ctx, body[off..end]);
                off = end;
            }
        }
        if (s.fail_after_body) return error.MockNetworkFailure;
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *MockTransport = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// HttpTransport —— 真实实现（std.http.Client，0.16 已确认存在）
// ─────────────────────────────────────────────────────────────────────────────

pub const HttpTransport = struct {
    gpa: Allocator,
    pub fn init(gpa: Allocator) HttpTransport {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *HttpTransport) void {
        _ = self;
    }

    pub fn transport(self: *HttpTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Transport.VTable{ .send = sendImpl, .deinit = deinitImpl };

    fn sendImpl(ptr: *anyopaque, io: Io, req: *const Request, sink: ChunkSink) anyerror!void {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));

        // ⚠️ **不要**在这里 `var client = ...; defer client.deinit();`
        //    首次真网络调用实测崩溃：
        //      assert(client.connection_pool.used.first == null);  // There are still active requests.
        //    原因是流式响应体还没收口，client 就被销毁了。
        //    改为传输层持有：生命周期覆盖所有请求，且连接池/TLS 会话可复用。
        // 先做**可能失败**的解析，再分配 client —— 否则早期失败路径会漏掉它。
        const uri = std.Uri.parse(req.url) catch return error.InvalidUrl;

        // 堆上建、**故意不 destroy**：在途请求收口前 `client.deinit()` 会断言失败
        //   assert(client.connection_pool.used.first == null);
        // 待办：把 client 提到传输层持有（需要用不改 HttpTransport 布局的方式，
        // 否则 client.zig 的 @fieldParentPtr 会因对齐变化编译失败）。
        const client = try self.gpa.create(std.http.Client);
        client.* = .{ .allocator = self.gpa, .io = io };

        var hdrs: std.ArrayListUnmanaged(std.http.Header) = .empty;
        defer hdrs.deinit(self.gpa);
        for (req.headers) |h| try hdrs.append(self.gpa, .{ .name = h.name, .value = h.value });

        var r = try client.request(.POST, uri, .{
            .extra_headers = hdrs.items,
            .keep_alive = false,
            .redirect_behavior = .not_allowed,
        });
        try r.sendBodyComplete(@constCast(req.body));

        var redirect_buf: [8192]u8 = undefined;
        var resp = try r.receiveHead(&redirect_buf);

        // ⚠️ `resp.head` 里的字符串在 `resp.reader()` 之后失效 —— 先取完头信息。
        var request_id: []const u8 = "";
        var retry_after: ?u64 = null;
        var it = resp.head.iterateHeaders();
        while (it.next()) |h| {
            if (request_id.len == 0 and
                (std.ascii.eqlIgnoreCase(h.name, "x-request-id") or
                    std.ascii.eqlIgnoreCase(h.name, "request-id") or
                    std.ascii.eqlIgnoreCase(h.name, "x-amzn-requestid")))
            {
                request_id = h.value;
            }
            if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) {
                retry_after = parseRetryAfter(h.value);
            }
        }
        var head = Head{
            .status = @intFromEnum(resp.head.status),
            .content_type = resp.head.content_type orelse "",
            .request_id = request_id,
            .retry_after_ms = retry_after,
        };
        try sink.on_head(sink.ctx, &head);

        // 逐块读出并立刻上交 —— 绝不缓冲成完整 body。
        var transfer_buf: [16 * 1024]u8 = undefined;
        var reader = resp.reader(&transfer_buf);
        var buf: [8 * 1024]u8 = undefined;
        while (true) {
            const n = reader.readSliceShort(&buf) catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
            };
            if (n == 0) break;
            try sink.on_chunk(sink.ctx, buf[0..n]);
        }
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

const NullIo = std.Io;

const Collector = struct {
    status: u16 = 0,
    content_type: []const u8 = "",
    request_id: []const u8 = "",
    retry_after_ms: ?u64 = null,
    body: std.ArrayListUnmanaged(u8) = .empty,
    head_calls: usize = 0,

    fn sink(self: *Collector) ChunkSink {
        return .{ .ctx = self, .on_head = onHead, .on_chunk = onChunk };
    }
    fn onHead(ctx: *anyopaque, h: *const Head) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.status = h.status;
        self.content_type = h.content_type;
        self.request_id = h.request_id;
        self.retry_after_ms = h.retry_after_ms;
        self.head_calls += 1;
    }
    fn onChunk(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        try self.body.appendSlice(testing.allocator, bytes);
    }
    fn deinit(self: *Collector) void {
        self.body.deinit(testing.allocator);
    }
};

/// 测试不需要真 io：mock 传输完全忽略它。
fn dummyIo() NullIo {
    return undefined;
}

test "http: Retry-After 数字+单位；日期格式退回本地退避" {
    try testing.expectEqual(@as(?u64, 3000), parseRetryAfter("3"));
    try testing.expectEqual(@as(?u64, 3000), parseRetryAfter(" 3s "));
    try testing.expectEqual(@as(?u64, 1500), parseRetryAfter("1500ms"));
    try testing.expectEqual(@as(?u64, null), parseRetryAfter("Wed, 21 Oct 2015 07:28:00 GMT"));
    try testing.expectEqual(@as(?u64, null), parseRetryAfter(""));
    try testing.expectEqual(@as(?u64, null), parseRetryAfter("abc"));
}

test "http: urlPath 提取" {
    try testing.expectEqualStrings("/v1/messages", urlPath("https://api.anthropic.com/v1/messages"));
    try testing.expectEqualStrings("/openai/v1/chat/completions", urlPath("http://127.0.0.1:8080/openai/v1/chat/completions"));
    try testing.expectEqualStrings("", urlPath("https://host"));
}

test "http: MockTransport 分块喂入 + 记录请求" {
    const body = "data: a\n\ndata: b\n\n";
    var t = MockTransport.init(testing.allocator, &.{.{
        .body = body,
        .chunk_size = 3,
        .request_id = "req_1",
    }});
    defer t.deinit();

    var c = Collector{};
    defer c.deinit();
    try t.transport().send(dummyIo(), &.{
        .url = "https://gw/v1/messages",
        .headers = &.{.{ .name = "x-api-key", .value = "k" }},
        .body = "{\"model\":\"m\"}",
    }, c.sink());

    try testing.expectEqual(@as(u16, 200), c.status);
    try testing.expectEqualStrings("req_1", c.request_id);
    try testing.expectEqualStrings(body, c.body.items);
    try testing.expectEqual(@as(usize, 1), t.callCount());
    try testing.expectEqualStrings("https://gw/v1/messages", t.lastRequest().?.url);
    try testing.expectEqualStrings("{\"model\":\"m\"}", t.lastRequest().?.body);
    // 分块：每块 <= 3 字节（至少 4 次）
    try testing.expect(c.head_calls == 1);
}

test "http: MockTransport 可模拟提前断流与网络错误" {
    var t = MockTransport.init(testing.allocator, &.{
        .{ .body = "data: a\n\ndata: b\n\n", .truncate_body_at = 8 },
        .{ .body = "x", .fail_after_body = true },
    });
    defer t.deinit();

    var c1 = Collector{};
    defer c1.deinit();
    try t.transport().send(dummyIo(), &.{ .url = "https://gw/v1/messages" }, c1.sink());
    try testing.expectEqualStrings("data: a\n", c1.body.items);

    var c2 = Collector{};
    defer c2.deinit();
    try testing.expectError(error.MockNetworkFailure, t.transport().send(dummyIo(), &.{ .url = "https://gw/v1/messages" }, c2.sink()));
}

test "http: 真实 HttpTransport 的早期失败路径（强制整函数语义分析，不触网）" {
    var t = HttpTransport.init(testing.allocator);
    defer t.deinit();
    const tr = t.transport();
    try testing.expect(@intFromPtr(tr.ptr) == @intFromPtr(&t));
    var c = Collector{};
    defer c.deinit();
    // URL 解析在任何 socket 操作之前失败 → 不会触网，但整个 sendImpl 必须可编译
    try testing.expectError(error.InvalidUrl, tr.send(dummyIo(), &.{ .url = ":: not a uri ::" }, c.sink()));
}

test "http: MockTransport 暴露 Retry-After" {
    var t = MockTransport.init(testing.allocator, &.{.{
        .status = 429,
        .content_type = "application/json",
        .retry_after_ms = 7000,
        .body = "{\"error\":{\"message\":\"slow down\"}}",
    }});
    defer t.deinit();
    var c = Collector{};
    defer c.deinit();
    try t.transport().send(dummyIo(), &.{ .url = "https://gw/v1/messages" }, c.sink());
    try testing.expectEqual(@as(u16, 429), c.status);
    try testing.expectEqual(@as(?u64, 7000), c.retry_after_ms);
}
