//! `tools/grep.zig` —— `Grep`（别名 `grep`，文档 05 §4.6）。
//!
//! - 三种 `output_mode`：`content` / `files_with_matches` / `count`；
//! - 字面量走子串快路径，其余走 `regex.zig` 的最小正则子集（无外部依赖）；
//! - `head_limit` 缺省 **100**，且这个数只声明一次（`specs.GREP_DEFAULT_HEAD_LIMIT`），
//!   模型文案由 `comptimePrint` 从同一个常量生成 —— 修复「文案 250 / 代码 100」事故；
//! - `-i`/`-B`/`-A` 优先于遗留名 `case_insensitive`/`context_before`/`context_after`（P5）；
//! - 取消返回 `Grep was cancelled by user interrupt.`（P6）。

const std = @import("std");
const common = @import("common");
const json = common.json;
const specs = @import("specs.zig");
const sys = @import("sys.zig");
const regex = @import("regex.zig");
const truncate = @import("truncate.zig");

pub const spec = specs.grep_spec;

pub const definition = common.Tool{
    .name = "Grep",
    .aliases = &.{"grep"},
    .description = "Search file contents with a regular expression or literal string",
    .spec = spec,
    .is_read_only = alwaysTrue,
    .is_destructive = alwaysFalse,
    .is_concurrency_safe = alwaysTrue,
    .max_result_chars = specs.SEARCH_MAX_RESULT_CHARS,
    .execute = execute,
};

fn alwaysTrue(_: []const u8) bool {
    return true;
}
fn alwaysFalse(_: []const u8) bool {
    return false;
}

pub const MSG_CANCELLED = "Grep was cancelled by user interrupt.";
/// 单次执行的条目硬上限（防跑飞；`head_limit` 之外的安全阀）。
pub const HARD_ENTRY_CAP: usize = 10_000;

pub const OutputMode = enum {
    content,
    files_with_matches,
    count,

    pub fn parse(s: ?[]const u8) OutputMode {
        const v = s orelse return .content;
        if (std.mem.eql(u8, v, "files_with_matches")) return .files_with_matches;
        if (std.mem.eql(u8, v, "count")) return .count;
        return .content;
    }

    /// 显式 wire 映射（不用 `@tagName`，契约规则 6）。
    pub fn wireName(self: OutputMode) []const u8 {
        return switch (self) {
            .content => "content",
            .files_with_matches => "files_with_matches",
            .count => "count",
        };
    }
};

fn errFmt(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) anyerror!common.ToolResult {
    return .{ .output = try std.fmt.allocPrint(gpa, fmt, args), .is_error = true };
}

fn splitLines(gpa: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var list = std.ArrayListUnmanaged([]const u8).empty;
    errdefer list.deinit(gpa);
    var start: usize = 0;
    while (start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        try list.append(gpa, text[start..nl]);
        start = nl + 1;
    }
    return list.toOwnedSlice(gpa);
}

/// `pos` 所在行的 0-based 行号。
pub fn lineIndexAt(text: []const u8, pos: usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    const end = @min(pos, text.len);
    while (i < end) : (i += 1) {
        if (text[i] == '\n') n += 1;
    }
    return n;
}

pub fn globFilterMatches(filter: []const u8, rel: []const u8, basename: []const u8) bool {
    if (std.mem.indexOfScalar(u8, filter, '/') != null) return sys.globMatch(filter, rel);
    return sys.globMatch(filter, basename);
}

