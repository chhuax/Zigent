//! `memory/instructions.zig` —— **指令文件**（项目约定，四条正交链的第 ① 条）。
//!
//! ## 发现顺序（本项目裁定的顺序）
//!
//! ```
//! 1. <home>/.zigent/AGENTS.md          用户级（跨项目）
//! 2. <cwd>/AGENTS.md                    项目级
//! 3. <cwd>/.agents/rules/*.md           目录内全部 .md，**按文件名排序**
//! ```
//!
//! ## 与 legacy 的三处**故意**收窄（任务书明确规定，覆盖文档 13 §1.4）
//!
//! | legacy 行为 | 本项目 | 理由 |
//! |---|---|---|
//! | `AGENTS.md` 不存在时回退读同目录 `CLAUDE.md` | **完全不读 `CLAUDE.md`** | 已定：本项目不用 CLAUDE.md 这个名字 |
//! | 从 cwd **沿父目录向上到根**逐层找 | **只看 `<cwd>` 一层** | 任务书指定的发现顺序就是这三级 |
//! | 扫 `~/.claude` | **绝不扫** | 同上；`injection.legacy_claude_config` 还会把**读取** legacy 配置视为威胁 |
//!
//! 「`AGENTS.md` 是唯一被识别的文件名」——这一点是硬约束。
//!
//! ## `@include`（逐字对齐文档 13 §1.4 的 A3/A4/A5）
//!
//! - A3：`@include "path"` / `@include 'path'`，**相对包含它的文件所在目录**。
//!   （legacy 的 `Pattern` 只认带引号的形式；本实现对**无引号**写法也接受 ——
//!   这是刻意的**超集**，见 `parseInclude` 注释。）
//! - A4：深度上限 **5**；超深度的指令行**原样返回、不展开**（不报错）。
//! - A5：循环 → `<!-- circular @include skipped: X -->`；
//!   缺失 → `<!-- @include not found: X -->`；
//!   单文件 > **12000** 字符 → 截断 + `"...[truncated]..."`。
//!   长度同样按 **code point** 计（与热核记忆同一口径，见 `hot.zig`）。
//!
//! ## 注入形态（文档 13 §1.4「包裹格式」，逐字复刻）
//!
//! ```
//! # Project Instructions
//!
//! ## /abs/path/AGENTS.md
//! ```md
//! <展开后的内容（trim 过）>
//! ```
//! ```
//!
//! ## ★ 路径围栏（`@include` 的安全边界）
//!
//! 一个克隆来的仓库里的 `AGENTS.md` 可以写 `@include "../../../../.ssh/id_rsa"`
//! 把本机文件读进提示词。所以 `@include` **必须**落在允许的根之内：
//!
//! ```
//! 默认根 = [ <cwd> , <home>/.zigent ]        （+ Options.extra_roots）
//! ```
//!
//! 越界的 `@include` **不读文件**，只渲染一条诊断标记：
//! `<!-- @include outside allowed root: X -->`（与 A5 的其余标记同风格）。
//!
//! **判定是词法的**（`util.fsio.normalize` 折叠 `.` / `..` / 重复分隔符），
//! **不解析符号链接** —— 与 `perm/` 的 `PathValidator` 同一口径（`util/fsio.zig`
//! 文件头也写明「首期同样只做归一化 + 前缀判定」）。也就是说：一个指向根外的
//! **符号链接**仍能穿过围栏；补 realpath 是 `util/fsio.zig` 一处的事，
//! 本模块不另起一套口径。
//!
//! `discover` 保持 4 参（围栏取默认根），需要额外根时用 `discoverFenced`。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const common = @import("common");
const util = @import("util");
const testutil = @import("testutil.zig");

