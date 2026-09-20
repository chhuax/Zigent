//! `config/paths.zig` —— ★ **全部落盘路径的唯一出口**（文档 10 §1/§5）。
//!
//! 三根（文档 03 §6.3 的目录契约，**最容易被记错的一条**）：
//!
//! ```
//! 用户根    ~/.zigent/                                   （机器私有）
//! 工作区根  <cwd>/.agents/                                （可提交，**不是 .zigent**）
//! 运行时态  ~/.zigent/projects/<encoded-cwd>/            （transcript / 运行时产物）
//! 记忆热核  ~/.zigent/memories/<ns>/                     （**不是 <cwd>/.agents/memory/**）
//! ```
//!
//! 硬规则：
//!   1. 全内核**只有本文件**可以出现 `".agents"` / `".zigent"` / `"projects"` 等字面量；
//!   2. 返回的一切都是**已归一化的绝对路径**（词法归一化，**不 realpath** ——
//!      文档 10 §3.4：realpath 会让 `encodeProjectPath` 的键在符号链接路径下与 legacy 分裂）；
//!   3. 调用方不得自行 `std.fs.path.join` 拼配置路径。
//!
//! 编码规则是**三套不同**的规则（文档 10 §5.2，**不许合并**）：
//!   - `encodeProjectPath`     非 `[A-Za-z0-9._-]` → `-`，不截断
//!   - `persistentSessionKey`  合法则原样，否则 `session-` + 64 hex SHA-256
//!   - `sanitizePathSegment`   非 `[A-Za-z0-9._-]` → `_`，截断 64，blank → `default`

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const util = @import("util");

// ─────────────────────────────────────────────────────────────────────────────
// 字面量（本文件是它们**唯一**的允许出现处）
// ─────────────────────────────────────────────────────────────────────────────

pub const USER_DIR_NAME = ".zigent";
pub const WORKSPACE_DIR_NAME = ".agents";
pub const PROJECTS_DIR_NAME = "projects";
pub const MEMORIES_DIR_NAME = "memories";
pub const TRANSCRIPTS_DIR_NAME = "transcripts";
pub const TOOL_RESULTS_DIR_NAME = "tool-results";

/// 名字字符串的唯一来源：给「前缀/相等匹配、写 git exclude」用。
pub fn workspaceDirName() []const u8 {
    return WORKSPACE_DIR_NAME;
}

pub fn userDirName() []const u8 {
    return USER_DIR_NAME;
}

/// OS 分支保留形状（文档 10 §5.3）：首期只填 macos/linux，windows/wsl 留分支。
pub const OsKind = enum { macos, linux, windows, wsl, unknown };

pub fn currentOs() OsKind {
    return switch (@import("builtin").os.tag) {
        .macos => .macos,
        .linux => .linux,
        .windows => .windows,
        else => .unknown,
    };
}

/// 本机可能的主机名环境变量（`resolveHostname` 的回退来源）。
pub const HOSTNAME_ENV = "HOSTNAME";
/// 无主机名可查时的哨兵（文档 10 §8.1：`"unknown-host"`）。
pub const UNKNOWN_HOST = "unknown-host";

/// 环境变量名（文档 10 §4.1）。
pub const ENV_ZIGENT_HOME = "ZIGENT_HOME";
pub const ENV_ZIGENT_CONFIG = "ZIGENT_CONFIG";
pub const ENV_HOME = "HOME";
pub const ENV_USERPROFILE = "USERPROFILE";
/// `config.json` 里 `model.default` 档位的覆盖值（文档 10 §4.3 / userconfig.zig）。
pub const ENV_ZIGENT_DEFAULT_MODEL = "ZIGENT_DEFAULT_MODEL";

// ─────────────────────────────────────────────────────────────────────────────
// 编码 + 归一化（纯函数，可独立测试）
// ─────────────────────────────────────────────────────────────────────────────

fn isProjectPathSafe(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => true,
        else => false,
    };
}

