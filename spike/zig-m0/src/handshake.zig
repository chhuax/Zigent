//! 桌面壳交付契约（E3）—— 纯逻辑部分，可测试，与 HTTP 实现解耦。
//!
//! 这 7 条是「先 Web 服务、后桌面壳」能顺利接上的前提。见
//! `docs/analysis/2026-09-19-02-功能清单与核心优先.md` §9.3。
//!
//! 1. 端口可用 0（OS 分配）+ 把实际端口回报出来
//! 2. `GET /health` 返回固定就绪标记，且**无需 token**
//! 3. 一次性 token 鉴权（REST + SSE 都校验）
//! 4. 优雅关闭入口
//! 5. `--version` 含版本号
//! 6. 进程组/子进程清理
//! 7. stdout 只走协议、日志走 stderr
//!
//! 本文件覆盖 1/2/3/4/5 的**可测部分**；6/7 必须在真机上验证（见 SPIKE-E3）。

const std = @import("std");

// ---------------------------------------------------------------------------
// 2. 就绪标记
// ---------------------------------------------------------------------------

/// 壳轮询 `/health` 时期待的字面量。沿用现有既有实现侧的约定，
/// 这样旧的桌面壳脚本/健康检查工具可以直接复用。
pub const HEALTH_MARKER = "zigent-ready";

/// `/health` 是唯一的公开路径 —— 壳必须能在没有 token 的情况下判断就绪。
pub fn isPublicPath(path: []const u8) bool {
 // 只放行精确匹配，避免 `/health/../api/...` 之类的绕过
 return std.mem.eql(u8, path, "/health");
}

// ---------------------------------------------------------------------------
// 1. 端口回报（stdout 一行 JSON）
// ---------------------------------------------------------------------------

/// 监听成功后写到 stdout 的那一行。
/// ⚠️ stdout 只走协议；日志一律 stderr —— 壳会解析这一行来拿端口。
///
/// 刻意**不用 Writer 抽象、不用 ArrayList writer**：Zig 0.15 起
/// Writer/Reader 参数化（"Writergate"）改动很大，而这里只需要格式化到一个
/// 固定 buffer，`std.fmt.bufPrint` 是跨版本稳定的。
pub const MAX_LISTENING_LINE = 256;

pub fn buildListeningLine(buf: []u8, port: u16, pid: i32, version: []const u8) ![]const u8 {
 return std.fmt.bufPrint(
 buf,
 "{{\"event\":\"listening\",\"port\":{d},\"pid\":{d},\"version\":\"{s}\"}}\n",
 .{ port, pid, version },
 );
}

/// 壳侧（或测试）解析这一行。返回 null 表示"不是 listening 行"（应继续读下一行）。
pub fn parseListeningLine(line: []const u8) ?u16 {
 // 手写最小解析：不引 std.json，避免版本敏感 API。
 const trimmed = std.mem.trim(u8, line, " \t\r\n");
 if (trimmed.len == 0) return null;
 if (std.mem.indexOf(u8, trimmed, "\"listening\"") == null) return null;

 const key = "\"port\":";
 const at = std.mem.indexOf(u8, trimmed, key) orelse return null;
 var i = at + key.len;
 while (i < trimmed.len and (trimmed[i] == ' ')) i += 1;
 const start = i;
 while (i < trimmed.len and trimmed[i] >= '0' and trimmed[i] <= '9') i += 1;
 if (i == start) return null;
 return std.fmt.parseInt(u16, trimmed[start..i], 10) catch null;
}

// ---------------------------------------------------------------------------
// 3. 一次性 token
// ---------------------------------------------------------------------------

pub const TOKEN_BYTES = 32;
pub const TOKEN_HEX_LEN = TOKEN_BYTES * 2;

pub const Token = struct {
 hex: [TOKEN_HEX_LEN]u8,

 pub fn slice(self: *const Token) []const u8 {
 return &self.hex;
 }
};

/// 壳生成 token 并传给内核（argv 或 env）。内核侧自生成仅用于单独自测。
///
/// ⚠️ 0.16 起 `std.crypto.random` 已移除 —— 随机数改由 `std.Io` 提供
/// （`io.random` / `io.randomSecure`）。**这就是"所有 IO 都要传 io 实例"的直接体现。**
pub fn generateToken(io: std.Io) Token {
 var raw: [TOKEN_BYTES]u8 = undefined;
 io.random(&raw);
 var t: Token = undefined;
 const digits = "0123456789abcdef";
 for (raw, 0..) |b, i| {
 t.hex[i * 2] = digits[b >> 4];
 t.hex[i * 2 + 1] = digits[b & 0x0f];
 }
 return t;
}

/// 定长常量时间比较 —— 长度不等直接 false（长度不是秘密）。
/// 0.16 起 `std.crypto.utils.timingSafeEql` 改名为 `std.crypto.timing_safe.eql`。
pub fn tokenMatches(expected: *const Token, provided: []const u8) bool {
 if (provided.len != TOKEN_HEX_LEN) return false;
 var buf: [TOKEN_HEX_LEN]u8 = undefined;
 @memcpy(&buf, provided);
 return std.crypto.timing_safe.eql([TOKEN_HEX_LEN]u8, expected.hex, buf);
}

/// 从请求里提取 token。**必须同时支持 header 与 query**：
/// - Tauri 的 fetch 能带 `Authorization: Bearer <token>`；
/// - 但浏览器原生 `EventSource` **无法带自定义头** —— 这是旧既有实现侧
/// 被迫改用 cookie 的原因（见移植雷区 §H）。query 参数是 SSE 的
/// 兜底通道。
pub const TokenSource = enum { header, query, none };

