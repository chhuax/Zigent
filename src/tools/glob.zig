//! `tools/glob.zig` —— `Glob`（别名 `glob`，文档 05 §4.5）。
//!
//! - 结果**按修改时间倒序**（G4）；
//! - 条数上限 `MAX_RESULTS = 1000`，结果字符上限 `65 536`（G1）；
//! - `path` 可选，缺省 `ctx.cwd`；
//! - 每个条目都查 `ctx.isCancelled()`，取消返回 `Glob was cancelled by user interrupt.`（G7）。

const std = @import("std");
const common = @import("common");
const json = common.json;
const specs = @import("specs.zig");
const sys = @import("sys.zig");
const truncate = @import("truncate.zig");

pub const spec = specs.glob_spec;

pub const definition = common.Tool{
    .name = "Glob",
    .aliases = &.{"glob"},
    .description = "Find files by glob pattern, sorted by modification time",
    .spec = spec,
    .is_read_only = alwaysTrue,
    .is_destructive = alwaysFalse,
    .is_concurrency_safe = alwaysTrue,
    .max_result_chars = specs.GLOB_MAX_RESULT_CHARS,
    .execute = execute,
};

fn alwaysTrue(_: []const u8) bool {
    return true;
}
fn alwaysFalse(_: []const u8) bool {
    return false;
}

pub const MSG_CANCELLED = "Glob was cancelled by user interrupt.";

const Entry = struct { path: []const u8, mtime: i64 };

fn lessByMtime(_: void, a: Entry, b: Entry) bool {
    if (a.mtime != b.mtime) return a.mtime > b.mtime; // 新的在前
    return std.mem.lessThan(u8, a.path, b.path); // 同 mtime 时稳定可复现
}

fn relativeTo(root: []const u8, path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, root)) {
        var rel = path[root.len..];
        if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
        return rel;
    }
    return path;
}

/// 含 `/` 的模式对**相对路径**匹配；裸模式对**basename**匹配（任意深度都找得到）。
pub fn patternMatches(pattern: []const u8, rel: []const u8, basename: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '/') != null) return sys.globMatch(pattern, rel);
    return sys.globMatch(pattern, basename);
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

    const pattern = v.getString("pattern") orelse return common.ToolResult.err("missing required field 'pattern'");
    const raw_root = v.getString("path") orelse ctx.cwd;

    const root = sys.resolve(ctx.gpa, ctx.cwd, raw_root) catch |e|
        return errFmt(ctx.gpa, "Cannot resolve path '{s}': {s}", .{ raw_root, @errorName(e) });
    defer ctx.gpa.free(root);

    if (!sys.isDir(ctx.io, root)) return errFmt(ctx.gpa, "Path is not a directory: {s}", .{root});
    if (ctx.isCancelled()) return common.ToolResult.err(MSG_CANCELLED);

    const files = sys.collectFiles(ctx.io, ctx.gpa, root, .{}) catch |e|
        return errFmt(ctx.gpa, "Cannot search '{s}': {s}", .{ root, @errorName(e) });
    defer sys.freePaths(ctx.gpa, files);

    var entries = std.ArrayListUnmanaged(Entry).empty;
    defer entries.deinit(ctx.gpa);
    for (files) |f| {
        if (ctx.isCancelled()) return common.ToolResult.err(MSG_CANCELLED);
        const rel = relativeTo(root, f);
        if (!patternMatches(pattern, rel, std.fs.path.basename(f))) continue;
        try entries.append(ctx.gpa, .{ .path = f, .mtime = sys.mtimeMs(ctx.io, f) });
    }

    std.mem.sort(Entry, entries.items, {}, lessByMtime);

    const shown = @min(entries.items.len, specs.GLOB_MAX_RESULTS);
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(ctx.gpa);
    for (entries.items[0..shown]) |e| {
        try out.appendSlice(ctx.gpa, e.path);
        try out.append(ctx.gpa, '\n');
    }
    if (entries.items.len > shown) {
        try out.print(
            ctx.gpa,
            "... [truncated: {d} files shown, more matches exist; narrow your pattern or set a subdirectory path]\n",
            .{shown},
        );
    }

    var res = common.ToolResult.ok(try out.toOwnedSlice(ctx.gpa));
    try res.metadata.put(ctx.gpa, "matchCount", .{ .integer = @intCast(entries.items.len) });
    try res.metadata.put(ctx.gpa, "truncated", .{ .boolean = entries.items.len > shown });
    return truncate.finish(ctx.gpa, ctx, res, definition.max_result_chars);
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

