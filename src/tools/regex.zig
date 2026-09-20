//! `tools/regex.zig` —— `Grep` 的最小正则子集（**刻意不引依赖**，文档 05 §4.6）。
//!
//! 支持：字面量、`.`、`*`、`+`、`?`、`^`、`$`、字符类 `[...]`/`[^...]`、
//! 分组 `(...)`、或 `|`、转义 `\.` 与简写 `\d \w \s`（及其大写否定）。
//! 实现是**回溯 VM**（编译到指令表 + 显式栈），不是完整 PCRE：
//! 带 `MAX_STEPS` 上限，病态模式返回「不匹配」而不是挂死。
//!
//! `find` 的 `multiline` 语义：
//!   - false：调用方按行喂入；`^` = 行首、`$` = 行尾、`.` 不跨行；
//!   - true ：整篇输入；`^` = 串首或 `\n` 之后、`$` = 串尾或 `\n` 之前。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MAX_STEPS: usize = 1_000_000;

pub const Match = struct { start: usize, end: usize };

const Instr = union(enum) {
    char: u8,
    any,
    class: usize,
    anchor_start,
    anchor_end,
    split: struct { x: usize, y: usize },
    jmp: usize,
    match,
};

const Class = struct { negate: bool, ranges: []const [2]u8 };

const Node = union(enum) {
    empty,
    literal: u8,
    any,
    class: usize,
    anchor_start,
    anchor_end,
    concat: []const *Node,
    alt: []const *Node,
    star: *Node,
    plus: *Node,
    opt: *Node,
};

