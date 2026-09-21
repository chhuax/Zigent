//! SSE（Server-Sent Events）**读入侧**纯字节状态机 —— 零 IO、零 `std.json`。
//!
//! 硬约束（`spike/zig-m0/移植雷区.md` §A，逐条对应）：
//!   A1 只在**空行**处提交事件（空行 = 事件边界）
//!   A2 多行 `data:` 用 `'\n'` 拼接
//!   A3 流末尾没有空行时，最后一条事件也必须 flush（`finish()`）
//!   A4 以 `:` 开头的是注释行（心跳），忽略
//!   A5 字段值前**恰好一个**空格被剥离（`data: x`→`x`，`data:  x`→` x`）
//!   A6 行终止符 LF / CRLF / 裸 CR 都认
//!   A7 body reader 是分块的 —— **不能假设一次 read() = 一行 = 一个事件**
//!
//! 这是"拉"式解码器（契约 §4.2：`init/feed/finish/next/deinit`）：
//! `feed()` 只解析并**入队**已提交的事件，`next()` 逐个取出。
//! 一次 `feed()` 可以产出 0..N 个事件；一个事件也可能横跨多次 `feed()`。
//!
//! 生命周期：`next()` 返回的 `Event` 切片由 Decoder 拥有，**在下一次
//! `next()` 调用或 `deinit()` 之前有效**（要跨调用持有请自行 `dupe`）。

const std = @import("std");
const Allocator = std.mem.Allocator;

/// 一次已提交的 SSE 事件。`event` 为 `null` 表示该帧没有 `event:` 字段。
pub const Event = struct {
    event: ?[]const u8 = null,
    data: []const u8 = "",
    id: []const u8 = "",
};

/// 三家 provider 的流类型 —— 结束信号完全不同（最容易做错的地方）。
pub const StreamKind = enum {
    openai_chat,
    anthropic_messages,
    openai_responses,
};

/// 流的终态分类结果。
pub const TerminalSignal = enum {
    /// 还有数据
    pending,
    /// OpenAI Chat: `data: [DONE]`
    openai_done,
    /// Anthropic: `message_stop`
    message_stop,
    /// OpenAI Responses: `[DONE]` 是**错误信号**，不是正常结束
    responses_done_is_error,
};

/// 提前断流的文案是契约的一部分（既有实现侧两处抛 RetriableException）。
pub const ERR_OPENAI_PREMATURE = "OpenAI stream closed before [DONE]";
pub const ERR_ANTHROPIC_PREMATURE = "Anthropic stream closed before message_stop";
/// 零事件的 200 响应：必须单独识别（否则拿到 HTML 错误页时无从诊断）。
pub const ERR_EMPTY_STREAM = "provider returned an empty stream";

/// 判断某个 `data:` 载荷是否是结束信号。
pub fn classifyTerminal(kind: StreamKind, data: []const u8) TerminalSignal {
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    switch (kind) {
        .openai_chat => {
            if (std.mem.eql(u8, trimmed, "[DONE]")) return .openai_done;
        },
        .openai_responses => {
            // Responses 的 [DONE] 表示出错了，不是正常结束
            if (std.mem.eql(u8, trimmed, "[DONE]")) return .responses_done_is_error;
        },
        .anthropic_messages => {
            // Anthropic 没有 [DONE]，靠 message_stop。保守的子串判定。
            if (std.mem.indexOf(u8, trimmed, "\"message_stop\"") != null) return .message_stop;
        },
    }
    return .pending;
}

