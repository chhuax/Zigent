//! `engine/transcript.zig` —— JSONL 会话日志 + `parentUuid` 链 + resume。
//!
//! ## transcript 是**混合事件日志**，不是纯对话（雷区 J）
//!
//! ```
//! ~/.zigent/projects/<encoded-cwd>/transcripts/<sessionId>.jsonl
//! 每行: Entry{uuid, parentUuid, type, sessionId, timestamp, message, metadata}
//! ```
//!
//! - 对话链靠 **`parentUuid` 链表**重建，**不靠行序**：
//!   `latestLeaf` → 沿 parentUuid 回溯（去环）→ reverse。
//! - `type` 分流：参与对话链 = `message` / `compact_boundary` / `replay`；
//!   **不参与**（写同一文件但重建时跳过）= `tombstone` / `stop_metadata` /
//!   `inference_*` / `tool_*` / `error` / `retry` / `session_*` / `agent_*` / `file_*`。
//! - 重建时剔除**孤儿 tool_result**（保证送进模型的历史永远配对）。
//! - **三套时间戳键名都要认**：`timestamp` / `createdAt` / `created_at`。
//!
//! ## 原子写
//!
//! `appendTurn` 把 assistant + 紧邻 user(result) **两条一次写入**（单次
//! `appendFile`），因此不存在"assistant 已落盘、result 未落盘"的中间态。

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const util = @import("util");
const turn_mod = @import("turn.zig");

pub const Turn = turn_mod.Turn;
pub const Message = common.Message;
const json = common.json;

pub const EntryType = enum {
    message,
    compact_boundary,
    replay,
    tombstone,
    stop_metadata,
    inference,
    tool,
    /// `error` 是 Zig 关键字 → 字段名 `err`，**wire 名仍是 "error"**
    err,
    retry,
    session,
    agent,
    file,
    /// 未来/未知类型（前向兼容：不认识的一律**不进对话链**）
    unknown,

    pub fn wireName(self: EntryType) []const u8 {
        return switch (self) {
            .message => "message",
            .compact_boundary => "compact_boundary",
            .replay => "replay",
            .tombstone => "tombstone",
            .stop_metadata => "stop_metadata",
            .inference => "inference",
            .tool => "tool",
            .err => "error",
            .retry => "retry",
            .session => "session",
            .agent => "agent",
            .file => "file",
            .unknown => "unknown",
        };
    }

    pub fn fromWire(s: []const u8) EntryType {
        // 前缀族：inference_* / tool_* / error* / retry* / session_* / agent_* / file_*
        if (std.mem.eql(u8, s, "message")) return .message;
        if (std.mem.eql(u8, s, "compact_boundary")) return .compact_boundary;
        if (std.mem.eql(u8, s, "replay")) return .replay;
        if (std.mem.eql(u8, s, "tombstone")) return .tombstone;
        if (std.mem.eql(u8, s, "stop_metadata")) return .stop_metadata;
        if (std.mem.startsWith(u8, s, "inference")) return .inference;
        if (std.mem.startsWith(u8, s, "tool")) return .tool;
        if (std.mem.startsWith(u8, s, "error")) return .err;
        if (std.mem.startsWith(u8, s, "retry")) return .retry;
        if (std.mem.startsWith(u8, s, "session")) return .session;
        if (std.mem.startsWith(u8, s, "agent")) return .agent;
        if (std.mem.startsWith(u8, s, "file")) return .file;
        return .unknown;
    }

    /// **只有这三种参与对话链重建。**
    pub fn participatesInChain(self: EntryType) bool {
        return switch (self) {
            .message, .compact_boundary, .replay => true,
            else => false,
        };
    }
};

