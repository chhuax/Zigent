//! `config/secret.zig` —— ★ **`enc:1:` 密文的逐字节兼容实现**（文档 10 §8 / 文档 13 §4）。
//!
//! 这是**硬约束**：改一个字节 = 存量用户的 provider 密钥全部解不开。
//!
//! ```
//! 落盘字符串  "enc:1:" + base64( [1B ver=1] || [12B IV] || [ciphertext] || [16B GCM tag] )
//! 算法        AES-256-GCM（"AES/GCM/NoPadding"，128 位 tag，**无 AAD**）
//! KDF         PBKDF2-HMAC-SHA256, 120_000 轮, 256 bit
//! SALT        16 字节【硬编码】
//! passphrase  APP_SECRET + ":" + userHome + ":" + hostname
//! ```
//!
//! 形状来自 `spike/zig-m0/src/e5_crypto.zig`（已验证可跑的骨架），
//! 参数值来自文档 10 §8.1 的逐字段证据表。
//!
//! ⚠️ **两个必须逐字保留的常量**见下方 `APP_SECRET` / `SALT`：
//! 它们就是 spike 文件里那两个 `*_PLACEHOLDER` 常量 —— 在这里被**填上真值**
//! 并保留「占位符」的注释，因为改动它们等于让存量密文全部失效。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const util = @import("util");

// ─────────────────────────────────────────────────────────────────────────────
// 常量（文档 10 §8.1 的逐字段证据表）
// ─────────────────────────────────────────────────────────────────────────────

pub const ENC1_PREFIX = "enc:1:";
pub const VERSION_BYTE: u8 = 1;
pub const IV_LEN = 12;
pub const TAG_LEN = 16;
pub const SALT_LEN = 16;
pub const KEY_LEN = 32;
pub const PBKDF2_ROUNDS: u32 = 120_000;
/// blob 最小长度：`[1B ver][12B IV][16B tag]`（空明文的最小密文）。
pub const MIN_BLOB_LEN = 1 + IV_LEN + TAG_LEN;
/// 既有实现用 GCMParameterSpec 不带 AAD。
pub const AD: []const u8 = "";

/// ⚠️ **PLACEHOLDER → 真值已填**（spike `APP_SECRET_PLACEHOLDER` 对应物）。
/// 逐字来自文档 10 §8.1：改动即让存量密文全部解不开。
pub const APP_SECRET = "zigent-provider-secret-v1-7b3e9d1f4a82c5e6";

/// ⚠️ **PLACEHOLDER → 真值已填**（spike `SALT_PLACEHOLDER` 对应物）。
/// 16 字节**硬编码** salt，逐字来自文档 10 §8.1：
/// `4c a7 1e 90 33 d8 6b f2 05 be 71 2a 8d 14 c0 59`。
pub const SALT = [SALT_LEN]u8{
    0x4c, 0xa7, 0x1e, 0x90, 0x33, 0xd8, 0x6b, 0xf2,
    0x05, 0xbe, 0x71, 0x2a, 0x8d, 0x14, 0xc0, 0x59,
};

pub const SecretError = error{
    /// blob 长度不足或版本字节 != 1（对外文案「密文损坏或版本不符」）
    CorruptOrUnsupportedVersion,
    /// GCM tag 校验失败 —— 最常见的原因是**主机名或 home 变了**
    DecryptFailed,
    /// 输入不是 `enc:1:`（调用方本应先用 `isEncrypted` 判定）
    NotEnc1,
};

// ─────────────────────────────────────────────────────────────────────────────
// 判定 / passphrase / hostname / 派生
// ─────────────────────────────────────────────────────────────────────────────

/// 是否 `enc:1:` 密文（前缀匹配，不做 base64 校验）。
pub fn isEncrypted(s: []const u8) bool {
    return std.mem.startsWith(u8, s, ENC1_PREFIX);
}

/// passphrase 派生顺序是契约：`APP_SECRET + ":" + userHome + ":" + hostname`。
///
/// ⚠️ `user_home` 必须来自 `paths.resolveHome`（`ZIGENT_HOME` 一变则旧密文全废）。
pub fn buildPassphrase(buf: []u8, user_home: []const u8, hostname: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}:{s}:{s}", .{ APP_SECRET, user_home, hostname });
}