fn sleepMs(io: std.Io, ms: u64) void {
    std.Io.sleep(io, .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms }, .awake) catch {};
}

test "glob: patternMatches 裸模式匹配任意深度、含斜杠匹配相对路径" {
    try testing.expect(patternMatches("*.zig", "sub/a.zig", "a.zig"));
    try testing.expect(!patternMatches("*.zig", "sub/a.txt", "a.txt"));
    try testing.expect(patternMatches("sub/*.txt", "sub/a.txt", "a.txt"));
    try testing.expect(!patternMatches("other/*.txt", "sub/a.txt", "a.txt"));
}

test "glob: 在临时树里找 *.zig 与 **/*.txt" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try sys.makeTestDir(io, testing.allocator, "glob");
    defer testing.allocator.free(dir);
    defer sys.removeTree(io, dir) catch {};

    try touch(io, dir, "a.zig", "x");
    try touch(io, dir, "b.txt", "x");
    try touch(io, dir, "sub/c.zig", "x");
    try touch(io, dir, "sub/d.txt", "x");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = dir };

    const zig = try execute(&ctx, "{\"pattern\":\"*.zig\"}");
    try testing.expect(!zig.is_error);
    try testing.expectEqual(@as(i64, 2), zig.metadata.get("matchCount").?.asInt().?);
    try testing.expect(std.mem.indexOf(u8, zig.output, "a.zig") != null);
    try testing.expect(std.mem.indexOf(u8, zig.output, "sub/c.zig") != null);

    const txt = try execute(&ctx, "{\"pattern\":\"**/*.txt\"}");
    try testing.expectEqual(@as(i64, 2), txt.metadata.get("matchCount").?.asInt().?);
    try testing.expect(std.mem.indexOf(u8, txt.output, "b.txt") != null);
    try testing.expect(std.mem.indexOf(u8, txt.output, "sub/d.txt") != null);

    const none = try execute(&ctx, "{\"pattern\":\"*.md\"}");
    try testing.expect(!none.is_error);
    try testing.expectEqual(@as(usize, 0), none.output.len);
}

test "glob: 结果按修改时间倒序" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try sys.makeTestDir(io, testing.allocator, "glob");
    defer testing.allocator.free(dir);
    defer sys.removeTree(io, dir) catch {};

    try touch(io, dir, "old.zig", "x");
    sleepMs(io, 30);
    try touch(io, dir, "new.zig", "x");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = dir };

    const res = try execute(&ctx, "{\"pattern\":\"*.zig\"}");
    const first_nl = std.mem.indexOfScalar(u8, res.output, '\n').?;
    try testing.expect(std.mem.endsWith(u8, res.output[0..first_nl], "new.zig"));
}

test "glob: 显式 path 参数与非法 path" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try sys.makeTestDir(io, testing.allocator, "glob");
    defer testing.allocator.free(dir);
    defer sys.removeTree(io, dir) catch {};
    try touch(io, dir, "sub/e.zig", "x");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = "/nonexistent-cwd" };

    const args = try std.fmt.allocPrint(arena.allocator(), "{{\"pattern\":\"*.zig\",\"path\":\"{s}/sub\"}}", .{dir});
    const res = try execute(&ctx, args);
    try testing.expect(!res.is_error);
    try testing.expectEqual(@as(i64, 1), res.metadata.get("matchCount").?.asInt().?);

    const bad = try execute(&ctx, "{\"pattern\":\"*.zig\",\"path\":\"/definitely/not/here\"}");
    try testing.expect(bad.is_error);
    try testing.expect(std.mem.indexOf(u8, bad.output, "not a directory") != null);
}

test "glob: 取消令牌 → 取消文案" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try sys.makeTestDir(io, testing.allocator, "glob");
    defer testing.allocator.free(dir);
    defer sys.removeTree(io, dir) catch {};

    var flag = std.atomic.Value(bool).init(true);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = dir, .cancelled = &flag };

    const res = try execute(&ctx, "{\"pattern\":\"*\"}");
    try testing.expect(res.is_error);
    try testing.expectEqualStrings(MSG_CANCELLED, res.output);
}
