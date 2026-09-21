//! 手写 JSON —— 解析器 + 编码器（L0 契约层，纯逻辑，零 IO）。
//!
//! 为什么不用 `std.json`（文档 04 §8 / 03 §5.5）：
//!   1. 字段名是**跨版本兼容契约**，必须由我们精确控制（旧 transcript 必须能读）；
//!   2. `std.json` 本身在 0.15–0.16 仍在变（版本 churn 要隔离在契约层内）；
//!   3. 「未知字段保留」需要可控 —— 反射式解析会静默丢掉它不认识的字段。
//!
//! 本文件只提供**两种东西**：
//!   - `Value` / `Object`：动态 JSON（承载 `metadata` / `payload` / 未知字段留底）；
//!   - `Encoder`：push 式编码器（手写 toJson 全部基于它）。
//!
//! ⚠️ 铁律：**工具入参（`ToolUseBlock.input`）绝不经过 parse → re-serialize**。
//! 解析器在这里只是为了「读」，不是为了「改写」。

const std = @import("std");
const Allocator = std.mem.Allocator;

// ─────────────────────────────────────────────────────────────────────────────
// 值模型
// ─────────────────────────────────────────────────────────────────────────────

/// 动态 JSON 值。对象保持**插入顺序**（wire 兼容要求字段顺序稳定可复现）。
pub const Value = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    number: f64,
    string: []const u8,
    array: []const Value,
    object: Object,

    pub fn get(self: Value, key: []const u8) ?Value {
        return switch (self) {
            .object => |o| o.get(key),
            else => null,
        };
    }

    pub fn getString(self: Value, key: []const u8) ?[]const u8 {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn getInt(self: Value, key: []const u8) ?i64 {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .integer => |i| i,
            .number => |f| @intFromFloat(f),
            .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
            else => null,
        };
    }

    pub fn getBool(self: Value, key: []const u8) ?bool {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn getArray(self: Value, key: []const u8) ?[]const Value {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .array => |a| a,
            else => null,
        };
    }

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .integer => |i| i,
            .number => |f| @intFromFloat(f),
            else => null,
        };
    }

    pub fn isNull(self: Value) bool {
        return self == .null;
    }
};

/// 有序对象。查找用线性扫描 —— wire 对象都是小对象（< 20 字段）。
pub const Object = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub const Entry = struct {
        key: []const u8,
        value: Value,
        /// 该值在源文本里的**原始切片**（解析时记录）。
        /// 用途：`ToolUseBlock.input` 必须逐字节保真（不变量 I1），
        /// 所以「读进来再写出去」时优先用原始切片，而不是重新序列化。
        raw: ?[]const u8 = null,
    };

    pub fn get(self: Object, key: []const u8) ?Value {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    pub fn getRaw(self: Object, key: []const u8) ?[]const u8 {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.raw;
        }
        return null;
    }

    pub fn contains(self: Object, key: []const u8) bool {
        return self.get(key) != null;
    }

    pub fn count(self: Object) usize {
        return self.entries.items.len;
    }

    pub fn put(self: *Object, gpa: Allocator, key: []const u8, value: Value) Allocator.Error!void {
        // 后写覆盖先写（同时保留原位置，保证顺序稳定）
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) {
                e.value = value;
                return;
            }
        }
        try self.entries.append(gpa, .{ .key = key, .value = value });
    }
};

/// 便捷：`JsonMap` 就是对象（保留旧名以对齐文档 04 的字段表）。
pub const Map = Object;

// ─────────────────────────────────────────────────────────────────────────────
// 解析
// ─────────────────────────────────────────────────────────────────────────────

pub const ParseError = error{
    UnexpectedEnd,
    UnexpectedToken,
    InvalidNumber,
    InvalidString,
    InvalidEscape,
    InvalidUnicodeEscape,
    TrailingGarbage,
    DepthExceeded,
    OutOfMemory,
};

pub const max_depth = 128;

