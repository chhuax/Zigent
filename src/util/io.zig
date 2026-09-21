//! `util/io.zig` —— **`std.Io` 的唯一适配层**（WP-01，文档 11 §5）。
//!
//! 规则：**除本文件外，任何模块不得直接调用 `std.Io` 的系统级原语**
//! （socket / listen / accept / file open / process spawn / sleep）。
//! 允许直接使用 `Io` 的"值语义"接口（`Mutex` / `Condition` / `Queue`）—— 那部分稳定。
//!
//! 价值：Zig 0.16 已把 `std.Thread.Mutex`、`std.crypto.random`、`std.posix.getenv`、
//! `std.fs.File` 全部搬进 `std.Io`；0.17/0.18 再变只改这一个文件。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

// ── 时间 ─────────────────────────────────────────────────────────────────────

/// 延迟（替代已删除的 `std.Thread.sleep`）。
pub fn sleep(io: Io, millis: u64) Io.Cancelable!void {
    try std.Io.sleep(io, .{ .nanoseconds = @as(i96, millis) * std.time.ns_per_ms }, .awake);
}

/// 单调时钟毫秒（用于耗时统计）。
pub fn monotonicMillis(io: Io) i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// 墙钟 epoch 毫秒（用于时间戳落盘）。
pub fn epochMillis(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toMilliseconds();
}

/// ISO-8601（UTC，毫秒精度）—— 事件信封的 `timestamp` 契约。
pub fn formatIso8601(buf: []u8, epoch_ms: i64) []const u8 {
    const ms_total = epoch_ms;
    const secs = @divFloor(ms_total, 1000);
    const ms: u32 = @intCast(@mod(ms_total, 1000));
    const days = @divFloor(secs, 86400);
    const secs_of_day: u32 = @intCast(@mod(secs, 86400));
    const hh = secs_of_day / 3600;
    const mm = (secs_of_day % 3600) / 60;
    const ss = secs_of_day % 60;
    const c = civilFromDays(days);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        @as(u64, @intCast(@max(c.year, 0))), c.month, c.day, hh, mm, ss, ms,
    }) catch buf[0..0];
}

const Civil = struct { year: i64, month: u32, day: u32 };

/// Howard Hinnant 的 civil_from_days。
fn civilFromDays(z_in: i64) Civil {
    var z = z_in;
    z += 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u32 = @intCast(doy - (153 * mp + 2) / 5 + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = if (m <= 2) y + 1 else y, .month = m, .day = d };
}

// ── 随机 ─────────────────────────────────────────────────────────────────────

/// 随机字节（替代已删除的 `std.crypto.random`）。
pub fn randomBytes(io: Io, buf: []u8) void {
    io.random(buf);
}

const hex_digits = "0123456789abcdef";

/// 随机 hex 串（token / id / 临时名）。
pub fn randomHex(io: Io, gpa: Allocator, n_bytes: usize) Allocator.Error![]u8 {
    const raw = try gpa.alloc(u8, n_bytes);
    defer gpa.free(raw);
    randomBytes(io, raw);
    const out = try gpa.alloc(u8, n_bytes * 2);
    for (raw, 0..) |b, i| {
        out[i * 2] = hex_digits[b >> 4];
        out[i * 2 + 1] = hex_digits[b & 0x0F];
    }
    return out;
}

// ── 常量时间比较 ─────────────────────────────────────────────────────────────

/// 替代已改名的 `std.crypto.utils.timingSafeEql`。
pub fn timingSafeEql(comptime T: type, a: T, b: T) bool {
    return std.crypto.timing_safe.eql(T, a, b);
}

/// 常量时间比较两段字节（长度不等直接 false —— 长度本身不是秘密）。
pub fn timingSafeEqlSlice(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var acc: u8 = 0;
    for (a, b) |x, y| acc |= x ^ y;
    return acc == 0;
}

// ── 环境变量 ─────────────────────────────────────────────────────────────────

/// 主机名（`enc:1:` 的 passphrase 参与派生；**改主机名会导致旧密文解不开**）。
///
/// ⚠️ 这是 `std.posix` 在本仓库的**第二个（也是最后一个）**合法使用点，
/// 所以它必须留在这个隔离层文件里，而不是散落到 `config/secret.zig`。
pub fn gethostname(io: Io, gpa: Allocator) ![]u8 {
    _ = io;
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const name = std.posix.gethostname(&buf) catch return gpa.dupe(u8, "unknown-host");
    return gpa.dupe(u8, name);
}

