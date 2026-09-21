//! `tools/` —— L2 能力：**首期 8 个工具** + 单一 schema 真源。
//!
//! 允许的依赖（由 `build.zig` 声明；**别的模块 import 不进来**）：
//!   ← common
//!
//! 两条结构性纪律（INTERFACES-v1 §4.4 / 文档 03 §9）：
//!   1. `tools/` 绝不 import `engine/`：运行时状态只经 `ToolContext` / `ToolContext.host`；
//!   2. `tools/` 只 import `common`：权限**契约**类型在 `common/perm.zig`，不需要 `perm/`。
//!
//! `Registry.get` 必须同时命中 **canonical 名与别名**（transcript 里存的是历史名，
//! 删一个别名 = 一类会话再也 resume 不回来）。

const std = @import("std");
const common = @import("common");
const util = @import("util");

pub const module_info = .{
    .name = "tools",
    .layer = "L2 能力",
    .deps = &[_][]const u8{ "common", "util" },
};

// ── 子模块 ──
pub const specs = @import("specs.zig");
pub const sys = @import("sys.zig");
pub const diff = @import("diff.zig");
pub const regex = @import("regex.zig");
pub const truncate = @import("truncate.zig");

pub const read = @import("read.zig");
pub const write = @import("write.zig");
pub const edit = @import("edit.zig");
pub const bash = @import("bash.zig");
pub const glob = @import("glob.zig");
pub const grep = @import("grep.zig");
pub const todo = @import("todo.zig");
pub const ask = @import("ask.zig");

/// 给 `llm.ToolSpec` 的镜像结构 —— **刻意不 import `llm`**（否则依赖方向反过来）。
/// 字段名与 `llm.ToolSpec` 逐字一致，装配点直接字段映射即可。
pub const ToolSpecOut = struct {
    name: []const u8,
    description: []const u8,
    schema_json: []const u8,
};

/// 工具注册表 —— **每会话一个实例**，没有全局单例、没有容器级 `var`。
pub const Registry = struct {
    gpa: std.mem.Allocator,
    tools: []const common.Tool,

    /// 名字 / 别名解析（`common.Tool.matches` 同时比 canonical 与 `aliases`）。
    pub fn get(self: *const Registry, name: []const u8) ?common.Tool {
        for (self.tools) |t| {
            if (t.matches(name)) return t;
        }
        return null;
    }

    pub fn count(self: *const Registry) usize {
        return self.tools.len;
    }

    /// 8 份模型 schema（调用方用 `freeModelSpecs` 释放）。
    pub fn modelSpecs(self: *const Registry, gpa: std.mem.Allocator) ![]ToolSpecOut {
        const out = try gpa.alloc(ToolSpecOut, self.tools.len);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |s| gpa.free(s.schema_json);
            gpa.free(out);
        }
        for (self.tools, 0..) |t, i| {
            out[i] = .{
                .name = t.name,
                .description = t.description,
                .schema_json = try t.spec.modelSchemaAlloc(gpa),
            };
            built += 1;
        }
        return out;
    }

    pub fn deinit(self: *Registry) void {
        self.gpa.free(self.tools);
        self.tools = &.{};
    }
};

pub fn freeModelSpecs(gpa: std.mem.Allocator, list: []ToolSpecOut) void {
    for (list) |s| gpa.free(s.schema_json);
    gpa.free(list);
}

/// canonical 名（顺序即注册顺序）。
pub const registered_names = [_][]const u8{
    "Read",      "Write",      "Edit",      "Bash",
    "Glob",      "Grep",       "TodoWrite", "ask_user_question",
};

/// **首期唯一的装配点**：8 个工具，全部只依赖 `common`。
pub fn defaultRegistry(gpa: std.mem.Allocator) !Registry {
    const tools = try gpa.alloc(common.Tool, 8);
    errdefer gpa.free(tools);
    tools[0] = read.definition;
    tools[1] = write.definition;
    tools[2] = edit.definition;
    tools[3] = bash.definition;
    tools[4] = glob.definition;
    tools[5] = grep.definition;
    tools[6] = todo.definition;
    tools[7] = ask.definition;
    return .{ .gpa = gpa, .tools = tools };
}

comptime {
    _ = common.module_info.name;
    _ = util.module_info.name;
    _ = specs;
    _ = sys;
    _ = diff;
    _ = regex;
    _ = truncate;
    _ = read;
    _ = write;
    _ = edit;
    _ = bash;
    _ = glob;
    _ = grep;
    _ = todo;
    _ = ask;
}

// ─────────────────────────────────────────────────────────────────────────────
// 测试（聚合 + 门禁）
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test {
    // 触碰到每个文件 → Zig 才会把它们的 test 块编译进来。
    _ = specs;
    _ = sys;
    _ = diff;
    _ = regex;
    _ = truncate;
    _ = read;
    _ = write;
    _ = edit;
    _ = bash;
    _ = glob;
    _ = grep;
    _ = todo;
    _ = ask;
}