pub const Regex = struct {
    arena: std.heap.ArenaAllocator,
    prog: []Instr,
    classes: []Class,
    ignore_case: bool,
    /// 程序是否以 `^` 开头（搜索时可提前停止尝试其它起点）
    starts_anchored: bool,

    pub fn compile(gpa: Allocator, pattern: []const u8, ignore_case: bool) !Regex {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        var classes = std.ArrayListUnmanaged(Class).empty;
        var p = Parser{ .arena = a, .src = pattern, .classes = &classes };
        const root = try p.parseAlt();
        if (p.i != pattern.len or p.failed) return error.InvalidPattern;

        var list = std.ArrayListUnmanaged(Instr).empty;
        try emitNode(a, &list, root);
        try list.append(a, .match);

        const prog = try list.toOwnedSlice(a);
        return .{
            .arena = arena,
            .prog = prog,
            .classes = try classes.toOwnedSlice(a),
            .ignore_case = ignore_case,
            .starts_anchored = prog.len > 0 and prog[0] == .anchor_start,
        };
    }

    pub fn deinit(self: *Regex) void {
        self.arena.deinit();
    }

    fn eqChar(self: *const Regex, a: u8, b: u8) bool {
        if (a == b) return true;
        if (!self.ignore_case) return false;
        return std.ascii.toLower(a) == std.ascii.toLower(b);
    }

    fn classMatch(_: *const Regex, c: Class, ch: u8) bool {
        var hit = false;
        for (c.ranges) |r| {
            if (ch >= r[0] and ch <= r[1]) {
                hit = true;
                break;
            }
        }
        if (hit) return !c.negate;
        return c.negate;
    }

    fn isLineStart(text: []const u8, pos: usize, multiline: bool) bool {
        if (pos == 0) return true;
        if (!multiline) return false;
        return text[pos - 1] == '\n';
    }

    fn isLineEnd(text: []const u8, pos: usize, multiline: bool) bool {
        if (pos >= text.len) return true;
        if (!multiline) return false;
        return text[pos] == '\n';
    }

    /// 从 `start` 起尝试匹配（不要求整段匹配，返回结束位置）。
    pub fn matchAt(self: *const Regex, scratch: Allocator, text: []const u8, start: usize, multiline: bool) !?usize {
        var stack = std.ArrayListUnmanaged(struct { pc: usize, pos: usize }).empty;
        defer stack.deinit(scratch);

        var pc: usize = 0;
        var pos = start;
        var steps: usize = 0;
        while (true) {
            steps += 1;
            if (steps > MAX_STEPS) return null;
            var advanced = false;
            switch (self.prog[pc]) {
                .char => |c| {
                    if (pos < text.len and self.eqChar(text[pos], c)) {
                        pc += 1;
                        pos += 1;
                        advanced = true;
                    }
                },
                .any => {
                    if (pos < text.len and (multiline or text[pos] != '\n')) {
                        pc += 1;
                        pos += 1;
                        advanced = true;
                    }
                },
                .class => |ci| {
                    if (pos < text.len and self.classMatch(self.classes[ci], text[pos])) {
                        pc += 1;
                        pos += 1;
                        advanced = true;
                    }
                },
                .anchor_start => {
                    if (isLineStart(text, pos, multiline)) {
                        pc += 1;
                        advanced = true;
                    }
                },
                .anchor_end => {
                    if (isLineEnd(text, pos, multiline)) {
                        pc += 1;
                        advanced = true;
                    }
                },
                .split => |s| {
                    try stack.append(scratch, .{ .pc = s.y, .pos = pos });
                    pc = s.x;
                    advanced = true;
                },
                .jmp => |t| {
                    pc = t;
                    advanced = true;
                },
                .match => return pos,
            }
            if (!advanced) {
                const st = stack.pop() orelse return null;
                pc = st.pc;
                pos = st.pos;
            }
        }
    }

    /// 在 `text[from..]` 中找最左匹配。
    pub fn find(self: *const Regex, scratch: Allocator, text: []const u8, from: usize, multiline: bool) !?Match {
        var s = from;
        while (s <= text.len) : (s += 1) {
            if (try self.matchAt(scratch, text, s, multiline)) |end| {
                return .{ .start = s, .end = end };
            }
            if (self.starts_anchored and !multiline) return null;
        }
        return null;
    }

    pub fn isMatch(self: *const Regex, scratch: Allocator, text: []const u8, multiline: bool) !bool {
        return (try self.find(scratch, text, 0, multiline)) != null;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 解析
// ─────────────────────────────────────────────────────────────────────────────

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    i: usize = 0,
    classes: *std.ArrayListUnmanaged(Class),
    failed: bool = false,

    fn peek(p: *Parser) ?u8 {
        if (p.i >= p.src.len) return null;
        return p.src[p.i];
    }

    fn node(p: *Parser, n: Node) !*Node {
        const ptr = try p.arena.create(Node);
        ptr.* = n;
        return ptr;
    }

    fn parseAlt(p: *Parser) anyerror!*Node {
        var parts = std.ArrayListUnmanaged(*Node).empty;
        try parts.append(p.arena, try p.parseConcat());
        while (p.peek() == '|') {
            p.i += 1;
            try parts.append(p.arena, try p.parseConcat());
        }
        if (parts.items.len == 1) return parts.items[0];
        return p.node(.{ .alt = try parts.toOwnedSlice(p.arena) });
    }

    fn parseConcat(p: *Parser) anyerror!*Node {
        var parts = std.ArrayListUnmanaged(*Node).empty;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            try parts.append(p.arena, try p.parseRepeat());
        }
        if (parts.items.len == 0) return p.node(.empty);
        if (parts.items.len == 1) return parts.items[0];
        return p.node(.{ .concat = try parts.toOwnedSlice(p.arena) });
    }

    fn parseRepeat(p: *Parser) anyerror!*Node {
        var atom = try p.parseAtom();
        while (p.peek()) |c| {
            switch (c) {
                '*' => {
                    p.i += 1;
                    atom = try p.node(.{ .star = atom });
                },
                '+' => {
                    p.i += 1;
                    atom = try p.node(.{ .plus = atom });
                },
                '?' => {
                    p.i += 1;
                    atom = try p.node(.{ .opt = atom });
                },
                else => break,
            }
        }
        return atom;
    }

    fn parseAtom(p: *Parser) anyerror!*Node {
        const c = p.peek() orelse return p.node(.empty);
        switch (c) {
            '(' => {
                p.i += 1;
                const inner = try p.parseAlt();
                if (p.peek() == ')') {
                    p.i += 1;
                } else {
                    p.failed = true;
                }
                return inner;
            },
            '[' => return p.parseClass(),
            '.' => {
                p.i += 1;
                return p.node(.any);
            },
            '^' => {
                p.i += 1;
                return p.node(.anchor_start);
            },
            '$' => {
                p.i += 1;
                return p.node(.anchor_end);
            },
            '\\' => {
                p.i += 1;
                const e = p.peek() orelse {
                    p.failed = true;
                    return p.node(.empty);
                };
                p.i += 1;
                return p.escapeNode(e);
            },
            else => {
                p.i += 1;
                return p.node(.{ .literal = c });
            },
        }
    }

    fn escapeNode(p: *Parser, e: u8) anyerror!*Node {
        switch (e) {
            'd' => return p.classNode(false, &.{.{ '0', '9' }}),
            'D' => return p.classNode(true, &.{.{ '0', '9' }}),
            'w' => return p.classNode(false, &.{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '0', '9' }, .{ '_', '_' } }),
            'W' => return p.classNode(true, &.{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '0', '9' }, .{ '_', '_' } }),
            's' => return p.classNode(false, &.{ .{ ' ', ' ' }, .{ '\t', '\t' }, .{ '\n', '\n' }, .{ '\r', '\r' } }),
            'S' => return p.classNode(true, &.{ .{ ' ', ' ' }, .{ '\t', '\t' }, .{ '\n', '\n' }, .{ '\r', '\r' } }),
            'n' => return p.node(.{ .literal = '\n' }),
            't' => return p.node(.{ .literal = '\t' }),
            'r' => return p.node(.{ .literal = '\r' }),
            else => return p.node(.{ .literal = e }),
        }
    }

    fn classNode(p: *Parser, negate: bool, ranges: []const [2]u8) !*Node {
        const idx = p.classes.items.len;
        try p.classes.append(p.arena, .{ .negate = negate, .ranges = ranges });
        return p.node(.{ .class = idx });
    }

    fn parseClass(p: *Parser) anyerror!*Node {
        p.i += 1; // '['
        var negate = false;
        if (p.peek()) |c| {
            if (c == '^' or c == '!') {
                negate = true;
                p.i += 1;
            }
        }
        var ranges = std.ArrayListUnmanaged([2]u8).empty;
        var first = true;
        while (p.peek()) |c| {
            if (c == ']' and !first) break;
            first = false;
            // 简写类在字符类里展开
            if (c == '\\') {
                p.i += 1;
                const e = p.peek() orelse break;
                p.i += 1;
                switch (e) {
                    'd' => try ranges.appendSlice(p.arena, &.{.{ '0', '9' }}),
                    'w' => try ranges.appendSlice(p.arena, &.{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '0', '9' }, .{ '_', '_' } }),
                    's' => try ranges.appendSlice(p.arena, &.{ .{ ' ', ' ' }, .{ '\t', '\t' }, .{ '\n', '\n' }, .{ '\r', '\r' } }),
                    'n' => try ranges.append(p.arena, .{ '\n', '\n' }),
                    't' => try ranges.append(p.arena, .{ '\t', '\t' }),
                    else => try ranges.append(p.arena, .{ e, e }),
                }
                continue;
            }
            p.i += 1;
            if (p.peek() == '-' and p.i + 1 < p.src.len and p.src[p.i + 1] != ']') {
                const hi = p.src[p.i + 1];
                p.i += 2;
                try ranges.append(p.arena, .{ c, hi });
            } else {
                try ranges.append(p.arena, .{ c, c });
            }
        }
        if (p.peek() == ']') {
            p.i += 1;
        } else {
            p.failed = true;
        }
        return p.classNode(negate, try ranges.toOwnedSlice(p.arena));
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// 指令生成
// ─────────────────────────────────────────────────────────────────────────────

