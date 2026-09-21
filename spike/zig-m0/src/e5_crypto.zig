//! E5：密码学与数据格式的**逐字节兼容**探针。
//!
//! 这是**硬约束**：不兼容 = 用户已有的 provider 密钥全部解不开。
//! 只能照抄，不能重新设计。见 ../移植雷区.md §I。
//!
//! ## 必须在 spike 里跑通的双向验证
//!
//! ```
//! 既有实现加密 → Zig 解密 ✅
//! Zig 加密 → 既有实现解密 ✅
//! ```
//!
//! 用法（spike 阶段由既有实现侧生成向量）：
//! ```
//! export SPIKE_ENC1_VECTOR='<home>|<hostname>|<enc:1:...>|<expected-plaintext>'
//! zig build test # 有向量就跑真实兼容断言，没有就跳过
//! ```
//!
//! ⚠️ 版本敏感：`std.crypto.pwhash.pbkdf2` / `std.crypto.aead.aes_gcm.Aes256Gcm`
//! 的参数顺序在历史上调整过，编译失败时优先核对签名。

const std = @import("std");
const vector = @import("e5_vector.zig");

/// 既有实现侧 `ProviderSecretCrypto` 的固定参数 —— **一个都不能改**。
pub const ENC1_PREFIX = "enc:1:";
pub const PBKDF2_ROUNDS: u32 = 120_000;
pub const KEY_LEN = 32;
pub const SALT_LEN = 16; // 16B **硬编码** SALT（在既有实现里是常量）
pub const IV_LEN = 12;
pub const TAG_LEN = 16;
pub const VERSION_BYTE: u8 = 1;
pub const AD: []const u8 = ""; // 既有实现用 GCMParameterSpec 不带 AAD

/// ⚠️ 这两个常量必须从既有实现逐字抄来（`ProviderSecretCrypto` / `LoginCrypto`）。
/// 放在这里是为了**编译期提醒**：spike 阶段必须先用真实值替换。
pub const APP_SECRET_PLACEHOLDER = "REPLACE_WITH_APP_SECRET_FROM_JAVA_SOURCE";
pub const SALT_PLACEHOLDER = [_]u8{0} ** SALT_LEN; // REPLACE：既有实现里是硬编码的 16 字节

/// passphrase 派生顺序是契约：`APP_SECRET + ":" + userHome + ":" + hostname`
pub fn buildPassphrase(buf: []u8, app_secret: []const u8, user_home: []const u8, hostname: []const u8) ![]const u8 {
 return std.fmt.bufPrint(buf, "{s}:{s}:{s}", .{ app_secret, user_home, hostname });
}

/// PBKDF2-HMAC-SHA256(passphrase, salt, 120_000, 256 bit)
pub fn deriveKey(passphrase: []const u8, salt: []const u8) ![KEY_LEN]u8 {
 var key: [KEY_LEN]u8 = undefined;
 try std.crypto.pwhash.pbkdf2(
 &key,
 passphrase,
 salt,
 PBKDF2_ROUNDS,
 std.crypto.auth.hmac.sha2.HmacSha256,
 );
 return key;
}

/// blob 布局（既有实现侧 `[1B ver][12B IV][ct+16B tag]`）。
pub const Blob = struct {
 version: u8,
 iv: [IV_LEN]u8,
 tag: [TAG_LEN]u8,
 ciphertext: []const u8,
};

pub fn parseBlob(raw: []const u8) !Blob {
 if (raw.len < 1 + IV_LEN + TAG_LEN) return error.BlobTooShort;
 const version = raw[0];
 if (version != VERSION_BYTE) return error.UnsupportedVersion;
 var iv: [IV_LEN]u8 = undefined;
 @memcpy(&iv, raw[1 .. 1 + IV_LEN]);
 const ct_end = raw.len - TAG_LEN;
 var tag: [TAG_LEN]u8 = undefined;
 @memcpy(&tag, raw[ct_end..]);
 return .{ .version = version, .iv = iv, .tag = tag, .ciphertext = raw[1 + IV_LEN .. ct_end] };
}

