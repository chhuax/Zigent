//! `tools/diff.zig` —— Write / Edit 的 unified diff 预览（纯逻辑，零 IO）。
//!
//! 只做**行级 LCS**：文件级写入的预览足够，且实现可完全离线测试。
//! 大输入有明确的降级路径（`MAX_CELLS`），绝不因为「展示用 diff」把内存吃爆。

const std = @import("std");
const Allocator = std.mem.Allocator;

/// 少于这个格子数才跑完整 LCS；超出走「整文件替换」降级。
pub const MAX_CELLS: usize = 1_000_000;
/// 单侧最大行数。
pub const MAX_LINES: usize = 4000;
/// 缺省上下文行数。
pub const DEFAULT_CONTEXT: usize = 3;

pub const Stats = struct {
    added: usize = 0,
    removed: usize = 0,
};

pub const Result = struct {
    text: []u8,
    stats: Stats,
};

const OpTag = enum { eq, del, ins };
const Op = struct { tag: OpTag, line: []const u8 };

fn collectLines(gpa: Allocator, text: []const u8) ![][]const u8 {
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

/// 生成 unified diff。`path` 只用于 `--- a/<path>` / `+++ b/<path>` 头部。
pub fn unified(
    gpa: Allocator,
    before: []const u8,
    after: []const u8,
    path: []const u8,
    context: usize,
) !Result {
    const before_lines = try collectLines(gpa, before);
    defer gpa.free(before_lines);
    const after_lines = try collectLines(gpa, after);
    defer gpa.free(after_lines);

    var ops = std.ArrayListUnmanaged(Op).empty;
    defer ops.deinit(gpa);
    var stats = Stats{};

    const n = before_lines.len;
    const m = after_lines.len;
    const use_lcs = n <= MAX_LINES and m <= MAX_LINES and (n + 1) * (m + 1) <= MAX_CELLS;
    if (use_lcs) {
        try lcsOps(gpa, before_lines, after_lines, &ops, &stats);
    } else {
        for (before_lines) |l| {
            try ops.append(gpa, .{ .tag = .del, .line = l });
            stats.removed += 1;
        }
        for (after_lines) |l| {
            try ops.append(gpa, .{ .tag = .ins, .line = l });
            stats.added += 1;
        }
    }

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(gpa);

    if (n == 0) {
        try out.appendSlice(gpa, "--- /dev/null\n");
    } else {
        try out.print(gpa, "--- a/{s}\n", .{path});
    }
    if (m == 0) {
        try out.appendSlice(gpa, "+++ /dev/null\n");
    } else {
        try out.print(gpa, "+++ b/{s}\n", .{path});
    }

    try writeHunks(gpa, &out, ops.items, context);

    return .{ .text = try out.toOwnedSlice(gpa), .stats = stats };
}

fn lcsOps(
    gpa: Allocator,
    a: [][]const u8,
    b: [][]const u8,
    ops: *std.ArrayListUnmanaged(Op),
    stats: *Stats,
) !void {
    const n = a.len;
    const m = b.len;
    const width = m + 1;
    const table = try gpa.alloc(u32, (n + 1) * width);
    defer gpa.free(table);
    @memset(table, 0);

    // prefix-LCS：table[i][j] = LCS(a[0..i], b[0..j])，因此必须 i/j 都**升序**填。
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        var j: usize = 1;
        while (j <= m) : (j += 1) {
            const idx = i * width + j;
            table[idx] = if (std.mem.eql(u8, a[i - 1], b[j - 1]))
                table[(i - 1) * width + (j - 1)] + 1
            else
                @max(table[(i - 1) * width + j], table[i * width + (j - 1)]);
        }
    }

    // 反向回溯（从 (n,m) 起）—— 这是 LCS 的最小编辑脚本重建，
    // 正向贪心在并列时会多吐 del/ins 对（已实测）。
    var rev = std.ArrayListUnmanaged(Op).empty;
    defer rev.deinit(gpa);
    var x: usize = n;
    var y: usize = m;
    while (x > 0 and y > 0) {
        if (std.mem.eql(u8, a[x - 1], b[y - 1])) {
            try rev.append(gpa, .{ .tag = .eq, .line = a[x - 1] });
            x -= 1;
            y -= 1;
        } else if (table[(x - 1) * width + y] >= table[x * width + (y - 1)]) {
            try rev.append(gpa, .{ .tag = .del, .line = a[x - 1] });
            x -= 1;
        } else {
            try rev.append(gpa, .{ .tag = .ins, .line = b[y - 1] });
            y -= 1;
        }
    }
    while (x > 0) : (x -= 1) try rev.append(gpa, .{ .tag = .del, .line = a[x - 1] });
    while (y > 0) : (y -= 1) try rev.append(gpa, .{ .tag = .ins, .line = b[y - 1] });

    var k: usize = rev.items.len;
    while (k > 0) {
        k -= 1;
        const op = rev.items[k];
        switch (op.tag) {
            .ins => stats.added += 1,
            .del => stats.removed += 1,
            .eq => {},
        }
        try ops.append(gpa, op);
    }
}