pub const Entry = struct {
    uuid: []const u8,
    parent_uuid: ?[]const u8 = null,
    entry_type: EntryType = .message,
    session_id: []const u8 = "",
    timestamp: []const u8 = "",
    message: ?Message = null,
    metadata: json.Map = .{},

    pub fn toJson(self: Entry, e: *json.Encoder) !void {
        try e.beginObject();
        try e.stringField("uuid", self.uuid);
        try e.optStringField("parentUuid", self.parent_uuid);
        try e.stringField("type", self.entry_type.wireName());
        try e.stringField("sessionId", self.session_id);
        try e.stringField("timestamp", self.timestamp);
        if (self.message) |m| {
            try e.key("message");
            try m.toJson(e);
        }
        try e.key("metadata");
        try e.value(.{ .object = self.metadata });
        try e.endObject();
    }

    pub fn fromJson(gpa: Allocator, v: json.Value) !Entry {
        var msg: ?Message = null;
        if (v.get("message")) |mv| {
            if (mv == .object) msg = Message.fromJson(gpa, mv) catch null;
        }
        var meta = json.Map{};
        if (v.get("metadata")) |md| {
            if (md == .object) meta = md.object;
        }
        return .{
            .uuid = try common.content.dupField(gpa, v, "uuid"),
            .parent_uuid = if (v.getString("parentUuid")) |p| try gpa.dupe(u8, p) else null,
            .entry_type = EntryType.fromWire(v.getString("type") orelse ""),
            .session_id = try common.content.dupField(gpa, v, "sessionId"),
            // 三套时间戳键名都要认
            .timestamp = try dupTimestamp(gpa, v),
            .message = msg,
            .metadata = meta,
        };
    }
};

fn dupTimestamp(gpa: Allocator, v: json.Value) ![]const u8 {
    if (v.getString("timestamp")) |s| return gpa.dupe(u8, s);
    if (v.getString("createdAt")) |s| return gpa.dupe(u8, s);
    if (v.getString("created_at")) |s| return gpa.dupe(u8, s);
    return "";
}

