//! `tools/edit.zig` —— `Edit`（别名 `edit_file`，文档 05 §4.3）。
//!
//! 失败必须**响亮**（E1/E2/E3）：`old_string` 缺失、不唯一（且未开 `replace_all`）、
//! 新旧相同时一律返回 `is_error`，**绝不静默做部分替换**。
//! 失败信息带稳定签名（`OLD_STRING_NOT_FOUND` / `OLD_STRING_NOT_UNIQUE` / `NO_CHANGES`），
//! 便于上游做机器判别。
//!
//! 首期明确的收缩：E4「未读先改」需要会话级文件状态跟踪，首期没有
//! `SessionToolState`，故不做。

const std = @import("std");
const common = @import("common");
const json = common.json;
const specs = @import("specs.zig");
const sys = @import("sys.zig");
const diff = @import("diff.zig");
const truncate = @import("truncate.zig");

pub const spec = specs.edit_spec;

pub const definition = common.Tool{
    .name = "Edit",
    .aliases = &.{"edit_file"},
    .description = "Replace an exact string in a file",
    .spec = spec,
    .is_read_only = alwaysFalse,
    .is_destructive = alwaysTrue,
    .is_concurrency_safe = alwaysFalse,
    .max_result_chars = common.ToolResult.MAX_TOOL_RESULT_CHARS,
    .execute = execute,
};

fn alwaysFalse(_: []const u8) bool {
    return false;
}
fn alwaysTrue(_: []const u8) bool {
    return true;
}

fn errFmt(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) anyerror!common.ToolResult {
    return .{ .output = try std.fmt.allocPrint(gpa, fmt, args), .is_error = true };
}

/// 非重叠计数。
pub fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |p| {
        count += 1;
        i = p + needle.len;
    }
    return count;
}

/// 替换前 `n` 处（`all=false` 时只替换第一处）。
pub fn replaceOccurrences(
    gpa: std.mem.Allocator,
    content: []const u8,
    old: []const u8,
    new: []const u8,
    all: bool,
) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, content, i, old)) |p| {
        try out.appendSlice(gpa, content[i..p]);
        try out.appendSlice(gpa, new);
        i = p + old.len;
        if (!all) break;
    }
    try out.appendSlice(gpa, content[i..]);
    return out.toOwnedSlice(gpa);
}

