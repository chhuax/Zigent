//! SSE (Server-Sent Events) 增量解析器 —— M0 spike E2 的核心件。
//!
//! 对齐既有语义
//! 的实测语义。见 ../移植雷区.md §A。要点：
//!
//! A1 只在空行处提交事件
//! A2 多行 data: 用 '\n' 拼接
//! A3 流末尾没有空行时，最后一条事件也必须 flush（finish()）
//! A4 ':' 开头是注释，忽略
//! A5 字段值前恰好一个空格被剥离
//! A6 LF / CRLF / 裸 CR 都是合法行终止符
//! A7 body reader 是分块的 —— feed() 必须能处理任意切分位置
//!
//! 设计取舍：不用 std.json、不依赖任何版本敏感的 std API。
//! 纯字节状态机 → 0.15 的 ArrayListUnmanaged 与 0.17 都能编。

const std = @import("std");

/// 一次已提交的 SSE 事件。
///
/// ⚠️ 生命周期：`name` / `data` / `id` 指向 Parser 的内部缓冲区，
/// **只在下一次 feed()/finish() 之前有效**。sink 必须在回调内消费完或自行拷贝。
pub const Event = struct {
 name: []const u8 = "",
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

/// 判断某个 data 载荷是否是结束信号。
pub fn classifyTerminal(kind: StreamKind, data: []const u8) TerminalSignal {
 const trimmed = std.mem.trim(u8, data, " \t\r\n");
 switch (kind) {
 .openai_chat => {
 if (std.mem.eql(u8, trimmed, "[DONE]")) return .openai_done;
 },
 .openai_responses => {
 // Responses 的 [DONE] 表示出错了（既有实现: ResponsesStreamListener L60-62 抛 RetriableException）
 if (std.mem.eql(u8, trimmed, "[DONE]")) return .responses_done_is_error;
 },
 .anthropic_messages => {
 // Anthropic 没有 [DONE]，靠 message_stop。这里做保守的子串判定。
 if (std.mem.indexOf(u8, trimmed, "\"message_stop\"") != null) return .message_stop;
 },
 }
 return .pending;
}

pub const Parser = struct {
 gpa: std.mem.Allocator,

 /// 跨 chunk 的未完成行（A7 的关键）
 partial: std.ArrayListUnmanaged(u8) = .empty,
 /// 已累积的 data: 内容（A2 用 '\n' 连接）
 data: std.ArrayListUnmanaged(u8) = .empty,
 name: std.ArrayListUnmanaged(u8) = .empty,
 id: std.ArrayListUnmanaged(u8) = .empty,
 data_seen: bool = false,
 /// CRLF 跨 chunk 时，'\r' 是最后一个字节 —— 需要记住它
 saw_cr: bool = false,

 pub fn init(gpa: std.mem.Allocator) Parser {
 return .{ .gpa = gpa };
 }

 pub fn deinit(self: *Parser) void {
 self.partial.deinit(self.gpa);
 self.data.deinit(self.gpa);
 self.name.deinit(self.gpa);
 self.id.deinit(self.gpa);
 }

 /// 喂入任意大小的 chunk。sink 需要有 `emit(Event) anyerror!void` 方法。
 pub fn feed(self: *Parser, chunk: []const u8, sink: anytype) !void {
 for (chunk) |c| {
 if (self.saw_cr) {
 self.saw_cr = false;
 if (c == '\n') continue; // CRLF：行已在 '\r' 处处理
 }
 switch (c) {
 '\n' => try self.endOfLine(sink),
 '\r' => {
 try self.endOfLine(sink);
 self.saw_cr = true;
 },
 else => try self.partial.append(self.gpa, c),
 }
 }
 }

 /// A3：流结束时调用。若最后一条事件没有结尾空行，仍然要提交。
 pub fn finish(self: *Parser, sink: anytype) !void {
 self.saw_cr = false;
 if (self.partial.items.len > 0) try self.endOfLine(sink);
 // 没有尾随空行 → 这里补提交
 if (self.data_seen) try self.commit(sink);
 }

 fn endOfLine(self: *Parser, sink: anytype) !void {
 const line = self.partial.items;
 defer self.partial.clearRetainingCapacity();
 try self.processLine(line, sink);
 }

 fn processLine(self: *Parser, line: []const u8, sink: anytype) !void {
 if (line.len == 0) {
 try self.commit(sink); // A1
 return;
 }
 if (line[0] == ':') return; // A4

 var field: []const u8 = line;
 var value: []const u8 = "";
 if (std.mem.indexOfScalar(u8, line, ':')) |i| {
 field = line[0..i];
 value = line[i + 1 ..];
 if (value.len > 0 and value[0] == ' ') value = value[1..]; // A5：恰好一个
 }

 if (std.mem.eql(u8, field, "data")) {
 if (self.data_seen) try self.data.append(self.gpa, '\n'); // A2
 try self.data.appendSlice(self.gpa, value);
 self.data_seen = true;
 } else if (std.mem.eql(u8, field, "event")) {
 self.name.clearRetainingCapacity();
 try self.name.appendSlice(self.gpa, value);
 } else if (std.mem.eql(u8, field, "id")) {
 self.id.clearRetainingCapacity();
 try self.id.appendSlice(self.gpa, value);
 } else {
 // retry: 等字段本 spike 不消费
 }
 }

 fn commit(self: *Parser, sink: anytype) !void {
 if (!self.data_seen) {
 // 只有 event:/id: 没有 data: → 按规范不产生事件。
 // 但要清掉悬挂的 event name，避免污染下一个事件。
 self.name.clearRetainingCapacity();
 return;
 }
 const ev = Event{
 .name = self.name.items,
 .data = self.data.items,
 .id = self.id.items,
 };
 try sink.emit(ev); // 必须在 clear 之前
 self.data.clearRetainingCapacity();
 self.data_seen = false;
 // 注意：`event:` 字段的作用域是单个事件（规范），所以这里也清掉
 self.name.clearRetainingCapacity();
 }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

/// 测试用 sink：把事件深拷贝进一个列表。
const Collected = struct {
 gpa: std.mem.Allocator,
 items: std.ArrayListUnmanaged(Owned) = .empty,

 const Owned = struct { name: []u8, data: []u8, id: []u8 };

 fn emit(self: *Collected, ev: Event) !void {
 try self.items.append(self.gpa, .{
 .name = try self.gpa.dupe(u8, ev.name),
 .data = try self.gpa.dupe(u8, ev.data),
 .id = try self.gpa.dupe(u8, ev.id),
 });
 }

 fn deinit(self: *Collected) void {
 for (self.items.items) |it| {
 self.gpa.free(it.name);
 self.gpa.free(it.data);
 self.gpa.free(it.id);
 }
 self.items.deinit(self.gpa);
 }
};

test "SSE: 基本事件与多行 data（A1/A2/A5）" {
 const gpa = std.testing.allocator;
 var p = Parser.init(gpa);
 defer p.deinit();
 var got = Collected{ .gpa = gpa };
 defer got.deinit();

 try p.feed("event: content_block_delta\n", &got);
 try p.feed("data: {\"a\":1}\n", &got);
 try p.feed("data: {\"b\":2}\n", &got);
 try p.feed("\n", &got);

 try std.testing.expectEqual(@as(usize, 1), got.items.items.len);
 try std.testing.expectEqualStrings("content_block_delta", got.items.items[0].name);
 // A2：多行用 '\n' 连接
 try std.testing.expectEqualStrings("{\"a\":1}\n{\"b\":2}", got.items.items[0].data);
}

test "SSE: 字段值前恰好一个空格被剥离（A5）" {
 const gpa = std.testing.allocator;
 var p = Parser.init(gpa);
 defer p.deinit();
 var got = Collected{ .gpa = gpa };
 defer got.deinit();

 try p.feed("data: one-space\n\n", &got);
 try p.feed("data: two-spaces\n\n", &got);
 try p.feed("data:no-space\n\n", &got);

 try std.testing.expectEqual(@as(usize, 3), got.items.items.len);
 try std.testing.expectEqualStrings("one-space", got.items.items[0].data);
 try std.testing.expectEqualStrings(" two-spaces", got.items.items[1].data);
 try std.testing.expectEqualStrings("no-space", got.items.items[2].data);
}

test "SSE: 注释行被忽略（A4）" {
 const gpa = std.testing.allocator;
 var p = Parser.init(gpa);
 defer p.deinit();
 var got = Collected{ .gpa = gpa };
 defer got.deinit();

 try p.feed(": this is a comment\n", &got);
 try p.feed("data: x\n\n", &got);
 try std.testing.expectEqual(@as(usize, 1), got.items.items.len);
 try std.testing.expectEqualStrings("x", got.items.items[0].data);
}

test "SSE: 逐字节喂入（A7 —— body reader 分块的极端情形）" {
 const gpa = std.testing.allocator;
 const payload = "event: message_delta\ndata: {\"usage\":1}\n\n";
 var p = Parser.init(gpa);
 defer p.deinit();
 var got = Collected{ .gpa = gpa };
 defer got.deinit();

 for (payload) |c| try p.feed(&[_]u8{c}, &got);

 try std.testing.expectEqual(@as(usize, 1), got.items.items.len);
 try std.testing.expectEqualStrings("message_delta", got.items.items[0].name);
 try std.testing.expectEqualStrings("{\"usage\":1}", got.items.items[0].data);
}

test "SSE: EOF 无尾随空行也要 flush（A3 —— 丢 message_stop 的经典原因）" {
 const gpa = std.testing.allocator;
 var p = Parser.init(gpa);
 defer p.deinit();
 var got = Collected{ .gpa = gpa };
 defer got.deinit();

 try p.feed("data: {\"type\":\"message_stop\"}\n", &got);
 try std.testing.expectEqual(@as(usize, 0), got.items.items.len); // 还没提交
 try p.finish(&got); // A3
 try std.testing.expectEqual(@as(usize, 1), got.items.items.len);
 try std.testing.expectEqualStrings("{\"type\":\"message_stop\"}", got.items.items[0].data);
}

test "SSE: CRLF 与裸 CR 都是合法行终止符（A6）" {
 const gpa = std.testing.allocator;
 var p = Parser.init(gpa);
 defer p.deinit();
 var got = Collected{ .gpa = gpa };
 defer got.deinit();

 try p.feed("data: crlf\r\n\r\n", &got);
 try p.feed("data: bare-cr\r\r", &got);
 try p.feed("data: cr-at-chunk-end\r", &got);
 try p.feed("\n", &got); // CRLF 跨 chunk

 try std.testing.expectEqual(@as(usize, 3), got.items.items.len);
 try std.testing.expectEqualStrings("crlf", got.items.items[0].data);
 try std.testing.expectEqualStrings("bare-cr", got.items.items[1].data);
 try std.testing.expectEqualStrings("cr-at-chunk-end", got.items.items[2].data);
}

test "SSE: 结束信号三家不同（最容易做错的地方）" {
 // OpenAI Chat
 try std.testing.expectEqual(TerminalSignal.openai_done, classifyTerminal(.openai_chat, "[DONE]"));
 try std.testing.expectEqual(TerminalSignal.openai_done, classifyTerminal(.openai_chat, " [DONE] \n"));
 // Anthropic 没有 [DONE]
 try std.testing.expectEqual(TerminalSignal.pending, classifyTerminal(.anthropic_messages, "[DONE]"));
 try std.testing.expectEqual(TerminalSignal.message_stop, classifyTerminal(.anthropic_messages, "{\"type\":\"message_stop\"}"));
 // Responses 的 [DONE] 是错误
 try std.testing.expectEqual(TerminalSignal.responses_done_is_error, classifyTerminal(.openai_responses, "[DONE]"));
}

test "SSE: 只有 event: 没有 data: 不产生事件，且 event 名不污染下一个事件" {
 const gpa = std.testing.allocator;
 var p = Parser.init(gpa);
 defer p.deinit();
 var got = Collected{ .gpa = gpa };
 defer got.deinit();

 try p.feed("event: orphan\n\n", &got);
 try std.testing.expectEqual(@as(usize, 0), got.items.items.len);
 try p.feed("data: real\n\n", &got);
 try std.testing.expectEqual(@as(usize, 1), got.items.items.len);
 try std.testing.expectEqualStrings("", got.items.items[0].name); // 不被 orphan 污染
 try std.testing.expectEqualStrings("real", got.items.items[0].data);
}