/// 绝对规范化路径中非 `[A-Za-z0-9._-]` 的字符 → `'-'`（**不截断**）。
///
/// `/mnt/d/git/zigent` → `-mnt-d-git-zigent`（前导 `/` 也变成 `-`，逐字节复刻既有行为）。
pub fn encodeProjectPath(gpa: Allocator, cwd: []const u8) Allocator.Error![]u8 {
    const abs = try normalize(gpa, cwd);
    defer gpa.free(abs);
    const out = try gpa.alloc(u8, abs.len);
    for (abs, 0..) |c, i| out[i] = if (isProjectPathSafe(c)) c else '-';
    return out;
}

/// 会话文件系统键（transcript 文件名 / attachments 子目录）。
/// 匹配 `[A-Za-z0-9][A-Za-z0-9._-]{0,199}` → 原样；否则 `"session-" + 64 hex`。
pub fn persistentSessionKey(gpa: Allocator, session_id: []const u8) Allocator.Error![]u8 {
    if (isValidSessionId(session_id)) return gpa.dupe(u8, session_id);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(session_id, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(gpa, "session-{s}", .{hex});
}

fn isValidSessionId(s: []const u8) bool {
    if (s.len == 0 or s.len > 200) return false; // 1 + {0,199}
    switch (s[0]) {
        'A'...'Z', 'a'...'z', '0'...'9' => {},
        else => return false,
    }
    for (s[1..]) |c| {
        if (!isProjectPathSafe(c)) return false;
    }
    return true;
}

/// 目录段消毒：blank → `"default"`；非 `[A-Za-z0-9._-]` → `'_'`；**截断 64**。
pub fn sanitizePathSegment(gpa: Allocator, segment: []const u8) Allocator.Error![]u8 {
    const trimmed = std.mem.trim(u8, segment, " \t\r\n");
    if (trimmed.len == 0) return gpa.dupe(u8, "default");
    const n = @min(trimmed.len, 64);
    const out = try gpa.alloc(u8, n);
    for (trimmed[0..n], 0..) |c, i| out[i] = if (isProjectPathSafe(c)) c else '_';
    return out;
}

/// 词法归一化：折叠 `.` / `..` / 重复分隔符。**不解析符号链接。**
///
/// ⚠️ 契约要求 `home` / `cwd` 已经是归一化绝对路径（由 `engine/rt` 填入），
/// 所以这里**不做**相对路径的绝对化 —— 那需要 `io`，而本模块的路径 getter
/// 与 INTERFACES §4.1 一致地只收 `gpa`。相对路径原样交给 `util.fsio.normalize`。
///
/// 返回的切片**永远是 gpa 新分配的**（调用方 free 恰好一次）。
pub fn normalize(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    return util.fsio.normalize(gpa, path);
}

/// `~` 前缀的显式展开：`join(home, rest)`。
/// ⚠️ 用户配置里手写的 `"~/foo"` **不展开**（文档 10 §4.3），本函数只用于拼三根。
pub fn joinHome(gpa: Allocator, home: []const u8, rest: []const u8) Allocator.Error![]u8 {
    return join(gpa, &.{ home, rest });
}

/// 三根拼接的唯一实现（POSIX `/`）。
pub fn join(gpa: Allocator, parts: []const []const u8) Allocator.Error![]u8 {
    return std.fs.path.join(gpa, parts);
}

/// `HOME=/Users/me/` 这类尾斜杠必须剥掉：否则 `join(home, ".zigent")`
/// 会产出 `//`（macOS 上 `//x` 是网络节点路径，会变成只读的怪错误）。
/// 根 `/` 保留。
fn stripTrailingSlashes(p: []const u8) []const u8 {
    if (p.len <= 1) return p;
    return std.mem.trimEnd(u8, p, "/");
}

fn nonBlank(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return null;
    return t;
}

/// 二进制目录名（`<encoded-cwd>` 与 `<sessionKey>` 的父目录）：
/// 只做「取最后一段 + 消毒」，避免调用方再拼一次 `std.fs.path`。
pub fn dirBasename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

// ─────────────────────────────────────────────────────────────────────────────
// home 解析（四段回退 + trim；文档 10 §4.2）
// ─────────────────────────────────────────────────────────────────────────────

pub const HomeSource = enum { zigent_home, home_env, user_profile, fallback };

pub const HomeResolution = struct {
    /// 最终用于拼 `~/.zigent` 的字符串（**可能为空**）。
    value: []const u8,
    source: HomeSource,
    /// `"?"` 这类哨兵值被跳过的次数（诊断输出用）。
    skipped_sentinels: u8 = 0,
};

/// 四段回退：`ZIGENT_HOME` → `HOME` → `USERPROFILE` → `ZIGENT_HOME` 原值。
///
/// ⚠️ `"?"` 是测试环境的哨兵值，必须当「无效」跳过（文档 10 §4.2）。
/// ⚠️ `enc:1:` 解密的 passphrase 用的**就是**这个 home —— 二者必须同源。
pub fn resolveHome(env: *const std.process.Environ.Map) HomeResolution {
    var skipped: u8 = 0;
    if (nonBlank(util.io.getEnv(env, ENV_ZIGENT_HOME))) |v| {
        if (std.mem.eql(u8, v, "?")) skipped += 1 else return .{ .value = stripTrailingSlashes(v), .source = .zigent_home };
    }
    if (nonBlank(util.io.getEnv(env, ENV_HOME))) |v| {
        if (std.mem.eql(u8, v, "?")) skipped += 1 else return .{ .value = stripTrailingSlashes(v), .source = .home_env, .skipped_sentinels = skipped };
    }
    if (nonBlank(util.io.getEnv(env, ENV_USERPROFILE))) |v| {
        if (std.mem.eql(u8, v, "?")) skipped += 1 else return .{ .value = stripTrailingSlashes(v), .source = .user_profile, .skipped_sentinels = skipped };
    }
    const raw = util.io.getEnv(env, ENV_ZIGENT_HOME) orelse
        util.io.getEnv(env, ENV_HOME) orelse
        util.io.getEnv(env, ENV_USERPROFILE) orelse "";
    return .{ .value = stripTrailingSlashes(raw), .source = .fallback, .skipped_sentinels = skipped };
}

/// `ZIGENT_CONFIG` 的原样值（`trim` 后非空才生效；**不做 `~` 展开**，文档 10 §4.1）。
pub fn configOverride(env: *const std.process.Environ.Map) ?[]const u8 {
    return nonBlank(util.io.getEnv(env, ENV_ZIGENT_CONFIG));
}

// ─────────────────────────────────────────────────────────────────────────────
// Paths —— INTERFACES-v1 §4.1 的**逐字**形状
// ─────────────────────────────────────────────────────────────────────────────

pub const Paths = struct {
    /// 用户根（已解析，可能为空串 —— 由调用方保证是归一化绝对路径）。
    home: []const u8,
    /// 工作区身份 cwd（已归一化绝对路径）。
    cwd: []const u8,
    /// settings LOCAL 层用的工作区根；`null` = 与 `cwd` 同根。
    ///
    /// 文档 10 §3.4：PROJECT 层用 `execution_cwd`、LOCAL 层用 `workspace_root`，
    /// 二者在 `enter_worktree` 之后允许不同。契约只要求单个 `cwd`，
    /// 所以这是**可选覆盖**、默认与 `cwd` 相同（行为与契约一致）。
    workspace: ?[]const u8 = null,
    /// `ZIGENT_CONFIG` 的原样值；`null` = 用默认位置（文档 10 §4.1）。
    config_override: ?[]const u8 = null,
    /// home 是从哪一段回退来的（doctor 用）。
    home_source: HomeSource = .fallback,

    /// 便捷构造：从环境解析 home + cwd（cwd 用进程启动时的工作目录）。
    /// 字段都是 `[]const u8`，指向 `env`/`cwd` 的存储 —— 调用方必须保证其存活期覆盖 `Paths`。
    pub fn discover(io: Io, gpa: Allocator, env: *const std.process.Environ.Map, cwd: []const u8) !Paths {
        _ = io;
        _ = gpa;
        const h = resolveHome(env);
        return .{
            .home = h.value,
            .cwd = cwd,
            .config_override = configOverride(env),
            .home_source = h.source,
        };
    }

    fn base(self: *const Paths) []const u8 {
        return self.workspace orelse self.cwd;
    }

    // ── ① 用户根 <home>/.zigent ──────────────────────────────────────────
    pub fn userDir(self: *const Paths, gpa: Allocator) Allocator.Error![]u8 {
        const joined = try joinHome(gpa, self.home, USER_DIR_NAME);
        defer gpa.free(joined);
        return normalize(gpa, joined);
    }

    // ── ② 工作区根 <cwd>/.agents（**不是 .zigent**） ─────────────────────
    pub fn workspaceDir(self: *const Paths, gpa: Allocator) Allocator.Error![]u8 {
        const joined = try join(gpa, &.{ self.base(), WORKSPACE_DIR_NAME });
        defer gpa.free(joined);
        return normalize(gpa, joined);
    }

    // ── ③ 运行时态 <home>/.zigent/projects/<encoded-cwd> ────────────────
    /// cwd 去掉前导 `/`（以及编码规则里的其它非法字符），`/` → `-`。
    pub fn encodedCwd(self: *const Paths, gpa: Allocator) Allocator.Error![]u8 {
        return encodeProjectPath(gpa, self.cwd);
    }

    pub fn projectRuntimeDir(self: *const Paths, gpa: Allocator) Allocator.Error![]u8 {
        const ud = try self.userDir(gpa);
        defer gpa.free(ud);
        const enc = try self.encodedCwd(gpa);
        defer gpa.free(enc);
        return join(gpa, &.{ ud, PROJECTS_DIR_NAME, enc });
    }

    pub fn transcriptsDir(self: *const Paths, gpa: Allocator) Allocator.Error![]u8 {
        return self.sub(gpa, TRANSCRIPTS_DIR_NAME);
    }

    pub fn toolResultsDir(self: *const Paths, gpa: Allocator) Allocator.Error![]u8 {
        return self.sub(gpa, TOOL_RESULTS_DIR_NAME);
    }

    pub fn goalsDir(self: *const Paths, gpa: Allocator) Allocator.Error![]u8 {
        return self.sub(gpa, "goals");
    }

    pub fn worktreesDir(self: *const Paths, gpa: Allocator) Allocator.Error![]u8 {
        return self.sub(gpa, "worktrees");
    }

    fn sub(self: *const Paths, gpa: Allocator, name: []const u8) Allocator.Error![]u8 {
        const root = try self.projectRuntimeDir(gpa);
        defer gpa.free(root);
        return join(gpa, &.{ root, name });
    }

    // ── ④ 记忆热核 <home>/.zigent/memories/<ns>（**跨项目共享**） ───────
    pub fn memoriesDir(self: *const Paths, gpa: Allocator, ns: []const u8) Allocator.Error![]u8 {
        const ud = try self.userDir(gpa);
        defer gpa.free(ud);
        const seg = try sanitizePathSegment(gpa, ns);
        defer gpa.free(seg);
        return join(gpa, &.{ ud, MEMORIES_DIR_NAME, seg });
    }

    // ── ⑤ 配置文件 ───────────────────────────────────────────────────────
    pub fn userConfigFile(self: *const Paths, gpa: Allocator) Allocator.Error![]u8 {
        if (self.config_override) |p| return gpa.dupe(u8, p); // 原样，不参与 ~ 展开
        const ud = try self.userDir(gpa);
        defer gpa.free(ud);
        return join(gpa, &.{ ud, "config.json" });
    }

    pub fn userSettingsFile(self: *const Paths, gpa: Allocator) Allocator.Error![]u8 {
        return self.userFile(gpa, "settings.json");
    }

    /// ⚠️ LOCAL 层用 `workspace_root`（可用 `.workspace` 覆盖），不是 `execution_cwd`。
    pub fn projectSettingsFile(self: *const Paths, gpa: Allocator) Allocator.Error![]u8 {
        const wd = try workspaceDirFor(gpa, self.cwd);
        defer gpa.free(wd);
        return join(gpa, &.{ wd, "settings.json" });
    }

    pub fn localSettingsFile(self: *const Paths, gpa: Allocator) Allocator.Error![]u8 {
        const wd = try workspaceDirFor(gpa, self.base());
        defer gpa.free(wd);
        return join(gpa, &.{ wd, "settings.local.json" });
    }

    pub fn managedSettingsFile(self: *const Paths, gpa: Allocator) Allocator.Error![]u8 {
        return self.userFile(gpa, "settings.managed.json");
    }

    pub fn policySettingsFile(self: *const Paths, gpa: Allocator) Allocator.Error![]u8 {
        return self.userFile(gpa, "settings.policy.json");
    }

    fn userFile(self: *const Paths, gpa: Allocator, name: []const u8) Allocator.Error![]u8 {
        const ud = try self.userDir(gpa);
        defer gpa.free(ud);
        return join(gpa, &.{ ud, name });
    }

    fn workspaceDirFor(gpa: Allocator, root: []const u8) Allocator.Error![]u8 {
        const joined = try join(gpa, &.{ root, WORKSPACE_DIR_NAME });
        defer gpa.free(joined);
        return normalize(gpa, joined);
    }

    // ── ⑥ settings 层候选路径（合并顺序 = 指纹检测顺序，**唯一同源**） ──
    /// 低 → 高：user < project < local < managed < policy。
    /// 调用方**不得**自行拼这份列表（文档 10 §3.3「避免第二处真相」）。
    pub fn settingsCandidatePaths(self: *const Paths, gpa: Allocator) Allocator.Error![][]u8 {
        var out = std.ArrayListUnmanaged([]u8).empty;
        errdefer {
            for (out.items) |p| gpa.free(p);
            out.deinit(gpa);
        }
        try out.append(gpa, try self.userSettingsFile(gpa));
        try out.append(gpa, try self.projectSettingsFile(gpa));
        try out.append(gpa, try self.localSettingsFile(gpa));
        try out.append(gpa, try self.managedSettingsFile(gpa));
        try out.append(gpa, try self.policySettingsFile(gpa));
        return out.toOwnedSlice(gpa);
    }

    // ── ⑦ 建目录（幂等） ─────────────────────────────────────────────────
    pub fn ensureRuntimeDirs(self: *const Paths, io: Io) !void {
        const gpa = std.heap.page_allocator;
        const ud = try self.userDir(gpa);
        defer gpa.free(ud);
        const runtime = try self.projectRuntimeDir(gpa);
        defer gpa.free(runtime);

        try mkdirpDir(io, ud);
        try mkdirpDir(io, runtime);
        for ([_][]const u8{ TRANSCRIPTS_DIR_NAME, TOOL_RESULTS_DIR_NAME, "goals", "worktrees" }) |name| {
            const sub_path = try join(gpa, &.{ runtime, name });
            defer gpa.free(sub_path);
            try mkdirpDir(io, sub_path);
        }
        // ⚠️ **刻意不建工作区根 `<cwd>/.agents/`**（契约只说 runtime）。
        //    那是用户仓库里的可提交目录，写权限/意图都属于工作区自己的写入面；
        //    内核在 `<cwd>` 可能只读（容器挂载）时也必须能起运行时目录。
        //    需要它的调用方（settings 写入、instructions 发现）自行按需创建。
    }
};

/// `mkdirp` 的调用包装：**必须剥掉尾斜杠**。
/// 尾斜杠会让 `createDirPath` 拿最后一段空组件去 `mkdir("")`，
/// 在 macOS 上表现为 `error.ReadOnlyFileSystem`（难查的静默失败）。
fn mkdirpDir(io: Io, path: []const u8) !void {
    const trimmed = if (path.len > 1) std.mem.trimEnd(u8, path, "/") else path;
    try util.io.mkdirp(io, trimmed);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "paths: 目录契约 —— 用户根 .zigent / 工作区根 .agents" {
    const gpa = testing.allocator;
    const p = Paths{ .home = "/Users/me", .cwd = "/repo" };

    const ud = try p.userDir(gpa);
    defer gpa.free(ud);
    try testing.expectEqualStrings("/Users/me/.zigent", ud);

    const wd = try p.workspaceDir(gpa);
    defer gpa.free(wd);
    try testing.expectEqualStrings("/repo/.agents", wd);
    try testing.expect(std.mem.indexOf(u8, wd, ".zigent") == null);
    try testing.expectEqualStrings(".agents", workspaceDirName());
}

test "paths: encodedCwd / projectRuntimeDir / 各类目录" {
    const gpa = testing.allocator;
    const p = Paths{ .home = "/Users/me", .cwd = "/mnt/d/git/zigent" };

    const enc = try p.encodedCwd(gpa);
    defer gpa.free(enc);
    try testing.expectEqualStrings("-mnt-d-git-zigent", enc);

    const rt = try p.projectRuntimeDir(gpa);
    defer gpa.free(rt);
    try testing.expectEqualStrings("/Users/me/.zigent/projects/-mnt-d-git-zigent", rt);

    const tr = try p.transcriptsDir(gpa);
    defer gpa.free(tr);
    try testing.expectEqualStrings("/Users/me/.zigent/projects/-mnt-d-git-zigent/transcripts", tr);

    const tres = try p.toolResultsDir(gpa);
    defer gpa.free(tres);
    try testing.expectEqualStrings("/Users/me/.zigent/projects/-mnt-d-git-zigent/tool-results", tres);

    const goals = try p.goalsDir(gpa);
    defer gpa.free(goals);
    try testing.expectEqualStrings("/Users/me/.zigent/projects/-mnt-d-git-zigent/goals", goals);

    const wt = try p.worktreesDir(gpa);
    defer gpa.free(wt);
    try testing.expectEqualStrings("/Users/me/.zigent/projects/-mnt-d-git-zigent/worktrees", wt);
}

test "paths: 记忆热核在 ~/.zigent/memories/<ns>，**不在** <cwd>/.agents/memory" {
    const gpa = testing.allocator;
    const p = Paths{ .home = "/Users/me", .cwd = "/repo" };

    const m = try p.memoriesDir(gpa, "default");
    defer gpa.free(m);
    try testing.expectEqualStrings("/Users/me/.zigent/memories/default", m);
    try testing.expect(std.mem.indexOf(u8, m, ".agents") == null);

    const b = try p.memoriesDir(gpa, "benchmark");
    defer gpa.free(b);
    try testing.expectEqualStrings("/Users/me/.zigent/memories/benchmark", b);

    // blank ns → "default"
    const d = try p.memoriesDir(gpa, "  ");
    defer gpa.free(d);
    try testing.expectEqualStrings("/Users/me/.zigent/memories/default", d);
}

test "paths: 五个 settings 文件（含 managed/policy 在用户根）" {
    const gpa = testing.allocator;
    const p = Paths{ .home = "/Users/me", .cwd = "/repo" };

    const uc = try p.userConfigFile(gpa);
    defer gpa.free(uc);
    try testing.expectEqualStrings("/Users/me/.zigent/config.json", uc);

    const us = try p.userSettingsFile(gpa);
    defer gpa.free(us);
    try testing.expectEqualStrings("/Users/me/.zigent/settings.json", us);

    const ps = try p.projectSettingsFile(gpa);
    defer gpa.free(ps);
    try testing.expectEqualStrings("/repo/.agents/settings.json", ps);

    const ls = try p.localSettingsFile(gpa);
    defer gpa.free(ls);
    try testing.expectEqualStrings("/repo/.agents/settings.local.json", ls);

    const ms = try p.managedSettingsFile(gpa);
    defer gpa.free(ms);
    try testing.expectEqualStrings("/Users/me/.zigent/settings.managed.json", ms);

    const po = try p.policySettingsFile(gpa);
    defer gpa.free(po);
    try testing.expectEqualStrings("/Users/me/.zigent/settings.policy.json", po);

    const cand = try p.settingsCandidatePaths(gpa);
    defer {
        for (cand) |c| gpa.free(c);
        gpa.free(cand);
    }
    try testing.expectEqual(@as(usize, 5), cand.len);
    try testing.expectEqualStrings("/Users/me/.zigent/settings.json", cand[0]);
    try testing.expectEqualStrings("/Users/me/.zigent/settings.policy.json", cand[4]);
}

test "paths: ZIGENT_CONFIG 覆盖且不做 ~ 展开" {
    const gpa = testing.allocator;
    const p = Paths{ .home = "/Users/me", .cwd = "/repo", .config_override = "~/x/c.json" };
    const uc = try p.userConfigFile(gpa);
    defer gpa.free(uc);
    try testing.expectEqualStrings("~/x/c.json", uc);

    const p2 = Paths{ .home = "/Users/me", .cwd = "/repo", .config_override = "/tmp/c.json" };
    const uc2 = try p2.userConfigFile(gpa);
    defer gpa.free(uc2);
    try testing.expectEqualStrings("/tmp/c.json", uc2);
}

test "paths: workspace 覆盖只改 LOCAL 层（PROJECT 仍用执行 cwd）" {
    const gpa = testing.allocator;
    const p = Paths{ .home = "/h", .cwd = "/repo/wt", .workspace = "/repo" };
    const ls = try p.localSettingsFile(gpa);
    defer gpa.free(ls);
    try testing.expectEqualStrings("/repo/.agents/settings.local.json", ls);
    const ps = try p.projectSettingsFile(gpa);
    defer gpa.free(ps);
    try testing.expectEqualStrings("/repo/wt/.agents/settings.json", ps);
}

test "paths: encodeProjectPath golden 表（非 [A-Za-z0-9._-] → '-'，不截断）" {
    const gpa = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "/mnt/d/git/zigent", "-mnt-d-git-zigent" },
        .{ "/Users/me/proj (v2)", "-Users-me-proj--v2-" },
        .{ "/a/b_c.d-e", "-a-b_c.d-e" },
        .{ "/", "-" },
    };
    for (cases) |c| {
        const got = try encodeProjectPath(gpa, c[0]);
        defer gpa.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

test "paths: persistentSessionKey 合法原样 / 非法走 SHA-256" {
    const gpa = testing.allocator;

    const ok = try persistentSessionKey(gpa, "abc-123.X_y");
    defer gpa.free(ok);
    try testing.expectEqualStrings("abc-123.X_y", ok);

    const bad = try persistentSessionKey(gpa, "a/b");
    defer gpa.free(bad);
    try testing.expectEqual(@as(usize, "session-".len + 64), bad.len);
    try testing.expect(std.mem.startsWith(u8, bad, "session-"));

    const long = try persistentSessionKey(gpa, "x" ** 201);
    defer gpa.free(long);
    try testing.expect(std.mem.startsWith(u8, long, "session-"));

    // 空串也走 hash（不 panic、不产生空文件名）
    const empty = try persistentSessionKey(gpa, "");
    defer gpa.free(empty);
    try testing.expect(std.mem.startsWith(u8, empty, "session-"));

    // 与 SHA-256 逐字节一致
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("a/b", &digest, .{});
    const expect = try std.fmt.allocPrint(gpa, "session-{s}", .{std.fmt.bytesToHex(digest, .lower)});
    defer gpa.free(expect);
    try testing.expectEqualStrings(expect, bad);
}

test "paths: sanitizePathSegment（blank → default，非安全字符 → _，截断 64）" {
    const gpa = testing.allocator;
    const a = try sanitizePathSegment(gpa, "a/b:c");
    defer gpa.free(a);
    try testing.expectEqualStrings("a_b_c", a);

    const b = try sanitizePathSegment(gpa, "   ");
    defer gpa.free(b);
    try testing.expectEqualStrings("default", b);

    const c = try sanitizePathSegment(gpa, "x" ** 100);
    defer gpa.free(c);
    try testing.expectEqual(@as(usize, 64), c.len);
}

test "paths: home 四段回退 + \"?\" 哨兵 + trim" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    // 空 map → fallback 空串
    try testing.expectEqual(HomeSource.fallback, resolveHome(&env).source);

    try env.put("HOME", "/home/me");
    try env.put("USERPROFILE", "/win/me");
    {
        const h = resolveHome(&env);
        try testing.expectEqualStrings("/home/me", h.value);
        try testing.expectEqual(HomeSource.home_env, h.source);
    }

    // ZIGENT_HOME 优先，且 trim
    try env.put("ZIGENT_HOME", "  /tmp/z  ");
    {
        const h = resolveHome(&env);
        try testing.expectEqualStrings("/tmp/z", h.value);
        try testing.expectEqual(HomeSource.zigent_home, h.source);
    }

    // 空串/纯空白 → 回退下一段
    try env.put("ZIGENT_HOME", "   ");
    {
        const h = resolveHome(&env);
        try testing.expectEqualStrings("/home/me", h.value);
    }

    // "?" 哨兵 → 跳过并计数
    try env.put("ZIGENT_HOME", "?");
    {
        const h = resolveHome(&env);
        try testing.expectEqualStrings("/home/me", h.value);
        try testing.expectEqual(@as(u8, 1), h.skipped_sentinels);
    }

    // HOME 也是 "?" → 落 USERPROFILE
    try env.put("HOME", "?");
    {
        const h = resolveHome(&env);
        try testing.expectEqualStrings("/win/me", h.value);
        try testing.expectEqual(HomeSource.user_profile, h.source);
    }

    // 三段都无效 → fallback
    try env.put("USERPROFILE", "?");
    {
        const h = resolveHome(&env);
        try testing.expectEqual(HomeSource.fallback, h.source);
        try testing.expectEqualStrings("?", h.value); // 原样返回（调用方可据此诊断）
        try testing.expectEqual(@as(u8, 3), h.skipped_sentinels);
    }
}

test "paths: ZIGENT_CONFIG 覆盖解析（空串不算）" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expect(configOverride(&env) == null);
    try env.put("ZIGENT_CONFIG", "  ");
    try testing.expect(configOverride(&env) == null);
    try env.put("ZIGENT_CONFIG", "/tmp/c.json");
    try testing.expectEqualStrings("/tmp/c.json", configOverride(&env).?);
}