/// 解析一段完整 JSON 文本。所有产出都分配在传入的 arena 上（整体释放）。
pub fn parse(arena: Allocator, text: []const u8) ParseError!Value {
    var p = Parser{ .arena = arena, .src = text, .i = 0 };
    p.skipWs();
    const v = try p.parseValue(0);
    p.skipWs();
    if (p.i != p.src.len) return error.TrailingGarbage;
    return v;
}

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    i: usize,

    fn peek(p: *Parser) ?u8 {
        if (p.i >= p.src.len) return null;
        return p.src[p.i];
    }

    fn skipWs(p: *Parser) void {
        while (p.i < p.src.len) : (p.i += 1) {
            switch (p.src[p.i]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn expect(p: *Parser, c: u8) ParseError!void {
        if (p.i >= p.src.len) return error.UnexpectedEnd;
        if (p.src[p.i] != c) return error.UnexpectedToken;
        p.i += 1;
    }

    fn parseValue(p: *Parser, depth: usize) ParseError!Value {
        if (depth > max_depth) return error.DepthExceeded;
        p.skipWs();
        const c = p.peek() orelse return error.UnexpectedEnd;
        return switch (c) {
            '{' => p.parseObject(depth),
            '[' => p.parseArray(depth),
            '"' => .{ .string = try p.parseString() },
            't' => blk: {
                try p.lit("true");
                break :blk .{ .boolean = true };
            },
            'f' => blk: {
                try p.lit("false");
                break :blk .{ .boolean = false };
            },
            'n' => blk: {
                try p.lit("null");
                break :blk .null;
            },
            '-', '0'...'9' => p.parseNumber(),
            else => error.UnexpectedToken,
        };
    }

    fn lit(p: *Parser, s: []const u8) ParseError!void {
        if (p.i + s.len > p.src.len) return error.UnexpectedEnd;
        if (!std.mem.eql(u8, p.src[p.i .. p.i + s.len], s)) return error.UnexpectedToken;
        p.i += s.len;
    }

    fn parseObject(p: *Parser, depth: usize) ParseError!Value {
        try p.expect('{');
        var obj = Object{};
        p.skipWs();
        if (p.peek() == '}') {
            p.i += 1;
            return .{ .object = obj };
        }
        while (true) {
            p.skipWs();
            const key = try p.parseString();
            p.skipWs();
            try p.expect(':');
            p.skipWs();
            const val_start = p.i;
            const val = try p.parseValue(depth + 1);
            const val_end = p.i;
            try obj.entries.append(p.arena, .{
                .key = key,
                .value = val,
                .raw = p.src[val_start..val_end],
            });
            p.skipWs();
            const c = p.peek() orelse return error.UnexpectedEnd;
            if (c == ',') {
                p.i += 1;
                continue;
            }
            if (c == '}') {
                p.i += 1;
                return .{ .object = obj };
            }
            return error.UnexpectedToken;
        }
    }

    fn parseArray(p: *Parser, depth: usize) ParseError!Value {
        try p.expect('[');
        var items = std.ArrayListUnmanaged(Value).empty;
        p.skipWs();
        if (p.peek() == ']') {
            p.i += 1;
            return .{ .array = &.{} };
        }
        while (true) {
            const val = try p.parseValue(depth + 1);
            try items.append(p.arena, val);
            p.skipWs();
            const c = p.peek() orelse return error.UnexpectedEnd;
            if (c == ',') {
                p.i += 1;
                continue;
            }
            if (c == ']') {
                p.i += 1;
                return .{ .array = try items.toOwnedSlice(p.arena) };
            }
            return error.UnexpectedToken;
        }
    }

    fn parseNumber(p: *Parser) ParseError!Value {
        const start = p.i;
        if (p.peek() == '-') p.i += 1;
        while (p.i < p.src.len) : (p.i += 1) {
            switch (p.src[p.i]) {
                '0'...'9', '.', 'e', 'E', '+', '-' => {},
                else => break,
            }
        }
        const tok = p.src[start..p.i];
        if (tok.len == 0) return error.InvalidNumber;
        // 无小数点/指数 → 整数（保住大整数精度）
        if (std.mem.indexOfAny(u8, tok, ".eE") == null) {
            const v = std.fmt.parseInt(i64, tok, 10) catch {
                // 超出 i64 的大整数：退回 f64（不能丢字段，但已知会损失精度）
                const f = std.fmt.parseFloat(f64, tok) catch return error.InvalidNumber;
                return .{ .number = f };
            };
            return .{ .integer = v };
        }
        const f = std.fmt.parseFloat(f64, tok) catch return error.InvalidNumber;
        if (!std.math.isFinite(f)) return error.InvalidNumber;
        return .{ .number = f };
    }

    fn parseString(p: *Parser) ParseError![]const u8 {
        try p.expect('"');
        var buf = std.ArrayListUnmanaged(u8).empty;
        while (true) {
            if (p.i >= p.src.len) return error.UnexpectedEnd;
            const c = p.src[p.i];
            p.i += 1;
            switch (c) {
                '"' => return try buf.toOwnedSlice(p.arena),
                '\\' => {
                    if (p.i >= p.src.len) return error.UnexpectedEnd;
                    const e = p.src[p.i];
                    p.i += 1;
                    switch (e) {
                        '"' => try buf.append(p.arena, '"'),
                        '\\' => try buf.append(p.arena, '\\'),
                        '/' => try buf.append(p.arena, '/'),
                        'b' => try buf.append(p.arena, 0x08),
                        'f' => try buf.append(p.arena, 0x0C),
                        'n' => try buf.append(p.arena, '\n'),
                        'r' => try buf.append(p.arena, '\r'),
                        't' => try buf.append(p.arena, '\t'),
                        'u' => {
                            const cp = try p.parseHex4();
                            if (cp >= 0xD800 and cp <= 0xDBFF) {
                                // 代理对
                                if (p.i + 1 < p.src.len and p.src[p.i] == '\\' and p.src[p.i + 1] == 'u') {
                                    p.i += 2;
                                    const lo = try p.parseHex4();
                                    if (lo >= 0xDC00 and lo <= 0xDFFF) {
                                        const full: u21 = @intCast(0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00));
                                        try appendUtf8(&buf, p.arena, full);
                                        continue;
                                    }
                                    try appendUtf8(&buf, p.arena, 0xFFFD);
                                    try appendUtf8(&buf, p.arena, 0xFFFD);
                                    continue;
                                }
                                try appendUtf8(&buf, p.arena, 0xFFFD);
                                continue;
                            }
                            try appendUtf8(&buf, p.arena, std.math.cast(u21, cp) orelse 0xFFFD);
                        },
                        else => return error.InvalidEscape,
                    }
                },
                else => {
                    // 未转义的控制字符是非法的，但历史网关会发 —— 宽容接受
                    try buf.append(p.arena, c);
                },
            }
        }
    }

    fn parseHex4(p: *Parser) ParseError!u32 {
        if (p.i + 4 > p.src.len) return error.UnexpectedEnd;
        var v: u32 = 0;
        for (p.src[p.i .. p.i + 4]) |c| {
            const d: u32 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return error.InvalidUnicodeEscape,
            };
            v = v * 16 + d;
        }
        p.i += 4;
        return v;
    }
};