pub const Decoder = struct {
    gpa: Allocator,

    /// 跨 chunk 的未完成行（A7 的关键）
    partial: std.ArrayListUnmanaged(u8) = .empty,
    /// 已累积的 `data:` 内容（A2 用 '\n' 连接）
    data_buf: std.ArrayListUnmanaged(u8) = .empty,
    name_buf: std.ArrayListUnmanaged(u8) = .empty,
    id_buf: std.ArrayListUnmanaged(u8) = .empty,
    data_seen: bool = false,
    /// CRLF 跨 chunk 时 `'\r'` 是最后一个字节 —— 需要记住它
    saw_cr: bool = false,
    finished: bool = false,

    /// 已提交但**尚未被 next() 取走**的事件队列。
    queue: std.ArrayListUnmanaged(Owned) = .empty,
    head: usize = 0,
    /// 上一次 next() 返回的事件（保活到下一次 next()）。
    current: ?Owned = null,

    const Owned = struct { name: []u8, data: []u8, id: []u8 };

    pub fn init(gpa: Allocator) Decoder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Decoder) void {
        if (self.current) |c| freeOwned(self.gpa, c);
        if (self.head < self.queue.items.len) {
            for (self.queue.items[self.head..]) |c| freeOwned(self.gpa, c);
        }
        self.queue.deinit(self.gpa);
        self.partial.deinit(self.gpa);
        self.data_buf.deinit(self.gpa);
        self.name_buf.deinit(self.gpa);
        self.id_buf.deinit(self.gpa);
        self.* = undefined;
    }

    fn freeOwned(gpa: Allocator, c: Owned) void {
        gpa.free(c.name);
        gpa.free(c.data);
        gpa.free(c.id);
    }

    /// 喂入任意大小的 chunk。可以逐字节喂（A7 的极端情形）。
    pub fn feed(self: *Decoder, bytes: []const u8) !void {
        if (self.finished) return error.AlreadyFinished;
        for (bytes) |c| {
            if (self.saw_cr) {
                self.saw_cr = false;
                if (c == '\n') continue; // CRLF：行已在 '\r' 处处理
            }
            switch (c) {
                '\n' => try self.endOfLine(),
                '\r' => {
                    try self.endOfLine();
                    self.saw_cr = true;
                },
                else => try self.partial.append(self.gpa, c),
            }
        }
    }

    /// A3：流结束时调用。若最后一条事件没有结尾空行，仍然要提交。
    pub fn finish(self: *Decoder) !void {
        if (self.finished) return;
        self.finished = true;
        self.saw_cr = false;
        if (self.partial.items.len > 0) try self.endOfLine();
        // 没有尾随空行 → 这里补提交
        if (self.data_seen) try self.commit();
    }

    /// 取下一条已提交的事件；没有则返回 `null`。
    pub fn next(self: *Decoder) ?Event {
        if (self.current) |c| {
            freeOwned(self.gpa, c);
            self.current = null;
        }
        if (self.head >= self.queue.items.len) {
            if (self.queue.items.len > 0) self.queue.clearRetainingCapacity();
            self.head = 0;
            return null;
        }
        const it = self.queue.items[self.head];
        self.head += 1;
        if (self.head == self.queue.items.len) {
            self.queue.clearRetainingCapacity();
            self.head = 0;
        }
        self.current = it;
        return .{
            .event = if (it.name.len == 0) null else it.name,
            .data = it.data,
            .id = it.id,
        };
    }

    fn endOfLine(self: *Decoder) !void {
        const line = self.partial.items;
        defer self.partial.clearRetainingCapacity();
        try self.processLine(line);
    }

    fn processLine(self: *Decoder, line: []const u8) !void {
        if (line.len == 0) {
            try self.commit(); // A1
            return;
        }
        if (line[0] == ':') return; // A4：注释 / 心跳

        var field: []const u8 = line;
        var value: []const u8 = "";
        if (std.mem.indexOfScalar(u8, line, ':')) |i| {
            field = line[0..i];
            value = line[i + 1 ..];
            if (value.len > 0 and value[0] == ' ') value = value[1..]; // A5：恰好一个
        }

        if (std.mem.eql(u8, field, "data")) {
            if (self.data_seen) try self.data_buf.append(self.gpa, '\n'); // A2
            try self.data_buf.appendSlice(self.gpa, value);
            self.data_seen = true;
        } else if (std.mem.eql(u8, field, "event")) {
            self.name_buf.clearRetainingCapacity();
            try self.name_buf.appendSlice(self.gpa, value);
        } else if (std.mem.eql(u8, field, "id")) {
            self.id_buf.clearRetainingCapacity();
            try self.id_buf.appendSlice(self.gpa, value);
        } else {
            // retry: 等字段本层不消费
        }
    }

    fn commit(self: *Decoder) !void {
        if (!self.data_seen) {
            // 只有 event:/id: 没有 data: → 按规范不产生事件。
            // 但要清掉悬挂的 event name，避免污染下一个事件。
            self.name_buf.clearRetainingCapacity();
            return;
        }
        const owned = Owned{
            .name = try self.gpa.dupe(u8, self.name_buf.items),
            .data = try self.gpa.dupe(u8, self.data_buf.items),
            .id = try self.gpa.dupe(u8, self.id_buf.items),
        };
        errdefer freeOwned(self.gpa, owned);
        try self.queue.append(self.gpa, owned);
        self.data_buf.clearRetainingCapacity();
        self.data_seen = false;
        // `event:` 的作用域是单个事件（规范），这里也清掉
        self.name_buf.clearRetainingCapacity();
    }
};

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// 测试辅助：把 decoder 里所有事件拷进列表，便于断言。
const Collected = struct {
    gpa: Allocator,
    items: std.ArrayListUnmanaged(Item) = .empty,

    const Item = struct { event: ?[]u8, data: []u8, id: []u8 };

    fn drain(self: *Collected, d: *Decoder) !void {
        while (d.next()) |ev| {
            try self.items.append(self.gpa, .{
                .event = if (ev.event) |e| try self.gpa.dupe(u8, e) else null,
                .data = try self.gpa.dupe(u8, ev.data),
                .id = try self.gpa.dupe(u8, ev.id),
            });
        }
    }

    fn deinit(self: *Collected) void {
        for (self.items.items) |it| {
            if (it.event) |e| self.gpa.free(e);
            self.gpa.free(it.data);
            self.gpa.free(it.id);
        }
        self.items.deinit(self.gpa);
    }
};