pub fn execute(ctx: *common.ToolContext, input: []const u8) anyerror!common.ToolResult {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    if (try spec.validate(a, input)) |msg| return errFmt(ctx.gpa, "Invalid input: {s}", .{msg});
    const v = json.parse(a, input) catch return common.ToolResult.err("input must be valid JSON");

    const pattern = v.getString("pattern") orelse return common.ToolResult.err("missing required field 'pattern'");
    if (pattern.len == 0) return errFmt(ctx.gpa, "pattern must not be empty", .{});

    const mode = OutputMode.parse(v.getString("output_mode"));
    const ignore_case = v.getBool("-i") orelse v.getBool("case_insensitive") orelse false;
    const multiline = v.getBool("multiline") orelse false;
    const show_numbers = v.getBool("-n") orelse true;
    const head_limit: usize = blk: {
        const raw = v.getInt("head_limit") orelse @as(i64, @intCast(specs.GREP_DEFAULT_HEAD_LIMIT));
        break :blk @intCast(@max(1, raw));
    };
    const offset: usize = if (v.getInt("offset")) |o| @intCast(@max(0, o)) else 0;
    const ctx_all: i64 = v.getInt("-C") orelse v.getInt("context") orelse 0;
    const before: usize = @intCast(@max(0, v.getInt("-B") orelse ctx_all));
    const after: usize = @intCast(@max(0, v.getInt("-A") orelse ctx_all));
    const glob_filter = v.getString("glob");
    const raw_root = v.getString("path") orelse ctx.cwd;

    const root = sys.resolve(ctx.gpa, ctx.cwd, raw_root) catch |e|
        return errFmt(ctx.gpa, "Cannot resolve path '{s}': {s}", .{ raw_root, @errorName(e) });
    defer ctx.gpa.free(root);

    if (ctx.isCancelled()) return common.ToolResult.err(MSG_CANCELLED);

    const literal = regex.isLiteral(pattern);
    var re: ?regex.Regex = null;
    if (!literal) {
        re = regex.Regex.compile(ctx.gpa, pattern, ignore_case) catch |e| switch (e) {
            error.InvalidPattern => return errFmt(ctx.gpa, "Invalid regular expression: {s}", .{pattern}),
            else => return errFmt(ctx.gpa, "Cannot compile pattern: {s}", .{@errorName(e)}),
        };
    }
    defer if (re) |*r| r.deinit();

    // 收集待搜索文件
    var files = std.ArrayListUnmanaged([]const u8).empty;
    defer files.deinit(ctx.gpa);
    var owned: [][]u8 = &.{};
    defer sys.freePaths(ctx.gpa, owned);

    if (sys.isDir(ctx.io, root)) {
        owned = sys.collectFiles(ctx.io, ctx.gpa, root, .{}) catch |e|
            return errFmt(ctx.gpa, "Cannot search '{s}': {s}", .{ root, @errorName(e) });
        for (owned) |f| try files.append(ctx.gpa, f);
    } else if (sys.exists(ctx.io, root)) {
        try files.append(ctx.gpa, root);
    } else {
        return errFmt(ctx.gpa, "Path not found: {s}", .{root});
    }

    var entries = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (entries.items) |e| ctx.gpa.free(e);
        entries.deinit(ctx.gpa);
    }

    for (files.items) |file| {
        if (ctx.isCancelled()) return common.ToolResult.err(MSG_CANCELLED);
        if (glob_filter) |gf| {
            if (!globFilterMatches(gf, relativeTo(root, file), std.fs.path.basename(file))) continue;
        }

        const content = sys.readFileAlloc(ctx.io, ctx.gpa, file, specs.READ_MAX_BYTES) catch continue;
        defer ctx.gpa.free(content);
        if (isBinaryish(content)) continue;

        const lines = try splitLines(ctx.gpa, content);
        defer ctx.gpa.free(lines);

        var matched = std.ArrayListUnmanaged(usize).empty;
        defer matched.deinit(ctx.gpa);

        if (literal) {
            try findLiteralMatches(ctx.gpa, content, lines, pattern, ignore_case, multiline, &matched);
        } else {
            try findRegexMatches(ctx.gpa, &re.?, content, lines, multiline, &matched);
        }
        if (matched.items.len == 0) continue;

        switch (mode) {
            .files_with_matches => {
                try entries.append(ctx.gpa, try ctx.gpa.dupe(u8, file));
            },
            .count => {
                try entries.append(ctx.gpa, try std.fmt.allocPrint(ctx.gpa, "{s}:{d}", .{ file, matched.items.len }));
            },
            .content => {
                try emitContentLines(ctx.gpa, &entries, file, lines, matched.items, before, after, show_numbers);
            },
        }
        if (entries.items.len >= HARD_ENTRY_CAP) break;
    }

    const start = @min(offset, entries.items.len);
    const end = @min(start + head_limit, entries.items.len);

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(ctx.gpa);
    for (entries.items[start..end], 0..) |e, i| {
        if (i > 0) try out.append(ctx.gpa, '\n');
        try out.appendSlice(ctx.gpa, e);
    }
    if (out.items.len > 0) try out.append(ctx.gpa, '\n');
    if (entries.items.len > end) {
        try out.print(ctx.gpa, "... [truncated: {d} of {d} results shown; use offset/head_limit]\n", .{ end - start, entries.items.len });
    }

    var res = common.ToolResult.ok(try out.toOwnedSlice(ctx.gpa));
    try res.metadata.put(ctx.gpa, "matchCount", .{ .integer = @intCast(entries.items.len) });
    try res.metadata.put(ctx.gpa, "outputMode", .{ .string = mode.wireName() });
    return truncate.finish(ctx.gpa, ctx, res, definition.max_result_chars);
}

