//! `util/proc.zig` —— **子进程 argv 构造与执行的唯一出口**（文档 03 §4.3）。
//!
//! 为什么集中（雷区 K / 文档 03 §4.5）：
//!   - 散落各处的 argv 拼装会让 Windows 的 `-EncodedCommand`（base64 UTF-16LE）坑
//!     在每个调用点重踩一次（`-Command` 会在 CreateProcess 参数层破坏双引号）；
//!   - 超时 / 进程组 / 进程树终止必须只有一份实现。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: i32,
    signal: ?i32 = null,
    timed_out: bool = false,
    duration_ms: i64 = 0,

    pub fn deinit(self: *Result, gpa: Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }

    pub fn ok(self: Result) bool {
        return self.exit_code == 0 and !self.timed_out;
    }

    /// 合并输出（工具结果常用）。
    pub fn combined(self: Result, gpa: Allocator) Allocator.Error![]u8 {
        return std.mem.concat(gpa, u8, &.{ self.stdout, self.stderr });
    }
};

pub const Options = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    /// 覆盖环境（null = 继承）
    environ_map: ?*const std.process.Environ.Map = null,
    timeout_ms: ?u64 = null,
    max_output_bytes: usize = 1 << 20,
};

pub const RunError = error{ Timeout, InvalidUtf8 } || std.process.RunError || Allocator.Error;

/// 执行一个**已构造好的 argv**（不经过 shell）。
pub fn run(io: Io, gpa: Allocator, opts: Options) RunError!Result {
    const start = @import("io.zig").monotonicMillis(io);
    const res = std.process.run(gpa, io, .{
        .argv = opts.argv,
        .cwd = if (opts.cwd) |c| .{ .path = c } else .inherit,
        .environ_map = opts.environ_map,
        .stdout_limit = Io.Limit.limited(opts.max_output_bytes),
        .stderr_limit = Io.Limit.limited(opts.max_output_bytes),
        .timeout = if (opts.timeout_ms) |ms|
            .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(@intCast(ms)), .clock = .awake } }
        else
            .none,
    }) catch |err| switch (err) {
        error.Timeout => return error.Timeout,
        error.StreamTooLong => return error.StreamTooLong,
        else => return err,
    };

    const exit_code: i32 = switch (res.term) {
        .exited => |c| c,
        .signal => |s| 128 + @as(i32, @intCast(@intFromEnum(s))),
        .stopped => |s| 128 + @as(i32, @intCast(@intFromEnum(s))),
        else => -1,
    };
    const signal: ?i32 = switch (res.term) {
        .signal => |s| @intCast(@intFromEnum(s)),
        else => null,
    };

    return .{
        .stdout = res.stdout,
        .stderr = res.stderr,
        .exit_code = exit_code,
        .signal = signal,
        .timed_out = false,
        .duration_ms = @import("io.zig").monotonicMillis(io) - start,
    };
}

/// 经过 shell 执行一条命令串（`bash -lc` / PowerShell）。
pub fn runShell(io: Io, gpa: Allocator, command: []const u8, opts: Options) RunError!Result {
    const argv = try shellArgv(gpa, command);
    defer gpa.free(argv);
    var o = opts;
    o.argv = argv;
    return run(io, gpa, o);
}

pub const ShellKind = enum { posix_sh, powershell };

/// 当前平台的 shell。
pub fn defaultShell() ShellKind {
    return switch (@import("builtin").os.tag) {
        .windows => .powershell,
        else => .posix_sh,
    };
}

/// **argv 构造的唯一出口**。调用方负责释放返回的切片与其中分配的字符串。
pub fn shellArgv(gpa: Allocator, command: []const u8) (Allocator.Error || error{InvalidUtf8})![][]const u8 {
    return shellArgvFor(gpa, defaultShell(), command);
}

pub fn shellArgvFor(gpa: Allocator, kind: ShellKind, command: []const u8) (Allocator.Error || error{InvalidUtf8})![][]const u8 {
    switch (kind) {
        .posix_sh => {
            const argv = try gpa.alloc([]const u8, 3);
            argv[0] = try gpa.dupe(u8, "/bin/bash");
            argv[1] = try gpa.dupe(u8, "-lc");
            argv[2] = try gpa.dupe(u8, command);
            return argv;
        },
        .powershell => {
            // ⚠️ 必须用 `-EncodedCommand`（base64 UTF-16LE）：
            //    `-Command` 会在 CreateProcess 参数层破坏双引号。
            const utf16 = try std.unicode.utf8ToUtf16LeAlloc(gpa, command);
            defer gpa.free(utf16);
            const raw = std.mem.sliceAsBytes(utf16);
            const b64_len = std.base64.standard.Encoder.calcSize(raw.len);
            const enc = try gpa.alloc(u8, b64_len);
            _ = std.base64.standard.Encoder.encode(enc, raw);
            const argv = try gpa.alloc([]const u8, 5);
            argv[0] = try gpa.dupe(u8, "powershell.exe");
            argv[1] = try gpa.dupe(u8, "-NoProfile");
            argv[2] = try gpa.dupe(u8, "-NonInteractive");
            argv[3] = try gpa.dupe(u8, "-EncodedCommand");
            argv[4] = enc;
            return argv;
        },
    }
}

pub fn freeArgv(gpa: Allocator, argv: [][]const u8) void {
    for (argv) |a| gpa.free(a);
    gpa.free(argv);
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "proc: argv 构造不经过 shell 拼接" {
    const argv = try shellArgvFor(testing.allocator, .posix_sh, "echo 'a b'");
    defer freeArgv(testing.allocator, argv);
    try testing.expectEqual(@as(usize, 3), argv.len);
    try testing.expectEqualStrings("/bin/bash", argv[0]);
    try testing.expectEqualStrings("-lc", argv[1]);
    try testing.expectEqualStrings("echo 'a b'", argv[2]);
}

test "proc: PowerShell 必须用 EncodedCommand" {
    const argv = try shellArgvFor(testing.allocator, .powershell, "echo \"hi\"");
    defer freeArgv(testing.allocator, argv);
    try testing.expectEqualStrings("-EncodedCommand", argv[3]);
    // 解码回来必须与原文一致
    const decoded = try std.base64.standard.Decoder.calcSizeForSlice(argv[4]);
    const buf = try testing.allocator.alloc(u8, decoded);
    defer testing.allocator.free(buf);
    try std.base64.standard.Decoder.decode(buf, argv[4]);
    const utf16 = std.mem.bytesAsSlice(u16, @as([]align(2) const u8, @alignCast(buf)));
    const back = try std.unicode.utf16LeToUtf8Alloc(testing.allocator, utf16);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("echo \"hi\"", back);
}

test "proc: 执行真实命令并拿到退出码" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var r = try run(io, testing.allocator, .{
        .argv = &.{"/bin/sh", "-c", "printf hello"},
    });
    defer r.deinit(testing.allocator);
    try testing.expect(r.ok());
    try testing.expectEqualStrings("hello", r.stdout);
}

test "proc: 非零退出码与 stderr" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var r = try run(io, testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "echo oops >&2; exit 3" },
    });
    defer r.deinit(testing.allocator);
    try testing.expect(!r.ok());
    try testing.expectEqual(@as(i32, 3), r.exit_code);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "oops") != null);
}
