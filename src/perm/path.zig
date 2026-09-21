//! `perm/path.zig` —— 路径越界守卫（词法口径，**首期不做 realpath**）。
//!
//! 设计依据：`docs/analysis/2026-09-19-07-权限与安全设计.md` §5.4 / §5.5 / §13.3。
//!
//! ## 为什么这里有一份 `normalize` / `isWithin`（而不是 import `util.fsio`）
//! `build.zig` 只给 `perm` 声明了 `common` 一个依赖（L2 能力模块彼此零依赖、且不碰
//! `util` 基座）。所以纯词法路径逻辑在本文件里自实现一份，语义与
//! `src/util/fsio.zig` 的 `normalize` / `isWithin` **逐字一致**（同一套契约断言），
//! 将来补 realpath 时两处一起改。
//!
//! ## ★ macOS `/tmp → /private/tmp` 的 caveat（最容易误判的一条）
//! `/tmp` 在 macOS 上是**符号链接**，指向 `/private/tmp`。本模块首期**不做 realpath**，
//! 因此 `base = /tmp/x`、`candidate = /tmp/x/y` 的前缀判定是纯字面的 —— 两者同源，
//! 恒为「在内」。若反过来把 `base` 也 realpath 成 `/private/tmp/x`，`/tmp/x/y`
//! 就会因为前缀不同被**误判成越界**（§5.4 明确列为「realpath 加固最容易搞坏的地方」）。
//! **纪律：base 绝不做 realpath；只有二期 `resolve_symlinks = true` 时才对
//! 「存在的祖先」做 realpath，并且那时 base 也必须一起 realpath 化。**
//!
//! 已知逃逸（首期照抄既有语义，避免与行为对等门禁 G6 混在一起归因，二期修）：
//!   * E1 `<cwd>/link -> /etc`，写 `link/passwd` → 字面前缀判定为「在内」；
//!   * E2 用户批准 `allowRoot=/home/u/escape`（`escape -> /`）→ 之后整个文件系统可写；
//!   * E4 TOCTOU：检查之后、打开之前被换成软链（需要 `O_NOFOLLOW`，二期）。

const std = @import("std");
const Allocator = std.mem.Allocator;

/// 首期只可能返回前三个（`SymlinkEscape` 是二期 `resolve_symlinks = true` 的出口，
/// **接口形状先留**，§12 差异清单 #13）。
pub const ResolveError = error{
    OutsideBase,
    UncPath,
    BlockedDevicePath,
    /// ★ 符号链接逃逸（既有实现无此错误；二期启用）。
    SymlinkEscape,
    OutOfMemory,
};

pub const Options = struct {
    /// 首期恒为 `false`（照抄既有语义：只做词法归一化）。
    /// 二期置 `true` 时按「最长存在祖先」realpath 后判前缀。
    resolve_symlinks: bool = false,
    /// 基准路径（cwd）。★ 若 `resolve_symlinks = true`，**base 也必须 realpath 化**，
    /// 否则 macOS 上 `/tmp` vs `/private/tmp` 会把所有正常路径判成越界。
    base: []const u8,
};

/// 词法归一化：折叠 `.` / `..` / 重复分隔符。**不解析符号链接**（与 `util.fsio` 同语义）。
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

/// `candidate` 是否在 `base` 之内（含相等）。**两侧都必须已归一化**；
/// 前缀后必须是 `/` 或串尾，否则 `/a/bc` 会被误判为在 `/a/b` 之内。
pub fn isWithin(base: []const u8, candidate: []const u8) bool {
    if (std.mem.eql(u8, base, candidate)) return true;
    if (!std.mem.startsWith(u8, candidate, base)) return false;
    if (base.len == 0) return true;
    if (base[base.len - 1] == '/') return true;
    return candidate[base.len] == '/';
}

/// 解析成绝对路径（词法，不 realpath）。
pub fn resolve(gpa: Allocator, base: []const u8, path: []const u8) Allocator.Error![]u8 {
    if (std.fs.path.isAbsolute(path)) return normalize(gpa, path);
    const joined = try std.fs.path.join(gpa, &.{ base, path });
    defer gpa.free(joined);
    return normalize(gpa, joined);
}

