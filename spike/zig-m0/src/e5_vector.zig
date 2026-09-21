//! E5 的真实兼容向量（由既有实现侧生成后填写）。
//!
//! 生成方法（既有实现）：
//! ```java
//! System.out.println(home + "|" + host + "|"
//! + ProviderSecretCrypto.encrypt("sk-test") + "|sk-test");
//! ```
//!
//! 然后：
//! 1) 把 `present` 改成 `true`
//! 2) 填入四个字段
//! 3) `zig build test`
//!
//! ⚠️ 另外必须把 `e5_crypto.zig` 里的 `APP_SECRET_PLACEHOLDER` / `SALT_PLACEHOLDER`
//! 换成既有实现里的真实常量，否则一定解不开。

/// 填好之后改成 true，测试才会跑真实断言。
pub const present = false;

pub const home = "";
pub const hostname = "";
/// 完整形态：`enc:1:<base64>`
pub const sealed = "";
pub const plaintext = "";