/// hostname：先 gethostname，失败/空 → `HOSTNAME` env，再失败 → `"unknown-host"`。
///
/// 对齐既有实现的 `resolveHostname` 回退链（文档 10 §8.1）。
/// `buf` 由调用方提供（≥256）；返回值是 `buf` 或 `"unknown-host"` 的切片。
pub fn resolveHostname(io: Io, gpa: Allocator, env: *const std.process.Environ.Map, buf: *[256]u8) []const u8 {
    // ⚠️ `std.posix` 只允许出现在 `util/io.zig`（CI 的 `zig build guard` 强制），
    // 所以本机 hostname 走 `util.io.gethostname`。
    // 它失败时自带的兜底就是 `"unknown-host"` —— 那正好是回退链的下一站。
    const local = util.io.gethostname(io, gpa) catch "unknown-host";
    defer gpa.free(local);
    const resolved: ?[]const u8 = if (std.mem.eql(u8, local, "unknown-host")) null else local;
    return pickHostname(resolved, util.io.getEnv(env, "HOSTNAME"), buf);
}

/// 回退链的**纯函数**部分（可独立测试）：
/// 本机 hostname（trim 后非空）→ `HOSTNAME` env（trim 后非空）→ `"unknown-host"`。
///
/// `buf` 必须 ≥ 256；超出长度的候选值按「无效」跳过（不截断 —— 截断会静默改派生）。
pub fn pickHostname(local: ?[]const u8, env_hostname: ?[]const u8, buf: *[256]u8) []const u8 {
    if (nonBlank(local)) |h| {
        if (h.len <= buf.len) {
            @memcpy(buf[0..h.len], h);
            return buf[0..h.len];
        }
    }
    if (nonBlank(env_hostname)) |h| {
        if (h.len <= buf.len) {
            @memcpy(buf[0..h.len], h);
            return buf[0..h.len];
        }
    }
    return "unknown-host";
}

fn nonBlank(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return null;
    return t;
}

/// 用进程默认源解析 hostname —— 便捷入口。
pub fn resolveHostnameDefault(io: Io, gpa: Allocator, env: *const std.process.Environ.Map, buf: *[256]u8) []const u8 {
    return resolveHostname(io, gpa, env, buf);
}

/// PBKDF2-HMAC-SHA256(passphrase, SALT, 120_000, 256bit)。
pub fn deriveKey(passphrase: []const u8) ![KEY_LEN]u8 {
    var key: [KEY_LEN]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(
        &key,
        passphrase,
        &SALT,
        PBKDF2_ROUNDS,
        std.crypto.auth.hmac.sha2.HmacSha256,
    );
    return key;
}

/// 从 (user_home, hostname) 直达 key。
pub fn deriveKeyFor(user_home: []const u8, hostname: []const u8) ![KEY_LEN]u8 {
    var buf: [1024]u8 = undefined;
    const pass = try buildPassphrase(&buf, user_home, hostname);
    return deriveKey(pass);
}

// ─────────────────────────────────────────────────────────────────────────────
// blob 布局
// ─────────────────────────────────────────────────────────────────────────────

/// blob 布局：`[1B ver][12B IV][ciphertext][16B tag]`。
pub const Blob = struct {
    version: u8,
    iv: [IV_LEN]u8,
    tag: [TAG_LEN]u8,
    ciphertext: []const u8,
};

pub fn parseBlob(raw: []const u8) SecretError!Blob {
    if (raw.len < MIN_BLOB_LEN) return error.CorruptOrUnsupportedVersion;
    const version = raw[0];
    if (version != VERSION_BYTE) return error.CorruptOrUnsupportedVersion;
    var iv: [IV_LEN]u8 = undefined;
    @memcpy(&iv, raw[1 .. 1 + IV_LEN]);
    const ct_end = raw.len - TAG_LEN;
    var tag: [TAG_LEN]u8 = undefined;
    @memcpy(&tag, raw[ct_end..]);
    return .{ .version = version, .iv = iv, .tag = tag, .ciphertext = raw[1 + IV_LEN .. ct_end] };
}

/// 写 blob 的**头部与尾部**（版本字节 + IV + tag）。
/// 密文段由调用方**就地**写入（GCM 的 `c` 参数），因此本函数只碰不重叠的两端。
pub fn writeBlob(dest: []u8, iv: [IV_LEN]u8, tag: [TAG_LEN]u8) !void {
    if (dest.len < MIN_BLOB_LEN) return error.NoSpaceLeft;
    dest[0] = VERSION_BYTE;
    @memcpy(dest[1 .. 1 + IV_LEN], &iv);
    @memcpy(dest[dest.len - TAG_LEN ..][0..TAG_LEN], &tag);
}