pub fn execute(ctx: *common.ToolContext, input: []const u8) anyerror!common.ToolResult {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    if (try spec.validate(a, input)) |msg| return errFmt(ctx.gpa, "Invalid input: {s}", .{msg});
    const v = json.parse(a, input) catch return common.ToolResult.err("input must be valid JSON");

    const raw_path = v.getString("file_path") orelse return common.ToolResult.err("missing required field 'file_path'");
    const old_string = v.getString("old_string") orelse return common.ToolResult.err("missing required field 'old_string'");
    const new_string = v.getString("new_string") orelse return common.ToolResult.err("missing required field 'new_string'");
    const replace_all = v.getBool("replace_all") orelse false;

    if (old_string.len == 0) {
        return errFmt(ctx.gpa, "ERR_OLD_STRING_EMPTY [OLD_STRING_EMPTY]: old_string must not be empty", .{});
    }
    if (std.mem.eql(u8, old_string, new_string)) {
        return errFmt(ctx.gpa, "ERR_NO_CHANGES [NO_CHANGES]: old_string and new_string are identical; nothing to do", .{});
    }

    const path = sys.resolve(ctx.gpa, ctx.cwd, raw_path) catch |e|
        return errFmt(ctx.gpa, "Cannot resolve path '{s}': {s}", .{ raw_path, @errorName(e) });

    if (sys.isDir(ctx.io, path)) return errFmt(ctx.gpa, "Path is a directory: {s}", .{path});

    const content = sys.readFileAlloc(ctx.io, ctx.gpa, path, specs.READ_MAX_BYTES) catch |e| switch (e) {
        error.FileNotFound => return errFmt(ctx.gpa, "ERR_MISSING_PATH [MISSING_PATH]: file not found: {s}", .{path}),
        else => return errFmt(ctx.gpa, "Cannot read file {s}: {s}", .{ path, @errorName(e) }),
    };
    defer ctx.gpa.free(content);

    const matches = countOccurrences(content, old_string);
    if (matches == 0) {
        return errFmt(ctx.gpa, "ERR_OLD_STRING_NOT_FOUND [OLD_STRING_NOT_FOUND]: old_string was not found in {s}", .{path});
    }
    if (matches > 1 and !replace_all) {
        return errFmt(
            ctx.gpa,
            "ERR_OLD_STRING_NOT_UNIQUE [OLD_STRING_NOT_UNIQUE]: old_string is not unique, found {d} matches in {s}; pass replace_all=true or include more context",
            .{ matches, path },
        );
    }

    const updated = try replaceOccurrences(ctx.gpa, content, old_string, new_string, replace_all or matches == 1);
    defer ctx.gpa.free(updated);

    const d = try diff.unified(ctx.gpa, content, updated, path, diff.DEFAULT_CONTEXT);

    sys.atomicWrite(ctx.io, ctx.gpa, path, updated) catch |e|
        return errFmt(ctx.gpa, "Cannot write file {s}: {s}", .{ path, @errorName(e) });

    const replacements: usize = if (replace_all) matches else 1;
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(ctx.gpa);
    try out.print(ctx.gpa, "Edited {s} ({d} replacement(s), +{d}/-{d})\n", .{ path, replacements, d.stats.added, d.stats.removed });
    try out.appendSlice(ctx.gpa, d.text);

    var res = common.ToolResult.ok(try out.toOwnedSlice(ctx.gpa));
    try res.metadata.put(ctx.gpa, "path", .{ .string = path });
    try res.metadata.put(ctx.gpa, "matchCount", .{ .integer = @intCast(replacements) });
    try res.metadata.put(ctx.gpa, "unifiedDiff", .{ .string = d.text });
    try res.metadata.put(ctx.gpa, "addedLines", .{ .integer = @intCast(d.stats.added) });
    try res.metadata.put(ctx.gpa, "removedLines", .{ .integer = @intCast(d.stats.removed) });
    return truncate.finish(ctx.gpa, ctx, res, definition.max_result_chars);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "edit: countOccurrences 非重叠计数" {
    try testing.expectEqual(@as(usize, 0), countOccurrences("abc", "z"));
    try testing.expectEqual(@as(usize, 1), countOccurrences("a b c", "b"));
    try testing.expectEqual(@as(usize, 3), countOccurrences("a a a", "a"));
    try testing.expectEqual(@as(usize, 2), countOccurrences("aaaa", "aa"));
    try testing.expectEqual(@as(usize, 0), countOccurrences("aaaa", ""));
}

test "edit: replaceOccurrences 单个 / 全部 / 中文" {
    const one = try replaceOccurrences(testing.allocator, "a b c", "b", "X", false);
    defer testing.allocator.free(one);
    try testing.expectEqualStrings("a X c", one);

    const all = try replaceOccurrences(testing.allocator, "a a a", "a", "b", true);
    defer testing.allocator.free(all);
    try testing.expectEqualStrings("b b b", all);

    const cjk = try replaceOccurrences(testing.allocator, "你好世界", "世界", "zig", true);
    defer testing.allocator.free(cjk);
    try testing.expectEqualStrings("你好zig", cjk);
}

fn setUp(io: std.Io, dir: []const u8, name: []const u8, content: []const u8) ![]u8 {
    const path = try std.fs.path.join(testing.allocator, &.{ dir, name });
    try sys.writeFile(io, path, content);
    return path;
}

test "edit: Write 之后 Edit 往返（含 diff 输出）" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try sys.makeTestDir(io, testing.allocator, "edit");
    defer testing.allocator.free(dir);
    defer sys.removeTree(io, dir) catch {};

    const target = try setUp(io, dir, "f.txt", "hello world\nsecond line\n");
    defer testing.allocator.free(target);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = dir };

    const args = try std.fmt.allocPrint(
        arena.allocator(),
        "{{\"file_path\":\"{s}\",\"old_string\":\"world\",\"new_string\":\"zig\",\"replace_all\":false}}",
        .{target},
    );
    const res = try execute(&ctx, args);
    try testing.expect(!res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.output, "1 replacement(s)") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "-hello world") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "+hello zig") != null);

    const back = try sys.readFileAlloc(io, testing.allocator, target, 1024);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("hello zig\nsecond line\n", back);
}

