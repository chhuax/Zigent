//! `perm/shell.zig` —— L3.5 Shell 危险命令检测与风险分级。
//!
//! 设计依据：`docs/analysis/2026-09-19-07-权限与安全设计.md` §4 与 §13.2。
//!
//! **两条独立的风险轴**（§11.1 反直觉点 1，Zig 必须拆成两个字段）：
//!   * **工具级**：`Bash` / `PowerShell` 的 `tool_risk_level` **恒为 `.high`**
//!     （`RiskLevel` 里没有 `DESTRUCTIVE`，`.high` 就是它的 wire 名 `HIGH` 的载体），
//!     连 `ls` 也一样 —— 见 `classify.riskLevelOf`。
//!   * **命令级**：`ShellAssessment.risk_level` → `Outcome.command_risk_level`，
//!     取值 `read_only` / `review` / `write` / `network` / `high`。
//!   朴素实现把命令级藏在 `inputSummary` 的文本里，导致卡片无法按等级上色。
//!
//! ⚠️ **22 条模式的匹配口径：在**整条原始命令串**上做 `find`，不做引号剥离**
//! （§4.3 末的硬约束，也写进 §14 差异清单 #12）：
//!   * `echo "rm -rf /"` → **DENY**（假阳性）—— 首期照抄既有行为过 G6 对等门禁；
//!   * 收紧成「token 级、引号内文本不算」是二期的事，与 realpath 加固同批。
//! 唯一例外是 3 个**局部大小写敏感**的开关（`-B` / `-D` / `-C`）：大小写是语义
//! （大写 = reset/force，小写 = 新建/安全删除），**绝不能把整条命令小写化**。
//!
//! Zig 标准库 0.16 **没有** `std.regex`（§4.4 末），所以这里用 `std.mem.indexOf`
//! 手写 22 个谓词 —— 每条谓词的形状都对着设计文档里的正则逐条翻译。

const std = @import("std");
const common = @import("common");

/// 大小写不敏感的子串查找（对应正则编译选项 `CASE_INSENSITIVE`）。
fn findCI(haystack: []const u8, needle: []const u8) bool {
    return containsIgnoreCase(haystack, needle);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// 大小写敏感的 `\b<word>` 判定。前一个字符不能是 `[A-Za-z0-9_]`。
fn wordAtCI(haystack: []const u8, from: usize, word: []const u8) bool {
    if (from + word.len > haystack.len) return false;
    if (!std.ascii.eqlIgnoreCase(haystack[from .. from + word.len], word)) return false;
    if (from > 0 and isWordChar(haystack[from - 1])) return false;
    const after = from + word.len;
    if (after < haystack.len and isWordChar(haystack[after])) return false;
    return true;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `\b<needle>`（只要求左侧边界），用于 `\bdrop\s+...` 这类前缀匹配。
fn startsWordCI(haystack: []const u8, from: usize, needle: []const u8) bool {
    if (from + needle.len > haystack.len) return false;
    if (!std.ascii.eqlIgnoreCase(haystack[from .. from + needle.len], needle)) return false;
    if (from > 0 and isWordChar(haystack[from - 1])) return false;
    return true;
}

/// `\s+`：至少一个空白。
fn skipSpaces(s: []const u8, from: usize) ?usize {
    var i = from;
    while (i < s.len and std.ascii.isWhitespace(s[i])) : (i += 1) {}
    if (i == from) return null;
    return i;
}

fn nextNonSpace(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and std.ascii.isWhitespace(s[i])) : (i += 1) {}
    return i;
}

/// 在 `s[from..]` 中按大小写不敏感找 `needle`；返回绝对下标。
fn indexOfCI(s: []const u8, from: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return if (from <= s.len) from else null;
    if (from >= s.len or s.len - from < needle.len) return null;
    var i = from;
    while (i + needle.len <= s.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(s[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// 取以空白为界的下一个 token（不解引号 —— 谓词只看形状）。
fn nextToken(s: []const u8, from: usize) ?struct { start: usize, end: usize } {
    var i = from;
    while (i < s.len and std.ascii.isWhitespace(s[i])) : (i += 1) {}
    if (i >= s.len) return null;
    const start = i;
    while (i < s.len and !std.ascii.isWhitespace(s[i])) : (i += 1) {}
    return .{ .start = start, .end = i };
}

/// 取 `git` 之后的子命令（跳过中间的全局开关，如 `-c k=v`、`--no-pager`）。
/// `git_token_start` 是**命令名 token**（可能是 `/usr/bin/git`）在 `raw` 里的起点；
/// 调用方应传 `firstCommandSpan(...).token_start`，这样前缀剥离后的偏移才是对的。
fn gitSubcommand(raw: []const u8, git_token_start: usize) ?[]const u8 {
    const name_tok = nextToken(raw, git_token_start) orelse return null;
    var i = name_tok.end;
    while (nextToken(raw, i)) |tok| {
        const t = raw[tok.start..tok.end];
        if (std.mem.startsWith(u8, t, "-")) {
            i = tok.end;
            continue;
        }
        return t;
    }
    return null;
}

/// `git checkout` 之后、同一段之内的 token 序列。
fn tokensBetween(raw: []const u8, from: usize, stop_at_separator: bool) []const u8 {
    var i = from;
    var last_non_space: usize = from;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (stop_at_separator and (c == '|' or c == ';' or c == '&' or c == '\n')) break;
        if (c == '"' or c == '\'') {
            // 引号内的分隔符不切断（B4）。
            const q = c;
            i += 1;
            while (i < raw.len and raw[i] != q) : (i += 1) {}
            last_non_space = i;
            continue;
        }
        if (!std.ascii.isWhitespace(c)) last_non_space = i;
    }
    return raw[from..@min(last_non_space + 1, raw.len)];
}

// ── 风险标记（11 个，对应 §4.1 的 packed struct）──────────────────────────────

pub const RiskFlags = packed struct(u16) {
    write_redirect: bool = false,
    destructive_command: bool = false,
    in_place_edit: bool = false,
    command_substitution: bool = false,
    subshell: bool = false,
    heredoc: bool = false,
    glob: bool = false,
    powershell_alias: bool = false,
    uncertain_parse: bool = false,
    network_access: bool = false,
    sandbox_bypass: bool = false,
    _pad: u5 = 0,

    /// wire 名与 `ShellRiskFlag` 常量名逐字一致（审计与权限卡片都用这个形态）。
    pub const wire_names = [11][]const u8{
        "WRITE_REDIRECT",
        "DESTRUCTIVE_COMMAND",
        "IN_PLACE_EDIT",
        "COMMAND_SUBSTITUTION",
        "SUBSHELL",
        "HEREDOC",
        "GLOB",
        "POWERSHELL_ALIAS",
        "UNCERTAIN_PARSE",
        "NETWORK_ACCESS",
        "SANDBOX_BYPASS",
    };

    pub fn wireNames(self: RiskFlags, out: *[11][]const u8) []const []const u8 {
        var n: usize = 0;
        inline for (wire_names) |name| {
            const field_name = comptime fieldNameForWire(name);
            if (@field(self, field_name)) {
                out[n] = name;
                n += 1;
            }
        }
        return out[0..n];
    }

    /// wire 名 → 字段名的编译期映射（wire 名是全大写常量，字段是小写 snake_case）。
    fn fieldNameForWire(comptime wire: []const u8) []const u8 {
        inline for (@typeInfo(RiskFlags).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "_pad")) continue;
            if (comptime asciiUpperEql(f.name, wire)) return f.name;
        }
        @compileError("unknown RiskFlags wire name: " ++ wire);
    }

    fn asciiUpperEql(comptime field: []const u8, comptime wire: []const u8) bool {
        if (field.len != wire.len) return false;
        for (field, wire) |a, b| {
            if (std.ascii.toUpper(a) != b) return false;
        }
        return true;
    }

    pub fn any(self: RiskFlags) bool {
        return @as(u16, @bitCast(self)) != 0;
    }
};

/// `ShellAssessment` 对风险等级归类的稳定标签（测试与卡片都用它，**不是**实现细节）。
pub const Classification = enum {
    empty,
    dangerous,
    mutating,
    risky_glob,
    network,
    nested,
    read_only,
    review,
    /// 只有 fd 复制（`2>&1` 这类）而没有真实文件目标。
    fd_dup,
    uncertain,

    pub fn wireName(self: Classification) []const u8 {
        return switch (self) {
            .empty => "EMPTY",
            .dangerous => "DESTRUCTIVE",
            .mutating => "WRITE",
            .risky_glob => "RISKY_GLOB",
            .network => "NETWORK",
            .nested => "NESTED",
            .read_only => "READ_ONLY",
            .review => "REVIEW",
            .fd_dup => "FD_DUP",
            .uncertain => "UNCERTAIN_PARSE",
        };
    }
};

// ── 22 条破坏性谓词（§4.3 逐条）──────────────────────────────────────────────

/// 模式 1：`\brm\s+(-\w*f\w*\s+|--recursive\s+|--force\s+)`
/// 注意 `-r`（不含 f）**不命中** → 落到 ASK WRITE（§13.2 用例 2）。
fn matchRmForce(raw: []const u8) bool {
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (!startsWordCI(raw, i, "rm")) continue;
        if (!wordAtCI(raw, i, "rm")) continue;
        const after_rm = i + 2;
        const tok = nextToken(raw, after_rm) orelse return false;
        const t = raw[tok.start..tok.end];
        if (!std.mem.startsWith(u8, t, "-")) return false;
        const body = t[1..];
        if (containsIgnoreCase(body, "f")) return true; // -rf / -f / -fr
        if (findCI(body, "recursive")) return true;
        if (findCI(body, "force")) return true;
        return false;
    }
    return false;
}

/// 模式 2/3/4：SQL 危险语句。
fn matchSqlDrop(raw: []const u8) bool {
    if (!containsIgnoreCase(raw, "drop")) return false;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (!startsWordCI(raw, i, "drop")) continue;
        if (!wordAtCI(raw, i, "drop")) continue;
        const j = skipSpaces(raw, i + 4) orelse continue;
        if (startsWordCI(raw, j, "table") or startsWordCI(raw, j, "database") or startsWordCI(raw, j, "schema")) return true;
    }
    return false;
}