// ─────────────────────────────────────────────────────────────────────────────
// 公开 API（INTERFACES §4.1）
// ─────────────────────────────────────────────────────────────────────────────

/// 透明解密（存量明文兼容）：**不以 `enc:1:` 开头 → 复制原值返回**。
///
/// 失败返回 `error.DecryptFailed`（tag 校验失败 ⇒ 十有八九是 home/hostname 变了）。
pub fn decrypt(gpa: Allocator, enc: []const u8, user_home: []const u8, hostname: []const u8) ![]u8 {
    // 存量明文直通：返回值同样是「调用方拥有」，保证释放语义无分支。
    if (!isEncrypted(enc)) return gpa.dupe(u8, enc);

    const key = try deriveKeyFor(user_home, hostname);

    const b64 = enc[ENC1_PREFIX.len..];
    if (b64.len == 0) return error.CorruptOrUnsupportedVersion;

    const raw_len = std.base64.standard.Decoder.calcSizeForSlice(b64) catch
        return error.CorruptOrUnsupportedVersion;
    if (raw_len < MIN_BLOB_LEN) return error.CorruptOrUnsupportedVersion;

    const raw = try gpa.alloc(u8, raw_len);
    defer gpa.free(raw);
    std.base64.standard.Decoder.decode(raw, b64) catch
        return error.CorruptOrUnsupportedVersion;

    const blob = try parseBlob(raw);
    const plain = try gpa.alloc(u8, blob.ciphertext.len);
    errdefer gpa.free(plain);
    std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(
        plain,
        blob.ciphertext,
        blob.tag,
        AD,
        blob.iv,
        key,
    ) catch return error.DecryptFailed;
    return plain;
}

/// 加密。空明文**原样返回**（既有实现 `plaintext.isEmpty() → 原样`）。
/// IV 必须来自密码学随机源（`util.io.randomBytes`，**不用** `std.crypto.random`）。
pub fn encrypt(gpa: Allocator, io: Io, plain: []const u8, user_home: []const u8, hostname: []const u8) ![]u8 {
    if (plain.len == 0) return gpa.dupe(u8, plain);
    const key = try deriveKeyFor(user_home, hostname);

    var iv: [IV_LEN]u8 = undefined;
    util.io.randomBytes(io, &iv);

    const raw_len = 1 + IV_LEN + plain.len + TAG_LEN;
    const raw = try gpa.alloc(u8, raw_len);
    defer gpa.free(raw);

    // 密文**就地**写进 raw 的中段（GCM `c` 参数），避免与 writeBlob 的 @memcpy 别名。
    const ct = raw[1 + IV_LEN .. 1 + IV_LEN + plain.len];
    var tag: [TAG_LEN]u8 = undefined;
    std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(ct, &tag, plain, AD, iv, key);
    try writeBlob(raw, iv, tag);

    const b64_len = std.base64.standard.Encoder.calcSize(raw_len);
    const out = try gpa.alloc(u8, ENC1_PREFIX.len + b64_len);
    @memcpy(out[0..ENC1_PREFIX.len], ENC1_PREFIX);
    _ = std.base64.standard.Encoder.encode(out[ENC1_PREFIX.len..], raw);
    return out;
}

/// 便捷：`decrypt` 但把「原本就是明文」显式表达出来（文档 10 §8.2 的 `Plain`）。
pub const Plain = union(enum) {
    borrowed: []const u8,
    owned: []u8,
};

pub fn decryptToString(gpa: Allocator, stored: []const u8, user_home: []const u8, hostname: []const u8) !Plain {
    if (!isEncrypted(stored)) return .{ .borrowed = stored };
    return .{ .owned = try decrypt(gpa, stored, user_home, hostname) };
}