/// 读环境变量（替代已删除的 `std.posix.getenv`）。
/// `env` 由 `main(init: std.process.Init)` 构造并随 `Rt` 下传（**不要全局单例**）。
pub fn getEnv(env: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    return env.get(key);
}

/// 读环境变量并解析成整数，带默认值。
pub fn getEnvInt(env: *const std.process.Environ.Map, key: []const u8, default: i64) i64 {
    const s = getEnv(env, key) orelse return default;
    return std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t\r\n"), 10) catch default;
}

// ── 文件 ─────────────────────────────────────────────────────────────────────

pub const FileError = error{
    NotFound,
    AccessDenied,
    IsDir,
    FileTooBig,
    OutOfMemory,
} || std.Io.Dir.OpenError || std.Io.File.ReadStreamingError || std.Io.File.WriteStreamingError;

/// 读整个文件（绝对路径）。`max_bytes` 防止把超大文件读进内存。
pub fn readFileAlloc(io: Io, gpa: Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const len = try file.length(io);
    if (len > max_bytes) return error.FileTooBig;
    const buf = try gpa.alloc(u8, @intCast(len));
    errdefer gpa.free(buf);
    var reader = file.reader(io, &.{});
    try reader.interface.readSliceAll(buf);
    return buf;
}

/// 写整个文件（绝对路径，截断）。
pub fn writeFile(io: Io, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer file.close(io);
    var writer = file.writer(io, &.{});
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

/// 追加写（transcript JSONL 用）。
///
/// **为什么是"读长度 + 定位写"而不是 O_APPEND**：0.16 的 `Io.File` 既没有
/// `seekTo`，`OpenFileOptions.Mode` 也只有 `{read_only, write_only, read_write}`
/// —— 没有 append 模式。所以只能自己取当前长度当 offset。
///
/// ⚠️ **`length` + `writePositionalAll` 这两步不是原子的**，必须靠 `lock` 兜底：
/// 两个写者同时读到同一个 offset，就会把对方的记录**覆盖掉**（不是交错，是丢数据）。
/// transcript 正好是最可能被并发写的文件，而文档 04 §9 要求
/// `tool_use` / `tool_result` 成对落盘，丢一条就破坏配对不变量。
///
/// `lock = .exclusive` 由 `OpenFileOptions` 提供，在 Darwin/BSD 上**与 open 原子地
/// 获取**（Linux/Windows 是 open 之后补一次系统调用，仍然安全）。
///
/// 📌 **这把锁是 advisory（劝告锁）**：只能挡住同样走这个函数的写者。
/// 外部进程若直接写同一个文件，锁不会拦它 —— 这是操作系统语义，不是本函数的缺陷。
pub fn appendFile(io: Io, path: []const u8, bytes: []const u8) !void {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{
        .mode = .write_only,
        .lock = .exclusive,
    }) catch |err| switch (err) {
        // `truncate` 在 CreateFileOptions 里**默认是 true**，追加语义下必须显式关掉：
        // 从上面 FileNotFound 到这里之间，别的进程可能刚好把文件建好并写了内容，
        // 默认值会把它清空。
        error.FileNotFound => try std.Io.Dir.createFileAbsolute(io, path, .{
            .truncate = false,
            .lock = .exclusive,
        }),
        else => return err,
    };
    // close 会一并释放上面的 advisory 锁，所以临界区正好是 length+write 这一段。
    defer file.close(io);
    const off = try file.length(io);
    try file.writePositionalAll(io, bytes, off);
}

/// **原子写**：临时文件 + rename。
///
/// 为什么必须原子（文档 04 §9 破坏窗口 1）：assistant(tool_use) 与紧邻
/// user(tool_result) 要么都在、要么都不在，**不存在中间态**。
pub fn atomicWrite(io: Io, gpa: Allocator, path: []const u8, bytes: []const u8) !void {
    const suffix = try randomHex(io, gpa, 6);
    defer gpa.free(suffix);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp-{s}", .{ path, suffix });
    defer gpa.free(tmp);
    try writeFile(io, tmp, bytes);
    std.Io.Dir.renameAbsolute(tmp, path, io) catch |err| {
        std.Io.Dir.deleteFileAbsolute(io, tmp) catch {};
        return err;
    };
}

/// 文件 mtime（epoch 毫秒）。文件不存在 → null。
/// （`tools/` 的 Glob 需要按 mtime 倒序，这是它唯一的 stat 需求。）
pub fn mtimeMs(io: Io, path: []const u8) ?i64 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const st = std.Io.File.stat(file, io) catch return null;
    return st.mtime.toMilliseconds();
}