fn matchSqlDeleteFrom(raw: []const u8) bool {
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (!startsWordCI(raw, i, "delete")) continue;
        if (!wordAtCI(raw, i, "delete")) continue;
        const j = skipSpaces(raw, i + 6) orelse continue;
        if (startsWordCI(raw, j, "from")) return true;
    }
    return false;
}

fn matchSqlTruncate(raw: []const u8) bool {
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (!startsWordCI(raw, i, "truncate")) continue;
        if (!wordAtCI(raw, i, "truncate")) continue;
        // 正则写作 `\btruncate\s+table?` —— `table` 的尾字母可选，等于「有空白就够了」。
        if (skipSpaces(raw, i + 8) != null) return true;
    }
    return false;
}

/// 模式 5/6：git push 强推。`-f` / `--force` **大小写不敏感**（§4.4 末）。
fn matchGitPushForce(raw: []const u8) bool {
    var i: usize = 0;
    while (i + 3 <= raw.len) : (i += 1) {
        if (!wordAtCI(raw, i, "git")) continue;
        const sub = gitSubcommand(raw, i) orelse continue;
        if (!std.ascii.eqlIgnoreCase(sub, "push")) continue;
        const seg = tokensBetween(raw, i, true);
        if (containsIgnoreCase(seg, "--force")) return true;
        var t: usize = i + 3;
        while (nextToken(raw, t)) |tok| {
            if (tok.start >= i + seg.len) break;
            const tok_text = raw[tok.start..tok.end];
            if (std.ascii.eqlIgnoreCase(tok_text, "-f")) return true;
            t = tok.end;
        }
        return false;
    }
    return false;
}

/// 模式 7：`git reset --hard`。
fn matchGitResetHard(raw: []const u8) bool {
    var i: usize = 0;
    while (i + 3 <= raw.len) : (i += 1) {
        if (!wordAtCI(raw, i, "git")) continue;
        const sub = gitSubcommand(raw, i) orelse continue;
        if (!std.ascii.eqlIgnoreCase(sub, "reset")) continue;
        return containsIgnoreCase(tokensBetween(raw, i, true), "--hard");
    }
    return false;
}

/// 模式 8：`git clean (-\w*f\w*|-d)`。
fn matchGitClean(raw: []const u8) bool {
    var i: usize = 0;
    while (i + 3 <= raw.len) : (i += 1) {
        if (!wordAtCI(raw, i, "git")) continue;
        const sub = gitSubcommand(raw, i) orelse continue;
        if (!std.ascii.eqlIgnoreCase(sub, "clean")) continue;
        const seg_end = i + tokensBetween(raw, i, true).len;
        var t: usize = i + 3;
        while (nextToken(raw, t)) |tok| {
            if (tok.start >= seg_end) break;
            const tok_text = raw[tok.start..tok.end];
            // 只看 `-` 开头的开关（`clean` 子命令本身不含 `-`，天然被跳过）。
            if (tok_text.len > 1 and tok_text[0] == '-') {
                const body = tok_text[1..];
                if (std.ascii.eqlIgnoreCase(body, "d")) return true;
                if (containsIgnoreCase(body, "f")) return true;
            }
            t = tok.end;
        }
        return false;
    }
    return false;
}

/// 模式 9/10/11/12：`git checkout` 的四种破坏形态。
fn matchGitCheckout(raw: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 3 <= raw.len) : (i += 1) {
        if (!wordAtCI(raw, i, "git")) continue;
        const sub = gitSubcommand(raw, i) orelse continue;
        if (!std.ascii.eqlIgnoreCase(sub, "checkout")) continue;
        const seg = tokensBetween(raw, i, true); // 同段内（正则的 `[^|;&]*`）
        if (containsIgnoreCase(seg, "--")) return "git_checkout_discard";
        // 模式 10：`git checkout .` / `./src` / `.\`（点后必须是空白、分隔符或行尾）
        var t: usize = i + 3;
        while (nextToken(raw, t)) |tok| {
            if (tok.start >= i + seg.len) break;
            const tok_text = raw[tok.start..tok.end];
            if (tok_text.len > 0 and tok_text[0] == '.') {
                const after_dot = tok_text[1..];
                if (after_dot.len == 0 or after_dot[0] == '/' or after_dot[0] == '\\') return "git_checkout_dot";
            }
            if (std.ascii.eqlIgnoreCase(tok_text, "-f") or std.ascii.eqlIgnoreCase(tok_text, "--force")) {
                return "git_checkout_force";
            }
            // 模式 12：★ `-B` **大小写敏感**（`-b` 是新建分支，安全）
            if (std.mem.eql(u8, tok_text, "-B")) return "git_checkout_force_branch";
            t = tok.end;
        }
        return null;
    }
    return null;
}

