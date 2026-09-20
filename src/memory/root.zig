//! memory/ —— L2 能力
//!
//! 记忆热核 + 归档检索 + 指令文件 + 注入防护。
//!
//! 允许的依赖（由 `build.zig` 声明；**别的模块 import 不进来**）：
//!   ← common
//!
//! ## 对外契约（`docs/internal/INTERFACES-v1.md` §4.5）
//!
//! ```zig
//! memory.Limits / memory.HotMemory / memory.Kind
//! memory.injection.scan / memory.injection.sanitize
//! memory.Archive.Entry / memory.Archive.Hit / memory.Archive.append / .search
//! memory.instructions.File / .discover / .render
//! ```
//!
//! ## 四条正交链（文档 03 §10）里本模块负责的两条
//!
//! - **② 持久记忆（跨会话）**：热核 `MEMORY.md` / `USER.md`（`hot.zig`）
//!   + 归档 JSONL grep 打分（`archive.zig`）+ 注入防护（`injection.zig`）；
//! - **① 指令文件（项目约定）**：`AGENTS.md` 家族 + `@include`（`instructions.zig`）。
//!
//! ③ 会话记忆、④ 会话检索在别处（engine / tools），本模块只提供存储与检索原语。
//!
//! ## 依赖与 IO 边界
//!
//! `build.zig`：`link(memory, &.{ .{ "common", common }, .{ "util", util } })`。
//! **系统级原语只允许出现在 `util/io.zig` + `util/fsio.zig`** ——
//! 本模块一律通过 `util.io.*` / `util.fsio.*` 读写、建目录、删树、取 cwd。
//! 路径（`<dir>` / `cwd` / `home`）仍然全部由 engine 作为参数传入，
//! 所以 `memory/` **不依赖 `config`**。
//!
//! `memory/` 里唯一"自带"的 OS 相关代码是 `testutil.zig`：测试专用沙箱，
//! 只在 `test` 块里被引用（非测试编译单元不会分析它），且它自己也只用 `util.io`。

const std = @import("std");
const testing = std.testing;
const common = @import("common");
const util = @import("util");

/// 模块自述 —— 也用来**强制引用每个声明的依赖**：
/// 没有下面这段 comptime 触碰，Zig 的惰性编译会让 `build.zig` 的声明形同虚设。
pub const module_info = .{
    .name = "memory",
    .layer = "L2 能力",
    .deps = &[_][]const u8{ "common", "util" },
};

comptime {
    _ = common.module_info.name;
    _ = util.module_info.name;
}

// ── 子模块 ───────────────────────────────────────────────────────────────────

/// 热核记忆。
pub const hot = @import("hot.zig");
/// 注入防护（威胁规则表 + 读取侧过滤）。
pub const injection = @import("injection.zig");
/// 归档检索（方案 A：JSONL + grep + 打分）。
pub const archive = @import("archive.zig");
/// 指令文件（`AGENTS.md` + `@include`）。
pub const instructions = @import("instructions.zig").instructions;

// ── 契约直达 re-export（消费点不必写两级路径）───────────────────────────────

pub const Limits = hot.Limits;
pub const Kind = hot.Kind;
pub const HotMemory = hot.HotMemory;

pub const Archive = archive.Archive;
pub const ArchiveEntry = archive.Archive.Entry;
pub const ArchiveHit = archive.Archive.Hit;

pub const InstructionFile = instructions.File;

test "memory: 依赖链可解析" {
    try testing.expectEqualStrings("memory", module_info.name);
    try testing.expectEqualStrings("L2 能力", module_info.layer);
    try testing.expectEqual(@as(usize, 2), module_info.deps.len);
    try testing.expectEqualStrings("common", module_info.deps[0]);
    try testing.expectEqualStrings("util", module_info.deps[1]);
}

// 契约形态自检：INTERFACES-v1 §4.5 里的每个入口都必须存在且**可调用**
// （这里只做 comptime 触碰 —— 真正的行为在各自文件的测试里）。
test "memory: 契约 §4.5 的入口全部可解析" {
    comptime {
        _ = &HotMemory.load;
        _ = &HotMemory.render;
        _ = &HotMemory.append;
        _ = &HotMemory.deinit;

        _ = &injection.scan;
        _ = &injection.sanitize;
        _ = &injection.rules;

        _ = Archive.Entry;
        _ = Archive.Hit;
        _ = &Archive.append;
        _ = &Archive.search;

        _ = instructions.File;
        _ = &instructions.discover;
        _ = &instructions.render;

        _ = Limits.default;
        _ = Kind.memory;
        _ = Kind.user;
    }
}

test {
    _ = @import("hot.zig");
    _ = @import("injection.zig");
    _ = @import("archive.zig");
    _ = @import("instructions.zig");
}