/// 路径越界守卫的主入口。
///
/// 步骤（§5.4 的加固算法，首期只走到第 3 步）：
///   1. 拒绝 UNC（`\\server\share` 归一化后以 `//` 开头）
///   2. 拒绝设备/特殊文件（`/dev/zero` 会把内存读爆；`/proc/<pid>/environ` 会泄漏 API key）
///   3. `lexical = normalize(base + input)`，`!resolve_symlinks` → 只做前缀判定
///   4. `resolve_symlinks = true` → 最长存在祖先 realpath（二期）
pub fn resolveAndValidate(
    gpa: Allocator,
    opts: Options,
    input_path: []const u8,
    allowed_roots: []const []const u8,
) ResolveError![]u8 {
    if (isUnc(input_path)) return error.UncPath;

    const nbase = try normalize(gpa, opts.base);
    defer gpa.free(nbase);
    const lexical = try resolve(gpa, nbase, input_path);
    defer gpa.free(lexical);

    if (isBlockedDevicePath(lexical)) return error.BlockedDevicePath;

    // ★ base 自身、以及配置里的授权根，都按**词法**比较（macOS /tmp caveat 见文件头）。
    if (!isWithin(nbase, lexical)) {
        var allowed = false;
        for (allowed_roots) |root| {
            const nroot = try normalize(gpa, root);
            defer gpa.free(nroot);
            if (isWithin(nroot, lexical)) {
                allowed = true;
                break;
            }
        }
        if (!allowed) return error.OutsideBase;
    }

    // 二期：readlink 最长存在祖先 → realpath 后重判（`resolve_symlinks`）。
    // 首期留形状，不实现；实现时必须同时 realpath 化 base（见 `Options.base` 注释）。
    if (opts.resolve_symlinks) return error.SymlinkEscape;

    return gpa.dupe(u8, lexical);
}

/// UNC 拒绝：归一化前把 `\` 当分隔符，若以 `//` 开头即视为 UNC。
/// （Windows 语义留形状：首期只 macOS/Linux，也保留这条判断与注释。）
pub fn isUnc(path: []const u8) bool {
    if (path.len < 2) return false;
    const a = if (path[0] == '\\') '/' else path[0];
    const b = if (path[1] == '\\') '/' else path[1];
    if (a != '/' or b != '/') return false;
    // 单独一个 `//` 或 `//x` 才是 UNC；POSIX 下 `///x` 也视为 UNC。
    return true;
}

/// Windows 盘符剥离（路径守卫的 Windows 语义留形状）。
/// 例如 `C:\Users\x` → `\Users\x`，便于后续统一按 `/` 分词。
pub fn stripDrivePrefix(path: []const u8) []const u8 {
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') return path[2..];
    return path;
}