/// 模式 13：`git restore`（含 `--staged`，保守从严）。
fn matchGitRestore(raw: []const u8) bool {
    var i: usize = 0;
    while (i + 3 <= raw.len) : (i += 1) {
        if (!wordAtCI(raw, i, "git")) continue;
        const sub = gitSubcommand(raw, i) orelse continue;
        if (std.ascii.eqlIgnoreCase(sub, "restore")) return true;
    }
    return false;
}

/// 模式 14：`git branch -D`（**`-D` 大小写敏感**）或 `--delete --force` / `--force --delete`。
fn matchGitBranchDelete(raw: []const u8) bool {
    var i: usize = 0;
    while (i + 3 <= raw.len) : (i += 1) {
        if (!wordAtCI(raw, i, "git")) continue;
        const sub = gitSubcommand(raw, i) orelse continue;
        if (!std.ascii.eqlIgnoreCase(sub, "branch")) continue;
        const seg = tokensBetween(raw, i, true);
        if (containsIgnoreCase(seg, "--delete") and containsIgnoreCase(seg, "--force")) return true;
        var t: usize = i + 3;
        while (nextToken(raw, t)) |tok| {
            if (tok.start >= i + seg.len) break;
            const tok_text = raw[tok.start..tok.end];
            if (tok_text.len > 1 and tok_text[0] == '-') {
                const body = tok_text[1..];
                // `-D` 大小写敏感：小写 `-d` 只删**已合并**分支，Git 自己有保护。
                if (std.mem.indexOfScalar(u8, body, 'D') != null) return true;
            }
            t = tok.end;
        }
        return false;
    }
    return false;
}

/// 模式 15：`git stash (drop|clear)`。
fn matchGitStashDestroy(raw: []const u8) bool {
    var i: usize = 0;
    while (i + 3 <= raw.len) : (i += 1) {
        if (!wordAtCI(raw, i, "git")) continue;
        const sub = gitSubcommand(raw, i) orelse continue;
        if (!std.ascii.eqlIgnoreCase(sub, "stash")) continue;
        const seg = tokensBetween(raw, i, true);
        var t: usize = i + 3;
        while (nextToken(raw, t)) |tok| {
            if (tok.start >= i + seg.len) break;
            const tok_text = raw[tok.start..tok.end];
            // `stash` 子命令本身跳过，只看它后面的第一个动作词。
            if (std.ascii.eqlIgnoreCase(tok_text, "stash")) {
                t = tok.end;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(tok_text, "drop") or std.ascii.eqlIgnoreCase(tok_text, "clear")) return true;
            return false;
        }
        return false;
    }
    return false;
}

/// 模式 16：`git switch -C`（**`-C` 大小写敏感**）/ `--force` / `--force-create` / `--discard-changes`。
fn matchGitSwitchForce(raw: []const u8) bool {
    var i: usize = 0;
    while (i + 3 <= raw.len) : (i += 1) {
        if (!wordAtCI(raw, i, "git")) continue;
        const sub = gitSubcommand(raw, i) orelse continue;
        if (!std.ascii.eqlIgnoreCase(sub, "switch")) continue;
        const seg = tokensBetween(raw, i, true);
        if (containsIgnoreCase(seg, "--force") or containsIgnoreCase(seg, "--force-create") or containsIgnoreCase(seg, "--discard-changes")) return true;
        var t: usize = i + 3;
        while (nextToken(raw, t)) |tok| {
            if (tok.start >= i + seg.len) break;
            const tok_text = raw[tok.start..tok.end];
            // 小写 `-c` = 新建分支，安全。
            if (std.mem.eql(u8, tok_text, "-C")) return true;
            t = tok.end;
        }
        return false;
    }
    return false;
}

fn matchChmodR777(raw: []const u8) bool {
    var i: usize = 0;
    while (i + 5 <= raw.len) : (i += 1) {
        if (!startsWordCI(raw, i, "chmod")) continue;
        if (!wordAtCI(raw, i, "chmod")) continue;
        const rest = raw[i..];
        if (!containsIgnoreCase(rest, "-R ")) continue;
        if (findCI(rest, "777")) return true;
    }
    return false;
}

/// 模式 18：`\bmkfs\.` —— **必须带点**，所以 `mkfs /dev/sdb1` 是已知漏报（用例 32）。
fn matchMkfs(raw: []const u8) bool {
    var i: usize = 0;
    while (i + 5 <= raw.len) : (i += 1) {
        if (!startsWordCI(raw, i, "mkfs")) continue;
        if (!wordAtCI(raw, i, "mkfs")) continue;
        if (i + 5 < raw.len and raw[i + 4] == '.') return true;
    }
    return false;
}

/// 模式 19：`\bdd\s+if=`。
fn matchDd(raw: []const u8) bool {
    var i: usize = 0;
    while (i + 2 <= raw.len) : (i += 1) {
        if (!startsWordCI(raw, i, "dd")) continue;
        if (!wordAtCI(raw, i, "dd")) continue;
        const after = i + 2;
        if (after < raw.len and std.ascii.isWhitespace(raw[after])) {
            const rest = std.mem.trimStart(u8, raw[after..], " \t\r\n");
            if (std.mem.startsWith(u8, rest, "if=")) return true;
        }
    }
    return false;
}

/// 模式 20：`\bformat\s+[A-Z]:`（Windows 盘符）。
fn matchFormatDrive(raw: []const u8) bool {
    var i: usize = 0;
    while (i + 6 <= raw.len) : (i += 1) {
        if (!startsWordCI(raw, i, "format")) continue;
        if (!wordAtCI(raw, i, "format")) continue;
        const j = skipSpaces(raw, i + 6) orelse continue;
        if (j + 1 < raw.len and std.ascii.isAlphabetic(raw[j]) and raw[j + 1] == ':') return true;
    }
    return false;
}

/// 模式 21（宽松）：`:\(\)\{.*}\s*;\s*:` —— 从 `:` 起，`(`/`)`/`{` 之间允许空白。
fn matchForkBombLoose(raw: []const u8) bool {
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] != ':') continue;
        var j = i + 1;
        while (j < raw.len and std.ascii.isWhitespace(raw[j])) : (j += 1) {}
        if (j >= raw.len or raw[j] != '(') continue;
        j += 1;
        while (j < raw.len and std.ascii.isWhitespace(raw[j])) : (j += 1) {}
        if (j >= raw.len or raw[j] != ')') continue;
        j += 1;
        while (j < raw.len and std.ascii.isWhitespace(raw[j])) : (j += 1) {}
        if (j >= raw.len or raw[j] != '{') continue;
        // 模式 21 用 `.*` 贪婪：`{` 之后只要出现 `;` 与 `:` 就算命中（比模式 22 宽）。
        const tail = raw[j..];
        if (std.mem.indexOfScalar(u8, tail, ';') != null and std.mem.indexOfScalar(u8, tail, ':') != null) return true;
    }
    return false;
}