test "root: 依赖链可解析" {
    try testing.expectEqualStrings("tools", module_info.name);
    try testing.expectEqual(@as(usize, 2), module_info.deps.len);
    try testing.expectEqualStrings("common", module_info.deps[0]);
    try testing.expectEqualStrings("util", module_info.deps[1]);
}

test "root: 默认注册表恰好 8 个工具，canonical 名齐全" {
    var reg = try defaultRegistry(testing.allocator);
    defer reg.deinit();
    try testing.expectEqual(@as(usize, 8), reg.count());
    for (registered_names) |n| {
        try testing.expect(reg.get(n) != null);
    }
}

test "root: Registry.get 命中别名（transcript 兼容）" {
    var reg = try defaultRegistry(testing.allocator);
    defer reg.deinit();

    const alias_cases = [_][2][]const u8{
        .{ "Read", "read_file" },
        .{ "Write", "write_file" },
        .{ "Edit", "edit_file" },
        .{ "Bash", "bash" },
        .{ "Glob", "glob" },
        .{ "Grep", "grep" },
        .{ "TodoWrite", "todo_write" },
    };
    for (alias_cases) |c| {
        const by_canonical = reg.get(c[0]).?;
        const by_alias = reg.get(c[1]).?;
        try testing.expectEqualStrings(c[0], by_canonical.name);
        try testing.expectEqualStrings(c[0], by_alias.name);
    }
    // ask_user_question 无别名（逐字保留 snake_case）
    try testing.expectEqualStrings("ask_user_question", reg.get("ask_user_question").?.name);
    try testing.expect(reg.get("AskUserQuestion") == null);
    try testing.expect(reg.get("nope") == null);
}

test "root: 每个工具的 spec 与注册表定义同源，modelSpecs JSON 合法" {
    var reg = try defaultRegistry(testing.allocator);
    defer reg.deinit();

    const all = try reg.modelSpecs(testing.allocator);
    defer freeModelSpecs(testing.allocator, all);
    try testing.expectEqual(@as(usize, 8), all.len);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (all) |s| {
        _ = try common.json.parse(arena.allocator(), s.schema_json);
        const t = reg.get(s.name).?;
        try testing.expectEqualStrings(t.description, s.description);
        try testing.expect(std.mem.indexOf(u8, s.schema_json, "\"additionalProperties\":false") != null);
    }
}

test "root: 三维分类与结果上限（表驱动门禁）" {
    var reg = try defaultRegistry(testing.allocator);
    defer reg.deinit();

    try testing.expect(reg.get("Read").?.is_read_only("{}"));
    try testing.expect(reg.get("Glob").?.is_read_only("{}"));
    try testing.expect(reg.get("Grep").?.is_read_only("{}"));
    try testing.expect(reg.get("ask_user_question").?.is_read_only("{}"));

    try testing.expect(reg.get("Write").?.is_destructive("{}"));
    try testing.expect(reg.get("Edit").?.is_destructive("{}"));
    try testing.expect(!reg.get("Read").?.is_destructive("{}"));

    try testing.expect(reg.get("Read").?.is_concurrency_safe("{}"));
    try testing.expect(!reg.get("Write").?.is_concurrency_safe("{}"));
    try testing.expect(!reg.get("Bash").?.is_concurrency_safe("{}"));

    // Bash 的 read_only 是动态判定
    try testing.expect(reg.get("Bash").?.is_read_only("{\"command\":\"ls -la\"}"));
    try testing.expect(!reg.get("Bash").?.is_read_only("{\"command\":\"rm -rf /\"}"));

    try testing.expectEqual(@as(usize, 400_000), reg.get("Read").?.max_result_chars);
    try testing.expectEqual(@as(usize, 400_000), reg.get("TodoWrite").?.max_result_chars);
    try testing.expectEqual(@as(usize, 50_000), reg.get("Bash").?.max_result_chars);
    try testing.expectEqual(@as(usize, 50_000), reg.get("Grep").?.max_result_chars);
    try testing.expectEqual(@as(usize, 65_536), reg.get("Glob").?.max_result_chars);
}

test "root: 工具自判权限默认 defer（首期 8 个都没覆盖 check_permissions）" {
    var reg = try defaultRegistry(testing.allocator);
    defer reg.deinit();
    var ctx = common.ToolContext{ .gpa = testing.allocator, .io = undefined, .cwd = "/" };
    for (reg.tools) |t| {
        try testing.expectEqual(common.perm.Verdict.deferred, t.permissions("{}", &ctx).verdict);
    }
}
