//! `server/token.zig` —— 桌面壳交付契约 #3：**一次性 token**。
//!
//! 只绑 loopback 不够 —— 本机其它进程也能访问。壳生成 token、经 argv/env 传入，
//! 内核**全请求校验**（`/health` 例外，因为壳靠它判断能否载入 UI）。
//!
//! ⚠️ `/health` 免 token 是**故意的**：否则壳拿不到"服务已就绪"的信号。

const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("util");

pub const HEADER = "authorization";
pub const QUERY_KEY = "token";
pub const HEALTH_PATH = "/health";

pub const Token = struct {
    value: []const u8,

    pub fn generate(io: std.Io, gpa: Allocator) !Token {
        return .{ .value = try util.io.randomHex(io, gpa, 32) };
    }

    pub fn fromEnvOrGenerate(io: std.Io, gpa: Allocator, env: *const std.process.Environ.Map) !Token {
        if (util.io.getEnv(env, "ZIGENT_TOKEN")) |v| {
            if (v.len > 0) return .{ .value = try gpa.dupe(u8, v) };
        }
        return generate(io, gpa);
    }

    pub fn deinit(self: Token, gpa: Allocator) void {
        gpa.free(self.value);
    }

    /// 常量时间比较（防时序侧信道）。
    pub fn matches(self: Token, candidate: []const u8) bool {
        return util.io.timingSafeEqlSlice(self.value, candidate);
    }
};

/// 从 `Authorization: Bearer <t>` 或 `?token=<t>` 里取凭据。
///
/// ⚠️ 浏览器 `EventSource` **无法带自定义头** —— query 参数是 SSE 的唯一兜底。
/// 新前端是 Tauri（可以带头），所以 query 只是兼容路径，不是首选。
pub fn extract(headers: []const Header, query: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, HEADER)) {
            const v = std.mem.trim(u8, h.value, " \t");
            if (std.ascii.startsWithIgnoreCase(v, "bearer ")) {
                return std.mem.trim(u8, v[7..], " \t");
            }
            return v;
        }
    }
    return queryParam(query, QUERY_KEY);
}

/// 与 `http.zig` 共用同一个 Header 形状（避免两套等价类型在调用点互相不兼容）。
pub const Header = @import("http.zig").Header;

pub fn queryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

/// 该路径是否免 token。
pub fn isPublicPath(path: []const u8) bool {
    return std.mem.eql(u8, path, HEALTH_PATH);
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "token: 生成 64 位 hex 且唯一" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const a = try Token.generate(io, testing.allocator);
    defer a.deinit(testing.allocator);
    const b = try Token.generate(io, testing.allocator);
    defer b.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 64), a.value.len);
    try testing.expect(!a.matches(b.value));
    try testing.expect(a.matches(a.value));
}

test "token: 从 Authorization 头提取（含 Bearer 前缀）" {
    const hs = [_]Header{.{ .name = "Authorization", .value = "Bearer abc123" }};
    try testing.expectEqualStrings("abc123", extract(&hs, "").?);
    const hs2 = [_]Header{.{ .name = "authorization", .value = "abc123" }};
    try testing.expectEqualStrings("abc123", extract(&hs2, "").?);
}

test "token: 从 query 提取（EventSource 兜底路径）" {
    try testing.expectEqualStrings("xyz", extract(&.{}, "token=xyz").?);
    try testing.expectEqualStrings("xyz", extract(&.{}, "a=1&token=xyz&b=2").?);
    try testing.expect(extract(&.{}, "a=1") == null);
}

test "token: /health 免 token" {
    try testing.expect(isPublicPath("/health"));
    try testing.expect(!isPublicPath("/api/session"));
}

test "token: 环境变量优先" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("ZIGENT_TOKEN", "from-env");
    const t = try Token.fromEnvOrGenerate(threaded.io(), testing.allocator, &env);
    defer t.deinit(testing.allocator);
    try testing.expectEqualStrings("from-env", t.value);
}