test "edit: 歧义 old_string 必须报错（不静默部分替换）" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try sys.makeTestDir(io, testing.allocator, "edit");
    defer testing.allocator.free(dir);
    defer sys.removeTree(io, dir) catch {};

    const target = try setUp(io, dir, "dup.txt", "a a a\n");
    defer testing.allocator.free(target);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = dir };

    const args = try std.fmt.allocPrint(
        arena.allocator(),
        "{{\"file_path\":\"{s}\",\"old_string\":\"a\",\"new_string\":\"b\",\"replace_all\":false}}",
        .{target},
    );
    const res = try execute(&ctx, args);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.output, "OLD_STRING_NOT_UNIQUE") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "found 3 matches") != null);

    // 文件必须原封不动
    const back = try sys.readFileAlloc(io, testing.allocator, target, 1024);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("a a a\n", back);
}

test "edit: replace_all=true 全部替换" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try sys.makeTestDir(io, testing.allocator, "edit");
    defer testing.allocator.free(dir);
    defer sys.removeTree(io, dir) catch {};

    const target = try setUp(io, dir, "dup.txt", "a a a\n");
    defer testing.allocator.free(target);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = dir };

    const args = try std.fmt.allocPrint(
        arena.allocator(),
        "{{\"file_path\":\"{s}\",\"old_string\":\"a\",\"new_string\":\"b\",\"replace_all\":true}}",
        .{target},
    );
    const res = try execute(&ctx, args);
    try testing.expect(!res.is_error);
    try testing.expectEqual(@as(i64, 3), res.metadata.get("matchCount").?.asInt().?);

    const back = try sys.readFileAlloc(io, testing.allocator, target, 1024);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("b b b\n", back);
}

test "edit: old_string 缺失 / 新旧相同 / 文件缺失都报错" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try sys.makeTestDir(io, testing.allocator, "edit");
    defer testing.allocator.free(dir);
    defer sys.removeTree(io, dir) catch {};

    const target = try setUp(io, dir, "f.txt", "abc\n");
    defer testing.allocator.free(target);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = dir };

    const not_found = try execute(&ctx, try std.fmt.allocPrint(
        arena.allocator(),
        "{{\"file_path\":\"{s}\",\"old_string\":\"zzz\",\"new_string\":\"y\",\"replace_all\":false}}",
        .{target},
    ));
    try testing.expect(not_found.is_error);
    try testing.expect(std.mem.indexOf(u8, not_found.output, "OLD_STRING_NOT_FOUND") != null);

    const no_change = try execute(&ctx, try std.fmt.allocPrint(
        arena.allocator(),
        "{{\"file_path\":\"{s}\",\"old_string\":\"abc\",\"new_string\":\"abc\",\"replace_all\":false}}",
        .{target},
    ));
    try testing.expect(no_change.is_error);
    try testing.expect(std.mem.indexOf(u8, no_change.output, "NO_CHANGES") != null);

    const missing = try execute(&ctx, try std.fmt.allocPrint(
        arena.allocator(),
        "{{\"file_path\":\"{s}/nope.txt\",\"old_string\":\"a\",\"new_string\":\"b\",\"replace_all\":false}}",
        .{dir},
    ));
    try testing.expect(missing.is_error);
    try testing.expect(std.mem.indexOf(u8, missing.output, "MISSING_PATH") != null);
}

test "edit: 未通过 spec 校验的输入被拦下" {
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/" };
    const res = try execute(&ctx, "{\"file_path\":\"/x\",\"old_string\":\"a\",\"new_string\":\"b\"}");
    defer testing.allocator.free(res.output);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.output, "Invalid input") != null);
}