pub const instructions = struct {
    pub const File = struct {
        /// 归一化后的**绝对**路径（render 的 `## <路径>` 用它）。
        path: []const u8,
        /// `@include` 展开 + 截断之后的正文。
        text: []const u8,
    };

    /// 用户级配置目录（`~/.zigent/`）—— 与 `portable-layout` 契约同名。
    pub const user_config_dir = ".zigent";
    /// **唯一**被识别的指令文件名。
    pub const agents_md = "AGENTS.md";
    /// 项目级规则目录（相对 cwd）。
    pub const rules_rel_dir = ".agents/rules";
    /// A4：`@include` 深度上限。
    pub const max_include_depth: usize = 5;
    /// A5：单文件字符上限（code point）。
    pub const max_file_chars: usize = 12_000;
    /// 单文件读取上限（护栏：别把一个二进制当指令文件读进内存）。
    pub const max_file_bytes: usize = 4 << 20;

    pub const include_directive = "@include";

    /// `discoverFenced` 的选项（默认值 = 只加"默认根"）。
    pub const Options = struct {
        /// 除 `<cwd>` 与 `<home>/.zigent` 之外**额外允许**的根。
        /// 绝对或相对都可以（相对者按进程 cwd 解析），会做词法归一化 + 去重。
        extra_roots: []const []const u8 = &.{},
    };

    /// 按发现顺序返回指令文件（每个都已经完成 `@include` 展开）。
    /// 不存在的位置直接跳过 —— 一个项目完全没有任何指令文件是正常的。
    ///
    /// `home == null` 表示用户 home 不可知 → 跳过用户级。
    /// `@include` 围栏取**默认根**（`<cwd>` + `<home>/.zigent`）。
    pub fn discover(
        io: Io,
        gpa: Allocator,
        cwd: []const u8,
        home: ?[]const u8,
    ) ![]File {
        return discoverFenced(io, gpa, cwd, home, .{});
    }

    /// `discover` 的围栏版本：可以追加额外允许的根。
    pub fn discoverFenced(
        io: Io,
        gpa: Allocator,
        cwd: []const u8,
        home: ?[]const u8,
        options: Options,
    ) ![]File {
        var out = std.ArrayListUnmanaged(File).empty;
        errdefer freeFiles(gpa, out.items);

        // 已加入的绝对路径（去重）。存的是自有副本，退出时统一释放。
        var added = std.ArrayListUnmanaged([]u8).empty;
        defer {
            for (added.items) |p| gpa.free(p);
            added.deinit(gpa);
        }

        // ── 围栏根（全部归一化成绝对路径）──
        const roots = try buildRoots(io, gpa, cwd, home, options.extra_roots);
        defer {
            for (roots) |r| gpa.free(r);
            gpa.free(roots);
        }
        const fence = Fence{ .roots = roots };

        // 层 1：用户级
        if (home) |h| {
            if (h.len > 0) {
                const p = try std.fs.path.join(gpa, &.{ h, user_config_dir, agents_md });
                defer gpa.free(p);
                try addCandidate(io, gpa, &out, &added, p, fence);
            }
        }

        // 层 2：项目级
        {
            const p = try std.fs.path.join(gpa, &.{ cwd, agents_md });
            defer gpa.free(p);
            try addCandidate(io, gpa, &out, &added, p, fence);
        }

        // 层 3：.agents/rules/*.md（按绝对路径字节序排序 == 按文件名排序）
        {
            const dir = try std.fs.path.join(gpa, &.{ cwd, rules_rel_dir });
            defer gpa.free(dir);
            const paths = try util.fsio.collectFiles(io, gpa, dir, .{ .max_depth = 1 });
            defer util.fsio.freePaths(gpa, paths);
            std.mem.sort([]u8, paths, {}, lessThanPath);
            for (paths) |p| {
                if (!std.mem.endsWith(u8, p, ".md")) continue;
                try addCandidate(io, gpa, &out, &added, p, fence);
            }
        }

        return out.toOwnedSlice(gpa);
    }

    pub fn freeFiles(gpa: Allocator, files: []File) void {
        for (files) |f| {
            gpa.free(f.path);
            gpa.free(f.text);
        }
        gpa.free(files);
    }

    /// 注入块。`files` 为空 → 返回空串（没有指令文件就不注入这一段）。
    pub fn render(gpa: Allocator, files: []const File) ![]u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(gpa);
        if (files.len == 0) return out.toOwnedSlice(gpa);

        try out.appendSlice(gpa, "# Project Instructions\n");
        for (files) |f| {
            try out.print(gpa, "\n## {s}\n```md\n", .{f.path});
            try out.appendSlice(gpa, std.mem.trim(u8, f.text, " \t\r\n"));
            try out.appendSlice(gpa, "\n```\n");
        }
        return out.toOwnedSlice(gpa);
    }

    /// 把一段含 `@include` 的文本展开（**不读顶层文件**的入口，留给测试/诊断用）。
    /// 围栏根 = `base_dir` 自身。
    pub fn expandText(io: Io, gpa: Allocator, text: []const u8, base_dir: []const u8) ![]u8 {
        const root = try absoluteNormalized(io, gpa, base_dir);
        defer gpa.free(root);
        var roots = [_][]const u8{root};

        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(gpa);
        var visited = Visited{};
        defer visited.deinit(gpa);
        try expandInto(io, gpa, &out, text, root, 0, &visited, .{ .roots = &roots });
        return out.toOwnedSlice(gpa);
    }
};