fn appendUtf8(buf: *std.ArrayListUnmanaged(u8), gpa: Allocator, cp: u21) ParseError!void {
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &tmp) catch {
        try buf.append(gpa, '?');
        return;
    };
    try buf.appendSlice(gpa, tmp[0..n]);
}

// ─────────────────────────────────────────────────────────────────────────────
// 编码
// ─────────────────────────────────────────────────────────────────────────────

/// push 式编码器：调用方负责调用顺序（手写 toJson 的全部基础设施）。
pub const Encoder = struct {
    out: std.ArrayListUnmanaged(u8) = .empty,
    gpa: Allocator,
    /// 每一层是否已经吐过元素（决定是否要补逗号）
    stack: std.ArrayListUnmanaged(bool) = .empty,

    pub fn init(gpa: Allocator) Encoder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Encoder) void {
        self.out.deinit(self.gpa);
        self.stack.deinit(self.gpa);
    }

    pub fn toOwnedSlice(self: *Encoder) Allocator.Error![]u8 {
        self.stack.deinit(self.gpa);
        self.stack = .empty;
        return self.out.toOwnedSlice(self.gpa);
    }

    pub fn text(self: *Encoder) []const u8 {
        return self.out.items;
    }

    fn beforeValue(self: *Encoder) Allocator.Error!void {
        if (self.stack.items.len == 0) return;
        const top = &self.stack.items[self.stack.items.len - 1];
        if (top.*) try self.out.append(self.gpa, ',');
        top.* = true;
    }

    pub fn beginObject(self: *Encoder) Allocator.Error!void {
        try self.beforeValue();
        try self.out.append(self.gpa, '{');
        try self.stack.append(self.gpa, false);
    }

    pub fn endObject(self: *Encoder) Allocator.Error!void {
        _ = self.stack.pop();
        try self.out.append(self.gpa, '}');
    }

    pub fn beginArray(self: *Encoder) Allocator.Error!void {
        try self.beforeValue();
        try self.out.append(self.gpa, '[');
        try self.stack.append(self.gpa, false);
    }

    pub fn endArray(self: *Encoder) Allocator.Error!void {
        _ = self.stack.pop();
        try self.out.append(self.gpa, ']');
    }

    /// 写 key（并吞掉逗号），随后必须紧跟一个值。
    pub fn key(self: *Encoder, k: []const u8) Allocator.Error!void {
        try self.beforeValue();
        try writeEscaped(&self.out, self.gpa, k);
        try self.out.append(self.gpa, ':');
        // 该 key 的值尚未写入：撤销本层的 "已写" 标记，
        // 让紧随其后的值不再补逗号（逗号已由 key 处理）。
        if (self.stack.items.len > 0) {
            self.stack.items[self.stack.items.len - 1] = false;
        }
    }

    pub fn string(self: *Encoder, s: []const u8) Allocator.Error!void {
        try self.beforeValue();
        try writeEscaped(&self.out, self.gpa, s);
    }

    pub fn integer(self: *Encoder, v: i64) Allocator.Error!void {
        try self.beforeValue();
        try self.out.print(self.gpa, "{d}", .{v});
    }

    pub fn uint(self: *Encoder, v: u64) Allocator.Error!void {
        try self.beforeValue();
        try self.out.print(self.gpa, "{d}", .{v});
    }

    pub fn float(self: *Encoder, v: f64) Allocator.Error!void {
        try self.beforeValue();
        if (!std.math.isFinite(v)) {
            try self.out.appendSlice(self.gpa, "null");
            return;
        }
        try self.out.print(self.gpa, "{d}", .{v});
    }

    pub fn boolean(self: *Encoder, v: bool) Allocator.Error!void {
        try self.beforeValue();
        try self.out.appendSlice(self.gpa, if (v) "true" else "false");
    }

    pub fn nullv(self: *Encoder) Allocator.Error!void {
        try self.beforeValue();
        try self.out.appendSlice(self.gpa, "null");
    }

    /// 直接塞入一段已是合法 JSON 的原文（**只用于原样透传**，如 `ToolUseBlock.input`）。
    pub fn raw(self: *Encoder, s: []const u8) Allocator.Error!void {
        try self.beforeValue();
        try self.out.appendSlice(self.gpa, s);
    }

    /// 便捷：key + 任意 Value。
    pub fn field(self: *Encoder, k: []const u8, v: Value) Allocator.Error!void {
        try self.key(k);
        try self.value(v);
    }

    pub fn value(self: *Encoder, v: Value) Allocator.Error!void {
        switch (v) {
            .null => try self.nullv(),
            .boolean => |b| try self.boolean(b),
            .integer => |i| try self.integer(i),
            .number => |f| try self.float(f),
            .string => |s| try self.string(s),
            .array => |a| {
                try self.beginArray();
                for (a) |item| try self.value(item);
                try self.endArray();
            },
            .object => |o| {
                try self.beginObject();
                for (o.entries.items) |e| try self.field(e.key, e.value);
                try self.endObject();
            },
        }
    }

    pub fn stringField(self: *Encoder, k: []const u8, s: []const u8) Allocator.Error!void {
        try self.key(k);
        try self.string(s);
    }

    pub fn intField(self: *Encoder, k: []const u8, v: i64) Allocator.Error!void {
        try self.key(k);
        try self.integer(v);
    }

    pub fn boolField(self: *Encoder, k: []const u8, v: bool) Allocator.Error!void {
        try self.key(k);
        try self.boolean(v);
    }

    /// 可选字段：`null` 时**整个字段缺席**（文档 04 §8：null 与缺席语义不同）。
    pub fn optStringField(self: *Encoder, k: []const u8, s: ?[]const u8) Allocator.Error!void {
        if (s) |v| try self.stringField(k, v);
    }

    pub fn optIntField(self: *Encoder, k: []const u8, v: ?i64) Allocator.Error!void {
        if (v) |x| try self.intField(k, x);
    }

    pub fn optBoolField(self: *Encoder, k: []const u8, v: ?bool) Allocator.Error!void {
        if (v) |x| try self.boolField(k, x);
    }
};

