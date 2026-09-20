//! config/ —— L1 接入
//!
//! 配置与鉴权：**路径唯一出口** · 分层设置 · provider/模型目录 · `enc:1:` 密文。
//!
//! 允许的依赖（由 `build.zig` 声明；**别的模块 import 不进来**）：
//!   ← common
//!   ← util
//!
//! ## 目录契约（最容易记错的一条，文档 03 §6.3 / 文档 10 §1）
//!
//! ```
//! 用户级    ~/.zigent/                              机器私有：配置 / 密钥 / 全局记忆
//! 工作区级  <cwd>/.agents/                           可提交：settings / skills / AGENTS.md
//! 运行时    ~/.zigent/projects/<encoded-cwd>/       transcript / tool-results / goals / worktrees
//! 记忆热核  ~/.zigent/memories/<ns>/                **不是** <cwd>/.agents/memory/
//! ```
//!
//! ## 分层 settings 优先级（低 → 高）
//!
//! ```
//! 内置默认 < ~/.zigent/settings.json < <cwd>/.agents/settings.json
//!          < <cwd>/.agents/settings.local.json
//!          < ~/.zigent/settings.managed.json < ~/.zigent/settings.policy.json
//!          < 环境变量覆盖
//! ```
//!
//! 失效判定用**合并后内容的 SHA-256**（不是 mtime）；未知字段一律保留。

const std = @import("std");
const common = @import("common");
const util = @import("util");

pub const paths = @import("paths.zig");
pub const settings = @import("settings.zig");
pub const userconfig = @import("userconfig.zig");
pub const auth = @import("auth.zig");
pub const secret = @import("secret.zig");

// ── INTERFACES §4.1 的类型直达 re-export（消费点不必写两级路径）──
pub const Paths = paths.Paths;
pub const Settings = settings.Settings;
pub const UserConfig = userconfig.UserConfig;
pub const ProviderEntry = userconfig.ProviderEntry;
pub const Tier = userconfig.Tier;

/// 模块自述 —— 也用来**强制引用每个声明的依赖**：
/// 没有下面这段 comptime 触碰，Zig 的惰性编译会让 `build.zig` 的声明形同虚设。
pub const module_info = .{
    .name = "config",
    .layer = "L1 接入",
    .deps = &[_][]const u8{ "common", "util" },
};

comptime {
    _ = common.module_info.name;
    _ = util.module_info.name;
    _ = paths;
    _ = settings;
    _ = userconfig;
    _ = auth;
    _ = secret;
}

test "config: 依赖链可解析" {
    try std.testing.expectEqualStrings("config", module_info.name);
}

test {
    std.testing.refAllDecls(@This());
}

// 显式触碰每个文件，保证「只 import 不引用」也不会让某个文件的测试被静默跳过。
test "config: 每个子模块都被引用（测试不会静默漏跑）" {
    _ = paths;
    _ = settings;
    _ = userconfig;
    _ = auth;
    _ = secret;
    // 契约类型的形状锚点：改了这些就等于改了 INTERFACES。
    _ = Paths{ .home = "", .cwd = "" };
    _ = Settings{};
    _ = UserConfig{};
}