test "SSE: 基本事件与多行 data（A1/A2/A5）" {
    const gpa = testing.allocator;
    var p = Decoder.init(gpa);
    defer p.deinit();
    var got = Collected{ .gpa = gpa };
    defer got.deinit();

    try p.feed("event: content_block_delta\n");
    try p.feed("data: {\"a\":1}\n");
    try p.feed("data: {\"b\":2}\n");
    try p.feed("\n");
    try got.drain(&p);

    try testing.expectEqual(@as(usize, 1), got.items.items.len);
    try testing.expectEqualStrings("content_block_delta", got.items.items[0].event.?);
    // A2：多行用 '\n' 连接
    try testing.expectEqualStrings("{\"a\":1}\n{\"b\":2}", got.items.items[0].data);
}

test "SSE: 字段值前恰好一个空格被剥离（A5）" {
    const gpa = testing.allocator;
    var p = Decoder.init(gpa);
    defer p.deinit();
    var got = Collected{ .gpa = gpa };
    defer got.deinit();

    try p.feed("data: one-space\n\n");
    try p.feed("data:  two-spaces\n\n");
    try p.feed("data:no-space\n\n");
    try got.drain(&p);

    try testing.expectEqual(@as(usize, 3), got.items.items.len);
    try testing.expectEqualStrings("one-space", got.items.items[0].data);
    try testing.expectEqualStrings(" two-spaces", got.items.items[1].data);
    try testing.expectEqualStrings("no-space", got.items.items[2].data);
}

test "SSE: 注释行被忽略（A4 —— 心跳不算事件）" {
    const gpa = testing.allocator;
    var p = Decoder.init(gpa);
    defer p.deinit();
    var got = Collected{ .gpa = gpa };
    defer got.deinit();

    try p.feed(": this is a comment\n");
    try p.feed(": ping\n\n");
    try p.feed("data: x\n\n");
    try got.drain(&p);
    try testing.expectEqual(@as(usize, 1), got.items.items.len);
    try testing.expectEqualStrings("x", got.items.items[0].data);
}

test "SSE: 逐字节喂入（A7 —— body reader 分块的极端情形）" {
    const gpa = testing.allocator;
    const payload = "event: message_delta\ndata: {\"usage\":1}\n\n";
    var p = Decoder.init(gpa);
    defer p.deinit();
    var got = Collected{ .gpa = gpa };
    defer got.deinit();

    for (payload) |c| try p.feed(&[_]u8{c});
    try got.drain(&p);

    try testing.expectEqual(@as(usize, 1), got.items.items.len);
    try testing.expectEqualStrings("message_delta", got.items.items[0].event.?);
    try testing.expectEqualStrings("{\"usage\":1}", got.items.items[0].data);
}

test "SSE: EOF 无尾随空行也要 flush（A3 —— 丢 message_stop 的经典原因）" {
    const gpa = testing.allocator;
    var p = Decoder.init(gpa);
    defer p.deinit();
    var got = Collected{ .gpa = gpa };
    defer got.deinit();

    try p.feed("data: {\"type\":\"message_stop\"}\n");
    try got.drain(&p);
    try testing.expectEqual(@as(usize, 0), got.items.items.len); // 还没提交
    try p.finish(); // A3
    try got.drain(&p);
    try testing.expectEqual(@as(usize, 1), got.items.items.len);
    try testing.expectEqualStrings("{\"type\":\"message_stop\"}", got.items.items[0].data);
}

