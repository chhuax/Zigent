//! `tools/sys.zig` —— **`util/` 的薄门面**（facade），不是第二份实现。
//!
//! 单一 OS 边界纪律：系统级原语只允许住在 `util/io.zig` / `util/fsio.zig` /
//! `util/proc.zig`。`tools/` 的工具代码只调本文件，本文件**几乎全部**是
//! `pub const X = util.<mod>.X;` 形式的转发 —— 名字与调用点保持一致，
//! 换 util 实现时工具代码零改动。
//!
//! ⚠️ **唯一一处工具本地实现：`mtimeMs`**。`util/io.zig` 目前没有暴露
//! `stat` / mtime 原语（只有 read/write/exists/isDir），而 `Glob` 的契约要求
//! 「按修改时间倒序」，所以这里补一个最小实现（`std.Io.Dir.cwd().statFile`）。
//! 它应当被视为 util 的缺口：**将来 util.io 补上 `mtimeMs(io, path) ?i64`
//! 后，本文件把这一行换成转发即可。**
//!
//! `runShell` 也保留一个薄包装：调用点用的是 `{cwd, timeout_ms, max_output_bytes}`
//! 三字段，而 `util.proc.runShell` 的 `Options` 多一个 `argv`（它内部会覆盖）。
//! 包装只做字段搬运，**argv 构造仍然完全由 `util.proc.shellArgv` 负责**
//! （Windows 的 `-EncodedCommand` 坑只有一份实现）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const util = @import("util");

// ── 整模块转发（需要时可直接 `sys.io.xxx` / `sys.fsio.xxx` / `sys.proc.xxx`）──
pub const io = util.io;
pub const fsio = util.fsio;
pub const proc = util.proc;

// ── 路径（`util/fsio.zig`）──
pub const normalize = util.fsio.normalize;
pub const resolve = util.fsio.resolve;
pub const isWithin = util.fsio.isWithin;
pub const resolveWithin = util.fsio.resolveWithin;

// ── glob 与目录遍历（`util/fsio.zig`）──
pub const globMatch = util.fsio.globMatch;
pub const WalkOptions = util.fsio.WalkOptions;
pub const collectFiles = util.fsio.collectFiles;
pub const freePaths = util.fsio.freePaths;
pub const readIfExists = util.fsio.readIfExists;

// ── 文件（`util/io.zig`）──
pub const readFileAlloc = util.io.readFileAlloc;
pub const writeFile = util.io.writeFile;
pub const appendFile = util.io.appendFile;
pub const atomicWrite = util.io.atomicWrite;
pub const exists = util.io.exists;
pub const isDir = util.io.isDir;
pub const mkdirp = util.io.mkdirp;
pub const deleteFile = util.io.deleteFile;
pub const removeTree = util.io.removeTree;
pub const randomHex = util.io.randomHex;

// ── 进程（`util/proc.zig`）──
pub const Result = util.proc.Result;
pub const RunError = util.proc.RunError;
pub const ShellKind = util.proc.ShellKind;
pub const defaultShell = util.proc.defaultShell;
pub const shellArgv = util.proc.shellArgv;
pub const shellArgvFor = util.proc.shellArgvFor;
pub const freeArgv = util.proc.freeArgv;
pub const run = util.proc.run;

/// 调用点用的三字段选项（argv 由 `util.proc.shellArgv` 内部构造）。
pub const Options = struct {
    cwd: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
    max_output_bytes: usize = 1 << 20,
};

/// 经 shell 执行一条命令串（`bash -lc` / PowerShell `-EncodedCommand`）。
///
/// ⚠️ 这里组合 `util.proc.shellArgv` + `util.proc.run`，**而不是**直接调
/// `util.proc.runShell`：后者当前的 `RunError` 少了 `error.InvalidUtf8`
/// （`util/proc.zig:88` 的 `try shellArgv(...)` 因此在其函数体被分析时编译失败）。
/// argv 构造仍然**唯一**在 `util.proc.shellArgv`，本函数只做搬运。
/// util 修掉 `RunError` 后，这里可以换成一行 `return util.proc.runShell(...)`。
pub fn runShell(io_: Io, gpa: Allocator, command: []const u8, opts: Options) (RunError || error{InvalidUtf8})!Result {
    const argv = try util.proc.shellArgv(gpa, command);
    defer util.proc.freeArgv(gpa, argv);
    return util.proc.run(io_, gpa, .{
        .argv = argv,
        .cwd = opts.cwd,
        .timeout_ms = opts.timeout_ms,
        .max_output_bytes = opts.max_output_bytes,
    });
}

// ── util 目前没有、但 Glob 需要的 ──

/// 文件 mtime（毫秒）；取不到返回 0（排序时排到最后）。
/// ⚠️ 见文件头：这是 util.io 的缺口，目前只能在这里用 `std.Io.Dir` 直接 stat。
pub fn mtimeMs(io_: Io, path: []const u8) i64 {
    // 委托给 util.io（唯一的 OS 边界）：不存在 → 0（排序时排最后）
    return util.io.mtimeMs(io_, path) orelse 0;
}

