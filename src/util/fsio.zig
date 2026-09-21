//! `util/fsio.zig` —— 路径与文件系统原语的**唯一出口**。
//!
//! 集中在这里的原因（文档 03 §4.3）：换平台/改布局只改一处；
//! 且**符号链接逃逸的判定口径**必须统一。
//!
//! 越界判定有两个函数，**用途不同，不要混**：
//!   - `resolveWithin` —— 纯词法，不碰磁盘。只作快速预筛，**不是安全边界**。
//!   - `resolveWithinReal` —— 词法 + realpath 复核，**这才是权限层的判据**。
//!     凡是要据此打开文件的地方，走这个。

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

/// 归一化 + 越界判定（**纯词法，不解析符号链接**）。
///
/// ⚠️ **这个函数不能单独当安全边界用。** 它只看路径字符串：工作区里一个指向
/// `/etc/passwd` 或 `~/.ssh` 的符号链接，字符串上完全在 base 之内，这里会放行。
/// 它的正当用途是**快速预筛**（拒掉明显的 `../` 逃逸，且不需要碰磁盘），
/// 以及处理**尚不存在的路径**。
///
/// 真正的权限判据是 `resolveWithinReal` —— 凡是要据此**打开文件**的地方，
/// 必须走那个。
pub fn resolveWithin(gpa: Allocator, base: []const u8, path: []const u8) Allocator.Error!?[]u8 {
    const abs = try resolve(gpa, base, path);
    defer gpa.free(abs);
    const nbase = try normalize(gpa, base);
    defer gpa.free(nbase);
    if (!isWithin(nbase, abs)) return null;
    return try gpa.dupe(u8, abs);
}

/// 越界判定的**权威版本**：词法预筛 + `realpath` 复核，能挡住符号链接逃逸。
///
/// 返回 `null` 表示越界（调用方应当拒绝该操作）；否则返回**词法归一化后**的
/// 绝对路径（调用方拥有，负责 free）。
///
/// 为什么返回词法路径而不是 realpath 结果：调用方拿它去 open / 展示 / 存 transcript，
/// 用户输入什么就该看到什么；realpath 只用于**判定**，不替换结果。
///
/// **算法**（关键在于目标文件可能还不存在，例如写新文件）：
///   1. 先跑词法判定，拒掉 `../` 这类；
///   2. `realpath(base)` 拿到基准的真实路径；
///   3. 从候选路径开始，逐级向上找到**最深的已存在祖先**，对它做 realpath。
///      已存在的部分是符号链接能藏身的唯一地方 —— 不存在的尾巴不可能是链接。
///   4. 把 realpath 过的祖先与剩余尾巴拼回去，再做一次前缀判定。
///
/// 📌 **不要改用 `OpenFileOptions.resolve_beneath` 来代替本函数。** 那个选项看着
/// 能一步到位，但 `Io.Threaded` 的实现是 `if (@hasField(posix.O, "RESOLVE_BENEATH"))`
/// —— 那是 FreeBSD 的 `O` flag，**macOS 上该字段不存在，选项被静默忽略且不报错**，
/// 会得到一个在 Linux/FreeBSD 上有效、在 macOS 上完全失效的假防护。
pub fn resolveWithinReal(
    io: Io,
    gpa: Allocator,
    base: []const u8,
    path: []const u8,
) !?[]u8 {
    // 第 1 步：词法预筛。越界直接拒，省掉后面的磁盘访问。
    const lexical = (try resolveWithin(gpa, base, path)) orelse return null;
    errdefer gpa.free(lexical);

    // 第 2 步：base 自身的真实路径。base 不存在就没什么可守的，直接拒。
    const real_base = std.Io.Dir.realPathFileAbsoluteAlloc(io, base, gpa) catch return null;
    defer gpa.free(real_base);

    // 第 3 步：从完整路径开始，逐级向上剥，找到第一个能 realpath 成功的祖先。
    // `probe_len` 是当前探测前缀的长度。
    var probe_len = lexical.len;
    const real_prefix = while (probe_len > 0) {
        if (std.Io.Dir.realPathFileAbsoluteAlloc(io, lexical[0..probe_len], gpa)) |rp| {
            break rp;
        } else |_| {
            // 往上剥一级；剥到没有分隔符就说明连 base 都没命中，判越界。
            probe_len = std.mem.lastIndexOfScalar(u8, lexical[0..probe_len], '/') orelse return null;
        }
    } else return null;
    defer gpa.free(real_prefix);

    // 第 4 步：真实祖先必须在真实 base 之内；
    // 尾巴是尚不存在的部分，词法上已经确认不含 `..`，拼回去判定即可。
    const nreal_base = try normalize(gpa, real_base);
    defer gpa.free(nreal_base);
    const nreal_prefix = try normalize(gpa, real_prefix);
    defer gpa.free(nreal_prefix);

    if (!isWithin(nreal_base, nreal_prefix)) {
        gpa.free(lexical);
        return null;
    }
    return lexical;
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

/// `collectFiles` 的结果。
///
/// 为什么不直接返回 `[][]u8`：遍历可能在 `max_entries` 处**提前停止**，
/// 而调用方（尤其是 watcher）必须能区分"目录里就这么多文件"和"我只看到了一部分"。
/// 见 `truncated` 字段的说明。
pub const Walk = struct {
    /// 绝对路径列表。调用方拥有，用 `freePaths` 释放。
    paths: [][]u8,
    /// 是否因为撞到 `max_entries` 而**提前停止**（结果不完整）。
    ///
    /// ⚠️ **调用方必须处理这个标志**。`Io.Dir.walk` 的返回顺序不保证稳定，
    /// 所以两次遍历被截断掉的**不是同一批文件**。对 watcher 来说，
    /// 如果把不完整的结果当成完整快照去 diff，那些时有时无的文件会在
    /// 相邻两轮里反复进出，稳定地喷出成片虚假的 created / deleted 事件。
    truncated: bool,
};

/// 收集 `root` 下的全部**普通文件绝对路径**（POSIX 分隔符）。
///
/// 结果可能不完整 —— 必须检查返回值的 `truncated`，不要只取 `paths`。
pub fn collectFiles(
    io: Io,
    gpa: Allocator,
    root: []const u8,
    opts: WalkOptions,
) !Walk {
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir, error.FileNotFound => return .{ .paths = &.{}, .truncated = false },
        else => return err,
    };
    defer dir.close(io);

    var walker = try std.Io.Dir.walk(dir, gpa);
    defer walker.deinit();

    // `.empty` 是 0.16 的写法（不是 `.{}`）。Unmanaged 容器自己不存 allocator，
    // 所以后面每次 append / deinit 都要**再把同一个 gpa 传进去**。
    var out = std.ArrayListUnmanaged([]u8).empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    var truncated = false;

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
        if (out.items.len >= opts.max_entries) {
            truncated = true;
            break;
        }
        // 先接住 join 的结果再 append：写成 `try out.append(gpa, try join(...))`
        // 的话，append 失败时那块刚 join 出来的内存就没人释放了。
        const joined = try std.fs.path.join(gpa, &.{ root, entry.path });
        out.append(gpa, joined) catch |err| {
            gpa.free(joined);
            return err;
        };
    }
    return .{ .paths = try out.toOwnedSlice(gpa), .truncated = truncated };
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