test "SSE: CRLF 与裸 CR 都是合法行终止符（A6）" {
    const gpa = testing.allocator;
    var p = Decoder.init(gpa);
    defer p.deinit();
    var got = Collected{ .gpa = gpa };
    defer got.deinit();

    try p.feed("data: crlf\r\n\r\n");
    try p.feed("data: bare-cr\r\r");
    try p.feed("data: cr-at-chunk-end\r"); // 裸 CR 结束行
    try p.feed("\n"); // CRLF 跨 chunk：'\n' 被吞掉，不产生空行
    try p.feed("\n"); // 空行 → 提交
    try got.drain(&p);

    try testing.expectEqual(@as(usize, 3), got.items.items.len);
    try testing.expectEqualStrings("crlf", got.items.items[0].data);
    try testing.expectEqualStrings("bare-cr", got.items.items[1].data);
    try testing.expectEqualStrings("cr-at-chunk-end", got.items.items[2].data);
}

test "SSE: 结束信号三家不同（最容易做错的地方）" {
    try testing.expectEqual(TerminalSignal.openai_done, classifyTerminal(.openai_chat, "[DONE]"));
    try testing.expectEqual(TerminalSignal.openai_done, classifyTerminal(.openai_chat, " [DONE] \n"));
    // Anthropic 没有 [DONE]
    try testing.expectEqual(TerminalSignal.pending, classifyTerminal(.anthropic_messages, "[DONE]"));
    try testing.expectEqual(TerminalSignal.message_stop, classifyTerminal(.anthropic_messages, "{\"type\":\"message_stop\"}"));
    // Responses 的 [DONE] 是错误
    try testing.expectEqual(TerminalSignal.responses_done_is_error, classifyTerminal(.openai_responses, "[DONE]"));
}

test "SSE: 只有 event: 没有 data: 不产生事件，且 event 名不污染下一个事件" {
    const gpa = testing.allocator;
    var p = Decoder.init(gpa);
    defer p.deinit();
    var got = Collected{ .gpa = gpa };
    defer got.deinit();

    try p.feed("event: orphan\n\n");
    try got.drain(&p);
    try testing.expectEqual(@as(usize, 0), got.items.items.len);
    try p.feed("data: real\n\n");
    try got.drain(&p);
    try testing.expectEqual(@as(usize, 1), got.items.items.len);
    try testing.expect(got.items.items[0].event == null); // 不被 orphan 污染
    try testing.expectEqualStrings("real", got.items.items[0].data);
}

test "SSE: 空行分割的多帧在一次 feed 里全部提交（一次 read ≠ 一个事件）" {
    const gpa = testing.allocator;
    var p = Decoder.init(gpa);
    defer p.deinit();
    var got = Collected{ .gpa = gpa };
    defer got.deinit();

    try p.feed("data: a\n\ndata: b\n\ndata: c\n\n");
    try got.drain(&p);
    try testing.expectEqual(@as(usize, 3), got.items.items.len);
    try testing.expectEqualStrings("a", got.items.items[0].data);
    try testing.expectEqualStrings("c", got.items.items[2].data);
}

test "SSE: 帧从中间被切开也不丢（A7）" {
    const gpa = testing.allocator;
    const frame = "event: message_delta\ndata: {\"usage\":{\"output_tokens\":7}}\n\n";
    // 在每一个位置切一刀，都必须解析出同一条事件
    var cut: usize = 0;
    while (cut <= frame.len) : (cut += 1) {
        var p = Decoder.init(gpa);
        defer p.deinit();
        var got = Collected{ .gpa = gpa };
        defer got.deinit();

        try p.feed(frame[0..cut]);
        try p.feed(frame[cut..]);
        try p.finish();
        try got.drain(&p);
        try testing.expectEqual(@as(usize, 1), got.items.items.len);
        try testing.expectEqualStrings("message_delta", got.items.items[0].event.?);
        try testing.expectEqualStrings("{\"usage\":{\"output_tokens\":7}}", got.items.items[0].data);
    }
}

test "SSE: id 字段透传，retry 字段不产生事件" {
    const gpa = testing.allocator;
    var p = Decoder.init(gpa);
    defer p.deinit();
    var got = Collected{ .gpa = gpa };
    defer got.deinit();

    try p.feed("retry: 3000\nid: 42\ndata: x\n\n");
    try got.drain(&p);
    try testing.expectEqual(@as(usize, 1), got.items.items.len);
    try testing.expectEqualStrings("42", got.items.items[0].id);
    try testing.expectEqualStrings("x", got.items.items[0].data);
}

test "SSE: next() 逐个取出，返回值在下次 next() 前有效" {
    const gpa = testing.allocator;
    var p = Decoder.init(gpa);
    defer p.deinit();
    try p.feed("data: one\n\ndata: two\n\n");
    const a = p.next().?;
    try testing.expectEqualStrings("one", a.data);
    try p.finish();
    const b = p.next().?;
    try testing.expectEqualStrings("two", b.data);
    try testing.expect(p.next() == null);
}