fn emitNode(a: Allocator, list: *std.ArrayListUnmanaged(Instr), n: *const Node) anyerror!void {
    switch (n.*) {
        .empty => {},
        .literal => |c| try list.append(a, .{ .char = c }),
        .any => try list.append(a, .any),
        .class => |i| try list.append(a, .{ .class = i }),
        .anchor_start => try list.append(a, .anchor_start),
        .anchor_end => try list.append(a, .anchor_end),
        .concat => |parts| {
            for (parts) |part| try emitNode(a, list, part);
        },
        .alt => |parts| try emitAlt(a, list, parts),
        .star => |child| {
            const l1 = list.items.len;
            const split_idx = list.items.len;
            try list.append(a, .{ .split = .{ .x = l1 + 1, .y = 0 } });
            try emitNode(a, list, child);
            try list.append(a, .{ .jmp = l1 });
            list.items[split_idx].split.y = list.items.len;
        },
        .plus => |child| {
            const l1 = list.items.len;
            try emitNode(a, list, child);
            const split_idx = list.items.len;
            try list.append(a, .{ .split = .{ .x = l1, .y = 0 } });
            list.items[split_idx].split.y = list.items.len;
        },
        .opt => |child| {
            const split_idx = list.items.len;
            try list.append(a, .{ .split = .{ .x = split_idx + 1, .y = 0 } });
            try emitNode(a, list, child);
            list.items[split_idx].split.y = list.items.len;
        },
    }
}