test "paths: ensureRuntimeDirs 幂等建目录" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rnd = try util.io.randomHex(io, testing.allocator, 6);
    defer testing.allocator.free(rnd);
    const base = try std.fmt.allocPrint(testing.allocator, "/tmp/zigent-paths-test-{s}", .{rnd});
    defer testing.allocator.free(base);
    defer util.io.removeTree(io, base) catch {};

    const p = Paths{ .home = base, .cwd = "/mnt/d/git/zigent" };
    try p.ensureRuntimeDirs(io);
    try p.ensureRuntimeDirs(io); // 幂等

    try testing.expect(util.io.isDir(io, base));
    const rt = try p.projectRuntimeDir(testing.allocator);
    defer testing.allocator.free(rt);
    try testing.expect(util.io.isDir(io, rt));

    const tr = try p.transcriptsDir(testing.allocator);
    defer testing.allocator.free(tr);
    try testing.expect(util.io.isDir(io, tr));
}

test "paths: 归一化折叠 .. 与重复分隔符，不 realpath" {
    const gpa = testing.allocator;
    const p = Paths{ .home = "/Users/me", .cwd = "/a/b/../c/./d//" };
    const wd = try p.workspaceDir(gpa);
    defer gpa.free(wd);
    try testing.expectEqualStrings("/a/c/d/.agents", wd);
}

test "paths: 名字常量唯一出口" {
    try testing.expectEqualStrings(".zigent", userDirName());
    try testing.expectEqualStrings(".agents", workspaceDirName());
    try testing.expectEqualStrings("unknown-host", UNKNOWN_HOST);
    try testing.expectEqualStrings("ZIGENT_HOME", ENV_ZIGENT_HOME);
    try testing.expectEqualStrings("ZIGENT_CONFIG", ENV_ZIGENT_CONFIG);
    _ = currentOs();
}