// ── 路径围栏 ─────────────────────────────────────────────────────────────────

/// `@include` 的允许根集合。**两侧都必须已词法归一化**（`Fence` 的构造保证这点）。
pub const Fence = struct {
    roots: []const []const u8,

    pub fn allows(self: Fence, absolute_candidate: []const u8) bool {
        for (self.roots) |r| {
            if (util.fsio.isWithin(r, absolute_candidate)) return true;
        }
        return false;
    }
};

// ── 内部 ─────────────────────────────────────────────────────────────────────

const Visited = struct {
    map: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *Visited, gpa: Allocator) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.map.deinit(gpa);
    }

    fn add(self: *Visited, gpa: Allocator, path: []const u8) !void {
        const key = try gpa.dupe(u8, path);
        errdefer gpa.free(key);
        try self.map.put(gpa, key, {});
    }

    fn has(self: *Visited, path: []const u8) bool {
        return self.map.contains(path);
    }
};

/// 把 `p` 归一化成**绝对**路径（相对者按进程 cwd 解析）。
/// 只用 `util.io.cwdAlloc` + `util.fsio.resolve`，本模块不直接碰 `std.Io`。
fn absoluteNormalized(io: Io, gpa: Allocator, p: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(p)) return util.fsio.normalize(gpa, p);
    const cwd = try util.io.cwdAlloc(io, gpa);
    defer gpa.free(cwd);
    return util.fsio.resolve(gpa, cwd, p);
}

/// 收集围栏根：`<cwd>` + `<home>/.zigent` + extra（归一化 + 去重）。
fn buildRoots(
    io: Io,
    gpa: Allocator,
    cwd: []const u8,
    home: ?[]const u8,
    extra: []const []const u8,
) ![][]u8 {
    var out = std.ArrayListUnmanaged([]u8).empty;
    errdefer {
        for (out.items) |r| gpa.free(r);
        out.deinit(gpa);
    }

    try pushRoot(io, gpa, &out, cwd);
    if (home) |h| {
        if (h.len > 0) {
            const p = try std.fs.path.join(gpa, &.{ h, instructions.user_config_dir });
            defer gpa.free(p);
            try pushRoot(io, gpa, &out, p);
        }
    }
    for (extra) |e| try pushRoot(io, gpa, &out, e);

    return out.toOwnedSlice(gpa);
}

fn pushRoot(io: Io, gpa: Allocator, out: *std.ArrayListUnmanaged([]u8), p: []const u8) !void {
    const n = try absoluteNormalized(io, gpa, p);
    errdefer gpa.free(n);
    for (out.items) |r| {
        if (std.mem.eql(u8, r, n)) {
            gpa.free(n);
            return;
        }
    }
    try out.append(gpa, n);
}