/// 写一个带完整转义的 JSON 字符串（含引号）。
pub fn writeEscaped(out: *std.ArrayListUnmanaged(u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    try out.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            0x08 => try out.appendSlice(gpa, "\\b"),
            0x0C => try out.appendSlice(gpa, "\\f"),
            else => {
                if (c < 0x20) {
                    try out.print(gpa, "\\u{x:0>4}", .{c});
                } else {
                    try out.append(gpa, c);
                }
            },
        }
    }
    try out.append(gpa, '"');
}

/// 便捷：把一个值编码成新分配的字符串。
pub fn stringify(gpa: Allocator, v: Value) Allocator.Error![]u8 {
    var e = Encoder.init(gpa);
    errdefer e.deinit();
    try e.value(v);
    return e.toOwnedSlice();
}

/// 便捷：把一段文本编码成带引号的 JSON 字符串。
pub fn quote(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(gpa);
    try writeEscaped(&out, gpa, s);
    return out.toOwnedSlice(gpa);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "json: 解析对象并保序" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "{\"b\":1,\"a\":2,\"c\":[true,null,\"x\"]}");
    try testing.expectEqual(@as(i64, 1), v.getInt("b").?);
    try testing.expectEqual(@as(i64, 2), v.getInt("a").?);
    const arr = v.getArray("c").?;
    try testing.expectEqual(@as(usize, 3), arr.len);
    try testing.expectEqualStrings("x", arr[2].asString().?);
    // 保序
    try testing.expectEqualStrings("b", v.object.entries.items[0].key);
    try testing.expectEqualStrings("a", v.object.entries.items[1].key);
}

