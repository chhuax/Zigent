//! `config/auth.zig` —— BYOK 鉴权解析（文档 10 §8.3）。
//!
//! **一条硬规则**：`apiKeyEnv` 指向的环境变量 **优先于** 内联 `apiKey`。
//!
//! 理由（不是风格偏好）：
//!   - CI/容器场景密钥**不落盘**；
//!   - `config.json` 可能被误提交进版本库（真实案例），env 让密钥只存在于进程环境。
//!
//! ⚠️ 都不存在时返回 `null` —— **绝不回退 ambient `ANTHROPIC_API_KEY` /
//! `OPENAI_API_KEY`**。那会让「我明明没配却能用」并且跨 provider 串味。

const std = @import("std");
const common = @import("common");
const util = @import("util");
const userconfig = @import("userconfig.zig");
const secret = @import("secret.zig");

pub const ProviderEntry = userconfig.ProviderEntry;

/// 会「串味」的 ambient 变量 —— 仅用于 doctor 诊断，**从不**参与解析。
pub const AMBIENT_KEYS = [_][]const u8{
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "DEEPSEEK_API_KEY",
    "MINIMAX_API_KEY",
};

fn nonBlank(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return null;
    return t;
}

/// routing 路径：`apiKeyEnv` > 内联 `apiKey` > `null`。
///
/// 返回的切片**借用**自 `env`（环境块）或 `entry`（配置内存），调用方不得 free。
/// ⚠️ 内联值若形如 `enc:1:`，本函数**不解密** —— 解密需要 (home, hostname, io)，
/// 由调用方在得到 `entry` 时用 `secret.decrypt` 处理好（或调用 `resolveKeyDecrypted`）。
pub fn resolveKey(env: *const std.process.Environ.Map, entry: ProviderEntry) ?[]const u8 {
    if (nonBlank(entry.api_key_env)) |name| {
        if (nonBlank(util.io.getEnv(env, name))) |v| return v;
    }
    if (nonBlank(entry.api_key)) |v| return v;
    return null;
}

/// `resolveKey` + 内联密文解密。`apiKeyEnv` 命中时**完全不解密**（不做多余工作）。
///
/// 解密失败 → 返回 `error.DecryptFailed`；调用方（配置加载）应 `log.warn`
/// 并**保留原值**，不要中断整份配置加载。
pub fn resolveKeyDecrypted(
    gpa: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    entry: ProviderEntry,
    user_home: []const u8,
    hostname: []const u8,
) !?[]u8 {
    if (nonBlank(entry.api_key_env)) |name| {
        if (nonBlank(util.io.getEnv(env, name))) |v| return try gpa.dupe(u8, v);
    }
    if (nonBlank(entry.api_key)) |v| {
        if (secret.isEncrypted(v)) return try secret.decrypt(gpa, v, user_home, hostname);
        return try gpa.dupe(u8, v);
    }
    return null;
}

/// 密钥来源（诊断用；**不返回密钥值本身**）。
/// ⚠️ 变体名不能叫 `inline` —— 它是 Zig 关键字。
pub const KeySource = enum { environment, inline_api_key, none };

pub fn keySource(env: *const std.process.Environ.Map, entry: ProviderEntry) KeySource {
    if (nonBlank(entry.api_key_env)) |name| {
        if (nonBlank(util.io.getEnv(env, name)) != null) return .environment;
    }
    if (nonBlank(entry.api_key) != null) return .inline_api_key;
    return .none;
}

/// doctor：内联**明文** `apiKey`（非 `enc:1:`）应当告警（文档 10 §8.3）。
/// 返回 `true` = 需要告警。
pub fn inlinePlaintextKeyWarns(entry: ProviderEntry) bool {
    const v = nonBlank(entry.api_key) orelse return false;
    return !std.mem.startsWith(u8, v, "enc:1:");
}

/// doctor：该 provider 声明了 `apiKeyEnv` 但环境里没有对应变量。
pub fn missingEnvKey(env: *const std.process.Environ.Map, entry: ProviderEntry) bool {
    const name = nonBlank(entry.api_key_env) orelse return false;
    return nonBlank(util.io.getEnv(env, name)) == null;
}

/// 在任何 provider 上都没配 key，但进程环境里有 ambient key —— 值得提示
/// 「你可能是从 ambient 变量误以为配好了」。返回值**只是变量名**，不是密钥。
pub fn ambientHint(env: *const std.process.Environ.Map) ?[]const u8 {
    for (AMBIENT_KEYS) |k| {
        if (nonBlank(util.io.getEnv(env, k)) != null) return k;
    }
    return null;
}

/// 空 provider id 的兜底名（诊断输出用）。
pub fn displayName(entry: ProviderEntry) []const u8 {
    return if (entry.id.len != 0) entry.id else "<unnamed>";
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

const TEST_HOME = "/Users/me";
const TEST_HOST = "my-host";

test "auth: apiKeyEnv 优先于内联 apiKey" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("MY_KEY", "sk-from-env");

    const entry = ProviderEntry{
        .id = "p",
        .kind = "openai",
        .base_url = "",
        .api_key = "sk-inline",
        .api_key_env = "MY_KEY",
    };
    try testing.expectEqualStrings("sk-from-env", resolveKey(&env, entry).?);
    try testing.expectEqual(KeySource.environment, keySource(&env, entry));
}

