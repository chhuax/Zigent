//! `tools/read.zig` —— `Read`（别名 `read_file`，文档 05 §4.1）。
//!
//! 输出形态**逐字节冻结**：`%6d\t%s`，行号从 **1** 开始（`read.md` 与 `edit.md`
//! 两份 prompt 文案共同依赖它，改动会同时打破两处语义）。
//!
//! 输入只被**读**，绝不 parse→re-serialize（不变量 I1）。

const std = @import("std");
const common = @import("common");
const json = common.json;
const specs = @import("specs.zig");
const sys = @import("sys.zig");
const truncate = @import("truncate.zig");

pub const spec = specs.read_spec;

pub const definition = common.Tool{
    .name = "Read",
    .aliases = &.{"read_file"},
    .description = "Read file contents with optional line range",
    .spec = spec,
    .is_read_only = readOnly,
    .is_destructive = neverDestructive,
    .is_concurrency_safe = alwaysConcurrencySafe,
    .max_result_chars = common.ToolResult.MAX_TOOL_RESULT_CHARS,
    .execute = execute,
};

fn readOnly(_: []const u8) bool {
    return true;
}
fn neverDestructive(_: []const u8) bool {
    return false;
}
fn alwaysConcurrencySafe(_: []const u8) bool {
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
    // 归一化语义：超范围值**钳制**而不是报错（与契约行为对等）。
    const offset: usize = if (v.getInt("offset")) |o| @intCast(@max(0, o)) else 0;
    const limit: usize = if (v.getInt("limit")) |l| @intCast(@max(1, l)) else specs.READ_DEFAULT_LIMIT;

    const path = sys.resolve(ctx.gpa, ctx.cwd, raw_path) catch |e|
        return errFmt(ctx.gpa, "Cannot resolve path '{s}': {s}", .{ raw_path, @errorName(e) });
    defer ctx.gpa.free(path);

    if (sys.isDir(ctx.io, path)) return errFmt(ctx.gpa, "Path is a directory: {s}", .{path});

    const content = sys.readFileAlloc(ctx.io, ctx.gpa, path, specs.READ_MAX_BYTES) catch |e| switch (e) {
        error.FileNotFound => return errFmt(ctx.gpa, "File not found: {s}", .{path}),
        error.FileTooBig => return errFmt(ctx.gpa, "File is too large to read at once (> {d} bytes): {s}", .{ specs.READ_MAX_BYTES, path }),
        error.AccessDenied => return errFmt(ctx.gpa, "Permission denied: {s}", .{path}),
        else => return errFmt(ctx.gpa, "Cannot read file {s}: {s}", .{ path, @errorName(e) }),
    };
    defer ctx.gpa.free(content);

    if (isBinary(content)) return errFmt(ctx.gpa, "Cannot read binary file: {s}", .{path});

    const out = try numberLines(ctx.gpa, content, offset, limit);
    var res = common.ToolResult.ok(out);
    res = try truncate.finish(ctx.gpa, ctx, res, definition.max_result_chars);
    return res;
}

/// NUL 出现在前 8 KiB → 视为二进制（文档 05 §4.1 R5）。
pub fn isBinary(content: []const u8) bool {
    const n = @min(content.len, 8000);
    for (content[0..n]) |c| {
        if (c == 0) return true;
    }
    return false;
}

pub fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var n: usize = 1;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    if (text[text.len - 1] == '\n') n -= 1;
    return n;
}