pub fn exists(io: Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

pub fn isDir(io: Io, path: []const u8) bool {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    defer file.close(io);
    return (std.Io.File.stat(file, io) catch return false).kind == .directory;
}

/// 递归建目录（`mkdir -p`）。
/// 把绝对路径拆成「可直接 open 的根目录」+「相对该根的剩余部分」。
///
/// 📌 **根不能硬编码成 `"/"`**（这里原来就是这么写的）：那在 POSIX 上对，
/// 在 Windows 上会把 `C:\Users\me` 当成根目录下名为 `C:\Users\me` 的相对路径。
/// POSIX 的根固定是 `/`；Windows 的根是盘符（`C:\`）或 UNC 共享（`\\srv\share\`），
/// 由 `diskDesignator` 给出（它在 POSIX 上恒返回空串）。
///
/// ⚠️ Windows 分支**未经实机验证**（AGENTS.md 决策 #6：Windows/WSL 延后）。
/// 它的价值在于形状正确 —— 宁可现在就不做错，也不要留一个静默走错根的实现。
fn splitAbsoluteRoot(path: []const u8) struct { root: []const u8, rest: []const u8 } {
    const disk = std.fs.path.diskDesignator(path);
    if (disk.len == 0) return .{ .root = "/", .rest = std.mem.trimStart(u8, path, "/") };
    // 根要带上紧跟盘符的那个分隔符（`C:` 与 `C:\` 语义不同：前者是「该盘当前目录」）。
    const after = path[disk.len..];
    const rest = std.mem.trimStart(u8, after, "/\\");
    const root_len = disk.len + (after.len - rest.len);
    return .{ .root = path[0..root_len], .rest = rest };
}

pub fn mkdirp(io: Io, path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        const split = splitAbsoluteRoot(path);
        var root = try std.Io.Dir.openDirAbsolute(io, split.root, .{});
        defer root.close(io);
        try std.Io.Dir.createDirPath(root, io, split.rest);
    } else {
        try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, path);
    }
}

pub fn deleteFile(io: Io, path: []const u8) !void {
    try std.Io.Dir.deleteFileAbsolute(io, path);
}

/// 递归删除目录树（绝对或相对路径）。
pub fn removeTree(io: Io, path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        // 同 mkdirp：根由 splitAbsoluteRoot 给出，不能硬编码 "/"。
        const split = splitAbsoluteRoot(path);
        var root = try std.Io.Dir.openDirAbsolute(io, split.root, .{});
        defer root.close(io);
        try std.Io.Dir.deleteTree(root, io, split.rest);
    } else {
        try std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, path);
    }
}

/// 设置 POSIX 权限（`config.json` 必须 0600 —— 它含 API key）。
pub fn setPermissions(io: Io, path: []const u8, mode: std.Io.File.Permissions) !void {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
    defer file.close(io);
    try file.setPermissions(io, mode);
}

pub const mode_0600: std.Io.File.Permissions = .fromMode(0o600);
pub const mode_0700: std.Io.File.Permissions = .fromMode(0o700);

/// 当前工作目录（进程启动时的 cwd）。
///
/// ⚠️ 不用 `std.process.currentPathAlloc`：它返回**带哨兵的 `[:0]u8`**
/// （分配了 len+1 字节），而调用方拿到 `[]u8` 后 `free` 只释放 len 字节 ——
/// DebugAllocator 会报 "Allocation size does not match free size"。
/// 用栈缓冲 + `dupe` 得到一块大小完全匹配的内存。
pub fn cwdAlloc(io: Io, gpa: Allocator) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}

/// stdin 是不是终端（决定进交互式 REPL 还是当管道处理）。
pub fn stdinIsTty(io: Io) bool {
    return std.Io.File.isTty(std.Io.File.stdin(), io) catch false;
}

/// 从 stdin 读**一行**（不含换行）。返回 null = EOF 且没读到任何内容。
///
/// 为什么逐字节读：`Io.Reader` 的 `readSliceShort` 语义是"填满缓冲或 EOF 才返回"，
/// 用它读交互输入会**卡死**（用户敲一行后它会继续等剩下的）。逐字节读在人类打字
/// 速度下完全够用，而且绕开了所有缓冲陷阱。
pub fn readLine(io: Io, gpa: Allocator, max_bytes: usize) !?[]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(gpa);
    var file = std.Io.File.stdin();
    var reader = file.reader(io, &.{});
    const iface = &reader.interface;
    while (out.items.len < max_bytes) {
        var one: [1]u8 = undefined;
        var d: [1][]u8 = .{one[0..]};
        const n = iface.vtable.readVec(iface, &d) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return error.ReadLineFailed,
        };
        if (n == 0) break;
        switch (one[0]) {
            '\n' => return try out.toOwnedSlice(gpa),
            '\r' => {},
            else => try out.append(gpa, one[0]),
        }
    }
    // 走到这里说明撞上了 max_bytes：必须把这一行**剩下的部分读干净**再返回。
    // 否则残余字节会留在流里，下一次 readLine 把它们当成新的一行返回 ——
    // 一条超长输入会被拆成若干条看似合法的输入，对着 stdin 协议就是注入。
    if (out.items.len >= max_bytes) {
        while (true) {
            var one: [1]u8 = undefined;
            var d: [1][]u8 = .{one[0..]};
            const n = iface.vtable.readVec(iface, &d) catch break;
            if (n == 0 or one[0] == '\n') break;
        }
    }
    if (out.items.len == 0) {
        out.deinit(gpa);
        return null;
    }
    return try out.toOwnedSlice(gpa);
}

