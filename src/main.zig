//! Zigent 入口 —— 只负责把控制权交给 cli/。
//!
//! 单向依赖的最后一环：main → cli → {server, client_proto} → engine → L2 → L1 → L0。
//!
//! `main` 取 `std.process.Init`，因此 `gpa` / `io` / `environ_map` 由运行时注入，
//! **不需要任何全局单例**（文档 11 验收 #1）。
const std = @import("std");
const cli = @import("cli");

pub fn main(init: std.process.Init) !void {
    const code = try cli.run(init);
    if (code != 0) std.process.exit(code);
}