/// 模式 22（经典）：`:\(\)\s*\{\s*:\|\s*:\s*&\s*}\s*;`
fn matchForkBombClassic(raw: []const u8) bool {
    var i: usize = 0;
    while (i + 4 <= raw.len) : (i += 1) {
        const rest = raw[i..];
        if (!std.mem.startsWith(u8, rest, ":()")) continue;
        var j: usize = 3;
        while (j < rest.len and std.ascii.isWhitespace(rest[j])) : (j += 1) {}
        if (j >= rest.len or rest[j] != '{') continue;
        j += 1;
        while (j < rest.len and std.ascii.isWhitespace(rest[j])) : (j += 1) {}
        if (j >= rest.len or rest[j] != ':') continue;
        j += 1;
        while (j < rest.len and std.ascii.isWhitespace(rest[j])) : (j += 1) {}
        if (j >= rest.len or rest[j] != '|') continue;
        j += 1;
        while (j < rest.len and std.ascii.isWhitespace(rest[j])) : (j += 1) {}
        if (j >= rest.len or rest[j] != ':') continue;
        j += 1;
        while (j < rest.len and std.ascii.isWhitespace(rest[j])) : (j += 1) {}
        if (j >= rest.len or rest[j] != '&') continue;
        j += 1;
        while (j < rest.len and std.ascii.isWhitespace(rest[j])) : (j += 1) {}
        if (j >= rest.len or rest[j] != '}') continue;
        j += 1;
        while (j < rest.len and std.ascii.isWhitespace(rest[j])) : (j += 1) {}
        if (j < rest.len and rest[j] == ';') return true;
    }
    return false;
}

// ── 只读 / 写类命令表（**单一事实源**，合并朴素实现里漂移的两份表，§4.8-1/-2）──

pub const READ_ONLY_COMMANDS = [_][]const u8{
    "cat",        "cd",       "cut",    "du",       "df",        "echo",     "env",
    "file",       "find",     "git",    "grep",     "head",      "wc",       "ls",
    "lsblk",      "lsof",     "less",   "more",     "man",       "printenv", "ps",
    "pwd",        "readlink", "rg",     "sed",      "sort",      "stat",     "tail",
    "tree",       "uniq",     "uname",  "which",    "whoami",    "id",       "date",
    "true",       "false",    "sleep",  "test",     "dirname",   "basename", "tr",
    "awk",        "jq",       "diff",   "cmp",      "sha256sum", "shasum",   "md5sum",
    "type",       "command",  "printf", "realpath", "readelf",   "nm",       "strings",
    "od",         "xxd",      "whois",  "dig",      "host",      "nslookup", "ping",
    "traceroute", "ifconfig", "ip",     "netstat",  "ss",        "lscpu",    "free",
    "top",        "uptime",   "arch",   "hostname", "basename",  "tee",
};

/// 归到 `/usr/bin/x` → `x`。
pub fn commandBasename(token: []const u8) []const u8 {
    var t = token;
    // Windows 盘符剥离（路径守卫的 Windows 语义留形状）。
    if (t.len > 2 and std.ascii.isAlphabetic(t[0]) and t[1] == ':' and (t[2] == '\\' or t[2] == '/')) t = t[2..];
    if (std.mem.lastIndexOfAny(u8, t, "/\\")) |idx| t = t[idx + 1 ..];
    return t;
}

/// git 的只读子命令集（§4.5，共 24 个）。
pub const GIT_READ_ONLY_SUBCOMMANDS = [_][]const u8{
    "status",   "log",          "diff",       "show",     "shortlog", "describe",
    "blame",    "reflog",       "rev-parse",  "rev-list", "ls-files", "ls-remote",
    "ls-tree",  "branch",       "tag",        "remote",   "stash",    "grep",
    "cat-file", "for-each-ref", "merge-base", "config",   "worktree", "help",
};

fn isGitReadOnly(raw: []const u8, git_start: usize) bool {
    const sub = gitSubcommand(raw, git_start) orelse return false;
    for (GIT_READ_ONLY_SUBCOMMANDS) |s| {
        if (std.ascii.eqlIgnoreCase(sub, s)) return true;
    }
    return false;
}

/// 写类命令段（`containsMutatingSegment`）—— Bash：`rm mv cp chmod chown truncate tee sed perl`。
/// ⚠️ `mkdir` / `touch` / `ln` **刻意不在**这个集合里：`mkdir -p a/b` 落 ASK REVIEW
/// 而不是 ASK WRITE（§4.5 的双轨缺陷，Zig 首期照抄 → 用例 62）。
pub const MUTATING_COMMANDS = [_][]const u8{
    "rm", "mv", "cp", "chmod", "chown", "truncate", "tee", "sed", "perl", "dd", "mkfs",
};

/// 网络命令（`NETWORK_COMMANDS`）。
pub const NETWORK_COMMANDS = [_][]const u8{
    "curl",    "wget", "nc",    "ncat",    "netcat", "ssh",   "scp",   "sftp",
    "rsync",   "http", "https", "ftp",     "telnet", "socat", "lynx",  "aria2c",
    "npm",     "npx",  "pip",   "pip3",    "gem",    "go",    "cargo", "docker",
    "kubectl", "helm", "apt",   "apt-get", "yum",    "dnf",   "brew",  "pacman",
};

/// 绕沙箱 / 解释器命令（`SANDBOX_BYPASS_COMMANDS`，原表全是 bash 侧名字）。
pub const SANDBOX_BYPASS_COMMANDS = [_][]const u8{
    "sh",          "bash",    "zsh",     "dash",    "ksh",  "csh",  "tcsh",  "fish",
    "env",         "eval",    "exec",    "sudo",    "doas", "su",   "xargs", "nohup",
    "tmux",        "screen",  "python",  "python3", "perl", "ruby", "node",  "php",
    "systemd-run", "unshare", "nsenter",
};

fn inTable(table: []const []const u8, name: []const u8) bool {
    for (table) |t| {
        if (std.ascii.eqlIgnoreCase(name, t)) return true;
    }
    return false;
}