fn relativeTo(root: []const u8, path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, root)) {
        var rel = path[root.len..];
        if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
        return rel;
    }
    return path;
}

fn isBinaryish(content: []const u8) bool {
    const n = @min(content.len, 8000);
    for (content[0..n]) |c| {
        if (c == 0) return true;
    }
    return false;
}

fn appendUnique(list: *std.ArrayListUnmanaged(usize), gpa: std.mem.Allocator, idx: usize) !void {
    if (list.items.len > 0 and list.items[list.items.len - 1] == idx) return;
    try list.append(gpa, idx);
}

fn findLiteralMatches(
    gpa: std.mem.Allocator,
    content: []const u8,
    lines: [][]const u8,
    pattern: []const u8,
    ignore_case: bool,
    multiline: bool,
    matched: *std.ArrayListUnmanaged(usize),
) !void {
    if (!multiline) {
        for (lines, 0..) |line, i| {
            if (regex.literalFind(line, pattern, ignore_case, 0) != null) try matched.append(gpa, i);
        }
        return;
    }
    var pos: usize = 0;
    while (regex.literalFind(content, pattern, ignore_case, pos)) |p| {
        try appendUnique(matched, gpa, lineIndexAt(content, p));
        pos = p + @max(pattern.len, 1);
        if (pos > content.len) break;
    }
}

fn findRegexMatches(
    gpa: std.mem.Allocator,
    re: *const regex.Regex,
    content: []const u8,
    lines: [][]const u8,
    multiline: bool,
    matched: *std.ArrayListUnmanaged(usize),
) !void {
    if (!multiline) {
        for (lines, 0..) |line, i| {
            if (try re.isMatch(gpa, line, false)) try matched.append(gpa, i);
        }
        return;
    }
    var pos: usize = 0;
    while (try re.find(gpa, content, pos, true)) |m| {
        try appendUnique(matched, gpa, lineIndexAt(content, m.start));
        pos = if (m.end > m.start) m.end else m.start + 1;
        if (pos > content.len) break;
    }
}

