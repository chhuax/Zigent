//! `ext/skills.zig` —— Skills 的**发现与预算**（首期不做执行）。
//!
//! 预算口径（雷区 H）：上下文窗口 × 1%（默认 `DEFAULT_CHAR_BUDGET = 8000`），
//! **单条描述 250 字符**上限。

const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("util");

pub const DEFAULT_CHAR_BUDGET: usize = 8000;
pub const MAX_DESCRIPTION_CHARS: usize = 250;

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    path: []const u8,
};

/// 从若干目录里发现 `*.md` 技能（文件名即技能名）。
/// 预算按 **code point** 计；超出预算的条目被跳过（不是截断后硬塞）。
pub fn discover(io: std.Io, gpa: Allocator, dirs: []const []const u8) ![]Skill {
    var out = std.ArrayListUnmanaged(Skill).empty;
    errdefer out.deinit(gpa);
    var used: usize = 0;

    for (dirs) |dir| {
        const paths = util.fsio.collectFiles(io, gpa, dir, .{}) catch continue;
        defer util.fsio.freePaths(gpa, paths);
        for (paths) |p| {
            if (!std.mem.endsWith(u8, p, ".md")) continue;
            const base = std.fs.path.basename(p);
            const name = base[0 .. base.len - 3];
            const text = util.fsio.readIfExists(io, gpa, p, 1 << 16) catch continue;
            const body = text orelse continue;
            const desc_full = firstMeaningfulLine(body);
            const desc = common_truncate(desc_full, MAX_DESCRIPTION_CHARS);
            if (used + desc.len > DEFAULT_CHAR_BUDGET) {
                gpa.free(body);
                continue;
            }
            used += desc.len;
            try out.append(gpa, .{
                .name = try gpa.dupe(u8, name),
                .description = try gpa.dupe(u8, desc),
                .path = try gpa.dupe(u8, p),
            });
            gpa.free(body);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn firstMeaningfulLine(text: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r#");
        if (t.len > 0) return t;
    }
    return "";
}

fn common_truncate(s: []const u8, max_cp: usize) []const u8 {
    return @import("common").usage.truncateCodePoints(s, max_cp);
}

pub fn freeSkills(gpa: Allocator, skills: []Skill) void {
    for (skills) |s| {
        gpa.free(s.name);
        gpa.free(s.description);
        gpa.free(s.path);
    }
    gpa.free(skills);
}

const testing = std.testing;

test "skills: 预算常量与文档一致" {
    try testing.expectEqual(@as(usize, 8000), DEFAULT_CHAR_BUDGET);
    try testing.expectEqual(@as(usize, 250), MAX_DESCRIPTION_CHARS);
}

test "skills: 首行提取跳过空行与 # 前缀" {
    try testing.expectEqualStrings("写博客", firstMeaningfulLine("\n# 写博客\n正文"));
    try testing.expectEqualStrings("", firstMeaningfulLine("   \n\t\n"));
}