fn lessThanPath(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn addCandidate(
    io: Io,
    gpa: Allocator,
    out: *std.ArrayListUnmanaged(instructions.File),
    added: *std.ArrayListUnmanaged([]u8),
    candidate: []const u8,
    fence: Fence,
) !void {
    const resolved = try absoluteNormalized(io, gpa, candidate);
    defer gpa.free(resolved);

    // 围栏（顶层候选也都过一遍 —— 纵深防御；正常情况下它们本就在 <cwd> 内）。
    if (!fence.allows(resolved)) return;

    for (added.items) |p| {
        if (std.mem.eql(u8, p, resolved)) return;
    }

    // 一次读入同时判「存在 + 是普通文件」：目录 / 超大 / 无权限 / 竞态消失
    // 一律当作"没有这个指令文件"（不报错，与 discover 的跳过语义一致）。
    const raw = (util.fsio.readIfExists(io, gpa, resolved, instructions.max_file_bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    }) orelse return;
    defer gpa.free(raw);

    var visited = Visited{};
    defer visited.deinit(gpa);
    try visited.add(gpa, resolved);

    var body = std.ArrayListUnmanaged(u8).empty;
    errdefer body.deinit(gpa);
    try expandInto(io, gpa, &body, raw, std.fs.path.dirname(resolved) orelse "/", 0, &visited, fence);

    const text = try body.toOwnedSlice(gpa);
    errdefer gpa.free(text);
    const path = try gpa.dupe(u8, resolved);
    errdefer gpa.free(path);

    try out.append(gpa, .{ .path = path, .text = text });
    try added.append(gpa, try gpa.dupe(u8, resolved));
}

/// 展开一段文件内容（单文件截断 + `@include` 递归 + 路径围栏）。
///
/// **自递归**（不拆成两个互相调用的函数）—— 否则 Zig 会对推断错误集报
/// `dependency loop with length 2`。
fn expandInto(
    io: Io,
    gpa: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    raw: []const u8,
    base_dir: []const u8,
    depth: usize,
    visited: *Visited,
    fence: Fence,
) !void {
    // A5：单文件 > 12000 字符 → 截断 + 标记（按 code point 计）
    const cp = common.usage.countCodePoints(raw);
    const truncated = cp > instructions.max_file_chars;
    const text = if (truncated)
        common.usage.truncateCodePoints(raw, instructions.max_file_chars)
    else
        raw;

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;

        const target = parseInclude(line) orelse {
            try out.appendSlice(gpa, line);
            continue;
        };

        const inc = util.fsio.resolve(gpa, base_dir, target) catch {
            try out.appendSlice(gpa, line);
            continue;
        };
        defer gpa.free(inc);

        if (!fence.allows(inc)) {
            // ★ 越界：**不读文件**，只留诊断标记
            try out.print(gpa, "<!-- @include outside allowed root: {s} -->", .{target});
        } else if (visited.has(inc)) {
            // A5：循环
            try out.print(gpa, "<!-- circular @include skipped: {s} -->", .{target});
        } else if (depth + 1 > instructions.max_include_depth) {
            // A4：超深度**原样返回不展开**
            try out.appendSlice(gpa, line);
        } else {
            const sub = (util.fsio.readIfExists(io, gpa, inc, instructions.max_file_bytes) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            }) orelse {
                // A5：缺失（含"是目录 / 过大 / 无权限"）
                try out.print(gpa, "<!-- @include not found: {s} -->", .{target});
                continue;
            };
            defer gpa.free(sub);
            try visited.add(gpa, inc);
            try expandInto(io, gpa, out, sub, std.fs.path.dirname(inc) orelse "/", depth + 1, visited, fence);
        }
    }

    if (truncated) try out.appendSlice(gpa, "...[truncated]...");
}

/// 解析一行的 `@include` 指令，返回**去引号后的目标路径**；不是指令则 null。
///
/// A3 记录的 legacy 语法只有带引号的形式（`@include "path"`）。
/// 本实现**同时接受无引号**（取第一个空白分隔的 token）——
/// 这是刻意的超集：任务书把指令写成 `@include <path>`，
/// 而无引号接受不会破坏任何带引号的既有文件。
pub fn parseInclude(line: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, t, instructions.include_directive)) return null;
    const rest = t[instructions.include_directive.len..];
    if (rest.len == 0) return null;
    if (rest[0] != ' ' and rest[0] != '\t') return null; // `@includex` 不是指令

    const arg = std.mem.trim(u8, rest, " \t");
    if (arg.len == 0) return null;

    if (arg[0] == '"' or arg[0] == '\'') {
        const quote = arg[0];
        const close = std.mem.indexOfScalar(u8, arg[1..], quote) orelse return null;
        if (close == 0) return null;
        return arg[1 .. 1 + close];
    }

    var it = std.mem.tokenizeAny(u8, arg, " \t");
    const tok = it.next() orelse return null;
    if (tok.len == 0) return null;
    return tok;
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "instructions: 发现顺序（用户级 → 项目级 → rules/*.md 排序）" {
    var env: testutil.TestDir = undefined;
    try env.init();
    defer env.deinit();
    const io = env.io();
    const gpa = testing.allocator;

    const home = try std.fs.path.join(gpa, &.{ env.path, "home" });
    defer gpa.free(home);
    const cwd = try std.fs.path.join(gpa, &.{ env.path, "cwd" });
    defer gpa.free(cwd);
    try util.io.mkdirp(io, home);
    try util.io.mkdirp(io, cwd);

    try testutil.writeAt(io, gpa, home, ".zigent/AGENTS.md", "HOME-RULES");
    try testutil.writeAt(io, gpa, cwd, "AGENTS.md", "PROJECT-RULES");
    try testutil.writeAt(io, gpa, cwd, ".agents/rules/b.md", "RULE-B");
    try testutil.writeAt(io, gpa, cwd, ".agents/rules/a.md", "RULE-A");
    try testutil.writeAt(io, gpa, cwd, ".agents/rules/notes.txt", "NOT-MARKDOWN");

    const files = try instructions.discover(io, gpa, cwd, home);
    defer instructions.freeFiles(gpa, files);

    try testing.expectEqual(@as(usize, 4), files.len);
    try testing.expect(std.mem.endsWith(u8, files[0].path, "/home/.zigent/AGENTS.md"));
    try testing.expect(std.mem.endsWith(u8, files[1].path, "/cwd/AGENTS.md"));
    try testing.expect(std.mem.endsWith(u8, files[2].path, "/rules/a.md"));
    try testing.expect(std.mem.endsWith(u8, files[3].path, "/rules/b.md"));

    try testing.expectEqualStrings("HOME-RULES", files[0].text);
    try testing.expectEqualStrings("PROJECT-RULES", files[1].text);
    try testing.expectEqualStrings("RULE-A", files[2].text);
    try testing.expectEqualStrings("RULE-B", files[3].text);
}