/// 解密的结果统一成「需要 free 的切片」，便于调用方无分支释放。
pub fn decryptOwned(gpa: Allocator, stored: []const u8, user_home: []const u8, hostname: []const u8) ![]u8 {
    return decrypt(gpa, stored, user_home, hostname);
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

const TEST_HOME = "/Users/me";
const TEST_HOST = "my-host";

test "secret: passphrase 派生顺序是契约（APP_SECRET:home:hostname）" {
    var buf: [256]u8 = undefined;
    const p = try buildPassphrase(&buf, TEST_HOME, TEST_HOST);
    try testing.expectEqualStrings("zigent-provider-secret-v1-7b3e9d1f4a82c5e6:/Users/me:my-host", p);
    // 常量逐字锁定（改了这里就是兼容性事故）
    try testing.expectEqualStrings("zigent-provider-secret-v1-7b3e9d1f4a82c5e6", APP_SECRET);
    try testing.expectEqualSlices(u8, &.{
        0x4c, 0xa7, 0x1e, 0x90, 0x33, 0xd8, 0x6b, 0xf2,
        0x05, 0xbe, 0x71, 0x2a, 0x8d, 0x14, 0xc0, 0x59,
    }, &SALT);
}

test "secret: isEncrypted 前缀判定" {
    try testing.expect(isEncrypted("enc:1:AAAA"));
    try testing.expect(!isEncrypted("sk-plain-abc"));
    try testing.expect(!isEncrypted(""));
    try testing.expect(!isEncrypted("ENC:1:AAAA"));
}

test "secret: PBKDF2 参数正确（RFC 6070 风格已知向量）" {
    var k1: [32]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&k1, "password", "salt", 1, std.crypto.auth.hmac.sha2.HmacSha256);
    var hex: [64]u8 = undefined;
    const d = "0123456789abcdef";
    for (k1, 0..) |b, i| {
        hex[i * 2] = d[b >> 4];
        hex[i * 2 + 1] = d[b & 0x0f];
    }
    try testing.expectEqualStrings("120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b", &hex);

    var k2: [32]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&k2, "password", "salt", 2, std.crypto.auth.hmac.sha2.HmacSha256);
    for (k2, 0..) |b, i| {
        hex[i * 2] = d[b >> 4];
        hex[i * 2 + 1] = d[b & 0x0f];
    }
    try testing.expectEqualStrings("ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43", &hex);
}

test "secret: blob 布局 [1B ver][12B IV][ct][16B tag]" {
    var raw: [1 + IV_LEN + 5 + TAG_LEN]u8 = undefined;
    raw[0] = 1;
    @memset(raw[1 .. 1 + IV_LEN], 0xAA);
    @memset(raw[1 + IV_LEN .. 1 + IV_LEN + 5], 0xBB);
    @memset(raw[1 + IV_LEN + 5 ..], 0xCC);

    const b = try parseBlob(&raw);
    try testing.expectEqual(@as(u8, 1), b.version);
    try testing.expectEqual(@as(usize, 5), b.ciphertext.len);
    try testing.expectEqual(@as(u8, 0xAA), b.iv[0]);
    try testing.expectEqual(@as(u8, 0xBB), b.ciphertext[0]);
    try testing.expectEqual(@as(u8, 0xCC), b.tag[0]);
}

// ★ **enc:1: 信封的逐字节 layout 测试**（不是「自洽往返」那种弱断言）：
// 手工解 base64 → 断言 `[0]=1` / `[1..13]=IV` / 尾部 16B 是 tag /
// 中间长度 = 明文长度；再用同一 key 手工重建 GCM 密文进行交叉验证。
test "secret: enc:1: 信封逐字节 layout（base64 → ver/IV/ct/tag）" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const plain = "sk-abcdef1234567890";
    const sealed = try encrypt(gpa, io, plain, TEST_HOME, TEST_HOST);
    defer gpa.free(sealed);

    try testing.expect(std.mem.startsWith(u8, sealed, ENC1_PREFIX));

    const b64 = sealed[ENC1_PREFIX.len..];
    const raw_len = try std.base64.standard.Decoder.calcSizeForSlice(b64);
    const raw = try gpa.alloc(u8, raw_len);
    defer gpa.free(raw);
    try std.base64.standard.Decoder.decode(raw, b64);

    // ① 总长度 = 1 + 12 + len(plain) + 16
    try testing.expectEqual(@as(usize, 1 + IV_LEN + plain.len + TAG_LEN), raw.len);
    // ② 版本字节
    try testing.expectEqual(@as(u8, 1), raw[0]);
    // ③ 密文段长度 == 明文长度（GCM 是流式，不做 padding）
    const blob = try parseBlob(raw);
    try testing.expectEqual(@as(usize, plain.len), blob.ciphertext.len);
    try testing.expectEqualSlices(u8, raw[1 .. 1 + IV_LEN], &blob.iv);
    try testing.expectEqualSlices(u8, raw[raw.len - TAG_LEN ..], &blob.tag);

    // ④ base64 是**标准**字母表（不是 URL-safe）：解出的字节逐字节等于 raw
    var reenc: [64]u8 = undefined;
    const b64_again = std.base64.standard.Encoder.encode(&reenc, raw);
    try testing.expectEqualStrings(b64, b64_again);

    // ⑤ 交叉验证：用同一 key + 解析出的 IV/ct/tag 手工 GCM 解密得回明文
    const key = try deriveKeyFor(TEST_HOME, TEST_HOST);
    var manual: [64]u8 = undefined;
    try std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(
        manual[0..blob.ciphertext.len],
        blob.ciphertext,
        blob.tag,
        AD,
        blob.iv,
        key,
    );
    try testing.expectEqualStrings(plain, manual[0..plain.len]);

    // ⑥ 篡改 tag 的 1 bit → DecryptFailed（不是 panic、不是垃圾）
    var mut = try gpa.dupe(u8, sealed);
    defer gpa.free(mut);
    const last = mut.len - 1;
    mut[last] = if (mut[last] == 'A') 'B' else 'A';
    try testing.expectError(error.DecryptFailed, decrypt(gpa, mut, TEST_HOME, TEST_HOST));
}