/// 拒读设备/特殊文件（§5.5）。
pub fn isBlockedDevicePath(path: []const u8) bool {
    const p = stripDrivePrefix(path);
    const blocked = [_][]const u8{
        "/dev/zero",   "/dev/random", "/dev/urandom", "/dev/full",
        "/dev/stdin",  "/dev/tty",    "/dev/console", "/dev/stdout",
        "/dev/stderr", "/dev/fd/0",   "/dev/fd/1",    "/dev/fd/2",
    };
    for (blocked) |b| {
        if (std.mem.eql(u8, p, b)) return true;
    }
    // `/proc/<pid>/...`（pid 可以是数字、`self`、`thread-self`）
    if (std.mem.startsWith(u8, p, "/proc/")) {
        const rest = p["/proc/".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
        const pid = rest[0..slash];
        if (pid.len == 0) return false;
        if (!isPidLike(pid)) return false;
        const tail = rest[slash..];
        if (std.mem.eql(u8, tail, "/environ")) return true;
        if (std.mem.startsWith(u8, tail, "/fd/")) {
            const fd = tail["/fd/".len..];
            if (fd.len == 1 and (fd[0] == '0' or fd[0] == '1' or fd[0] == '2')) return true;
        }
    }
    return false;
}

fn isPidLike(s: []const u8) bool {
    if (std.mem.eql(u8, s, "self") or std.mem.eql(u8, s, "thread-self")) return true;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return s.len > 0;
}

/// 文本读上限 256 KiB（§5.5）。
pub const MAX_TEXT_READ_BYTES: usize = 256 * 1024;
/// 图片读上限 5 MiB（首期可选）。
pub const MAX_IMAGE_READ_BYTES: usize = 5 * 1024 * 1024;
/// 可编辑文件上限 1 GiB。
pub const MAX_EDIT_FILE_BYTES: usize = 1024 * 1024 * 1024;

/// 记忆/配置路径的密钥检测（§5.5）：路径落在 agent 记忆目录且正文含 `api_key=...` 之类 → 拒绝。
/// 目的是防止把 API key 写进会被注入上下文的热核记忆。
pub fn isAgentMemoryPath(path: []const u8) bool {
    const markers = [_][]const u8{ "/.agents/", "/.claude/", "/.zigent/", "/memories/" };
    for (markers) |m| {
        if (std.mem.indexOf(u8, path, m) != null) return true;
    }
    return false;
}

/// 正文里是否含密钥赋值（`(api[_-]?key|secret|token|password)\s*[:=]\s*['\"]?[^\s'\"]{12,}`）。
pub fn containsSecretAssignment(text: []const u8) bool {
    const keys = [_][]const u8{ "api_key", "api-key", "apikey", "secret", "token", "password" };
    for (keys) |k| {
        var i: usize = 0;
        while (indexOfCI(text, i, k)) |at| {
            var j = at + k.len;
            while (j < text.len and (text[j] == ' ' or text[j] == '\t')) : (j += 1) {}
            if (j < text.len and (text[j] == ':' or text[j] == '=')) {
                j += 1;
                while (j < text.len and (text[j] == ' ' or text[j] == '\t')) : (j += 1) {}
                if (j < text.len and (text[j] == '"' or text[j] == '\'')) j += 1;
                var n: usize = 0;
                while (j + n < text.len) : (n += 1) {
                    const c = text[j + n];
                    if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '"' or c == '\'') break;
                }
                if (n >= 12) return true;
            }
            i = at + k.len;
        }
    }
    return false;
}

fn indexOfCI(s: []const u8, from: usize, needle: []const u8) ?usize {
    if (needle.len == 0 or from >= s.len or s.len - from < needle.len) return null;
    var i = from;
    while (i + needle.len <= s.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(s[i .. i + needle.len], needle)) return i;
    }
    return null;
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "path: 归一化与 util.fsio 同语义" {
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

test "path: isWithin 不允许 /a/bc 落在 /a/b 里" {
    try testing.expect(isWithin("/a/b", "/a/b/c"));
    try testing.expect(isWithin("/a/b", "/a/b"));
    try testing.expect(!isWithin("/a/b", "/a/bc"));
    try testing.expect(!isWithin("/a/b", "/a"));
    try testing.expect(!isWithin("/a/b", "/a/c"));
}

test "path: ★ macOS /tmp 不 realpath base（否则误判越界）" {
    // 若把 base realpath 成 /private/tmp，这条会变 null。
    const p = try resolveAndValidate(testing.allocator, .{ .base = "/tmp" }, "/tmp/x/y", &.{});
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("/tmp/x/y", p);
}

test "path: 设备/特殊文件被拒" {
    try testing.expect(isBlockedDevicePath("/dev/zero"));
    try testing.expect(isBlockedDevicePath("/proc/self/environ"));
    try testing.expect(isBlockedDevicePath("/proc/1234/fd/1"));
    try testing.expect(isBlockedDevicePath("/proc/self/fd/2"));
    try testing.expect(!isBlockedDevicePath("/proc/self/fd/9"));
    try testing.expect(!isBlockedDevicePath("/dev/null"));
    try testing.expect(!isBlockedDevicePath("/proc/self/status"));
}

test "path: UNC 与密钥检测" {
    try testing.expect(isUnc("\\\\server\\share\\f"));
    try testing.expect(!isUnc("/tmp/x"));
    try testing.expect(containsSecretAssignment("api_key = \"abcdef123456\""));
    try testing.expect(!containsSecretAssignment("api_key = short"));
    try testing.expect(isAgentMemoryPath("/home/u/.zigent/memories/a.md"));
}