test "instructions: 只认 AGENTS.md —— CLAUDE.md 与 ~/.claude 一律不读" {
    var env: testutil.TestDir = undefined;
    try env.init();
    defer env.deinit();
    const io = env.io();
    const gpa = testing.allocator;

    const home = try std.fs.path.join(gpa, &.{ env.path, "home" });
    defer gpa.free(home);
    const cwd = try std.fs.path.join(gpa, &.{ env.path, "cwd" });
    defer gpa.free(cwd);
    try util.io.mkdirp(io, home);
    try util.io.mkdirp(io, cwd);

    try testutil.writeAt(io, gpa, cwd, "CLAUDE.md", "LEGACY-PROJECT");
    try testutil.writeAt(io, gpa, home, ".claude/CLAUDE.md", "LEGACY-HOME");
    try testutil.writeAt(io, gpa, cwd, ".agents/AGENTS.md", "AGENTS-DOT-DIR-NOT-DISCOVERED");

    const files = try instructions.discover(io, gpa, cwd, home);
    defer instructions.freeFiles(gpa, files);
    try testing.expectEqual(@as(usize, 0), files.len);

    // 连"向上找父目录"也不做：把 AGENTS.md 只放在父目录
    try testutil.writeAt(io, gpa, env.path, "AGENTS.md", "PARENT");
    const files2 = try instructions.discover(io, gpa, cwd, home);
    defer instructions.freeFiles(gpa, files2);
    try testing.expectEqual(@as(usize, 0), files2.len);
}

test "instructions: home 为 null 时跳过用户级" {
    var env: testutil.TestDir = undefined;
    try env.init();
    defer env.deinit();
    const io = env.io();
    const gpa = testing.allocator;

    try testutil.writeAt(io, gpa, env.path, "AGENTS.md", "ONLY-PROJECT");
    const files = try instructions.discover(io, gpa, env.path, null);
    defer instructions.freeFiles(gpa, files);
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings("ONLY-PROJECT", files[0].text);
}

test "instructions: @include 展开（带引号 / 单引号 / 相对包含文件所在目录）" {
    var env: testutil.TestDir = undefined;
    try env.init();
    defer env.deinit();
    const io = env.io();
    const gpa = testing.allocator;

    try testutil.writeAt(io, gpa, env.path, "AGENTS.md", "HEAD\n@include \"rules/a.md\"\nTAIL");
    try testutil.writeAt(io, gpa, env.path, "rules/a.md", "A\n@include 'b.md'");
    try testutil.writeAt(io, gpa, env.path, "rules/b.md", "B");

    const files = try instructions.discover(io, gpa, env.path, null);
    defer instructions.freeFiles(gpa, files);
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings("HEAD\nA\nB\nTAIL", files[0].text);

    // 无引号写法（刻意的超集）
    const unquoted = try instructions.expandText(io, gpa, "@include rules/b.md", env.path);
    defer gpa.free(unquoted);
    try testing.expectEqualStrings("B", unquoted);

    // `@include` 后面没有参数 → 不是指令，原样保留
    const bare = try instructions.expandText(io, gpa, "@include", env.path);
    defer gpa.free(bare);
    try testing.expectEqualStrings("@include", bare);
}

test "instructions: @include 缺失文件 → 诊断标记；路径逃逸不影响本文件" {
    var env: testutil.TestDir = undefined;
    try env.init();
    defer env.deinit();
    const io = env.io();
    const gpa = testing.allocator;

    const text = try instructions.expandText(io, gpa, "A\n@include \"nope/missing.md\"\nB", env.path);
    defer gpa.free(text);
    try testing.expectEqualStrings("A\n<!-- @include not found: nope/missing.md -->\nB", text);
}