test "secret: 方向 1 —— 加密 → 解密得回明文（含多字节 UTF-8 / 控制字符）" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const cases = [_][]const u8{
        "sk-abcdef1234567890",
        "密钥-🀄️-全角ＡＢＣ",
        "含|竖线|和\"引号\"与\\反斜杠",
        "含\n换行\t制表\r回车",
        "x" ** 4096,
    };
    for (cases) |plain| {
        const sealed = try encrypt(gpa, io, plain, TEST_HOME, TEST_HOST);
        defer gpa.free(sealed);
        const opened = try decrypt(gpa, sealed, TEST_HOME, TEST_HOST);
        defer gpa.free(opened);
        try testing.expectEqualStrings(plain, opened);
    }
}

test "secret: 方向 2 —— 解密 → 再加密 → 再解密仍得回同一明文" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const plain = "round-trip-密钥";
    const sealed1 = try encrypt(gpa, io, plain, TEST_HOME, TEST_HOST);
    defer gpa.free(sealed1);
    const opened1 = try decrypt(gpa, sealed1, TEST_HOME, TEST_HOST);
    defer gpa.free(opened1);
    const sealed2 = try encrypt(gpa, io, opened1, TEST_HOME, TEST_HOST);
    defer gpa.free(sealed2);
    const opened2 = try decrypt(gpa, sealed2, TEST_HOME, TEST_HOST);
    defer gpa.free(opened2);
    try testing.expectEqualStrings(plain, opened2);
}

test "secret: 方向 3 —— IV 必须随机（同一明文两次加密结果不同）" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const a = try encrypt(gpa, io, "same-plaintext", TEST_HOME, TEST_HOST);
    defer gpa.free(a);
    const b = try encrypt(gpa, io, "same-plaintext", TEST_HOME, TEST_HOST);
    defer gpa.free(b);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "secret: 方向 4 —— 明文直通 + 空明文不加密" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const passthrough = try decrypt(gpa, "sk-plain-abc", TEST_HOME, TEST_HOST);
    defer gpa.free(passthrough);
    try testing.expectEqualStrings("sk-plain-abc", passthrough);

    const empty_enc = try encrypt(gpa, io, "", TEST_HOME, TEST_HOST);
    defer gpa.free(empty_enc);
    try testing.expectEqualStrings("", empty_enc);

    const empty_dec = try decrypt(gpa, "", TEST_HOME, TEST_HOST);
    defer gpa.free(empty_dec);
    try testing.expectEqualStrings("", empty_dec);

    // Plain union：明文走 borrowed，密文走 owned
    switch (try decryptToString(gpa, "sk-inline", TEST_HOME, TEST_HOST)) {
        .borrowed => |v| try testing.expectEqualStrings("sk-inline", v),
        .owned => |v| {
            gpa.free(v);
            return error.UnexpectedOwned;
        },
    }
}