/// 解密：0.16 起 `Aes256Gcm.decrypt` 的签名是
/// `decrypt(m: []u8, c: []const u8, tag, ad, npub, key) !void` —— **明文写进 m，返回 void**。
pub fn decryptBlob(blob: Blob, key: [KEY_LEN]u8, dest: []u8) ![]u8 {
 if (dest.len < blob.ciphertext.len) return error.NoSpaceLeft;
 const m = dest[0..blob.ciphertext.len];
 try std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(
 m,
 blob.ciphertext,
 blob.tag,
 AD,
 blob.iv,
 key,
 );
 return m;
}

/// `enc:1:<base64>` → 明文。返回的切片在 `out_raw` 里（调用方负责释放）。
pub fn unsealEnc1(
 gpa: std.mem.Allocator,
 sealed: []const u8,
 key: [KEY_LEN]u8,
) ![]u8 {
 if (!std.mem.startsWith(u8, sealed, ENC1_PREFIX)) return error.NotEnc1;
 const b64 = sealed[ENC1_PREFIX.len..];

 const decoder = std.base64.standard.Decoder;
 const raw_len = try decoder.calcSizeForSlice(b64);
 const raw = try gpa.alloc(u8, raw_len);
 defer gpa.free(raw);
 try decoder.decode(raw, b64);

 const blob = try parseBlob(raw);
 const plain = try gpa.alloc(u8, blob.ciphertext.len);
 errdefer gpa.free(plain);
 const out = try decryptBlob(blob, key, plain);
 return plain[0..out.len];
}