fn emitContentLines(
    gpa: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged([]u8),
    file: []const u8,
    lines: [][]const u8,
    matched: []const usize,
    before: usize,
    after: usize,
    show_numbers: bool,
) !void {
    var prev_end: ?usize = null;
    for (matched) |mi| {
        const start = mi -| before;
        const end = @min(mi + after, if (lines.len == 0) 0 else lines.len - 1);
        const begin = if (prev_end) |pe| @max(pe + 1, start) else start;
        if (lines.len == 0) continue;
        var i = begin;
        while (i <= end) : (i += 1) {
            const is_match = i == mi;
            const sep: u8 = if (is_match) ':' else '-';
            const text = try (if (show_numbers)
                std.fmt.allocPrint(gpa, "{s}{c}{d}{c}{s}", .{ file, sep, i + 1, sep, lines[i] })
            else
                std.fmt.allocPrint(gpa, "{s}{c}{s}", .{ file, sep, lines[i] }));
            try entries.append(gpa, text);
            if (entries.items.len >= HARD_ENTRY_CAP) return;
        }
        prev_end = end;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn touch(io: std.Io, dir: []const u8, rel: []const u8, body: []const u8) !void {
    const path = try std.fs.path.join(testing.allocator, &.{ dir, rel });
    defer testing.allocator.free(path);
    try sys.mkdirp(io, std.fs.path.dirname(path).?);
    try sys.writeFile(io, path, body);
}

test "grep: lineIndexAt 与 globFilterMatches" {
    const text = "l0\nl1\nl2\n";
    try testing.expectEqual(@as(usize, 0), lineIndexAt(text, 0));
    try testing.expectEqual(@as(usize, 1), lineIndexAt(text, 3));
    try testing.expectEqual(@as(usize, 2), lineIndexAt(text, 6));
    try testing.expect(globFilterMatches("*.zig", "src/a.zig", "a.zig"));
    try testing.expect(!globFilterMatches("*.zig", "src/a.txt", "a.txt"));
    try testing.expect(globFilterMatches("src/*.zig", "src/a.zig", "a.zig"));
}

test "grep: content / files_with_matches / count 三种模式" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try sys.makeTestDir(io, testing.allocator, "grep");
    defer testing.allocator.free(dir);
    defer sys.removeTree(io, dir) catch {};

    try touch(io, dir, "a.txt", "alpha\nbeta\ngamma\n");
    try touch(io, dir, "b.txt", "bravo\nalpha again\n");
    try touch(io, dir, "c.md", "alpha in md\n");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = dir };

    const content = try execute(&ctx, "{\"pattern\":\"alpha\"}");
    try testing.expect(!content.is_error);
    try testing.expect(std.mem.indexOf(u8, content.output, "a.txt:1:alpha") != null);
    try testing.expect(std.mem.indexOf(u8, content.output, "b.txt:2:alpha again") != null);
    try testing.expect(std.mem.indexOf(u8, content.output, "c.md:1:alpha in md") != null);

    const files_only = try execute(&ctx, "{\"pattern\":\"alpha\",\"output_mode\":\"files_with_matches\"}");
    try testing.expectEqual(@as(i64, 3), files_only.metadata.get("matchCount").?.asInt().?);
    try testing.expect(std.mem.indexOf(u8, files_only.output, ":") == null);

    const counts = try execute(&ctx, "{\"pattern\":\"alpha\",\"output_mode\":\"count\"}");
    try testing.expect(std.mem.indexOf(u8, counts.output, "b.txt:1") != null);

    const none = try execute(&ctx, "{\"pattern\":\"zzz-not-here\"}");
    try testing.expect(!none.is_error);
    try testing.expectEqual(@as(usize, 0), none.output.len);
}

test "grep: -i 忽略大小写、glob 过滤、正则子集" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try sys.makeTestDir(io, testing.allocator, "grep");
    defer testing.allocator.free(dir);
    defer sys.removeTree(io, dir) catch {};

    try touch(io, dir, "a.txt", "Alpha\nbeta\n");
    try touch(io, dir, "b.txt", "ALPHA\n");
    try touch(io, dir, "c.log", "alpha\n");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = dir };

    const ci = try execute(&ctx, "{\"pattern\":\"alpha\",\"-i\":true}");
    try testing.expectEqual(@as(i64, 3), ci.metadata.get("matchCount").?.asInt().?);

    const filtered = try execute(&ctx, "{\"pattern\":\"alpha\",\"-i\":true,\"glob\":\"*.log\"}");
    try testing.expectEqual(@as(i64, 1), filtered.metadata.get("matchCount").?.asInt().?);
    try testing.expect(std.mem.indexOf(u8, filtered.output, "c.log") != null);

    const anchored = try execute(&ctx, "{\"pattern\":\"^A.*a$\"}");
    try testing.expect(std.mem.indexOf(u8, anchored.output, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, anchored.output, "c.log") == null);

    const regex_hit = try execute(&ctx, "{\"pattern\":\"^a.*a$\",\"-i\":true}");
    try testing.expect(std.mem.indexOf(u8, regex_hit.output, "a.txt:1:Alpha") != null);
}