fn emitAlt(a: Allocator, list: *std.ArrayListUnmanaged(Instr), parts: []const *Node) anyerror!void {
    if (parts.len == 0) return;
    if (parts.len == 1) return emitNode(a, list, parts[0]);
    const split_idx = list.items.len;
    try list.append(a, .{ .split = .{ .x = split_idx + 1, .y = 0 } });
    try emitNode(a, list, parts[0]);
    const jmp_idx = list.items.len;
    try list.append(a, .{ .jmp = 0 });
    list.items[split_idx].split.y = list.items.len;
    try emitAlt(a, list, parts[1..]);
    list.items[jmp_idx].jmp = list.items.len;
}

// ─────────────────────────────────────────────────────────────────────────────
// 字面量快路径
// ─────────────────────────────────────────────────────────────────────────────

/// 模式是否不含任何元字符（可走 O(n·m) 子串搜索而不是 VM）。
pub fn isLiteral(pattern: []const u8) bool {
    for (pattern) |c| {
        switch (c) {
            '\\', '.', '*', '+', '?', '[', ']', '(', ')', '|', '^', '$' => return false,
            else => {},
        }
    }
    return true;
}

/// 子串搜索（可选 ASCII 大小写不敏感）。
pub fn literalFind(haystack: []const u8, needle: []const u8, ignore_case: bool, from: usize) ?usize {
    if (needle.len == 0) return from;
    if (from > haystack.len or needle.len > haystack.len - from) return null;
    if (!ignore_case) return std.mem.indexOfPos(u8, haystack, from, needle);
    var i = from;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, k| {
            if (std.ascii.toLower(haystack[i + k]) != std.ascii.toLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return i;
    }
    return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn matches(pattern: []const u8, text: []const u8) !bool {
    var re = try Regex.compile(testing.allocator, pattern, false);
    defer re.deinit();
    return re.isMatch(testing.allocator, text, false);
}

fn matchesI(pattern: []const u8, text: []const u8) !bool {
    var re = try Regex.compile(testing.allocator, pattern, true);
    defer re.deinit();
    return re.isMatch(testing.allocator, text, false);
}

test "regex: 字面量与 . " {
    try testing.expect(try matches("abc", "xxabcxx"));
    try testing.expect(!try matches("abc", "abx"));
    try testing.expect(try matches("a.c", "axc"));
    try testing.expect(!try matches("a.c", "ac"));
    const m = blk: {
        var re = try Regex.compile(testing.allocator, "abc", false);
        defer re.deinit();
        break :blk try re.find(testing.allocator, "xxabcxx", 0, false);
    };
    try testing.expectEqual(@as(usize, 2), m.?.start);
    try testing.expectEqual(@as(usize, 5), m.?.end);
}

test "regex: * + ? 的贪婪与回溯（a*a 必须能匹配 aaa）" {
    try testing.expect(try matches("ab*c", "ac"));
    try testing.expect(try matches("ab*c", "abbbc"));
    try testing.expect(try matches("ab+c", "abc"));
    try testing.expect(!try matches("ab+c", "ac"));
    try testing.expect(try matches("ab?c", "ac"));
    try testing.expect(try matches("ab?c", "abc"));
    try testing.expect(try matches("a*a", "aaa"));
    try testing.expect(try matches("a+", "aaa"));
}

test "regex: 锚点 ^ $" {
    try testing.expect(try matches("^foo$", "foo"));
    try testing.expect(!try matches("^foo$", "xfoo"));
    try testing.expect(!try matches("^foo$", "foox"));
    try testing.expect(try matches("^$", ""));
    try testing.expect(try matches("^a+$", "aaaa"));
}

test "regex: 字符类" {
    try testing.expect(try matches("[abc]+", "cab"));
    try testing.expect(!try matches("^[abc]+$", "abd"));
    try testing.expect(try matches("^[^0-9]+$", "abc"));
    try testing.expect(!try matches("^[^0-9]+$", "ab1"));
    try testing.expect(try matches("^[a-c]x$", "bx"));
    try testing.expect(try matches("\\d+", "abc123"));
    try testing.expect(!try matches("^\\d+$", "abc123"));
    try testing.expect(try matches("^\\w+$", "a_b9"));
}

test "regex: 分组与或" {
    try testing.expect(try matches("cat|dog", "hotdog"));
    try testing.expect(try matches("^(cat|dog)$", "dog"));
    try testing.expect(!try matches("^(cat|dog)$", "cow"));
    try testing.expect(try matches("^(ab)+$", "ababab"));
    try testing.expect(!try matches("^(ab)+$", "aba"));
}

test "regex: 转义元字符" {
    try testing.expect(try matches("a\\.c", "a.c"));
    try testing.expect(!try matches("a\\.c", "abc"));
    try testing.expect(try matches("\\$5", "cost $5"));
}

test "regex: 大小写不敏感" {
    try testing.expect(try matchesI("HELLO", "say hello"));
    try testing.expect(!try matches("HELLO", "say hello"));
}

test "regex: 非法模式报错而不是 panic" {
    try testing.expectError(error.InvalidPattern, Regex.compile(testing.allocator, "(abc", false));
    try testing.expectError(error.InvalidPattern, Regex.compile(testing.allocator, "[abc", false));
    try testing.expectError(error.InvalidPattern, Regex.compile(testing.allocator, "a\\", false));
}

test "regex: 病态模式受 MAX_STEPS 保护，不挂死" {
    var re = try Regex.compile(testing.allocator, "(a*)*b", false);
    defer re.deinit();
    const text = "a" ** 40;
    try testing.expect(!try re.isMatch(testing.allocator, text, false));
}

test "regex: 多行模式 . 与 ^ $ 跨行" {
    var re = try Regex.compile(testing.allocator, "^b.*c$", false);
    defer re.deinit();
    try testing.expect(!try re.isMatch(testing.allocator, "a\nbxc\nd", false));
    try testing.expect(try re.isMatch(testing.allocator, "a\nbxc\nd", true));
    var re2 = try Regex.compile(testing.allocator, "^d$", false);
    defer re2.deinit();
    try testing.expect(try re2.isMatch(testing.allocator, "a\nb\nc\nd", true));
}

test "regex: 字面量快路径判定与搜索" {
    try testing.expect(isLiteral("hello world"));
    try testing.expect(!isLiteral("h.llo"));
    try testing.expect(!isLiteral("a|b"));
    try testing.expectEqual(@as(?usize, 2), literalFind("xxabc", "abc", false, 0));
    try testing.expectEqual(@as(?usize, 0), literalFind("ABC", "abc", true, 0));
    try testing.expectEqual(@as(?usize, null), literalFind("ABC", "abc", false, 0));
}