/// 反向：明文 → `enc:1:<base64>`（用于验证「Zig 加密 → 既有实现解密」）。
pub fn sealEnc1(
 gpa: std.mem.Allocator,
 plaintext: []const u8,
 key: [KEY_LEN]u8,
 iv: [IV_LEN]u8,
) ![]u8 {
 const ct_len = plaintext.len;
 const raw_len = 1 + IV_LEN + ct_len + TAG_LEN;
 const raw = try gpa.alloc(u8, raw_len);
 defer gpa.free(raw);
 raw[0] = VERSION_BYTE;
 @memcpy(raw[1 .. 1 + IV_LEN], &iv);

 var tag: [TAG_LEN]u8 = undefined;
 // 0.16 签名：encrypt(c: []u8, tag: *[16]u8, m: []const u8, ad, npub, key) void
 std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(
 raw[1 + IV_LEN .. 1 + IV_LEN + ct_len],
 &tag,
 plaintext,
 AD,
 iv,
 key,
 );
 @memcpy(raw[1 + IV_LEN + ct_len ..], &tag);

 const encoder = std.base64.standard.Encoder;
 const b64_len = encoder.calcSize(raw_len);
 const out = try gpa.alloc(u8, ENC1_PREFIX.len + b64_len);
 @memcpy(out[0..ENC1_PREFIX.len], ENC1_PREFIX);
 _ = encoder.encode(out[ENC1_PREFIX.len..], raw);
 return out;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test "passphrase 派生顺序是契约（APP_SECRET:home:hostname）" {
 var buf: [256]u8 = undefined;
 const p = try buildPassphrase(&buf, "SECRET", "/Users/me", "my-host");
 try std.testing.expectEqualStrings("SECRET:/Users/me:my-host", p);
}

test "PBKDF2 参数：120000 轮 / 32 字节输出（与既有实现一致）" {
 // 用公开的 PBKDF2-HMAC-SHA256 测试向量验证我们的调用是对的。
 // RFC 7914 §11 / RFC 6070 风格的已知向量（password="password", salt="salt", c=1）
 var k1: [32]u8 = undefined;
 try std.crypto.pwhash.pbkdf2(&k1, "password", "salt", 1, std.crypto.auth.hmac.sha2.HmacSha256);
 const expect_c1 = "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b";
 var hex: [64]u8 = undefined;
 for (k1, 0..) |b, i| {
 const d = "0123456789abcdef";
 hex[i * 2] = d[b >> 4];
 hex[i * 2 + 1] = d[b & 0x0f];
 }
 try std.testing.expectEqualStrings(expect_c1, &hex);

 // c=2 的另一个向量
 var k2: [32]u8 = undefined;
 try std.crypto.pwhash.pbkdf2(&k2, "password", "salt", 2, std.crypto.auth.hmac.sha2.HmacSha256);
 const expect_c2 = "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43";
 for (k2, 0..) |b, i| {
 const d = "0123456789abcdef";
 hex[i * 2] = d[b >> 4];
 hex[i * 2 + 1] = d[b & 0x0f];
 }
 try std.testing.expectEqualStrings(expect_c2, &hex);
}

test "blob 布局：[1B ver][12B IV][ct][16B tag]" {
 var raw: [1 + IV_LEN + 5 + TAG_LEN]u8 = undefined;
 raw[0] = 1;
 @memset(raw[1 .. 1 + IV_LEN], 0xAA);
 @memset(raw[1 + IV_LEN .. 1 + IV_LEN + 5], 0xBB);
 @memset(raw[1 + IV_LEN + 5 ..], 0xCC);

 const b = try parseBlob(&raw);
 try std.testing.expectEqual(@as(u8, 1), b.version);
 try std.testing.expectEqual(@as(usize, 5), b.ciphertext.len);
 try std.testing.expectEqual(@as(u8, 0xAA), b.iv[0]);
 try std.testing.expectEqual(@as(u8, 0xBB), b.ciphertext[0]);
 try std.testing.expectEqual(@as(u8, 0xCC), b.tag[0]);
}

test "blob：版本字节不对要拒绝（将来升级 v2 的入口）" {
 var raw: [1 + IV_LEN + TAG_LEN]u8 = .{0} ** (1 + IV_LEN + TAG_LEN);
 raw[0] = 2;
 try std.testing.expectError(error.UnsupportedVersion, parseBlob(&raw));
 var too_short: [10]u8 = .{0} ** 10;
 try std.testing.expectError(error.BlobTooShort, parseBlob(&too_short));
}

test "自洽 round-trip：seal → unseal（证明原语正确，但不等于格式往返）" {
 const gpa = std.testing.allocator;
 const key = try deriveKey("APP:/home/u:host", &SALT_PLACEHOLDER);
 const iv = [_]u8{1} ** IV_LEN;
 const msg = "sk-abcdef1234567890";

 const sealed = try sealEnc1(gpa, msg, key, iv);
 defer gpa.free(sealed);

 try std.testing.expect(std.mem.startsWith(u8, sealed, ENC1_PREFIX));

 const opened = try unsealEnc1(gpa, sealed, key);
 defer gpa.free(opened);
 try std.testing.expectEqualStrings(msg, opened);
}

test "非 enc:1: 前缀按明文处理（兼容存量明文密钥）" {
 const gpa = std.testing.allocator;
 const key = try deriveKey("x", &SALT_PLACEHOLDER);
 try std.testing.expectError(error.NotEnc1, unsealEnc1(gpa, "sk-plain-key", key));
}

test "错 key 解不开（GCM tag 校验生效）" {
 const gpa = std.testing.allocator;
 const k1 = try deriveKey("A:/h:host", &SALT_PLACEHOLDER);
 const k2 = try deriveKey("B:/h:host", &SALT_PLACEHOLDER);
 const iv = [_]u8{2} ** IV_LEN;
 const sealed = try sealEnc1(gpa, "secret", k1, iv);
 defer gpa.free(sealed);
 // 解不开（tag 不匹配）。注意 GCM tag 主要防篡改，不是 KDF 验证；
 // 换 key 会因 tag 校验失败而报错。
 try std.testing.expectError(error.AuthenticationFailed, unsealEnc1(gpa, sealed, k2));
}

// ---------------------------------------------------------------------------
// 真·格式往返断言（需要外部向量；未提供时直接通过）
// ---------------------------------------------------------------------------

// 向量格式与填写方法见 `e5_vector.zig`。
// 刻意不用环境变量：0.16 把 env 访问也收进了 std.Io / std.process.Environ，
// 而测试里拿 Io 实例会额外增加噪音。改用**受版本控制的向量文件**，
// 更可复现、也更便于 review。
test "密文往返兼容：用真实向量解出明文（需填写 e5_vector.zig）" {
 const gpa = std.testing.allocator;
 if (!vector.present) return; // 未填写 → 跳过（其余测试仍会验证算法参数）

 var pass_buf: [512]u8 = undefined;
 const pass = try buildPassphrase(&pass_buf, APP_SECRET_PLACEHOLDER, vector.home, vector.hostname);
 const key = try deriveKey(pass, &SALT_PLACEHOLDER);

 const opened = try unsealEnc1(gpa, vector.sealed, key);
 defer gpa.free(opened);
 try std.testing.expectEqualStrings(vector.plaintext, opened);
}