pub const Transcript = struct {
    io: std.Io,
    gpa: Allocator,
    path: []const u8,
    /// entry 及其字符串都活在这个 arena 里 —— 只增长、整体释放，
    /// 所以不需要逐个 `free`（也就不会误 free 掉静态的 `""`）。
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    /// 打开（不存在则视为空，写入时自动创建）。
    pub fn open(io: std.Io, gpa: Allocator, path: []const u8) !Transcript {
        var self = Transcript{
            .io = io,
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .path = try gpa.dupe(u8, path),
        };
        errdefer self.arena.deinit();
        const raw = util.fsio.readIfExists(io, gpa, path, 64 << 20) catch null;
        if (raw) |text| {
            defer gpa.free(text);
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            var it = std.mem.splitScalar(u8, text, '\n');
            while (it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;
                // 单行坏掉不能拖垮整个会话（宁可丢一行）
                var line_arena = std.heap.ArenaAllocator.init(gpa);
                defer line_arena.deinit();
                const v = json.parse(line_arena.allocator(), trimmed) catch continue;
                const entry = Entry.fromJson(self.arena.allocator(), v) catch continue;
                try self.entries.append(self.arena.allocator(), entry);
            }
        }
        return self;
    }

    pub fn deinit(self: *Transcript) void {
        // ⚠️ entries 的**底层缓冲来自 arena**，所以必须用同一个 arena 释放，
        //    用 `self.gpa` 释放会 "Invalid free"。
        self.entries.deinit(self.arena.allocator());
        self.gpa.free(self.path);
        self.arena.deinit();
    }

    /// 追加一条（**单行一次写**）。
    pub fn append(self: *Transcript, entry: Entry) !void {
        var e = json.Encoder.init(self.gpa);
        defer e.deinit();
        try entry.toJson(&e);
        try e.out.append(self.gpa, '\n');
        try util.fsio.ensureParent(self.io, self.path);
        try util.io.appendFile(self.io, self.path, e.text());
        try self.entries.append(self.arena.allocator(), entry);
    }

    /// ★ 原子写：assistant + 紧邻 user(result) **一次写两条**。
    ///
    /// 这不是"方便"，而是配对不变量的持久化侧保证：
    /// 进程在任意时刻挂掉，磁盘上都不可能出现孤立的 `tool_use`。
    pub fn appendTurn(
        self: *Transcript,
        turn: Turn,
        session_id: []const u8,
        timestamp: []const u8,
    ) !void {
        const tr_arena = self.arena.allocator();
        const asst_uuid = try newUuid(self.io, tr_arena);
        // assistant 的 parent 是当前 leaf（**注意**：要在内存态同步之前取）
        const parent = self.latestLeafUuid();

        var e = json.Encoder.init(self.gpa);
        defer e.deinit();

        try (Entry{
            .uuid = asst_uuid,
            .parent_uuid = parent,
            .entry_type = .message,
            .session_id = session_id,
            .timestamp = timestamp,
            .message = turn.assistant,
        }).toJson(&e);
        try e.out.append(self.gpa, '\n');

        var result_uuid: ?[]const u8 = null;
        var result_msg: ?Message = null;
        if (turn.results.len > 0) {
            const ru = try newUuid(self.io, tr_arena);
            result_uuid = ru;
            const rm = try turn.resultMessage(tr_arena);
            result_msg = rm;
            try (Entry{
                .uuid = ru,
                .parent_uuid = asst_uuid,
                .entry_type = .message,
                .session_id = session_id,
                .timestamp = timestamp,
                .message = rm,
            }).toJson(&e);
            try e.out.append(self.gpa, '\n');
        }

        try util.fsio.ensureParent(self.io, self.path);
        // ★ 一次写入两条 —— 不存在"已落盘 assistant、未落盘 result"的中间态
        try util.io.appendFile(self.io, self.path, e.text());

        // 内存态同步（保持与磁盘一致）
        try self.entries.append(tr_arena, .{
            .uuid = asst_uuid,
            .parent_uuid = parent,
            .entry_type = .message,
            .session_id = try tr_arena.dupe(u8, session_id),
            .timestamp = try tr_arena.dupe(u8, timestamp),
            .message = turn.assistant,
        });
        if (result_uuid) |ru| {
            try self.entries.append(tr_arena, .{
                .uuid = ru,
                .parent_uuid = asst_uuid,
                .entry_type = .message,
                .session_id = try tr_arena.dupe(u8, session_id),
                .timestamp = try tr_arena.dupe(u8, timestamp),
                .message = result_msg.?,
            });
        }
    }

    /// 追加一条**不参与对话链**的旁路事件（tool/tombstone/error/retry/...）。
    pub fn appendSideEvent(
        self: *Transcript,
        entry_type: EntryType,
        session_id: []const u8,
        timestamp: []const u8,
        metadata: json.Map,
    ) !void {
        const uuid = try newUuid(self.io, self.arena.allocator());
        try self.append(.{
            .uuid = uuid,
            .parent_uuid = self.latestLeafUuid(),
            .entry_type = entry_type,
            .session_id = session_id,
            .timestamp = timestamp,
            .metadata = metadata,
        });
    }

    /// 最新叶子（最后一条参与对话链的 entry）。
    pub fn latestLeafUuid(self: *Transcript) ?[]const u8 {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.entries.items[i];
            if (e.entry_type.participatesInChain() and e.entry_type != .tombstone) return e.uuid;
        }
        return null;
    }

    fn indexOf(self: *Transcript, uuid: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.uuid, uuid)) return i;
        }
        return null;
    }

    /// 沿 `parentUuid` 回溯重建对话链（**去环**），返回**正序**。
    pub fn chain(self: *Transcript, gpa: Allocator) Allocator.Error![]Entry {
        var out = std.ArrayListUnmanaged(Entry).empty;
        errdefer out.deinit(gpa);

        var seen = std.StringHashMapUnmanaged(void).empty;
        defer seen.deinit(gpa);

        var cursor = self.latestLeafUuid();
        while (cursor) |uuid| {
            if (seen.contains(uuid)) break; // 去环
            try seen.put(gpa, uuid, {});
            const idx = self.indexOf(uuid) orelse break;
            const e = self.entries.items[idx];
            if (e.entry_type.participatesInChain() and e.message != null) {
                try out.append(gpa, e);
            }
            cursor = e.parent_uuid;
        }

        std.mem.reverse(Entry, out.items);
        return out.toOwnedSlice(gpa);
    }

    /// 重建送进模型的消息序列（**已剔除孤儿 tool_result**）。
    pub fn messages(self: *Transcript, gpa: Allocator) ![]Message {
        const entries = try self.chain(gpa);
        defer gpa.free(entries);
        var msgs = std.ArrayListUnmanaged(Message).empty;
        errdefer msgs.deinit(gpa);
        for (entries) |e| {
            if (e.message) |m| try msgs.append(gpa, m);
        }
        return turn_mod.repairMessages(gpa, msgs.items);
    }

    /// 以某个 entry 为叶子的分叉重建（fork 用）。
    pub fn messagesAt(self: *Transcript, gpa: Allocator, leaf_uuid: []const u8) ![]Message {
        var out = std.ArrayListUnmanaged(Message).empty;
        errdefer out.deinit(gpa);
        var seen = std.StringHashMapUnmanaged(void).empty;
        defer seen.deinit(gpa);
        var cursor: ?[]const u8 = leaf_uuid;
        var collected = std.ArrayListUnmanaged(Message).empty;
        defer collected.deinit(gpa);
        while (cursor) |uuid| {
            if (seen.contains(uuid)) break;
            try seen.put(gpa, uuid, {});
            const idx = self.indexOf(uuid) orelse break;
            const e = self.entries.items[idx];
            if (e.entry_type.participatesInChain()) {
                if (e.message) |m| try collected.append(gpa, m);
            }
            cursor = e.parent_uuid;
        }
        std.mem.reverse(Message, collected.items);
        try out.appendSlice(gpa, collected.items);
        return turn_mod.repairMessages(gpa, out.items);
    }
};