/// `cat -n` 风格：`%6d\t%s`，行号从 1 开始。
pub fn numberLines(gpa: std.mem.Allocator, content: []const u8, offset: usize, limit: usize) ![]u8 {
    const total = countLines(content);
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(gpa);

    var start: usize = 0;
    var idx: usize = 0;
    while (start < content.len) : (idx += 1) {
        const nl = std.mem.indexOfScalarPos(u8, content, start, '\n') orelse content.len;
        if (idx >= offset and idx - offset < limit) {
            try out.print(gpa, "{d:>6}\t{s}\n", .{ idx + 1, content[start..nl] });
        }
        start = nl + 1;
    }

    if (total > 0 and offset >= total) {
        try out.print(gpa, "... [offset {d} is beyond end of file ({d} lines)]\n", .{ offset, total });
    } else if (offset + limit < total) {
        try out.print(gpa, "... [truncated: showing lines {d}-{d} of {d}; use offset/limit to read more]\n", .{
            offset + 1,
            offset + limit,
            total,
        });
    }
    return out.toOwnedSlice(gpa);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn writeFixture(io: std.Io, dir: []const u8, name: []const u8, bytes: []const u8) ![]u8 {
    const path = try std.fs.path.join(testing.allocator, &.{ dir, name });
    try sys.writeFile(io, path, bytes);
    return path;
}

test "read: 行号格式 %6d\\t 且从 1 开始" {
    const out = try numberLines(testing.allocator, "alpha\nbeta\n", 0, 100);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("     1\talpha\n     2\tbeta\n", out);
}

test "read: offset/limit 截取与截断说明" {
    const content = "a\nb\nc\nd\ne\n";
    const head = try numberLines(testing.allocator, content, 0, 2);
    defer testing.allocator.free(head);
    try testing.expect(std.mem.indexOf(u8, head, "     1\ta\n") != null);
    try testing.expect(std.mem.indexOf(u8, head, "     3\tc") == null);
    try testing.expect(std.mem.indexOf(u8, head, "[truncated: showing lines 1-2 of 5") != null);

    const mid = try numberLines(testing.allocator, content, 2, 2);
    defer testing.allocator.free(mid);
    try testing.expect(std.mem.indexOf(u8, mid, "     3\tc\n") != null);
    try testing.expect(std.mem.indexOf(u8, mid, "     4\td\n") != null);
    try testing.expect(std.mem.indexOf(u8, mid, "     5\te") == null);
}

test "read: 空文件输出空、offset 越界给出提示" {
    const empty = try numberLines(testing.allocator, "", 0, 10);
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);

    const beyond = try numberLines(testing.allocator, "a\nb\n", 5, 10);
    defer testing.allocator.free(beyond);
    try testing.expect(std.mem.indexOf(u8, beyond, "beyond end of file (2 lines)") != null);
}

test "read: 二进制判定（NUL 在前 8KiB）" {
    try testing.expect(isBinary("ab\x00cd"));
    try testing.expect(!isBinary("ab c d"));
    var big = try testing.allocator.alloc(u8, 9000);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    big[8500] = 0; // 8KiB 之外 → 不算二进制
    try testing.expect(!isBinary(big));
}

test "read: 端到端读文件 / 缺失文件 / 目录都是 is_error" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = try sys.makeTestDir(io, testing.allocator, "read");
    defer testing.allocator.free(dir);
    defer sys.removeTree(io, dir) catch {};

    const path = try writeFixture(io, dir, "a.txt", "alpha\nbeta\ngamma\n");
    defer testing.allocator.free(path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = common.ToolContext{ .gpa = arena.allocator(), .io = io, .cwd = dir };

    const args = try std.fmt.allocPrint(arena.allocator(), "{{\"file_path\":\"{s}\",\"limit\":2}}", .{path});
    const res = try execute(&ctx, args);
    try testing.expect(!res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.output, "     1\talpha") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "     3\tgamma") == null);

    const missing_args = try std.fmt.allocPrint(arena.allocator(), "{{\"file_path\":\"{s}/nope.txt\"}}", .{dir});
    const missing = try execute(&ctx, missing_args);
    try testing.expect(missing.is_error);
    try testing.expect(std.mem.indexOf(u8, missing.output, "File not found") != null);

    const dir_args = try std.fmt.allocPrint(arena.allocator(), "{{\"file_path\":\"{s}\"}}", .{dir});
    const dir_res = try execute(&ctx, dir_args);
    try testing.expect(dir_res.is_error);
    try testing.expect(std.mem.indexOf(u8, dir_res.output, "Path is a directory") != null);

    // 坏输入：spec.validate 必须拦下
    const bad = try execute(&ctx, "{\"file_path\":1}");
    try testing.expect(bad.is_error);
    try testing.expect(std.mem.indexOf(u8, bad.output, "Invalid input") != null);
}