/// 会话级取消令牌（Ctrl-C 用）。
///
/// ⚠️ **这是本仓库唯一的顶层可变全局**，且是不得已：POSIX 信号处理器
/// **无法携带 userdata**（要避免就只能上 self-pipe，代价远大于收益）。
/// 它只被信号处理器写、被 `Rt.cancelled()` 读，不承载任何业务状态。
var sigint_flag: ?*std.atomic.Value(bool) = null;

fn onSigint(_: @TypeOf(std.posix.SIG.INT)) callconv(.c) void {
    if (sigint_flag) |f| f.store(true, .release);
}

/// 装 SIGINT 处理器：Ctrl-C 只**置取消位**，不再直接杀进程。
/// 这样"取消当前 run"和"退出程序"才能分开（在提示符处 Ctrl-C 才退出）。
pub fn installSigintCancel(flag: *std.atomic.Value(bool)) void {
    sigint_flag = flag;
    var act = std.posix.Sigaction{
        .handler = .{ .handler = onSigint },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

/// 读 stdin 全部内容（`stream-json` 输入用；管道关闭即返回）。
pub fn readStdinAlloc(io: Io, gpa: Allocator) ![]u8 {
    var reader = std.Io.File.stdin().readerStreaming(io, &.{});
    return reader.interface.readAlloc(gpa, 1 << 30);
}

/// 写 stdout（**协议通道**，日志绝不能混进来）。
pub fn writeStdout(io: Io, bytes: []const u8) !void {
    var writer = std.Io.File.stdout().writer(io, &.{});
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

/// 写 stderr（**日志通道**）。
pub fn writeStderr(io: Io, bytes: []const u8) void {
    var writer = std.Io.File.stderr().writer(io, &.{});
    writer.interface.writeAll(bytes) catch return;
    writer.interface.flush() catch return;
}

// ── 网络（**唯一的 socket 适配点**，文档 11 §5）────────────────────────────────

pub const Listener = struct {
    server: std.Io.net.Server,
    /// 实际绑定的端口（`port == 0` 时为内核分配的临时端口）
    port: u16,

    pub fn deinit(self: *Listener, io: Io) void {
        self.server.deinit(io);
    }

    pub fn accept(self: *Listener, io: Io) !std.Io.net.Stream {
        return self.server.accept(io);
    }
};

/// 起一个**只绑 loopback** 的 TCP 监听。
///
/// `port = 0` 时由内核分配临时端口，`Listener.port` 回报**实际**端口，
/// 满足交付契约 #1（不写死端口 + 把真实端口回报到 stdout）。
///
/// 端口从哪来：`std.Io.net` 确实没有公开 `getsockname`，但**不需要**它——
/// `netListenIp` 的实现在 `listen` 内部已经调过 `getsockname` 并把结果填进
/// `Socket.address`（其文档："Contains the resolved ephemeral port number if
/// requested"）。所以直接读 `server.socket.address` 即可，不要在这里另外去碰
/// `std.posix`：那是同一个系统调用做第二遍。
///
/// 📌 **这里原来是错的，别改回去**：早先的实现以为拿不到内核端口，于是在
/// 49152–65535 里**随机试绑、失败就换一个、最多 128 次**。三个问题：
///   1. 会和系统临时端口区间抢占，也会和别的进程竞态；
///   2. 配合 `reuse_address` 有可能绑到别人正处于 TIME_WAIT 的端口；
///   3. 换端口那行是 `candidate = 49152 + (candidate + 7919 - 49152) % 16383;`，
///      `candidate` 是 `u16`，`candidate + 7919` 在 `candidate >= 57617` 时
///      **整数溢出**。Zig 在 Debug/ReleaseSafe 下溢出是 **panic 而不是环绕**，
///      于是"端口被占用"这个它本来要处理的场景，约 48% 的概率直接把进程打崩。
pub fn listenLoopback(io: Io, port: u16) !Listener {
    const addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    const server = try std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
    return .{ .server = server, .port = server.socket.address.getPort() };
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// 测试用的最小 Io（不起了 async/concurrent worker）。
/// 文档 11 §7：测试自己构造、作用域内 deinit，**不引入全局单例**。
fn tmpPath(gpa: Allocator, io: Io, name: []const u8) ![]u8 {
    const rnd = try randomHex(io, gpa, 6);
    defer gpa.free(rnd);
    return std.fmt.allocPrint(gpa, "/tmp/zigent-util-test-{s}/{s}", .{ rnd, name });
}

test "io: ISO-8601 格式化" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", formatIso8601(&buf, 0));
    try testing.expectEqualStrings("2026-09-19T00:00:00.000Z", formatIso8601(&buf, 1789776000000));
    try testing.expectEqualStrings("2026-09-19T09:54:56.789Z", formatIso8601(&buf, 1789811696789));
}

test "io: 常量时间比较" {
    try testing.expect(timingSafeEqlSlice("abc", "abc"));
    try testing.expect(!timingSafeEqlSlice("abc", "abd"));
    try testing.expect(!timingSafeEqlSlice("abc", "ab"));
}

test "io: 原子写 + 读回 + 追加" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = try tmpPath(testing.allocator, io, "a/b/c.txt");
    defer testing.allocator.free(path);
    const dir = std.fs.path.dirname(path).?;
    defer removeTree(io, dir) catch {};

    try mkdirp(io, dir);
    try atomicWrite(io, testing.allocator, path, "hello 世界");
    const back = try readFileAlloc(io, testing.allocator, path, 1024);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("hello 世界", back);
    try testing.expect(exists(io, path));

    try appendFile(io, path, "\n+");
    const back2 = try readFileAlloc(io, testing.allocator, path, 1024);
    defer testing.allocator.free(back2);
    try testing.expectEqualStrings("hello 世界\n+", back2);

    try testing.expect(isDir(io, dir));
}

test "io: 超过上限的文件拒读" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const path = try tmpPath(testing.allocator, io, "big.txt");
    defer testing.allocator.free(path);
    defer removeTree(io, std.fs.path.dirname(path).?) catch {};
    try mkdirp(io, std.fs.path.dirname(path).?);
    try writeFile(io, path, "0123456789");
    try testing.expectError(error.FileTooBig, readFileAlloc(io, testing.allocator, path, 4));
}

test "io: 随机 hex 长度与唯一性" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const a = try randomHex(io, testing.allocator, 16);
    defer testing.allocator.free(a);
    const b = try randomHex(io, testing.allocator, 16);
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 32), a.len);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "io: 环境变量读取带默认值" {
    const env = std.process.Environ.Map.init(testing.allocator);
    try testing.expectEqual(@as(i64, 42), getEnvInt(&env, "NOPE_NOT_SET", 42));
}