/// 前导 `NAME=value` 环境赋值。
pub fn isEnvAssignment(tok: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return false;
    if (eq == 0) return false;
    for (tok[0..eq]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

/// `firstCommandName`（§4.6）：剥离前导环境赋值、`command` 前缀、`env` 前缀及其后的赋值，
/// 再取 basename。**只剥「安全白名单」，不剥「危险黑名单」** —— `sudo` / `xargs` /
/// `nohup` / `tmux` 都不在剥离名单里（这是刻意的方向）。
pub fn firstCommandName(seg: []const u8) []const u8 {
    return firstCommandSpan(seg).name;
}

/// 与 `firstCommandName` 同语义，但**同时给出这个 token 在段内的起始下标**。
/// 需要它的原因：`git` 的只读判定要在**子命令位置**上查表（§4.5），
/// 而前缀剥离（`env` / `command` / `NAME=value` / `/usr/bin/`）之后起点不再固定。
pub const CommandSpan = struct {
    name: []const u8,
    /// 该命令名（basename 之前那个 token）在段内的起始下标。
    token_start: usize,
};

pub fn firstCommandSpan(seg: []const u8) CommandSpan {
    var i: usize = 0;
    var guard: usize = 0;
    while (guard < 16) : (guard += 1) {
        const tok = nextToken(seg, i) orelse return .{ .name = "", .token_start = 0 };
        const t = seg[tok.start..tok.end];
        // ① 前导环境赋值 `NAME=value`（可以连续多个）
        if (isEnvAssignment(t)) {
            i = tok.end;
            continue;
        }
        // ② `command` 前缀（可重复）
        if (std.ascii.eqlIgnoreCase(t, "command")) {
            i = tok.end;
            continue;
        }
        // ③ `env` 前缀 + 它后面再跟的环境赋值
        if (std.ascii.eqlIgnoreCase(t, "env")) {
            i = tok.end;
            var inner_guard: usize = 0;
            while (inner_guard < 16) : (inner_guard += 1) {
                const inner = nextToken(seg, i) orelse break;
                if (!isEnvAssignment(seg[inner.start..inner.end])) break;
                i = inner.end;
            }
            continue;
        }
        return .{ .name = commandBasename(t), .token_start = tok.start };
    }
    return .{ .name = "", .token_start = 0 };
}

// ── 段切分（B1–B4）────────────────────────────────────────────────────────────

pub const MAX_SEGMENTS = 64;
pub const MAX_SEGMENT_LEN = 512;

pub const Segments = struct {
    buf: [MAX_SEGMENTS][MAX_SEGMENT_LEN]u8 = undefined,
    lens: [MAX_SEGMENTS]usize = @splat(0),
    n: usize = 0,

    pub fn slice(self: *const Segments, idx: usize) []const u8 {
        return self.buf[idx][0..self.lens[idx]];
    }

    pub fn count(self: *const Segments) usize {
        return self.n;
    }
};

fn pushSegment(segs: *Segments, cur: []const u8) void {
    if (segs.n >= MAX_SEGMENTS) return;
    const len = @min(cur.len, MAX_SEGMENT_LEN);
    @memcpy(segs.buf[segs.n][0..len], cur[0..len]);
    segs.lens[segs.n] = len;
    segs.n += 1;
}

/// 按 `&&` / `||` / `;` / `|` / `&` / 换行 切段，引号内的分隔符不切（B1/B4）。
/// `2>&1` / `&>` 这类重定向整体保留在段内（B3/B5）。
pub fn splitSegments(command: []const u8, out: *Segments) void {
    var cur: [MAX_SEGMENT_LEN]u8 = undefined;
    var clen: usize = 0;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const c = command[i];
        if (quote != 0) {
            if (clen < MAX_SEGMENT_LEN) {
                cur[clen] = c;
                clen += 1;
            }
            if (c == '\\' and quote == '"' and i + 1 < command.len) {
                i += 1;
                if (clen < MAX_SEGMENT_LEN) {
                    cur[clen] = command[i];
                    clen += 1;
                }
                continue;
            }
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            if (clen < MAX_SEGMENT_LEN) {
                cur[clen] = c;
                clen += 1;
            }
            continue;
        }
        if (c == '\n') {
            pushSegment(out, cur[0..clen]);
            clen = 0;
            continue;
        }
        if (c == ';') {
            pushSegment(out, cur[0..clen]);
            clen = 0;
            continue;
        }
        if (c == '&') {
            // `&&` 与单 `&`（后台）都是分隔符；但 `&>`/`&>>`（合并重定向，B3）与
            // `2>&1` / `1>&2`（fd 复制）里的 `&` **不是分隔符** —— 否则
            // `git show HEAD 1>&2 | head` 会被切成 `1>` 与 `2` 两段，重定向丢失。
            if (i + 1 < command.len and command[i + 1] == '>') {
                if (clen < MAX_SEGMENT_LEN) {
                    cur[clen] = c;
                    clen += 1;
                }
                continue;
            }
            if (i > 0 and (command[i - 1] == '>' or command[i - 1] == '<')) {
                if (clen < MAX_SEGMENT_LEN) {
                    cur[clen] = c;
                    clen += 1;
                }
                continue;
            }
            pushSegment(out, cur[0..clen]);
            clen = 0;
            if (i + 1 < command.len and command[i + 1] == '&') i += 1;
            continue;
        }
        if (c == '|') {
            pushSegment(out, cur[0..clen]);
            clen = 0;
            if (i + 1 < command.len and command[i + 1] == '|') i += 1;
            continue;
        }
        if (clen < MAX_SEGMENT_LEN) {
            cur[clen] = c;
            clen += 1;
        }
    }
    pushSegment(out, cur[0..clen]);
}

// ── 风险标记扫描 ─────────────────────────────────────────────────────────────

fn hasUncertainParse(command: []const u8) bool {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const c = command[i];
        if (quote == 0) {
            if (c == '\'' or c == '"') {
                quote = c;
            }
            continue;
        }
        if (c == '\\' and quote == '"') {
            i += 1;
            continue;
        }
        if (c == quote) quote = 0;
    }
    if (quote != 0) return true;
    if (command.len > 0 and command[command.len - 1] == '\\') return true;
    var depth: i32 = 0;
    for (command) |c| {
        if (c == '(') depth += 1;
        if (c == ')') depth -= 1;
    }
    if (depth != 0) return true;
    return false;
}

pub fn hasWriteRedirect(command: []const u8) bool {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const c = command[i];
        if (quote != 0) {
            if (c == '\\' and quote == '"') {
                i += 1;
                continue;
            }
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c != '>') continue;
        // `2>&1` / `1>&2` / `>&2`：文件描述符复制，没有文件目标 → 不算写。
        // 只有字面量 `2>&1` 被朴素实现写死豁免；这里统一成「fd 复制不算写」，
        // 多放过 `1>&2` 是**有意**的（§4.2 建议修成对称的）。
        if (i > 0 and command[i - 1] == '&') continue; // `&>`、`&>>`
        const next = i + 1;
        if (next < command.len and command[next] == '>') {
            // `>>`
        }
        var j = next;
        if (j < command.len and command[j] == '>') j += 1;
        while (j < command.len and std.ascii.isWhitespace(command[j])) : (j += 1) {}
        // `>&2`：目标必须是**裸数字**才算 fd 复制（`>&2x` 按普通目标处理）。
        // ★ 对 `2>&1` 与 `1>&2` **对称** —— 朴素实现只把字面量 `2>&1` 写死豁免，
        //   设计文档 §4.2 明确说「这是不一致，不是设计」，Zig 统一成
        //   「目标为文件描述符 → 不算写」。
        if (j < command.len and command[j] == '&') {
            if (j + 1 < command.len and std.ascii.isDigit(command[j + 1])) {
                var k = j + 1;
                while (k < command.len and std.ascii.isDigit(command[k])) : (k += 1) {}
                if (k == command.len or !isWordChar(command[k])) continue;
            }
        }
        // `2>/dev/null` 之类的 null sink 豁免：纯字符串判定，**不做路径归一化**
        // （归一化会引入不同行为，§4.2 警告）。
        if (std.mem.startsWith(u8, command[j..], "/dev/null")) continue;
        if (std.mem.startsWith(u8, command[j..], "/dev/stdout")) continue;
        if (std.mem.startsWith(u8, command[j..], "/dev/stderr")) continue;
        if (std.mem.startsWith(u8, command[j..], "/dev/fd/")) continue;
        return true;
    }
    return false;
}