test "grep: head_limit 生效、缺省值与 Spec 一致、offset 跳过" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try sys.makeTestDir(io, testing.allocator, "grep");
    defer testing.allocator.free(dir);
    defer sys.removeTree(io, dir) catch {};

    try touch(io, dir, "a.txt", "hit one\nhit two\nhit three\nhit four\n");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = dir };

    const limited = try execute(&ctx, "{\"pattern\":\"hit\",\"head_limit\":2}");
    try testing.expect(std.mem.indexOf(u8, limited.output, "hit one") != null);
    try testing.expect(std.mem.indexOf(u8, limited.output, "hit three") == null);
    try testing.expect(std.mem.indexOf(u8, limited.output, "truncated: 2 of 4") != null);

    const skipped = try execute(&ctx, "{\"pattern\":\"hit\",\"head_limit\":1,\"offset\":2}");
    try testing.expect(std.mem.indexOf(u8, skipped.output, "hit three") != null);
    try testing.expect(std.mem.indexOf(u8, skipped.output, "hit one") == null);

    // 缺省 head_limit 就是 specs 里的那个数
    const f = specs.grep_spec.field("head_limit").?;
    try testing.expect(f.default_json != null);
    try testing.expectEqualStrings("100", f.default_json.?);
    try testing.expectEqual(@as(usize, 100), specs.GREP_DEFAULT_HEAD_LIMIT);
}

test "grep: 上下文行 -C 以 '-' 分隔" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try sys.makeTestDir(io, testing.allocator, "grep");
    defer testing.allocator.free(dir);
    defer sys.removeTree(io, dir) catch {};

    try touch(io, dir, "ctx.txt", "before\ntarget\nafter\n");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = dir };

    const res = try execute(&ctx, "{\"pattern\":\"target\",\"-C\":1}");
    try testing.expect(std.mem.indexOf(u8, res.output, "ctx.txt:2:target") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "ctx.txt-1-before") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "ctx.txt-3-after") != null);
}

test "grep: 单文件 path / 不存在 path / 非法正则" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try sys.makeTestDir(io, testing.allocator, "grep");
    defer testing.allocator.free(dir);
    defer sys.removeTree(io, dir) catch {};
    try touch(io, dir, "one.txt", "needle\n");
    try touch(io, dir, "two.txt", "needle\n");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = dir };

    const single = try execute(&ctx, try std.fmt.allocPrint(arena.allocator(), "{{\"pattern\":\"needle\",\"path\":\"{s}/one.txt\"}}", .{dir}));
    try testing.expectEqual(@as(i64, 1), single.metadata.get("matchCount").?.asInt().?);
    try testing.expect(std.mem.indexOf(u8, single.output, "one.txt") != null);

    const missing = try execute(&ctx, "{\"pattern\":\"needle\",\"path\":\"/nope/nope\"}");
    try testing.expect(missing.is_error);
    try testing.expect(std.mem.indexOf(u8, missing.output, "Path not found") != null);

    const bad_re = try execute(&ctx, "{\"pattern\":\"(unclosed\"}");
    try testing.expect(bad_re.is_error);
    try testing.expect(std.mem.indexOf(u8, bad_re.output, "Invalid regular expression") != null);
}

test "grep: 取消令牌 → 取消文案" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try sys.makeTestDir(io, testing.allocator, "grep");
    defer testing.allocator.free(dir);
    defer sys.removeTree(io, dir) catch {};

    var flag = std.atomic.Value(bool).init(true);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = dir, .cancelled = &flag };

    const res = try execute(&ctx, "{\"pattern\":\"x\"}");
    try testing.expect(res.is_error);
    try testing.expectEqualStrings(MSG_CANCELLED, res.output);
}

test "grep: 空 pattern 被拒" {
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/" };
    const res = try execute(&ctx, "{\"pattern\":\"\"}");
    defer testing.allocator.free(res.output);
    try testing.expect(res.is_error);
}