test "auth: env 未设 → 回退内联；env 值空白不算命中" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    const entry = ProviderEntry{
        .id = "p",
        .kind = "openai",
        .base_url = "",
        .api_key = "sk-inline",
        .api_key_env = "MY_KEY",
    };
    // 未设 → inline
    try testing.expectEqualStrings("sk-inline", resolveKey(&env, entry).?);
    // 空串/纯空白 → 不算命中
    try env.put("MY_KEY", "   ");
    try testing.expectEqualStrings("sk-inline", resolveKey(&env, entry).?);
    // 正常值 → env
    try env.put("MY_KEY", "sk-from-env");
    try testing.expectEqualStrings("sk-from-env", resolveKey(&env, entry).?);
}

test "auth: 两者都没有 → null（**不回退 ambient ANTHROPIC/OPENAI_API_KEY**）" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("ANTHROPIC_API_KEY", "sk-ambient");
    try env.put("OPENAI_API_KEY", "sk-ambient-2");

    const entry = ProviderEntry{
        .id = "p",
        .kind = "anthropic",
        .base_url = "",
        .api_key = "",
        .api_key_env = "",
    };
    try testing.expect(resolveKey(&env, entry) == null);
    try testing.expectEqual(KeySource.none, keySource(&env, entry));

    // ambient 只用于诊断提示
    try testing.expectEqualStrings("ANTHROPIC_API_KEY", ambientHint(&env).?);
}

test "auth: apiKeyEnv 指向不存在的变量 → 告警，但仍可回退内联" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    const entry = ProviderEntry{
        .id = "p",
        .kind = "openai",
        .base_url = "",
        .api_key = "sk-inline",
        .api_key_env = "NOT_SET_KEY",
    };
    try testing.expect(missingEnvKey(&env, entry));
    try testing.expectEqualStrings("sk-inline", resolveKey(&env, entry).?);

    try env.put("NOT_SET_KEY", "x");
    try testing.expect(!missingEnvKey(&env, entry));
}

test "auth: 内联明文告警 / enc:1: 密文不告警" {
    const plain = ProviderEntry{
        .id = "p",
        .kind = "openai",
        .base_url = "",
        .api_key = "sk-plain-abc",
        .api_key_env = "",
    };
    try testing.expect(inlinePlaintextKeyWarns(plain));

    const enc = ProviderEntry{
        .id = "p",
        .kind = "openai",
        .base_url = "",
        .api_key = "enc:1:AAAA",
        .api_key_env = "",
    };
    try testing.expect(!inlinePlaintextKeyWarns(enc));

    const none = ProviderEntry{ .id = "p", .kind = "openai", .base_url = "", .api_key = "", .api_key_env = "" };
    try testing.expect(!inlinePlaintextKeyWarns(none));
}

test "auth: resolveKeyDecrypted —— 明文直通 / enc:1: 解密 / env 命中不解密" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const enc_value = try secret.encrypt(gpa, io, "sk-decrypted", TEST_HOME, TEST_HOST);
    defer gpa.free(enc_value);

    // ① 内联密文 → 解出明文
    const enc_entry = ProviderEntry{
        .id = "p",
        .kind = "openai",
        .base_url = "",
        .api_key = enc_value,
        .api_key_env = "",
    };
    const k1 = (try resolveKeyDecrypted(gpa, &env, enc_entry, TEST_HOME, TEST_HOST)).?;
    defer gpa.free(k1);
    try testing.expectEqualStrings("sk-decrypted", k1);

    // ② 内联明文 → 原样（但仍是拥有的拷贝，释放语义统一）
    const plain_entry = ProviderEntry{
        .id = "p",
        .kind = "openai",
        .base_url = "",
        .api_key = "sk-plain",
        .api_key_env = "",
    };
    const k2 = (try resolveKeyDecrypted(gpa, &env, plain_entry, TEST_HOME, TEST_HOST)).?;
    defer gpa.free(k2);
    try testing.expectEqualStrings("sk-plain", k2);

    // ③ env 命中 → **不解密**（错的 home 也不会报错）
    try env.put("MY_KEY", "sk-from-env");
    const both = ProviderEntry{
        .id = "p",
        .kind = "openai",
        .base_url = "",
        .api_key = enc_value,
        .api_key_env = "MY_KEY",
    };
    const k3 = (try resolveKeyDecrypted(gpa, &env, both, "/wrong/home", "wrong-host")).?;
    defer gpa.free(k3);
    try testing.expectEqualStrings("sk-from-env", k3);

    // ④ 内联密文 + 错的 home → DecryptFailed（调用方 log.warn + 保留原值）
    try testing.expectError(
        error.DecryptFailed,
        resolveKeyDecrypted(gpa, &env, enc_entry, "/wrong/home", TEST_HOST),
    );

    // ⑤ 都没有 → null
    const empty = ProviderEntry{ .id = "p", .kind = "openai", .base_url = "", .api_key = "", .api_key_env = "" };
    try testing.expect((try resolveKeyDecrypted(gpa, &env, empty, TEST_HOME, TEST_HOST)) == null);
}

test "auth: displayName 兜底" {
    try testing.expectEqualStrings("p", displayName(.{ .id = "p", .kind = "", .base_url = "", .api_key = "", .api_key_env = "" }));
    try testing.expectEqualStrings("<unnamed>", displayName(.{ .id = "", .kind = "", .base_url = "", .api_key = "", .api_key_env = "" }));
}

test "auth: 与 userconfig 的 ProviderEntry 是同一类型（无适配层）" {
    // 编译期断言：两处的类型必须完全相同，否则鉴权层要写转换代码。
    comptime {
        if (ProviderEntry != userconfig.ProviderEntry) @compileError("ProviderEntry 类型不一致");
    }
    var cfg: userconfig.UserConfig = .{};
    defer cfg.deinit(testing.allocator);
}