/// 测试用：在 `/tmp` 下建一个**本测试独占**的目录，返回其路径。
/// 每个触碰文件系统的测试都必须自己建一个，并在结束时 `removeTree`。
pub fn makeTestDir(io_: Io, gpa: Allocator, tag: []const u8) ![]u8 {
    const rnd = try util.io.randomHex(io_, gpa, 6);
    defer gpa.free(rnd);
    const dir = try std.fmt.allocPrint(gpa, "/tmp/zigent-tools-test-{s}-{s}", .{ tag, rnd });
    try util.io.mkdirp(io_, dir);
    return dir;
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试：门面必须**真的委托** util，且不引入第二份语义
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "sys: 门面逐项委托 util（函数类型逐字相同，没有本地副本）" {
    // 用函数类型相等证明「就是 util 的那个函数」，而不是同名重写。
    try testing.expect(@TypeOf(globMatch) == @TypeOf(util.fsio.globMatch));
    try testing.expect(@TypeOf(collectFiles) == @TypeOf(util.fsio.collectFiles));
    try testing.expect(@TypeOf(resolve) == @TypeOf(util.fsio.resolve));
    try testing.expect(@TypeOf(resolveWithin) == @TypeOf(util.fsio.resolveWithin));
    try testing.expect(@TypeOf(readFileAlloc) == @TypeOf(util.io.readFileAlloc));
    try testing.expect(@TypeOf(atomicWrite) == @TypeOf(util.io.atomicWrite));
    try testing.expect(@TypeOf(mkdirp) == @TypeOf(util.io.mkdirp));
    try testing.expect(@TypeOf(removeTree) == @TypeOf(util.io.removeTree));

    // 函数指针相等（同一份机器码）
    try testing.expect(&globMatch == &util.fsio.globMatch);
    try testing.expect(&collectFiles == &util.fsio.collectFiles);
    try testing.expect(&readFileAlloc == &util.io.readFileAlloc);
    try testing.expect(&shellArgv == &util.proc.shellArgv);
}

test "sys: collectFiles 产出绝对路径 —— Glob/Grep 直接消费的就是它" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io_ = threaded.io();

    const dir = try makeTestDir(io_, testing.allocator, "facade");
    defer testing.allocator.free(dir);
    defer removeTree(io_, dir) catch {};

    const nested = try std.fs.path.join(testing.allocator, &.{ dir, "sub/file.txt" });
    defer testing.allocator.free(nested);
    try mkdirp(io_, std.fs.path.dirname(nested).?);
    try writeFile(io_, nested, "x");

    const found = try collectFiles(io_, testing.allocator, dir, .{});
    defer freePaths(testing.allocator, found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expect(std.fs.path.isAbsolute(found[0]));
    try testing.expect(std.mem.startsWith(u8, found[0], dir));
    // 与 util 的直接调用必须给出同一结果（门面不改变语义）
    const direct = try util.fsio.collectFiles(io_, testing.allocator, dir, .{});
    defer util.fsio.freePaths(testing.allocator, direct);
    try testing.expectEqualStrings(found[0], direct[0]);
}

test "sys: 归一化/越界仍按 util 语义" {
    const a = try normalize(testing.allocator, "/a/b/../c/./d//");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/a/c/d", a);
    try testing.expect(isWithin("/a/b", "/a/b/c"));
    try testing.expect(!isWithin("/a/b", "/a/bc"));
    const ok = try resolveWithin(testing.allocator, "/repo", "src/a.zig");
    defer if (ok) |p| testing.allocator.free(p);
    try testing.expectEqualStrings("/repo/src/a.zig", ok.?);
    try testing.expect((try resolveWithin(testing.allocator, "/repo", "../etc/passwd")) == null);
}

test "sys: globMatch 仍是 util 的 * 不跨目录 / ** 跨目录" {
    try testing.expect(globMatch("**/*.zig", "src/deep/a.zig"));
    try testing.expect(globMatch("*.zig", "a.zig"));
    try testing.expect(!globMatch("*.zig", "src/a.zig"));
    try testing.expect(globMatch("[abc]x", "bx"));
}

test "sys: 原子写 + 读回 + mtime（自建 /tmp 目录并清理）" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io_ = threaded.io();

    const dir = try makeTestDir(io_, testing.allocator, "sys");
    defer testing.allocator.free(dir);
    defer removeTree(io_, dir) catch {};

    const path = try std.fs.path.join(testing.allocator, &.{ dir, "nested/file.txt" });
    defer testing.allocator.free(path);
    try mkdirp(io_, std.fs.path.dirname(path).?);
    try atomicWrite(io_, testing.allocator, path, "hello 世界");

    const back = try readFileAlloc(io_, testing.allocator, path, 1024);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("hello 世界", back);
    try testing.expect(exists(io_, path));
    try testing.expect(mtimeMs(io_, path) > 0);
}

test "sys: runShell 包装器保持 util 的退出码/stderr 语义" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io_ = threaded.io();
    var r = try runShell(io_, testing.allocator, "echo oops >&2; exit 3", .{ .timeout_ms = 30_000 });
    defer r.deinit(testing.allocator);
    try testing.expect(!r.ok());
    try testing.expectEqual(@as(i32, 3), r.exit_code);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "oops") != null);
}