/// 生成一个 uuid（无外部依赖：随机字节 + 版本/variant 位）。
pub fn newUuid(io: std.Io, gpa: Allocator) ![]u8 {
    var b: [16]u8 = undefined;
    util.io.randomBytes(io, &b);
    b[6] = (b[6] & 0x0F) | 0x40; // v4
    b[8] = (b[8] & 0x3F) | 0x80; // variant
    const hex = "0123456789abcdef";
    var out: [36]u8 = undefined;
    var oi: usize = 0;
    for (b, 0..) |x, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[oi] = '-';
            oi += 1;
        }
        out[oi] = hex[x >> 4];
        out[oi + 1] = hex[x & 0x0F];
        oi += 2;
    }
    return gpa.dupe(u8, out[0..36]);
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const content = common.content;

fn tmpTranscriptPath(gpa: Allocator, io: std.Io) ![]u8 {
    const rnd = try util.io.randomHex(io, gpa, 6);
    defer gpa.free(rnd);
    return std.fmt.allocPrint(gpa, "/tmp/zigent-transcript-test-{s}/t.jsonl", .{rnd});
}

fn mkTurn(gpa: Allocator, id: []const u8, text: []const u8) !Turn {
    const blocks = try gpa.alloc(common.ContentBlock, 1);
    blocks[0] = .{ .tool_use = .{ .tool_use_id = id, .tool_name = "Read", .input = "{}" } };
    const asst = common.Message{ .role = .assistant, .content = blocks };
    return Turn.init(gpa, asst, &.{.{
        .tool_use_id = id,
        .output = text,
        .is_error = false,
    }});
}

test "transcript: uuid 形状与唯一性" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const a = try newUuid(io, testing.allocator);
    defer testing.allocator.free(a);
    const b = try newUuid(io, testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 36), a.len);
    try testing.expectEqual(@as(u8, '-'), a[8]);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "transcript: 原子写一条 Turn 产生两行，且链上配对完整" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = try tmpTranscriptPath(testing.allocator, io);
    defer testing.allocator.free(path);
    defer util.io.removeTree(io, std.fs.path.dirname(path).?) catch {};

    var tr = try Transcript.open(io, testing.allocator, path);
    defer tr.deinit();
    const t = try mkTurn(a, "t1", "文件内容");
    try tr.appendTurn(t, "sess-1", "2026-09-19T00:00:00.000Z");

    const raw = try util.io.readFileAlloc(io, testing.allocator, path, 1 << 20);
    defer testing.allocator.free(raw);
    const lines = std.mem.count(u8, raw, "\n");
    try testing.expectEqual(@as(usize, 2), lines);

    const msgs = try tr.messages(a);
    try testing.expectEqual(@as(usize, 2), msgs.len);
    try testing.expectEqual(common.MessageRole.assistant, msgs[0].role);
    try testing.expectEqual(common.MessageRole.user, msgs[1].role);
}