fn writeHunks(
    gpa: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    ops: []const Op,
    context: usize,
) !void {
    if (ops.len == 0) return;

    // 找出所有变更的下标
    var changes = std.ArrayListUnmanaged(usize).empty;
    defer changes.deinit(gpa);
    for (ops, 0..) |op, idx| {
        if (op.tag != .eq) try changes.append(gpa, idx);
    }
    if (changes.items.len == 0) {
        try out.appendSlice(gpa, "@@ no changes @@\n");
        return;
    }

    // 以变更点为中心扩上下文并合并重叠窗口
    var start = changes.items[0] -| context;
    var end = @min(changes.items[0] + context + 1, ops.len);

    var ci: usize = 1;
    var hunk_open = false;
    while (true) {
        var next_start: ?usize = null;
        var next_end: usize = 0;
        if (ci < changes.items.len) {
            next_start = changes.items[ci] -| context;
            next_end = @min(changes.items[ci] + context + 1, ops.len);
        }
        if (next_start != null and next_start.? <= end) {
            end = @max(end, next_end);
            ci += 1;
            continue;
        }
        try emitHunk(gpa, out, ops, start, end, &hunk_open);
        if (next_start == null) break;
        start = next_start.?;
        end = next_end;
        ci += 1;
    }
}

fn emitHunk(
    gpa: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    ops: []const Op,
    start: usize,
    end: usize,
    hunk_open: *bool,
) !void {
    var a_start: usize = 1;
    var b_start: usize = 1;
    for (ops[0..start]) |op| {
        switch (op.tag) {
            .eq => {
                a_start += 1;
                b_start += 1;
            },
            .del => a_start += 1,
            .ins => b_start += 1,
        }
    }
    var a_len: usize = 0;
    var b_len: usize = 0;
    for (ops[start..end]) |op| {
        switch (op.tag) {
            .eq => {
                a_len += 1;
                b_len += 1;
            },
            .del => a_len += 1,
            .ins => b_len += 1,
        }
    }
    // 标准 diff：长度 0 时显示起点为 0
    if (a_len == 0) a_start = 0;
    if (b_len == 0) b_start = 0;
    try out.print(gpa, "@@ -{d},{d} +{d},{d} @@\n", .{ a_start, a_len, b_start, b_len });
    for (ops[start..end]) |op| {
        const marker: []const u8 = switch (op.tag) {
            .eq => " ",
            .del => "-",
            .ins => "+",
        };
        try out.appendSlice(gpa, marker);
        try out.appendSlice(gpa, op.line);
        try out.append(gpa, '\n');
    }
    hunk_open.* = true;
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "diff: 单行替换产生 -/+ 两行与统计" {
    const r = try unified(testing.allocator, "a\nb\nc\n", "a\nB\nc\n", "/x/f.txt", DEFAULT_CONTEXT);
    defer testing.allocator.free(r.text);
    try testing.expect(std.mem.indexOf(u8, r.text, "-b\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "+B\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "--- a//x/f.txt") != null);
    try testing.expectEqual(@as(usize, 1), r.stats.added);
    try testing.expectEqual(@as(usize, 1), r.stats.removed);
}

test "diff: 新文件用 /dev/null 作为 before" {
    const r = try unified(testing.allocator, "", "one\ntwo\n", "/x/new.txt", DEFAULT_CONTEXT);
    defer testing.allocator.free(r.text);
    try testing.expect(std.mem.indexOf(u8, r.text, "--- /dev/null") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "+one\n") != null);
    try testing.expectEqual(@as(usize, 2), r.stats.added);
    try testing.expectEqual(@as(usize, 0), r.stats.removed);
}

test "diff: 删除到空文件用 /dev/null 作为 after" {
    const r = try unified(testing.allocator, "one\n", "", "/x/gone.txt", DEFAULT_CONTEXT);
    defer testing.allocator.free(r.text);
    try testing.expect(std.mem.indexOf(u8, r.text, "+++ /dev/null") != null);
    try testing.expectEqual(@as(usize, 1), r.stats.removed);
}

test "diff: 相同内容不产生变更窗口" {
    const r = try unified(testing.allocator, "a\nb\n", "a\nb\n", "/x/same.txt", DEFAULT_CONTEXT);
    defer testing.allocator.free(r.text);
    try testing.expect(std.mem.indexOf(u8, r.text, "@@ no changes @@") != null);
    try testing.expectEqual(@as(usize, 0), r.stats.added + r.stats.removed);
}

test "diff: 两处远隔变更产生两个 hunk 且带上下文" {
    const before = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n";
    const after = "1\nX\n3\n4\n5\n6\n7\n8\n9\n10\nY\n12\n";
    const r = try unified(testing.allocator, before, after, "/x/h.txt", 1);
    defer testing.allocator.free(r.text);
    try testing.expect(std.mem.count(u8, r.text, "@@ -") == 2);
    try testing.expect(std.mem.indexOf(u8, r.text, "+X\n") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "+Y\n") != null);
}

test "diff: 行尾 CRLF 与无尾换行都被当作普通行内容" {
    const r = try unified(testing.allocator, "a\r\n", "a\r\nb", "/x/crlf.txt", DEFAULT_CONTEXT);
    defer testing.allocator.free(r.text);
    try testing.expectEqual(@as(usize, 1), r.stats.added);
    try testing.expect(std.mem.indexOf(u8, r.text, "+b\n") != null);
}
