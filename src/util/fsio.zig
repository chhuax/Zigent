//! `util/fsio.zig` —— 路径与文件系统原语的**唯一出口**。
//!
//! 集中在这里的原因（文档 03 §4.3）：换平台/改布局只改一处；
//! 且**符号链接逃逸的判定口径**必须统一（朴素实现的 `PathValidator` 只做
//! `startsWith`、没做 realpath —— 本项目首期同样只做归一化 + 前缀判定，
//! 但把判定函数集中，将来补 realpath 只改这里）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const io_mod = @import("io.zig");

/// 把可能是相对路径的 `path` 解析成绝对路径（不做 realpath，只做词法归一化）。
pub fn resolve(gpa: Allocator, base: []const u8, path: []const u8) Allocator.Error![]u8 {
    if (std.fs.path.isAbsolute(path)) return normalize(gpa, path);
    const joined = try std.fs.path.join(gpa, &.{ base, path });
    defer gpa.free(joined);
    return normalize(gpa, joined);
}

/// 词法归一化：折叠 `.` / `..` / 重复分隔符。**不解析符号链接。**
pub fn normalize(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    const absolute = std.fs.path.isAbsolute(path);
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(gpa);

    var it = std.mem.tokenizeAny(u8, path, "/\\");
    var parts = std.ArrayListUnmanaged([]const u8).empty;
    defer parts.deinit(gpa);
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
            } else if (!absolute) {
                try parts.append(gpa, part);
            }
            continue;
        }
        try parts.append(gpa, part);
    }

    if (absolute) try out.append(gpa, '/');
    for (parts.items, 0..) |part, i| {
        if (i > 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, part);
    }
    if (out.items.len == 0) try out.append(gpa, '.');
    return out.toOwnedSlice(gpa);
}

/// `candidate` 是否在 `base` 之内（含相等）。**两侧都必须已归一化**。
pub fn isWithin(base: []const u8, candidate: []const u8) bool {
    if (std.mem.eql(u8, base, candidate)) return true;
    if (!std.mem.startsWith(u8, candidate, base)) return false;
    if (base.len == 0) return true;
    if (base[base.len - 1] == '/') return true;
    return candidate[base.len] == '/';
}

/// 归一化 + 越界判定（权限层的主要判据）。
pub fn resolveWithin(gpa: Allocator, base: []const u8, path: []const u8) Allocator.Error!?[]u8 {
    const abs = try resolve(gpa, base, path);
    defer gpa.free(abs);
    const nbase = try normalize(gpa, base);
    defer gpa.free(nbase);
    if (!isWithin(nbase, abs)) return null;
    return try gpa.dupe(u8, abs);
}

// ── glob ─────────────────────────────────────────────────────────────────────

/// glob 匹配：
///   - `*` 匹配任意字符但**不跨 `/`**；
///   - `**` 跨 `/`；
///   - `?` 匹配单个非 `/` 字符；
///   - `[...]` 字符集，`[!...]` 取反。
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    return globMatchAt(pattern, path, 0);
}

fn globMatchAt(pattern: []const u8, path: []const u8, depth: usize) bool {
    if (depth > 64) return false;
    var pi: usize = 0;
    var si: usize = 0;
    while (pi < pattern.len) {
        const c = pattern[pi];
        switch (c) {
            '*' => {
                const double = pi + 1 < pattern.len and pattern[pi + 1] == '*';
                const rest = if (double) pattern[pi + 2 ..] else pattern[pi + 1 ..];
                // `**/` 可以匹配零层目录
                if (double and rest.len > 0 and rest[0] == '/') {
                    if (globMatchAt(rest[1..], path[si..], depth + 1)) return true;
                }
                var k = si;
                while (k <= path.len) : (k += 1) {
                    if (!double and k > si and path[k - 1] == '/') break;
                    if (globMatchAt(rest, path[k..], depth + 1)) return true;
                    if (k == path.len) break;
                }
                return false;
            },
            '?' => {
                if (si >= path.len or path[si] == '/') return false;
                pi += 1;
                si += 1;
            },
            '[' => {
                if (si >= path.len) return false;
                var j = pi + 1;
                var negate = false;
                if (j < pattern.len and (pattern[j] == '!' or pattern[j] == '^')) {
                    negate = true;
                    j += 1;
                }
                var matched = false;
                var first = true;
                while (j < pattern.len and (pattern[j] != ']' or first)) : (j += 1) {
                    first = false;
                    if (j + 2 < pattern.len and pattern[j + 1] == '-' and pattern[j + 2] != ']') {
                        if (path[si] >= pattern[j] and path[si] <= pattern[j + 2]) matched = true;
                        j += 2;
                    } else if (pattern[j] == path[si]) {
                        matched = true;
                    }
                }
                if (j >= pattern.len) return false; // 未闭合 → 当字面量处理
                if (matched == negate) return false;
                pi = j + 1;
                si += 1;
            },
            else => {
                if (si >= path.len or path[si] != c) return false;
                pi += 1;
                si += 1;
            },
        }
    }
    return si == path.len;
}

