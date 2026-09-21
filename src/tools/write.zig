//! `tools/write.zig` —— `Write`（别名 `write_file`，文档 05 §4.2）。
//!
//! 首期实现范围（明确不做的事也写清楚）：
//!   - ✅ 覆盖/新建、递归建父目录、原子写（临时文件 + rename）；
//!   - ✅ 覆盖时在 `metadata.unifiedDiff` 给出 unified diff 预览；
//!   - ⛔ 文件状态跟踪（W1「写前必读」/ W2 过期检查）需要 `SessionToolState`，
//!     首期没有会话状态容器，故不做 —— 这是**有意收缩**，不是遗漏。

const std = @import("std");
const common = @import("common");
const json = common.json;
const specs = @import("specs.zig");
const sys = @import("sys.zig");
const diff = @import("diff.zig");
const truncate = @import("truncate.zig");

pub const spec = specs.write_spec;

pub const definition = common.Tool{
    .name = "Write",
    .aliases = &.{"write_file"},
    .description = "Write content to a file, creating parent directories",
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

pub fn execute(ctx: *common.ToolContext, input: []const u8) anyerror!common.ToolResult {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    if (try spec.validate(a, input)) |msg| return errFmt(ctx.gpa, "Invalid input: {s}", .{msg});
    const v = json.parse(a, input) catch return common.ToolResult.err("input must be valid JSON");

    const raw_path = v.getString("file_path") orelse return common.ToolResult.err("missing required field 'file_path'");
    const content = v.getString("content") orelse return common.ToolResult.err("missing required field 'content'");

    const path = sys.resolve(ctx.gpa, ctx.cwd, raw_path) catch |e|
        return errFmt(ctx.gpa, "Cannot resolve path '{s}': {s}", .{ raw_path, @errorName(e) });

    if (sys.isDir(ctx.io, path)) return errFmt(ctx.gpa, "Path is a directory: {s}", .{path});

    // W8：默认 create_dirs = true（strict 模型 schema 刻意省略该字段）
    if (std.fs.path.dirname(path)) |parent| {
        sys.mkdirp(ctx.io, parent) catch |e|
            return errFmt(ctx.gpa, "Cannot create parent directory '{s}': {s}", .{ parent, @errorName(e) });
    }

    const existed = sys.exists(ctx.io, path);
    const before: []const u8 = if (existed)
        (sys.readFileAlloc(ctx.io, ctx.gpa, path, specs.READ_MAX_BYTES) catch |e|
            return errFmt(ctx.gpa, "Cannot read existing file {s}: {s}", .{ path, @errorName(e) }))
    else
        "";
    defer if (existed) ctx.gpa.free(before);

    const d = try diff.unified(ctx.gpa, before, content, path, diff.DEFAULT_CONTEXT);
    // d.text 归 metadata 所有（调用方的 arena/gpa 释放），此处不 free。

    sys.atomicWrite(ctx.io, ctx.gpa, path, content) catch |e|
        return errFmt(ctx.gpa, "Cannot write file {s}: {s}", .{ path, @errorName(e) });

    const chars = common.usage.countCodePoints(content);
    const out = try std.fmt.allocPrint(
        ctx.gpa,
        "Wrote {d} chars to {s} (+{d}/-{d})",
        .{ chars, path, d.stats.added, d.stats.removed },
    );

    var res = common.ToolResult.ok(out);
    try res.metadata.put(ctx.gpa, "path", .{ .string = path });
    // displayPath 必须拷贝：raw_path 指向解析用的 arena，execute 返回即释放。
    try res.metadata.put(ctx.gpa, "displayPath", .{ .string = try ctx.gpa.dupe(u8, raw_path) });
    try res.metadata.put(ctx.gpa, "created", .{ .boolean = !existed });
    try res.metadata.put(ctx.gpa, "unifiedDiff", .{ .string = d.text });
    try res.metadata.put(ctx.gpa, "addedLines", .{ .integer = @intCast(d.stats.added) });
    try res.metadata.put(ctx.gpa, "removedLines", .{ .integer = @intCast(d.stats.removed) });
    return truncate.finish(ctx.gpa, ctx, res, definition.max_result_chars);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "write: 新建文件 + 递归建父目录 + created 标记" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try sys.makeTestDir(io, testing.allocator, "write");
    defer testing.allocator.free(dir);
    defer sys.removeTree(io, dir) catch {};

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = dir };

    const target = try std.fs.path.join(arena.allocator(), &.{ dir, "deep/nested/new.txt" });
    const args = try std.fmt.allocPrint(arena.allocator(), "{{\"file_path\":\"{s}\",\"content\":\"one\\ntwo\\n\"}}", .{target});
    const res = try execute(&ctx, args);
    try testing.expect(!res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.output, "Wrote 8 chars") != null);
    try testing.expect(res.metadata.get("created").?.boolean);

    const back = try sys.readFileAlloc(io, testing.allocator, target, 1024);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("one\ntwo\n", back);
    try testing.expect(sys.isDir(io, std.fs.path.dirname(target).?));
}

test "write: 覆盖已有文件时 metadata 带 unifiedDiff 与增删行数" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try sys.makeTestDir(io, testing.allocator, "write");
    defer testing.allocator.free(dir);
    defer sys.removeTree(io, dir) catch {};

    const target = try std.fs.path.join(testing.allocator, &.{ dir, "f.txt" });
    defer testing.allocator.free(target);
    try sys.writeFile(io, target, "alpha\nbeta\n");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = dir };

    const args = try std.fmt.allocPrint(arena.allocator(), "{{\"file_path\":\"{s}\",\"content\":\"alpha\\nBETA\\n\"}}", .{target});
    const res = try execute(&ctx, args);
    try testing.expect(!res.is_error);
    try testing.expect(!res.metadata.get("created").?.boolean);
    const d = res.metadata.get("unifiedDiff").?.asString().?;
    try testing.expect(std.mem.indexOf(u8, d, "-beta") != null);
    try testing.expect(std.mem.indexOf(u8, d, "+BETA") != null);
    try testing.expectEqual(@as(i64, 1), res.metadata.get("addedLines").?.asInt().?);
    try testing.expectEqual(@as(i64, 1), res.metadata.get("removedLines").?.asInt().?);
}

test "write: 目标是目录时报错" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try sys.makeTestDir(io, testing.allocator, "write");
    defer testing.allocator.free(dir);
    defer sys.removeTree(io, dir) catch {};

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = dir };

    const args = try std.fmt.allocPrint(arena.allocator(), "{{\"file_path\":\"{s}\",\"content\":\"x\"}}", .{dir});
    const res = try execute(&ctx, args);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.output, "Path is a directory") != null);
}

test "write: 坏输入被 spec 拦下" {
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/" };
    const res = try execute(&ctx, "{\"file_path\":\"/x\"}");
    defer testing.allocator.free(res.output);
    try testing.expect(res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.output, "Invalid input") != null);
}