test "transcript: 重开文件后按 parentUuid 重建（不靠行序）" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = try tmpTranscriptPath(testing.allocator, io);
    defer testing.allocator.free(path);
    defer util.io.removeTree(io, std.fs.path.dirname(path).?) catch {};

    {
        var tr = try Transcript.open(io, testing.allocator, path);
        defer tr.deinit();
        try tr.appendTurn(try mkTurn(a, "t1", "一"), "s", "T1");
        try tr.appendTurn(try mkTurn(a, "t2", "二"), "s", "T2");
    }
    var tr2 = try Transcript.open(io, testing.allocator, path);
    defer tr2.deinit();
    const msgs = try tr2.messages(a);
    // 2 轮 × 2 条 = 4
    try testing.expectEqual(@as(usize, 4), msgs.len);
    try testing.expectEqualStrings("一", msgs[1].content[0].tool_result.output);
    try testing.expectEqualStrings("二", msgs[3].content[0].tool_result.output);
}

test "transcript: 不参与对话链的事件被跳过" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = try tmpTranscriptPath(testing.allocator, io);
    defer testing.allocator.free(path);
    defer util.io.removeTree(io, std.fs.path.dirname(path).?) catch {};

    var tr = try Transcript.open(io, testing.allocator, path);
    defer tr.deinit();
    try tr.appendTurn(try mkTurn(a, "t1", "x"), "s", "T1");
    try tr.appendSideEvent(.tool, "s", "T2", .{});
    try tr.appendSideEvent(.err, "s", "T3", .{});
    try tr.appendSideEvent(.retry, "s", "T4", .{});

    const msgs = try tr.messages(a);
    try testing.expectEqual(@as(usize, 2), msgs.len);
}

test "transcript: 三套时间戳键名都认" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e1 = try Entry.fromJson(a, try json.parse(a, "{\"uuid\":\"u\",\"type\":\"message\",\"createdAt\":\"A\"}"));
    try testing.expectEqualStrings("A", e1.timestamp);
    const e2 = try Entry.fromJson(a, try json.parse(a, "{\"uuid\":\"u\",\"type\":\"message\",\"created_at\":\"B\"}"));
    try testing.expectEqualStrings("B", e2.timestamp);
    const e3 = try Entry.fromJson(a, try json.parse(a, "{\"uuid\":\"u\",\"type\":\"message\",\"timestamp\":\"C\"}"));
    try testing.expectEqualStrings("C", e3.timestamp);
}

test "transcript: 未知 type 不进对话链（前向兼容）" {
    try testing.expect(!EntryType.fromWire("some_future_type").participatesInChain());
    try testing.expect(EntryType.fromWire("message").participatesInChain());
    try testing.expect(EntryType.fromWire("compact_boundary").participatesInChain());
    try testing.expect(EntryType.fromWire("replay").participatesInChain());
    try testing.expect(!EntryType.fromWire("tombstone").participatesInChain());
    try testing.expect(!EntryType.fromWire("tool_result").participatesInChain());
}

test "transcript: 坏行不拖垮整个会话" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = try tmpTranscriptPath(testing.allocator, io);
    defer testing.allocator.free(path);
    defer util.io.removeTree(io, std.fs.path.dirname(path).?) catch {};
    try util.io.mkdirp(io, std.fs.path.dirname(path).?);

    {
        var tr = try Transcript.open(io, testing.allocator, path);
        defer tr.deinit();
        try tr.appendTurn(try mkTurn(a, "t1", "x"), "s", "T1");
    }
    // 手动插入一行垃圾
    try util.io.appendFile(io, path, "{ this is not json }\n");

    var tr2 = try Transcript.open(io, testing.allocator, path);
    defer tr2.deinit();
    const msgs = try tr2.messages(a);
    try testing.expectEqual(@as(usize, 2), msgs.len);
}