test "json: 大整数不经过 f64" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "{\"n\":9007199254740993}");
    try testing.expectEqual(@as(i64, 9007199254740993), v.getInt("n").?);
}

test "json: 字符串转义与代理对往返" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "\"a\\n\\\"b\\\" \\u4e2d\\ud83d\\ude00\"");
    const s = v.asString().?;
    try testing.expect(std.mem.indexOf(u8, s, "a\n\"b\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "中") != null);
    try testing.expect(std.mem.indexOf(u8, s, "😀") != null);
}

test "json: 编码器嵌套与可选字段缺席" {
    var e = Encoder.init(testing.allocator);
    defer e.deinit();
    try e.beginObject();
    try e.stringField("type", "text_delta");
    try e.intField("n", 3);
    try e.optStringField("absent", null);
    try e.key("arr");
    try e.beginArray();
    try e.string("a");
    try e.string("b");
    try e.endArray();
    try e.endObject();
    try testing.expectEqualStrings(
        "{\"type\":\"text_delta\",\"n\":3,\"arr\":[\"a\",\"b\"]}",
        e.text(),
    );
}

test "json: 编码器 key 后接值不产生多余逗号" {
    var e = Encoder.init(testing.allocator);
    defer e.deinit();
    try e.beginObject();
    try e.key("obj");
    try e.beginObject();
    try e.key("x");
    try e.integer(1);
    try e.endObject();
    try e.key("y");
    try e.integer(2);
    try e.endObject();
    try testing.expectEqualStrings("{\"obj\":{\"x\":1},\"y\":2}", e.text());
}

test "json: 未知字段保留（前向兼容）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "{\"known\":1,\"future_field\":{\"deep\":[1,2]}}");
    try testing.expect(v.get("future_field") != null);
    const round = try stringify(testing.allocator, v);
    defer testing.allocator.free(round);
    try testing.expect(std.mem.indexOf(u8, round, "future_field") != null);
}

test "json: 畸形输入报错而不是 panic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnexpectedEnd, parse(arena.allocator(), "{\"a\":"));
    try testing.expectError(error.TrailingGarbage, parse(arena.allocator(), "{} garbage"));
    try testing.expectError(error.UnexpectedToken, parse(arena.allocator(), "}")); 
}