test "io: loopback 监听 + 端口 0 回报真实端口" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l = try listenLoopback(io, 0);
    defer l.deinit(io);
    // 📌 **不要在这里断言端口落在 49152–65535**（原来就是 `l.port >= 49152`）。
    // 那个区间是旧的"随机试绑"实现自己选的，现在端口由内核分配，而
    // **各系统的临时端口区间不同**：macOS 是 49152–65535，Linux 默认是
    // 32768–60999（net.ipv4.ip_local_port_range）。这条断言在 macOS 上恒真、
    // 在 Linux 上经常失败 —— 是被 CI 抓出来的真实跨平台差异。
    // 契约只要求"不是 0 且可连接"，范围不属于契约。
    try testing.expect(l.port != 0);

    var l2 = try listenLoopback(io, 0);
    defer l2.deinit(io);
    try testing.expect(l2.port != l.port);
}

test "io: listenLoopback(0) 回报内核分配的真实端口" {
    // 回归测试：这里曾经在 49152–65535 随机试绑，既有竞态，
    // 换端口那行还会在 candidate >= 57617 时 u16 溢出 panic。
    // 现在交给内核分配，直接从 socket.address 读回真实端口。
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var l = try listenLoopback(io, 0);
    defer l.deinit(io);

    // 必须是内核填回来的真实端口，不能还是 0。
    try testing.expect(l.port != 0);

    // 且这个端口真的能连上 —— 证明回报的不是个随便编的数。
    const addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(l.port) };
    var stream = try std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    stream.close(io);
}