test "instructions: 循环 @include 被打断（不死循环、不重复内容）" {
    var env: testutil.TestDir = undefined;
    try env.init();
    defer env.deinit();
    const io = env.io();
    const gpa = testing.allocator;

    try testutil.writeAt(io, gpa, env.path, "AGENTS.md", "ROOT\n@include \"b.md\"");
    try testutil.writeAt(io, gpa, env.path, "b.md", "B\n@include \"AGENTS.md\"");

    const files = try instructions.discover(io, gpa, env.path, null);
    defer instructions.freeFiles(gpa, files);
    try testing.expectEqual(@as(usize, 1), files.len);

    const body = files[0].text;
    try testing.expectEqualStrings("ROOT\nB\n<!-- circular @include skipped: AGENTS.md -->", body);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "ROOT"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "B\n"));
}

test "instructions: @include 深度上限 5（超深度原样保留，不展开）" {
    var env: testutil.TestDir = undefined;
    try env.init();
    defer env.deinit();
    const io = env.io();
    const gpa = testing.allocator;

    // AGENTS.md(0) → i1(1) → i2(2) → i3(3) → i4(4) → i5(5) → i6(6, 不展开)
    try testutil.writeAt(io, gpa, env.path, "AGENTS.md", "DEPTH0\n@include \"i1.md\"");
    try testutil.writeAt(io, gpa, env.path, "i1.md", "DEPTH1\n@include \"i2.md\"");
    try testutil.writeAt(io, gpa, env.path, "i2.md", "DEPTH2\n@include \"i3.md\"");
    try testutil.writeAt(io, gpa, env.path, "i3.md", "DEPTH3\n@include \"i4.md\"");
    try testutil.writeAt(io, gpa, env.path, "i4.md", "DEPTH4\n@include \"i5.md\"");
    try testutil.writeAt(io, gpa, env.path, "i5.md", "DEPTH5\n@include \"i6.md\"");
    try testutil.writeAt(io, gpa, env.path, "i6.md", "DEPTH6-MUST-NOT-APPEAR");

    const files = try instructions.discover(io, gpa, env.path, null);
    defer instructions.freeFiles(gpa, files);
    const body = files[0].text;

    try testing.expect(contains(body, "DEPTH0"));
    try testing.expect(contains(body, "DEPTH5"));
    try testing.expect(!contains(body, "DEPTH6"));
    // A4：超深度的指令行**原样保留**
    try testing.expect(contains(body, "@include \"i6.md\""));
}

test "instructions: 单文件 > 12000 字符截断 + 标记；恰好 12000 不截断" {
    var env: testutil.TestDir = undefined;
    try env.init();
    defer env.deinit();
    const io = env.io();
    const gpa = testing.allocator;

    const exact = try gpa.alloc(u8, instructions.max_file_chars);
    defer gpa.free(exact);
    @memset(exact, 'x');
    try testutil.writeAt(io, gpa, env.path, "AGENTS.md", exact);

    const files = try instructions.discover(io, gpa, env.path, null);
    defer instructions.freeFiles(gpa, files);
    try testing.expectEqual(instructions.max_file_chars, common.usage.countCodePoints(files[0].text));
    try testing.expect(!contains(files[0].text, "[truncated]"));

    const over = try gpa.alloc(u8, instructions.max_file_chars + 1);
    defer gpa.free(over);
    @memset(over, 'x');
    try testutil.writeAt(io, gpa, env.path, "AGENTS.md", over);

    const files2 = try instructions.discover(io, gpa, env.path, null);
    defer instructions.freeFiles(gpa, files2);
    try testing.expect(std.mem.endsWith(u8, files2[0].text, "...[truncated]..."));
    try testing.expectEqual(
        instructions.max_file_chars + "...[truncated]...".len,
        common.usage.countCodePoints(files2[0].text),
    );
}