// ── 目录遍历 ─────────────────────────────────────────────────────────────────

pub const WalkOptions = struct {
    /// 额外排除的目录名（默认加 `.git` 与 `node_modules`）
    exclude_dirs: []const []const u8 = &.{ ".git", "node_modules", "zig-cache", ".zig-cache", "zig-out" },
    max_entries: usize = 20_000,
    follow_symlinks: bool = false,
    max_depth: usize = 32,
};

/// 收集 `root` 下的全部**普通文件绝对路径**（POSIX 分隔符）。
pub fn collectFiles(
    io: Io,
    gpa: Allocator,
    root: []const u8,
    opts: WalkOptions,
) ![][]u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir, error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);

    var walker = try std.Io.Dir.walk(dir, gpa);
    defer walker.deinit();

    var out = std.ArrayListUnmanaged([]u8).empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            var skip = false;
            for (opts.exclude_dirs) |ex| {
                if (std.mem.eql(u8, entry.basename, ex)) skip = true;
            }
            if (skip or entry.depth() >= opts.max_depth) {
                walker.leave(io);
            }
            continue;
        }
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (entry.kind == .sym_link and !opts.follow_symlinks) continue;
        if (out.items.len >= opts.max_entries) break;
        try out.append(gpa, try std.fs.path.join(gpa, &.{ root, entry.path }));
    }
    return out.toOwnedSlice(gpa);
}

pub fn freePaths(gpa: Allocator, paths: [][]u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

/// 确保某个文件路径的父目录存在。
pub fn ensureParent(io: Io, path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    if (dir.len == 0) return;
    try io_mod.mkdirp(io, dir);
}

/// 读取文本文件；不存在返回 null（**不报错** —— 配置/记忆路径大量用这个语义）。
pub fn readIfExists(io: Io, gpa: Allocator, path: []const u8, max_bytes: usize) !?[]u8 {
    return io_mod.readFileAlloc(io, gpa, path, max_bytes) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "fsio: 归一化" {
    const a = try normalize(testing.allocator, "/a/b/../c/./d//");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/a/c/d", a);
    const b = try normalize(testing.allocator, "a/../../b");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("../b", b);
    const c = try normalize(testing.allocator, "/");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("/", c);
}

test "fsio: 越界判定" {
    try testing.expect(isWithin("/a/b", "/a/b/c"));
    try testing.expect(isWithin("/a/b", "/a/b"));
    try testing.expect(!isWithin("/a/b", "/a/bc"));
    try testing.expect(!isWithin("/a/b", "/a"));
    try testing.expect(!isWithin("/a/b", "/a/c"));
}

test "fsio: resolveWithin 拦住 ../ 逃逸" {
    const ok = try resolveWithin(testing.allocator, "/repo", "src/a.zig");
    defer if (ok) |p| testing.allocator.free(p);
    try testing.expectEqualStrings("/repo/src/a.zig", ok.?);

    const escape = try resolveWithin(testing.allocator, "/repo", "../etc/passwd");
    try testing.expect(escape == null);
}

test "fsio: glob 语义 —— * 不跨目录，** 跨目录" {
    try testing.expect(globMatch("*.zig", "a.zig"));
    try testing.expect(!globMatch("*.zig", "src/a.zig"));
    try testing.expect(globMatch("**/*.zig", "src/deep/a.zig"));
    try testing.expect(globMatch("**/*.zig", "a.zig"));
    try testing.expect(globMatch("src/**/*.zig", "src/a.zig"));
    try testing.expect(globMatch("a?c", "abc"));
    try testing.expect(!globMatch("a?c", "ac"));
    try testing.expect(globMatch("[abc]x", "bx"));
    try testing.expect(!globMatch("[!abc]x", "bx"));
    try testing.expect(globMatch("test_{a,b}.zig", "test_{a,b}.zig"));
}

test "fsio: macOS 的 /tmp 归一化不会误判越界" {
    // 若把 base 也 realpath 化，/tmp → /private/tmp 会把正常路径判成越界（雷区）。
    const p = try resolveWithin(testing.allocator, "/tmp", "/tmp/x/y");
    defer if (p) |v| testing.allocator.free(v);
    try testing.expect(p != null);
}