/// `&>` 形态（`&> f`）也是写重定向。
pub fn hasAmpWriteRedirect(command: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < command.len) : (i += 1) {
        if (command[i] != '&') continue;
        var j = i + 1;
        if (command[j] != '>') continue;
        j += 1;
        if (j < command.len and command[j] == '>') j += 1;
        while (j < command.len and std.ascii.isWhitespace(command[j])) : (j += 1) {}
        if (std.mem.startsWith(u8, command[j..], "/dev/null")) continue;
        return true;
    }
    return false;
}

fn hasInPlaceEdit(command: []const u8) bool {
    // 只认 `sed` / `perl`，且选项匹配 `-[A-Za-z]*i[A-Za-z.]*`。
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const name = blk: {
            if (startsWordCI(command, i, "sed") and wordAtCI(command, i, "sed")) break :blk "sed";
            if (startsWordCI(command, i, "perl") and wordAtCI(command, i, "perl")) break :blk "perl";
            break :blk null;
        } orelse continue;
        var t: usize = i + name.len;
        while (nextToken(command, t)) |tok| {
            const tok_text = command[tok.start..tok.end];
            if (tok_text.len == 0) break;
            if (tok_text[0] != '-') break;
            const body = tok_text[1..];
            const idx = std.mem.indexOfScalar(u8, body, 'i') orelse {
                t = tok.end;
                continue;
            };
            if (idx == 0) break; // `-i...`
            // `-[A-Za-z]*i[A-Za-z.]*`：i 之前必须全是字母
            var ok = true;
            for (body[0..idx]) |c| {
                if (!std.ascii.isAlphabetic(c)) ok = false;
            }
            if (ok) return true;
            t = tok.end;
        }
    }
    return false;
}

fn hasCommandSubstitution(command: []const u8) bool {
    if (std.mem.indexOf(u8, command, "$(") != null) return true;
    // 反引号（排除单引号内 —— 简化：直接找反引号，假阳性可接受）
    if (std.mem.indexOfScalar(u8, command, '`') != null) return true;
    return false;
}

fn hasSubshell(command: []const u8) bool {
    var quote: u8 = 0;
    for (command, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c != '(') continue;
        if (i > 0 and command[i - 1] == '$') continue; // `$(` 是命令替换
        return true;
    }
    return false;
}

fn hasHeredoc(command: []const u8) bool {
    return std.mem.indexOf(u8, command, "<<") != null;
}

fn hasGlob(command: []const u8) bool {
    for (command) |c| {
        if (c == '*' or c == '?' or c == '[') return true;
    }
    return false;
}

// ── 分级（§4.5 的优先级瀑布）──────────────────────────────────────────────────

/// 命令级风险判定的结果。`risk_level` 走 `Outcome.command_risk_level`，
/// `verdict` 是 L3.5 自己的结论（`deny` = 命中 22 条之一）。
pub const Assessment = struct {
    /// 命令级风险等级（**不是**工具级）。
    risk_level: common.perm.RiskLevel,
    verdict: common.perm.Verdict,
    flags: RiskFlags = .{},
    class: Classification = .review,
    /// 22 条破坏性谓词里命中的稳定 id（进审计与卡片，**不要**用正则串当 id）。
    rule_id: ?[]const u8 = null,
    reason: []const u8 = "",
    /// 额外命中的全部规矩 id（既有语义是「全部命中都记进 reasons」）。
    hits: []const []const u8 = &.{},

    pub fn isReadOnly(self: Assessment) bool {
        return self.verdict == .allow;
    }
};

/// 22 条谓词表：`id` + `reason` + 判定函数。**顺序即文档里的顺序**。
pub const DangerousPattern = struct {
    id: []const u8,
    reason: []const u8,
    matches: *const fn (raw: []const u8) bool,
};

fn wrapGitCheckout(raw: []const u8) bool {
    return matchGitCheckout(raw) != null;
}

pub const DANGEROUS_PATTERN_COUNT: usize = 22;

pub const dangerous_patterns = [DANGEROUS_PATTERN_COUNT]DangerousPattern{
    .{ .id = "rm_force", .reason = "recursive/forced remove", .matches = matchRmForce },
    .{ .id = "sql_drop", .reason = "SQL drop table/database/schema", .matches = matchSqlDrop },
    .{ .id = "sql_delete_from", .reason = "SQL delete from", .matches = matchSqlDeleteFrom },
    .{ .id = "sql_truncate", .reason = "SQL truncate", .matches = matchSqlTruncate },
    .{ .id = "git_push_force_long", .reason = "git push --force", .matches = gitPushForceLong },
    .{ .id = "git_push_force_short", .reason = "git push -f", .matches = gitPushForceShort },
    .{ .id = "git_reset_hard", .reason = "git reset --hard discards worktree and index", .matches = matchGitResetHard },
    .{ .id = "git_clean_force", .reason = "git clean removes untracked files", .matches = matchGitClean },
    .{ .id = "git_checkout_discard", .reason = "git checkout -- discards worktree changes", .matches = checkoutDiscard },
    .{ .id = "git_checkout_dot", .reason = "git checkout . discards all local changes", .matches = checkoutDot },
    .{ .id = "git_checkout_force", .reason = "git checkout --force", .matches = checkoutForce },
    .{ .id = "git_checkout_force_branch", .reason = "git checkout -B resets an existing branch (case-sensitive)", .matches = checkoutForceBranch },
    .{ .id = "git_restore", .reason = "git restore overwrites worktree", .matches = matchGitRestore },
    .{ .id = "git_branch_force_delete", .reason = "git branch -D force-deletes a branch (case-sensitive)", .matches = matchGitBranchDelete },
    .{ .id = "git_stash_destroy", .reason = "git stash drop/clear destroys stash entries", .matches = matchGitStashDestroy },
    .{ .id = "git_switch_force_create", .reason = "git switch -C force-creates/resets a branch (case-sensitive)", .matches = matchGitSwitchForce },
    .{ .id = "chmod_r777", .reason = "chmod -R 777 opens permissions globally", .matches = matchChmodR777 },
    .{ .id = "mkfs", .reason = "mkfs formats a filesystem", .matches = matchMkfs },
    .{ .id = "dd_if", .reason = "dd if= can overwrite a raw device", .matches = matchDd },
    .{ .id = "format_drive", .reason = "format <drive>: reformats a Windows volume", .matches = matchFormatDrive },
    .{ .id = "fork_bomb_loose", .reason = "fork bomb", .matches = matchForkBombLoose },
    .{ .id = "fork_bomb_classic", .reason = "fork bomb", .matches = matchForkBombClassic },
};