pub const ExtractedToken = struct {
 value: ?[]const u8 = null,
 source: TokenSource = .none,
};

pub fn extractToken(query: ?[]const u8, authorization: ?[]const u8) ExtractedToken {
 if (authorization) |h| {
 const prefix = "Bearer ";
 if (h.len > prefix.len and std.mem.startsWith(u8, h, prefix)) {
 return .{ .value = h[prefix.len..], .source = .header };
 }
 }
 if (query) |q| {
 if (queryParam(q, "token")) |v| return .{ .value = v, .source = .query };
 }
 return .{};
}

/// 从 `a=1&token=xyz&b=2` 里取一个参数（不做 URL 解码 —— token 是 hex，无需解码）。
pub fn queryParam(query: []const u8, key: []const u8) ?[]const u8 {
 var it = std.mem.splitScalar(u8, query, '&');
 while (it.next()) |pair| {
 const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
 if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
 }
 return null;
}

// ---------------------------------------------------------------------------
// 4. 优雅关闭
// ---------------------------------------------------------------------------

pub const SHUTDOWN_PATH = "/internal/shutdown";

/// 关闭是 `POST /internal/shutdown`（受 token 保护）或 SIGTERM。
///
/// ⚠️ 契约 #6（不留孤儿）在 spike 里必须**真机验证**：
/// 1. 父进程正常退出 → 子进程随之退出（壳 kill 内核）；
/// 2. 父进程被 `kill -9` → 子进程也必须能自己退出。
/// 第 2 条靠「父进程死亡检测」或「子进程在独立进程组里且父死即退」实现。
/// Linux 上可用 `prctl(PR_SET_PDEATHSIG, SIGTERM)`；macOS 无等价物，
/// 需轮询 `getppid() == 1`。**这正是要在 spike 里定下来的设计点。**
pub const OrphanStrategy = enum {
 /// Linux: prctl(PR_SET_PDEATHSIG)
 pdeathsig,
 /// macOS/通用: 定期检查 getppid() 变成 1（被 init 收养）
 reparent_poll,
};

pub fn orphanStrategyForOs() OrphanStrategy {
 return switch (@import("builtin").os.tag) {
 .linux => .pdeathsig,
 else => .reparent_poll,
 };
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "端口回报：写出的行能被解析回来（壳的握手基础）" {
 var buf: [MAX_LISTENING_LINE]u8 = undefined;
 const line = try buildListeningLine(&buf, 54321, 4242, "0.1.0");
 try std.testing.expect(std.mem.endsWith(u8, line, "\n"));
 try std.testing.expectEqual(@as(?u16, 54321), parseListeningLine(line));
 // 版本也在同一行里（壳可以顺便读到）
 try std.testing.expect(std.mem.indexOf(u8, line, "\"version\":\"0.1.0\"") != null);
}

test "端口回报：非 listening 行返回 null（壳可以继续读日志行）" {
 try std.testing.expectEqual(@as(?u16, null), parseListeningLine(""));
 try std.testing.expectEqual(@as(?u16, null), parseListeningLine("some log line\n"));
 try std.testing.expectEqual(@as(?u16, null), parseListeningLine("{\"event\":\"other\"}\n"));
 // 有 listening 但缺 port
 try std.testing.expectEqual(@as(?u16, null), parseListeningLine("{\"event\":\"listening\"}\n"));
}

test "健康检查：只有 /health 是公开路径" {
 try std.testing.expect(isPublicPath("/health"));
 // 这些都不该公开
 try std.testing.expect(!isPublicPath("/health/"));
 try std.testing.expect(!isPublicPath("/api/session"));
 try std.testing.expect(!isPublicPath("/health/../api/session"));
 try std.testing.expect(!isPublicPath(""));
}

test "token：生成的是定长 hex，且每次不同" {
 const a = generateToken();
 const b = generateToken();
 try std.testing.expectEqual(@as(usize, TOKEN_HEX_LEN), a.slice().len);
 for (a.slice()) |c| {
 try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
 }
 try std.testing.expect(!std.mem.eql(u8, a.slice(), b.slice()));
}

test "token：比较正确（含长度不等与近似串）" {
 const t = generateToken();
 try std.testing.expect(tokenMatches(&t, t.slice()));
 // 长度不对
 try std.testing.expect(!tokenMatches(&t, t.slice()[0 .. TOKEN_HEX_LEN - 1]));
 try std.testing.expect(!tokenMatches(&t, ""));
 // 只差一个字符
 var wrong = t.hex;
 wrong[TOKEN_HEX_LEN - 1] = if (wrong[TOKEN_HEX_LEN - 1] == 'a') 'b' else 'a';
 try std.testing.expect(!tokenMatches(&t, &wrong));
}

test "token 提取：header 优先于 query" {
 const from_header = extractToken("token=fromquery", "Bearer fromheader");
 try std.testing.expectEqual(TokenSource.header, from_header.source);
 try std.testing.expectEqualStrings("fromheader", from_header.value.?);

 const from_query = extractToken("a=1&token=fromquery&b=2", null);
 try std.testing.expectEqual(TokenSource.query, from_query.source);
 try std.testing.expectEqualStrings("fromquery", from_query.value.?);

 const none = extractToken("a=1", "Basic xyz");
 try std.testing.expectEqual(TokenSource.none, none.source);
 try std.testing.expectEqual(@as(?[]const u8, null), none.value);
}

test "孤儿策略：Linux 用 pdeathsig，其它用 reparent 轮询" {
 const s = orphanStrategyForOs();
 switch (@import("builtin").os.tag) {
 .linux => try std.testing.expectEqual(OrphanStrategy.pdeathsig, s),
 else => try std.testing.expectEqual(OrphanStrategy.reparent_poll, s),
 }
}