test "fsio: resolveWithinReal 挡住符号链接逃逸（词法版挡不住）" {
    // 这是整个权限层最关键的一条回归测试。
    // 构造：<tmp>/ws/escape -> /etc（一个指向工作区外的符号链接）
    // 期望：词法版 resolveWithin 放行（证明它不足以当安全边界），
    //       resolveWithinReal 拒绝（证明修复生效）。
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rnd = try io_mod.randomHex(io, testing.allocator, 6);
    defer testing.allocator.free(rnd);
    const root = try std.fmt.allocPrint(testing.allocator, "/tmp/zigent-sym-{s}", .{rnd});
    defer testing.allocator.free(root);
    defer io_mod.removeTree(io, root) catch {};

    const ws = try std.fmt.allocPrint(testing.allocator, "{s}/ws", .{root});
    defer testing.allocator.free(ws);
    try io_mod.mkdirp(io, ws);

    const link = try std.fmt.allocPrint(testing.allocator, "{s}/escape", .{ws});
    defer testing.allocator.free(link);
    try std.Io.Dir.symLinkAbsolute(io, "/etc", link, .{});

    // 词法版：路径字符串完全在 ws 之内 —— 放行。这正是它不能单独用的原因。
    const lex = try resolveWithin(testing.allocator, ws, "escape/passwd");
    defer if (lex) |v| testing.allocator.free(v);
    try testing.expect(lex != null);

    // 权威版：realpath 复核后发现落在 /etc，拒绝。
    const real = try resolveWithinReal(io, testing.allocator, ws, "escape/passwd");
    defer if (real) |v| testing.allocator.free(v);
    try testing.expect(real == null);
}

test "fsio: resolveWithinReal 放行工作区内尚不存在的新文件" {
    // 写新文件是正常操作，不能因为 realpath 找不到目标就误判越界。
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rnd = try io_mod.randomHex(io, testing.allocator, 6);
    defer testing.allocator.free(rnd);
    const ws = try std.fmt.allocPrint(testing.allocator, "/tmp/zigent-new-{s}", .{rnd});
    defer testing.allocator.free(ws);
    defer io_mod.removeTree(io, ws) catch {};
    try io_mod.mkdirp(io, ws);

    const p = try resolveWithinReal(io, testing.allocator, ws, "sub/dir/not-yet.txt");
    defer if (p) |v| testing.allocator.free(v);
    try testing.expect(p != null);
}

test "fsio: resolveWithinReal 在 macOS 的 /tmp 上不误判" {
    // 雷区：macOS 的 /tmp 是指向 /private/tmp 的符号链接。
    // 只要 base 和候选路径**两边都做 realpath**，就不会把正常路径判成越界；
    // 只对一边做就会。这个测试锁住"两边都做"这个写法。
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rnd = try io_mod.randomHex(io, testing.allocator, 6);
    defer testing.allocator.free(rnd);
    const ws = try std.fmt.allocPrint(testing.allocator, "/tmp/zigent-tmpsym-{s}", .{rnd});
    defer testing.allocator.free(ws);
    defer io_mod.removeTree(io, ws) catch {};
    try io_mod.mkdirp(io, ws);

    const f = try std.fmt.allocPrint(testing.allocator, "{s}/a.txt", .{ws});
    defer testing.allocator.free(f);
    try io_mod.writeFile(io, f, "x");

    const p = try resolveWithinReal(io, testing.allocator, ws, "a.txt");
    defer if (p) |v| testing.allocator.free(v);
    try testing.expect(p != null);
}