fn gitPushForceLong(raw: []const u8) bool {
    var i: usize = 0;
    while (i + 3 <= raw.len) : (i += 1) {
        if (!wordAtCI(raw, i, "git")) continue;
        const sub = gitSubcommand(raw, i) orelse continue;
        if (!std.ascii.eqlIgnoreCase(sub, "push")) continue;
        return containsIgnoreCase(tokensBetween(raw, i, true), "--force");
    }
    return false;
}

fn gitPushForceShort(raw: []const u8) bool {
    var i: usize = 0;
    while (i + 3 <= raw.len) : (i += 1) {
        if (!wordAtCI(raw, i, "git")) continue;
        const sub = gitSubcommand(raw, i) orelse continue;
        if (!std.ascii.eqlIgnoreCase(sub, "push")) continue;
        const seg = tokensBetween(raw, i, true);
        var t: usize = i + 3;
        while (nextToken(raw, t)) |tok| {
            if (tok.start >= i + seg.len) break;
            if (std.ascii.eqlIgnoreCase(raw[tok.start..tok.end], "-f")) return true;
            t = tok.end;
        }
        return false;
    }
    return false;
}

fn checkoutDiscard(raw: []const u8) bool {
    const hit = matchGitCheckout(raw) orelse return false;
    return std.mem.eql(u8, hit, "git_checkout_discard");
}

fn checkoutDot(raw: []const u8) bool {
    const hit = matchGitCheckout(raw) orelse return false;
    return std.mem.eql(u8, hit, "git_checkout_dot");
}

fn checkoutForce(raw: []const u8) bool {
    const hit = matchGitCheckout(raw) orelse return false;
    return std.mem.eql(u8, hit, "git_checkout_force");
}

fn checkoutForceBranch(raw: []const u8) bool {
    const hit = matchGitCheckout(raw) orelse return false;
    return std.mem.eql(u8, hit, "git_checkout_force_branch");
}

/// 第一条命中的破坏性模式 id（**只用第一条**给 `dangerousCommandReason`）。
fn firstRuleId(raw: []const u8) ?[]const u8 {
    for (dangerous_patterns) |p| {
        if (p.matches(raw)) return p.id;
    }
    return null;
}

/// 收集全部命中。
fn collectRuleIds(raw: []const u8, out: *[DANGEROUS_PATTERN_COUNT][]const u8) []const []const u8 {
    var n: usize = 0;
    for (dangerous_patterns) |p| {
        if (p.matches(raw)) {
            out[n] = p.id;
            n += 1;
        }
    }
    return out[0..n];
}

/// ★ 22 条危险命令模式：命中返回**稳定 rule id**，未命中返回 `null`。
/// 3 处局部大小写敏感（`-B` / `-D` / `-C`）已体现在谓词里，**不做整串小写化**。
pub fn dangerousCommandReason(command: []const u8) ?[]const u8 {
    if (command.len == 0) return null;
    return firstRuleId(command);
}

/// 命中 id 对应的人类可读原因。
pub fn dangerousRuleReason(id: []const u8) ?[]const u8 {
    for (dangerous_patterns) |p| {
        if (std.mem.eql(u8, p.id, id)) return p.reason;
    }
    return null;
}

/// ★ 只读判定：**每一段**的命令名都只读才算只读（§4.5 `isReadOnlyPlan`）。
pub fn isReadOnlyCommand(command: []const u8) bool {
    if (std.mem.trim(u8, command, " \t\r\n").len == 0) return false;
    if (hasUncertainParse(command)) return false;
    var segs: Segments = .{};
    splitSegments(command, &segs);
    var found = false;
    var idx: usize = 0;
    while (idx < segs.count()) : (idx += 1) {
        const seg = segs.slice(idx);
        if (std.mem.trim(u8, seg, " \t\r\n").len == 0) continue;
        if (isFdDupToken(seg)) continue;
        const span = firstCommandSpan(seg);
        if (span.name.len == 0) return false;
        found = true;
        if (std.ascii.eqlIgnoreCase(span.name, "git")) {
            if (!isGitReadOnly(seg, span.token_start)) return false;
            continue;
        }
        if (!inTable(&READ_ONLY_COMMANDS, span.name)) return false;
    }
    return found;
}

/// 整段只是一个 fd 复制 token（`2>&1`）→ 不参与命令名判定。
pub fn isFdDupToken(seg: []const u8) bool {
    const t = std.mem.trim(u8, seg, " \t\r\n");
    if (t.len < 3) return false;
    var i: usize = 0;
    while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) {}
    if (i == 0) return false;
    if (i + 1 >= t.len) return false;
    if (t[i] != '>' or t[i + 1] != '&') return false;
    var j = i + 2;
    if (j >= t.len) return false;
    while (j < t.len and std.ascii.isDigit(t[j])) : (j += 1) {}
    return j == t.len;
}

/// 命令级风险分级（§4.5 的 12 步瀑布）。**纯函数，不分配。**
pub fn assess(command: []const u8) Assessment {
    if (std.mem.trim(u8, command, " \t\r\n").len == 0) {
        return .{
            .risk_level = .review,
            .verdict = .ask,
            .class = .empty,
            .reason = "empty command",
        };
    }

    var flags = RiskFlags{};
    flags.write_redirect = hasWriteRedirect(command) or hasAmpWriteRedirect(command);
    flags.in_place_edit = hasInPlaceEdit(command);
    flags.command_substitution = hasCommandSubstitution(command);
    flags.subshell = hasSubshell(command);
    flags.heredoc = hasHeredoc(command);
    flags.glob = hasGlob(command);
    flags.uncertain_parse = hasUncertainParse(command);

    var hits_buf: [DANGEROUS_PATTERN_COUNT][]const u8 = undefined;
    const hits = collectRuleIds(command, &hits_buf);

    var segs: Segments = .{};
    splitSegments(command, &segs);
    var network = false;
    var sandbox_bypass = false;
    var mutating_segment = false;
    var idx: usize = 0;
    while (idx < segs.count()) : (idx += 1) {
        const seg = segs.slice(idx);
        if (std.mem.trim(u8, seg, " \t\r\n").len == 0) continue;
        if (isFdDupToken(seg)) continue;
        const name = firstCommandName(seg);
        if (name.len == 0) continue;
        if (inTable(&NETWORK_COMMANDS, name)) network = true;
        if (inTable(&SANDBOX_BYPASS_COMMANDS, name)) sandbox_bypass = true;
        if (inTable(&MUTATING_COMMANDS, name)) mutating_segment = true;
    }
    // 网络命令如果出现在 `git push/pull/fetch/clone` 这类段里，也算网络访问。
    if (containsIgnoreCase(command, "git push") or containsIgnoreCase(command, "git pull") or
        containsIgnoreCase(command, "git fetch") or containsIgnoreCase(command, "git clone")) network = true;
    flags.network_access = network;
    flags.sandbox_bypass = sandbox_bypass;

    // 第 1 步：22 条模式**最先，压过一切** → DENY HIGH。
    if (hits.len > 0) {
        flags.destructive_command = true;
        return .{
            .risk_level = .high,
            .verdict = .deny,
            .flags = flags,
            .class = .dangerous,
            .rule_id = hits[0],
            .reason = dangerousRuleReason(hits[0]) orelse "dangerous command",
            .hits = hits,
        };
    }

    // 第 8 步（网络/绕沙箱）压过写类：`curl … | sh` → NETWORK。
    if (network or sandbox_bypass) {
        return .{
            .risk_level = .network,
            .verdict = .ask,
            .flags = flags,
            .class = .network,
            .rule_id = null,
            .reason = if (network) "command performs network access" else "command can bypass the sandbox",
            .hits = hits,
        };
    }

    // 第 5 步：写类（重定向 / 原地编辑 / 写类命令段）。
    if (flags.write_redirect or flags.in_place_edit or mutating_segment) {
        return .{
            .risk_level = .write,
            .verdict = .ask,
            .flags = flags,
            .class = .mutating,
            .rule_id = null,
            .reason = if (flags.in_place_edit) "command edits files in place" else if (flags.write_redirect) "command writes to a file" else "command modifies the filesystem",
            .hits = hits,
        };
    }

    // 第 6 步：嵌套 / 解析不确定 → ASK REVIEW。
    if (flags.command_substitution or flags.subshell or flags.heredoc or flags.uncertain_parse) {
        return .{
            .risk_level = .review,
            .verdict = .ask,
            .flags = flags,
            .class = if (flags.uncertain_parse) .uncertain else .nested,
            .rule_id = null,
            .reason = if (flags.uncertain_parse) "command could not be parsed reliably" else "command nests other commands",
            .hits = hits,
        };
    }

    // 第 7 步：危险 glob（有写类命令 + glob）。
    if (flags.glob and mutating_segment) {
        return .{
            .risk_level = .write,
            .verdict = .ask,
            .flags = flags,
            .class = .risky_glob,
            .rule_id = null,
            .reason = "command globs files for a mutating command",
            .hits = hits,
        };
    }

    // 第 10 步：全部段只读 → ALLOW READ_ONLY。
    if (isReadOnlyCommand(command)) {
        return .{
            .risk_level = .read_only,
            .verdict = .allow,
            .flags = flags,
            .class = .read_only,
            .rule_id = null,
            .reason = "command is read-only",
            .hits = hits,
        };
    }

    // 第 12 步：兜底 ASK REVIEW（`mkdir -p a/b` / `timeout 30 ls` 都落这里）。
    return .{
        .risk_level = .review,
        .verdict = .ask,
        .flags = flags,
        .class = if (flags.glob) .risky_glob else .review,
        .rule_id = null,
        .reason = "command requires confirmation",
        .hits = hits,
    };
}