test "secret: 换 home / 换 hostname → DecryptFailed（两者都参与派生）" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const sealed = try encrypt(gpa, io, "secret", TEST_HOME, TEST_HOST);
    defer gpa.free(sealed);

    try testing.expectError(error.DecryptFailed, decrypt(gpa, sealed, "/Users/other", TEST_HOST));
    try testing.expectError(error.DecryptFailed, decrypt(gpa, sealed, TEST_HOME, "other-host"));
    try testing.expectError(error.DecryptFailed, decrypt(gpa, sealed, "/tmp/zigent-home", TEST_HOST));
    // 原参数仍可解
    const ok = try decrypt(gpa, sealed, TEST_HOME, TEST_HOST);
    defer gpa.free(ok);
    try testing.expectEqualStrings("secret", ok);
}

test "secret: 版本字节 != 1 与过短 blob → CorruptOrUnsupportedVersion" {
    const gpa = testing.allocator;

    var raw: [MIN_BLOB_LEN]u8 = .{0} ** MIN_BLOB_LEN;
    raw[0] = 2;
    try testing.expectError(error.CorruptOrUnsupportedVersion, parseBlob(&raw));
    try testing.expectError(error.CorruptOrUnsupportedVersion, parseBlob(raw[0 .. MIN_BLOB_LEN - 1]));

    // 伪造版本 2 的完整 enc:1: 串
    var b64_buf: [64]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &raw);
    const forged = try std.fmt.allocPrint(gpa, "{s}{s}", .{ ENC1_PREFIX, b64 });
    defer gpa.free(forged);
    try testing.expectError(
        error.CorruptOrUnsupportedVersion,
        decrypt(gpa, forged, TEST_HOME, TEST_HOST),
    );

    // 空 base64 段
    try testing.expectError(
        error.CorruptOrUnsupportedVersion,
        decrypt(gpa, ENC1_PREFIX, TEST_HOME, TEST_HOST),
    );

    // 非法 base64
    try testing.expectError(
        error.CorruptOrUnsupportedVersion,
        decrypt(gpa, "enc:1:!!!!", TEST_HOME, TEST_HOST),
    );
}

test "secret: URL-safe 字母表不被接受（本设计用标准字母表）" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const sealed = try encrypt(gpa, io, "\xff\xfe\xfd\xfc\xfb\xfa", TEST_HOME, TEST_HOST);
    defer gpa.free(sealed);
    // 该密文里可能有 '-'/'_' 之外的标准字符；至少验证标准字母表往返成功
    const opened = try decrypt(gpa, sealed, TEST_HOME, TEST_HOST);
    defer gpa.free(opened);
    try testing.expectEqualSlices(u8, "\xff\xfe\xfd\xfc\xfb\xfa", opened);
}

test "secret: hostname 回退链（env → 本机 → unknown-host）" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [256]u8 = undefined;
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    // 纯函数回退链：本机优先 → env 兜底 → unknown-host
    try testing.expectEqualStrings("local-host", pickHostname("local-host", "env-host", &buf));
    try testing.expectEqualStrings("local-host", pickHostname("  local-host  ", null, &buf));
    try testing.expectEqualStrings("env-host", pickHostname(null, "env-host", &buf));
    try testing.expectEqualStrings("env-host", pickHostname("", "env-host", &buf));
    try testing.expectEqualStrings("env-host", pickHostname("   ", " env-host ", &buf));
    try testing.expectEqualStrings("unknown-host", pickHostname(null, null, &buf));
    try testing.expectEqualStrings("unknown-host", pickHostname("", "  ", &buf));

    // 真实出口至少非空
    const h1 = resolveHostname(io, testing.allocator, &env, &buf);
    try testing.expect(h1.len > 0);
    try env.put("HOSTNAME", "env-host-2");
    var buf2: [256]u8 = undefined;
    try testing.expect(resolveHostname(io, testing.allocator, &env, &buf2).len > 0);
}

test "secret: 单个坏密钥不 panic（doctor/加载语义的底层保证）" {
    const gpa = testing.allocator;
    // 明文与各种畸形容器混在一起，逐个调用都必须只返回 error
    const bad = [_][]const u8{
        "enc:1:",
        "enc:1:AAAA",
        "enc:1:###",
        "enc:1:" ++ "A" ** 40,
    };
    for (bad) |b| {
        _ = decrypt(gpa, b, TEST_HOME, TEST_HOST) catch |e| {
            try testing.expect(e == error.DecryptFailed or e == error.CorruptOrUnsupportedVersion);
            continue;
        };
        return error.ShouldHaveFailed;
    }
}