test "instructions: render 的文件边界与包裹格式" {
    var env: testutil.TestDir = undefined;
    try env.init();
    defer env.deinit();
    const io = env.io();
    const gpa = testing.allocator;

    try testutil.writeAt(io, gpa, env.path, "AGENTS.md", "PROJECT");
    try testutil.writeAt(io, gpa, env.path, ".agents/rules/a.md", "RULE\n");

    const files = try instructions.discover(io, gpa, env.path, null);
    defer instructions.freeFiles(gpa, files);

    const block = try instructions.render(gpa, files);
    defer gpa.free(block);

    try testing.expect(std.mem.startsWith(u8, block, "# Project Instructions\n"));
    for (files) |f| {
        try testing.expect(contains(block, f.path));
    }
    try testing.expect(contains(block, "\n## "));
    try testing.expect(contains(block, "```md\nPROJECT\n```\n"));
    try testing.expect(contains(block, "```md\nRULE\n```\n"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, block, "```md"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, block, "\n```\n"));

    const empty = try instructions.render(gpa, &.{});
    defer gpa.free(empty);
    try testing.expectEqualStrings("", empty);
}

test "instructions: parseInclude 的边界" {
    try testing.expectEqualStrings("a.md", parseInclude("@include \"a.md\"").?);
    try testing.expectEqualStrings("a.md", parseInclude("  @include 'a.md'  ").?);
    try testing.expectEqualStrings("a.md", parseInclude("@include a.md").?);
    try testing.expectEqualStrings("a b.md", parseInclude("@include \"a b.md\" extra comment").?);
    try testing.expect(parseInclude("@includex a.md") == null);
    try testing.expect(parseInclude("@include") == null);
    try testing.expect(parseInclude("@include   ") == null);
    try testing.expect(parseInclude("text @include \"a.md\"") == null);
}

// ── 路径围栏（Task B）────────────────────────────────────────────────────────

test "instructions: Fence 的词法判定（前缀边界、根 = / 的退化情形）" {
    const roots = [_][]const u8{ "/a/b", "/home/me/.zigent" };
    const f = Fence{ .roots = &roots };

    try testing.expect(f.allows("/a/b"));
    try testing.expect(f.allows("/a/b/c/d.md"));
    try testing.expect(f.allows("/home/me/.zigent/AGENTS.md"));
    // 前缀陷阱：/a/bc 不是 /a/b 的子路径
    try testing.expect(!f.allows("/a/bc"));
    try testing.expect(!f.allows("/a"));
    try testing.expect(!f.allows("/etc/passwd"));
    try testing.expect(!f.allows("/home/me/.ssh/id_rsa"));

    const root = [_][]const u8{"/"};
    try testing.expect((Fence{ .roots = &root }).allows("/etc/passwd"));
}

test "instructions: @include 逃出 cwd → 只留标记、绝不读文件" {
    var env: testutil.TestDir = undefined;
    try env.init();
    defer env.deinit();
    const io = env.io();
    const gpa = testing.allocator;

    const cwd = try std.fs.path.join(gpa, &.{ env.path, "cwd" });
    defer gpa.free(cwd);
    try util.io.mkdirp(io, cwd);

    // 机密文件在 cwd **外面**（但仍在临时沙箱里，测试可移植）
    try testutil.writeAt(io, gpa, env.path, "secret.md", "TOP-SECRET-OUTSIDE");
    try testutil.writeAt(io, gpa, cwd, "AGENTS.md", "ROOT\n@include \"../secret.md\"");

    const files = try instructions.discover(io, gpa, cwd, null);
    defer instructions.freeFiles(gpa, files);
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expect(contains(files[0].text, "<!-- @include outside allowed root: ../secret.md -->"));
    try testing.expect(!contains(files[0].text, "TOP-SECRET-OUTSIDE"));
}

test "instructions: 相对 ../../../../etc/passwd 与绝对 /etc/passwd 都被拒绝" {
    var env: testutil.TestDir = undefined;
    try env.init();
    defer env.deinit();
    const io = env.io();
    const gpa = testing.allocator;

    const cwd = try std.fs.path.join(gpa, &.{ env.path, "cwd" });
    defer gpa.free(cwd);
    try util.io.mkdirp(io, cwd);

    try testutil.writeAt(io, gpa, cwd, "AGENTS.md",
        "A\n@include \"../../../../etc/passwd\"\nB\n@include \"/etc/passwd\"\nC");

    const files = try instructions.discover(io, gpa, cwd, null);
    defer instructions.freeFiles(gpa, files);
    const body = files[0].text;

    // 逐字节断言：两个越界指令都没被替换成任何文件内容
    try testing.expectEqualStrings(
        "A\n" ++
            "<!-- @include outside allowed root: ../../../../etc/passwd -->\n" ++
            "B\n" ++
            "<!-- @include outside allowed root: /etc/passwd -->\n" ++
            "C",
        body,
    );
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "outside allowed root"));
}