/// 从工具输入里取命令串（**纯函数，不分配**）：输入本身像裸串就直接用，
/// 否则返回 `null`，交给 `commandFromInputArena` 解析 JSON。
/// ⚠️ 绝不 parse→re-serialize：`ToolUseBlock.input` 的原始 JSON 字符串全程保持原样。
pub fn commandFromInput(input: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, input, " \t\r\n");
    if (t.len == 0) return null;
    if (t[0] == '{' or t[0] == '[') return null;
    if (t[0] == '"') {
        // 形如 `"ls -la"` 的裸 JSON 字符串
        if (t.len >= 2 and t[t.len - 1] == '"') return t[1 .. t.len - 1];
        return null;
    }
    return t;
}

/// JSON 输入里取 `command` / `cmd`（`arena` 由调用方持有；返回值指向 arena）。
pub fn commandFromJson(arena: std.mem.Allocator, input: []const u8) ?[]const u8 {
    const value = common.json.parse(arena, input) catch return null;
    if (value.getString("command")) |c| return c;
    if (value.getString("cmd")) |c| return c;
    return null;
}

/// 统一入口：裸串优先，其次 JSON；JSON 解析失败时退回「整串当命令」，
/// 避免畸形输入让检测静默失效（检测器本身对任何串都安全：不认识 → review）。
pub fn commandFromInputArena(arena: std.mem.Allocator, input: []const u8) ?[]const u8 {
    if (commandFromInput(input)) |c| return c;
    if (commandFromJson(arena, input)) |c| return c;
    const t = std.mem.trim(u8, input, " \t\r\n");
    if (t.len == 0) return null;
    if (t[0] == '{' or t[0] == '[') return null; // 对象/数组解析失败 → 不猜
    return t;
}

const testing = std.testing;

test "shell: 22 条模式表数量" {
    try testing.expectEqual(@as(usize, 22), DANGEROUS_PATTERN_COUNT);
    try testing.expectEqual(DANGEROUS_PATTERN_COUNT, dangerous_patterns.len);
}

test "shell: 大小写敏感的三个开关（-B / -D / -C 危险，小写安全）" {
    // ★ 这三条是「把整条命令小写化」会立刻炸掉的回归测试。
    try testing.expectEqualStrings("git_checkout_force_branch", dangerousCommandReason("git checkout -B main").?);
    try testing.expectEqualStrings("git_branch_force_delete", dangerousCommandReason("git branch -D feat").?);
    try testing.expectEqualStrings("git_switch_force_create", dangerousCommandReason("git switch -C main").?);

    try testing.expect(dangerousCommandReason("git checkout -b feature") == null);
    try testing.expect(dangerousCommandReason("git branch -d feat") == null);
    try testing.expect(dangerousCommandReason("git switch -c feature") == null);
}

test "shell: 强制开关 -f / --force 大小写不敏感" {
    try testing.expect(dangerousCommandReason("git push -F") != null);
    try testing.expect(dangerousCommandReason("git push --FORCE") != null);
    try testing.expect(dangerousCommandReason("git checkout -F main") != null);
    try testing.expect(dangerousCommandReason("RM -RF /tmp/x") != null);
}

test "shell: 裸串命令 vs JSON 输入" {
    try testing.expectEqualStrings("rm -rf x", commandFromInput("rm -rf x").?);
    try testing.expectEqualStrings("ls -la", commandFromInput("\"ls -la\"").?);
    try testing.expect(commandFromInput("{\"command\":\"rm -rf x\"}") == null); // 对象交给 arena 版

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("rm -rf x", commandFromInputArena(arena, "{\"command\":\"rm -rf x\",\"description\":\"d\"}").?);
    try testing.expectEqualStrings("ls", commandFromInputArena(arena, "{\"cmd\":\"ls\"}").?);
    try testing.expect(commandFromInputArena(arena, "{\"file_path\":\"/a\"}") == null);
    try testing.expect(commandFromInputArena(arena, "") == null);
    // 畸形 JSON 对象：不猜、不 panic，交给上层按「无命令」处理
    try testing.expect(commandFromInputArena(arena, "{oops") == null);
}

test "shell: 只读判定与段切分" {
    try testing.expect(isReadOnlyCommand("ls -la && pwd"));
    try testing.expect(!isReadOnlyCommand("ls -la && rm -rf x"));
    try testing.expect(!isReadOnlyCommand("git status | sh"));
    try testing.expect(!isReadOnlyCommand(""));
}

test "shell: 风险标记 wire 名稳定" {
    var buf: [11][]const u8 = undefined;
    var f = RiskFlags{};
    f.write_redirect = true;
    f.glob = true;
    const names = f.wireNames(&buf);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("WRITE_REDIRECT", names[0]);
    try testing.expectEqualStrings("GLOB", names[1]);
}