test "instructions: `..` 只要还在 cwd 内就允许展开" {
    var env: testutil.TestDir = undefined;
    try env.init();
    defer env.deinit();
    const io = env.io();
    const gpa = testing.allocator;

    const cwd = try std.fs.path.join(gpa, &.{ env.path, "cwd" });
    defer gpa.free(cwd);
    try util.io.mkdirp(io, cwd);

    // <cwd>/.agents/rules/a.md --../shared.md--> <cwd>/.agents/shared.md（在 cwd 内 ✓）
    try testutil.writeAt(io, gpa, cwd, ".agents/rules/a.md", "A\n@include \"../shared.md\"");
    try testutil.writeAt(io, gpa, cwd, ".agents/shared.md", "SHARED-INSIDE-CWD");

    const files = try instructions.discover(io, gpa, cwd, null);
    defer instructions.freeFiles(gpa, files);
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings("A\nSHARED-INSIDE-CWD", files[0].text);
    try testing.expect(!contains(files[0].text, "outside allowed root"));
}

test "instructions: home 侧的围栏根 = <home>/.zigent" {
    var env: testutil.TestDir = undefined;
    try env.init();
    defer env.deinit();
    const io = env.io();
    const gpa = testing.allocator;

    const home = try std.fs.path.join(gpa, &.{ env.path, "home" });
    defer gpa.free(home);
    const cwd = try std.fs.path.join(gpa, &.{ env.path, "cwd" });
    defer gpa.free(cwd);
    try util.io.mkdirp(io, cwd);

    // 用户级文件 include 同目录的 extra.md → 落在 <home>/.zigent 内 ✓
    // 它再 include danger.md（同目录，✓），danger.md 往 <home>/.ssh 逃 → 越界 ✗
    try testutil.writeAt(io, gpa, home, ".zigent/AGENTS.md",
        "HOME\n@include \"extra.md\"\n@include \"danger.md\"");
    try testutil.writeAt(io, gpa, home, ".zigent/extra.md", "HOME-EXTRA");
    try testutil.writeAt(io, gpa, home, ".zigent/danger.md", "D\n@include \"../.ssh/id_rsa\"");
    try testutil.writeAt(io, gpa, home, ".ssh/id_rsa", "PRIVATE-KEY-MUST-NOT-LEAK");

    const files = try instructions.discover(io, gpa, cwd, home);
    defer instructions.freeFiles(gpa, files);
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings(
        "HOME\nHOME-EXTRA\nD\n<!-- @include outside allowed root: ../.ssh/id_rsa -->",
        files[0].text,
    );
    try testing.expect(!contains(files[0].text, "PRIVATE-KEY-MUST-NOT-LEAK"));
}

test "instructions: discoverFenced 的 extra_roots 能放行 cwd 之外的公共规则" {
    var env: testutil.TestDir = undefined;
    try env.init();
    defer env.deinit();
    const io = env.io();
    const gpa = testing.allocator;

    const cwd = try std.fs.path.join(gpa, &.{ env.path, "cwd" });
    defer gpa.free(cwd);
    try util.io.mkdirp(io, cwd);

    try testutil.writeAt(io, gpa, env.path, "shared/common.md", "SHARED-RULES");
    try testutil.writeAt(io, gpa, cwd, "AGENTS.md", "ROOT\n@include \"../shared/common.md\"");

    // 4 参形式：默认根 = [cwd] → 越界
    const strict = try instructions.discover(io, gpa, cwd, null);
    defer instructions.freeFiles(gpa, strict);
    try testing.expect(contains(strict[0].text, "outside allowed root"));
    try testing.expect(!contains(strict[0].text, "SHARED-RULES"));

    // discoverFenced + extra_roots = <env> → 放行且真的展开
    const extra = [_][]const u8{env.path};
    const relaxed = try instructions.discoverFenced(io, gpa, cwd, null, .{ .extra_roots = &extra });
    defer instructions.freeFiles(gpa, relaxed);
    try testing.expect(contains(relaxed[0].text, "SHARED-RULES"));
    try testing.expect(!contains(relaxed[0].text, "outside allowed root"));

    // 引擎现用的 4 参调用形式必须继续可用（不破坏既有调用点）
    const still_works = try instructions.discover(io, gpa, cwd, null);
    defer instructions.freeFiles(gpa, still_works);
    try testing.expectEqual(@as(usize, 1), still_works.len);
}
