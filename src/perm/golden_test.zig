//! `perm/golden_test.zig` —— 验收测试集（文档 07 §13.1 / §13.2 / §13.3）。
//!
//! 这里放的是**跨文件**的行为断言：危险命令 golden 表走完整
//! `Checker.evaluate`（四级链），越界与缓存用例走 `path.zig` + `checker.zig`，
//! 另加三条最容易做反的顺序/回归防线。
//!
//! 单文件内部的单元测试留在各自文件里（`shell.zig` / `checker.zig` / …）；
//! 本文件只做「表格化」的验收，不重复单元测试。

const std = @import("std");
const common = @import("common");
const plan = @import("plan.zig");
const shell = @import("shell.zig");
const classify = @import("classify.zig");
const path_mod = @import("path.zig");
const checker = @import("checker.zig");

const testing = std.testing;
const Verdict = common.perm.Verdict;
const RiskLevel = common.perm.RiskLevel;

// ── §13.2 ★ 危险命令用例表（64 行，含 10 条 PowerShell 对照）─────────────────

const Golden = struct {
    cmd: []const u8,
    verdict: Verdict,
    risk: RiskLevel,
    /// 危险模式的稳定 id；没有命中模式时为 `null`（用 `class` 断言兜底）。
    rule: ?[]const u8,
    class: shell.Classification,
    /// 已知放行/已知假阳性（文档 §4.8 的缺口清单，首期照抄以防被无声改掉）。
    known_gap: bool = false,
};

pub const golden = [_]Golden{
    // 1–4 `rm`
    .{ .cmd = "rm -rf /tmp/x", .verdict = .deny, .risk = .high, .rule = "rm_force", .class = .dangerous },
    .{ .cmd = "rm -r /tmp/x", .verdict = .ask, .risk = .write, .rule = null, .class = .mutating },
    .{ .cmd = "rm --recursive /tmp/x", .verdict = .deny, .risk = .high, .rule = "rm_force", .class = .dangerous },
    .{ .cmd = "RM -RF /tmp/x", .verdict = .deny, .risk = .high, .rule = "rm_force", .class = .dangerous },
    // 5–16 git 工作区
    .{ .cmd = "git reset --hard HEAD~1", .verdict = .deny, .risk = .high, .rule = "git_reset_hard", .class = .dangerous },
    .{ .cmd = "git checkout -- src/a.zig", .verdict = .deny, .risk = .high, .rule = "git_checkout_discard", .class = .dangerous },
    .{ .cmd = "git checkout HEAD -- .", .verdict = .deny, .risk = .high, .rule = "git_checkout_discard", .class = .dangerous },
    .{ .cmd = "git checkout .", .verdict = .deny, .risk = .high, .rule = "git_checkout_dot", .class = .dangerous },
    .{ .cmd = "git checkout ./src", .verdict = .deny, .risk = .high, .rule = "git_checkout_dot", .class = .dangerous },
    // ★ 点后是字母 → 不命中模式 10 → 兜底 ASK REVIEW
    .{ .cmd = "git checkout .gitignore", .verdict = .ask, .risk = .review, .rule = null, .class = .review },
    .{ .cmd = "git checkout -f main", .verdict = .deny, .risk = .high, .rule = "git_checkout_force", .class = .dangerous },
    // ★ -B 大小写敏感
    .{ .cmd = "git checkout -B main", .verdict = .deny, .risk = .high, .rule = "git_checkout_force_branch", .class = .dangerous },
    // ★ -b 安全 → 兜底 ASK（checkout 不在只读子命令集）
    .{ .cmd = "git checkout -b feature", .verdict = .ask, .risk = .review, .rule = null, .class = .review },
    // ★ -D 大小写敏感
    .{ .cmd = "git branch -D feat", .verdict = .deny, .risk = .high, .rule = "git_branch_force_delete", .class = .dangerous },
    // ★ -d 安全删除，且 branch 在只读子命令集
    .{ .cmd = "git branch -d feat", .verdict = .allow, .risk = .read_only, .rule = null, .class = .read_only },
    .{ .cmd = "git branch -a", .verdict = .allow, .risk = .read_only, .rule = null, .class = .read_only },
    // 17–28 git 其它
    .{ .cmd = "git clean -fd", .verdict = .deny, .risk = .high, .rule = "git_clean_force", .class = .dangerous },
    .{ .cmd = "git clean -n", .verdict = .ask, .risk = .review, .rule = null, .class = .review },
    .{ .cmd = "git restore .", .verdict = .deny, .risk = .high, .rule = "git_restore", .class = .dangerous },
    .{ .cmd = "git restore --staged f", .verdict = .deny, .risk = .high, .rule = "git_restore", .class = .dangerous },
    .{ .cmd = "git stash drop", .verdict = .deny, .risk = .high, .rule = "git_stash_destroy", .class = .dangerous },
    .{ .cmd = "git stash", .verdict = .allow, .risk = .read_only, .rule = null, .class = .read_only },
    // ★ -C 大小写敏感
    .{ .cmd = "git switch -C main", .verdict = .deny, .risk = .high, .rule = "git_switch_force_create", .class = .dangerous },
    .{ .cmd = "git switch -c feature", .verdict = .ask, .risk = .review, .rule = null, .class = .review },
    .{ .cmd = "git push origin main --force", .verdict = .deny, .risk = .high, .rule = "git_push_force_long", .class = .dangerous },
    .{ .cmd = "git push -f", .verdict = .deny, .risk = .high, .rule = "git_push_force_short", .class = .dangerous },
    // ★ 已知放行：config / worktree 在只读子命令集里（§4.8 #3）
    .{ .cmd = "git config user.name x", .verdict = .allow, .risk = .read_only, .rule = null, .class = .read_only, .known_gap = true },
    .{ .cmd = "git worktree add ../wt", .verdict = .allow, .risk = .read_only, .rule = null, .class = .read_only, .known_gap = true },
    // 29–34 chmod / mkfs / dd
    .{ .cmd = "chmod -R 777 /var", .verdict = .deny, .risk = .high, .rule = "chmod_r777", .class = .dangerous },
    .{ .cmd = "chmod -R 755 /var", .verdict = .ask, .risk = .write, .rule = null, .class = .mutating },
    .{ .cmd = "mkfs.ext4 /dev/sdb1", .verdict = .deny, .risk = .high, .rule = "mkfs", .class = .dangerous },
    // ★ 模式 18 要求 `mkfs.`（带点）→ 已知漏报
    .{ .cmd = "mkfs /dev/sdb1", .verdict = .ask, .risk = .write, .rule = null, .class = .mutating, .known_gap = true },
    .{ .cmd = "dd if=/dev/zero of=/dev/sda", .verdict = .deny, .risk = .high, .rule = "dd_if", .class = .dangerous },
    // ★ 模式 19 只认 `if=` → 已知漏报
    .{ .cmd = "dd of=/tmp/x", .verdict = .ask, .risk = .write, .rule = null, .class = .mutating, .known_gap = true },
    // 35 fork bomb（模式 21 + 22 同时命中）
    .{ .cmd = ":(){ :|:& };:", .verdict = .deny, .risk = .high, .rule = "fork_bomb_loose", .class = .dangerous },
    // 36–38 SQL
    .{ .cmd = "DROP TABLE users", .verdict = .deny, .risk = .high, .rule = "sql_drop", .class = .dangerous },
    .{ .cmd = "delete from users where 1=1", .verdict = .deny, .risk = .high, .rule = "sql_delete_from", .class = .dangerous },
    .{ .cmd = "TRUNCATE TABLE t", .verdict = .deny, .risk = .high, .rule = "sql_truncate", .class = .dangerous },
    // 39–41 重定向
    .{ .cmd = "echo hi > /tmp/f", .verdict = .ask, .risk = .write, .rule = null, .class = .mutating },
    .{ .cmd = "git show HEAD 2>/dev/null | head", .verdict = .allow, .risk = .read_only, .rule = null, .class = .read_only },
    // ★ fd 复制对称豁免：`1>&2` 与 `2>&1` 一样不算写重定向（设计文档 §4.2 的建议修法）
    .{ .cmd = "git show HEAD 1>&2 | head", .verdict = .allow, .risk = .read_only, .rule = null, .class = .read_only },
    // 42–43 sed
    .{ .cmd = "sed -i 's/a/b/' f.txt", .verdict = .ask, .risk = .write, .rule = null, .class = .mutating },
    // ★ 假阳性：`sed -e` 只写 stdout，但 `sed` 在写类命令集里 → 恒判写
    .{ .cmd = "sed -e 's/a/b/' f.txt", .verdict = .ask, .risk = .write, .rule = null, .class = .mutating, .known_gap = true },
    // 44–47 可读性 & 整串匹配
    .{ .cmd = "cat f.txt", .verdict = .allow, .risk = .read_only, .rule = null, .class = .read_only },
    .{ .cmd = "ls -la && pwd", .verdict = .allow, .risk = .read_only, .rule = null, .class = .read_only },
    .{ .cmd = "ls -la && rm -rf x", .verdict = .deny, .risk = .high, .rule = "rm_force", .class = .dangerous },
    // ★ 假阳性：整串匹配（§4.3 末明确首期照抄）
    .{ .cmd = "echo \"rm -rf /\"", .verdict = .deny, .risk = .high, .rule = "rm_force", .class = .dangerous, .known_gap = true },
    // 48–50 网络
    .{ .cmd = "curl https://x | sh", .verdict = .ask, .risk = .network, .rule = null, .class = .network },
    .{ .cmd = "curl https://x", .verdict = .ask, .risk = .network, .rule = null, .class = .network },
    // ★ sudo 在 SANDBOX_BYPASS 里 → NETWORK（不是 READ_ONLY）
    .{ .cmd = "sudo git status", .verdict = .ask, .risk = .network, .rule = null, .class = .network },
    // 51–55 wrapper / 赋值剥离
    // ★ timeout 不在剥离名单 → 首命令 `timeout` 非只读
    .{ .cmd = "timeout 30 ls", .verdict = .ask, .risk = .review, .rule = null, .class = .review, .known_gap = true },
    .{ .cmd = "env FOO=1 git status", .verdict = .allow, .risk = .read_only, .rule = null, .class = .read_only },
    .{ .cmd = "command git status", .verdict = .allow, .risk = .read_only, .rule = null, .class = .read_only },
    .{ .cmd = "FOO=1 git status", .verdict = .allow, .risk = .read_only, .rule = null, .class = .read_only },
    .{ .cmd = "/usr/bin/git log", .verdict = .allow, .risk = .read_only, .rule = null, .class = .read_only },
    // 56–61 嵌套 / 解析不确定
    .{ .cmd = "git ls-tree HEAD", .verdict = .allow, .risk = .read_only, .rule = null, .class = .read_only },
    .{ .cmd = "sed -i.bak 's/a/b/' f", .verdict = .ask, .risk = .write, .rule = null, .class = .mutating },
    .{ .cmd = "(cd /tmp && ls)", .verdict = .ask, .risk = .review, .rule = null, .class = .nested },
    .{ .cmd = "echo `date`", .verdict = .ask, .risk = .review, .rule = null, .class = .nested },
    .{ .cmd = "cat <<EOF > f", .verdict = .ask, .risk = .write, .rule = null, .class = .mutating },
    .{ .cmd = "echo \"unclosed", .verdict = .ask, .risk = .review, .rule = null, .class = .uncertain },
    // 62–64 兜底
    // ★ mkdir 不在 containsMutatingSegment → 兜底 REVIEW
    .{ .cmd = "mkdir -p a/b", .verdict = .ask, .risk = .review, .rule = null, .class = .review, .known_gap = true },
    .{ .cmd = "xargs rm -rf", .verdict = .deny, .risk = .high, .rule = "rm_force", .class = .dangerous },
    .{ .cmd = "", .verdict = .ask, .risk = .review, .rule = null, .class = .empty },
};

/// 补充：`/dev/null` 与 fd 复制的 null sink 豁免（§4.2 的 `isNullSink`）。
const null_sink_rows = [_]Golden{
    .{ .cmd = "echo x > /dev/null", .verdict = .allow, .risk = .read_only, .rule = null, .class = .read_only },
    .{ .cmd = "ls -la 2>/dev/null", .verdict = .allow, .risk = .read_only, .rule = null, .class = .read_only },
    .{ .cmd = "echo x > f.txt", .verdict = .ask, .risk = .write, .rule = null, .class = .mutating },
};

test "golden: §13.2 危险命令表规模 ≥ 40 行" {
    try testing.expect(golden.len + null_sink_rows.len >= 40);
    try testing.expectEqual(@as(usize, 64), golden.len);
}

test "golden: §13.2 危险命令表（verdict + risk + rule id + class）" {
    var failures: usize = 0;
    for (golden) |row| {
        const a = shell.assess(row.cmd);
        var bad = false;
        if (a.verdict != row.verdict or a.risk_level != row.risk or a.class != row.class) bad = true;
        if (row.rule) |want| {
            if (a.rule_id == null or !std.mem.eql(u8, want, a.rule_id.?)) bad = true;
            if (shell.dangerousCommandReason(row.cmd) == null) bad = true;
        } else {
            if (a.rule_id != null) bad = true;
        }
        if (bad) {
            failures += 1;
            std.debug.print("MISMATCH [{s}] want={s}/{s}/{s} got={s}/{s}/{s} rule={s} want_rule={s}\n", .{
                row.cmd,             @tagName(row.verdict),  @tagName(row.risk), @tagName(row.class),
                @tagName(a.verdict), @tagName(a.risk_level), @tagName(a.class),  a.rule_id orelse "-",
                row.rule orelse "-",
            });
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "golden: null sink 与 fd 复制不算写重定向" {
    for (null_sink_rows) |row| {
        const a = shell.assess(row.cmd);
        try testing.expectEqual(row.verdict, a.verdict);
        try testing.expectEqual(row.risk, a.risk_level);
        try testing.expectEqual(row.class, a.class);
    }
}

test "golden: 走完整四级链（Bash + ASK 模式）后判定与 golden 表一致" {
    var c = checker.Checker.init(testing.allocator, undefined, "/repo");
    defer c.deinit();
    c.clock_fn = &fixedClock;
    for (golden) |row| {
        // `input` 直接给裸命令串（`commandFromInput` 的合法输入形态之一），
        // 这样特殊字符（反引号、双引号、fork bomb）不需要在测试里再拼 JSON 转义。
        const out = try c.evaluate(.{
            .tool_name = "Bash",
            .input = row.cmd,
            .is_read_only = false,
            .is_destructive = row.verdict == .deny,
        });
        try testing.expect(out.command_risk_level != null);
        // ★ 工具级风险恒 HIGH（连 `ls` 也一样）—— 与命令级风险是两条轴。
        try testing.expectEqual(RiskLevel.high, out.risk_level);
        // ★ 命令级风险必须与 golden 表一致。
        try testing.expectEqual(row.risk, out.command_risk_level.?);
        // 判定与 golden 表一致。
        try testing.expectEqual(row.verdict, out.verdict);
        const t = out.trace orelse return error.MissingTrace;
        try testing.expect(t.provenance.source_id.len > 0);
        // 判定优先级必须与结论一致（DENY=0x / ASK=1x / ALLOW=2x）。
        const want_priority: i32 = switch (out.verdict) {
            .deny => checker.PRIORITY_DENY,
            .ask, .deferred => checker.PRIORITY_ASK,
            .allow => checker.PRIORITY_ALLOW,
        };
        try testing.expectEqual(want_priority, t.provenance.priority);

        // 危险命令的稳定 rule id 必须进 trace metadata（审计用）。
        if (row.rule) |want| {
            const meta_rule = t.metadata.get("rule") orelse return error.MissingRuleInTrace;
            try testing.expectEqualStrings(want, meta_rule.string);
            try testing.expectEqualStrings("DESTRUCTIVE", t.metadata.get("class").?.string);
        }
    }
}

/// `testing.allocator` 场景下不能用真的 `io`（没有运行时），固定时钟让 trace 可断言。
fn fixedClock(_: std.Io) i64 {
    return 1_700_000_000_000;
}

// ── §13.3 ★ 越界与两级授权缓存（≥ 20 条）────────────────────────────────────

test "golden: 越界守卫 —— Err 类（不受授权影响）" {
    const T = struct {
        fn expectErr(p: []const u8) !void {
            const r = path_mod.resolveAndValidate(testing.allocator, .{ .base = "/repo" }, p, &.{});
            if (r) |ok| {
                testing.allocator.free(ok);
                return error.ExpectedOutsideBase;
            } else |err| {
                try testing.expectEqual(error.OutsideBase, err);
            }
        }
    };
    const escapes = [_][]const u8{
        "../etc/passwd",
        "../../etc/shadow",
        "/etc/passwd",
        "/etc/shadow",
        "src/../../etc/passwd",
        "/repo/../etc/passwd",
        "/root/.ssh/id_rsa",
        "/Users/other/secret.txt",
        "/var/log/system.log",
        "docs/../../../../../../etc/hosts",
        "/repo/.git/config.lock/../../../../etc/passwd",
        "/opt/outside/a.txt",
        "/tmp/not-authorized/a.txt",
        "/repo2/a.txt",
    };
    for (escapes) |p| try T.expectErr(p);
}

test "golden: 越界守卫 —— Ok 类（含嵌套授权根与 macOS /tmp caveat）" {
    // cwd 内
    try expectOk("/repo", "a.txt", &.{}, "/repo/a.txt");
    try expectOk("/repo", "src/deep/a.zig", &.{}, "/repo/src/deep/a.zig");
    try expectOk("/repo", "./src/../a.zig", &.{}, "/repo/a.zig");
    // 授权根（嵌套：/tmp 与 /tmp/plans 同时存在，取更具体那个不影响判定）
    try expectOk("/repo", "/tmp/plans/a.md", &.{ "/tmp/plans", "/tmp" }, "/tmp/plans/a.md");
    try expectOk("/repo", "/opt/shared/x", &.{"/opt/shared"}, "/opt/shared/x");
    // 前缀撞名不能误判：/tmp/plans-extra 不在 /tmp/plans 内（但被 /tmp 覆盖时才算 Ok）
    const bad = path_mod.resolveAndValidate(testing.allocator, .{ .base = "/repo" }, "/tmp/plans-extra/x", &.{"/tmp/plans"});
    try testing.expectError(error.OutsideBase, bad);
    // ★ macOS `/tmp` 软链 caveat：base 不做 realpath，/tmp/x → /private/tmp/x 的前缀判定必须仍成立
    try expectOk("/tmp", "x/y", &.{}, "/tmp/x/y");
    try expectOk("/tmp/x", "y", &.{}, "/tmp/x/y");
    // base 与 root 都是 /tmp 前缀族但指向不同目录 → 不误放行
    const cross = path_mod.resolveAndValidate(testing.allocator, .{ .base = "/tmp/x" }, "/tmp/y/z", &.{});
    try testing.expectError(error.OutsideBase, cross);
}

fn expectOk(base: []const u8, p: []const u8, roots: []const []const u8, want: []const u8) !void {
    const r = try path_mod.resolveAndValidate(testing.allocator, .{ .base = base }, p, roots);
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(want, r);
}

test "golden: 设备/特殊文件（§13.3 用例 13/14/15）" {
    const T = struct {
        fn expectErr(p: []const u8) !void {
            const r = path_mod.resolveAndValidate(testing.allocator, .{ .base = "/repo" }, p, &.{ "/", "/dev", "/proc" });
            try testing.expectError(error.BlockedDevicePath, r);
        }
    };
    try T.expectErr("/dev/zero");
    try T.expectErr("/proc/self/environ");
    try T.expectErr("/proc/1234/fd/1");
    try T.expectErr("/dev/fd/0");
    // UNC（§13.3 用例 12）
    try testing.expectError(error.UncPath, path_mod.resolveAndValidate(testing.allocator, .{ .base = "/repo" }, "\\\\server\\share\\f.txt", &.{}));
}

test "golden: 两级缓存 —— 读授权不得升级为写授权（§13.3 3/4/5/6/7/8）" {
    var c = checker.Checker.init(testing.allocator, undefined, "/repo");
    defer c.deinit();
    c.clock_fn = &fixedClock;

    // 3) 用户在卡片批准 allowRoot=/tmp/plans（读）
    try c.grantReadOnlyRoot("/tmp/plans");
    const r = try c.evaluate(.{ .tool_name = "Read", .input = "{\"file_path\":\"/tmp/plans/a.md\"}" });
    try testing.expectEqual(Verdict.allow, r.verdict);
    try testing.expectEqual(@as(usize, 1), c.read_only_roots.items.len);
    try testing.expectEqual(@as(usize, 0), c.allowed_roots.items.len);

    // 4) 紧接着写同一目录 → 仍然要弹卡片
    const w = try c.evaluate(.{ .tool_name = "Write", .input = "{\"file_path\":\"/tmp/plans/b.md\"}" });
    try testing.expectEqual(Verdict.ask, w.verdict);

    // 5/6) 派生 `Task` 子代理：读成功、写仍被拒
    var child = checker.Checker.init(testing.allocator, undefined, "/repo");
    defer child.deinit();
    child.clock_fn = &fixedClock;
    try child.inheritFrom(&c);
    const cr = try child.evaluate(.{ .tool_name = "Read", .input = "{\"file_path\":\"/tmp/plans/a.md\"}" });
    try testing.expectEqual(Verdict.allow, cr.verdict);
    const cw = try child.evaluate(.{ .tool_name = "Write", .input = "{\"file_path\":\"/tmp/plans/b.md\"}" });
    try testing.expectEqual(Verdict.ask, cw.verdict);

    // 7/8) 运行时披露 skill 目录（无用户确认）→ 子代理读 Ok、写被拒
    var skill = checker.Checker.init(testing.allocator, undefined, "/repo");
    defer skill.deinit();
    skill.clock_fn = &fixedClock;
    try skill.discloseReadOnlyRoot("/opt/plugin-store/skill", "/home/u");
    const sr = try skill.evaluate(.{ .tool_name = "Read", .input = "{\"file_path\":\"/opt/plugin-store/skill/ref.md\"}" });
    try testing.expectEqual(Verdict.allow, sr.verdict);
    const sw = try skill.evaluate(.{ .tool_name = "Write", .input = "{\"file_path\":\"/opt/plugin-store/skill/ref.md\"}" });
    try testing.expectEqual(Verdict.ask, sw.verdict);
}

test "golden: grantReadOnlyRoot 静默拒绝文件系统根 / home / cwd 祖先（§13.3 9/10）" {
    var c = checker.Checker.init(testing.allocator, undefined, "/repo");
    defer c.deinit();
    c.clock_fn = &fixedClock;
    try c.grantReadOnlyRoot("/"); // 文件系统根
    try c.discloseReadOnlyRoot("/home/u", "/home/u"); // home（披露入口）
    try c.discloseReadOnlyRoot("/", "/home/u"); // 文件系统根（披露入口）
    // cwd 的祖先也不可授权（否则等于把整个工作区父目录放成白名单）
    try c.grantReadOnlyRoot("/");
    try testing.expectEqual(@as(usize, 0), c.read_only_roots.items.len);

    // 反例：一个正常的技能目录可以披露成功
    try c.discloseReadOnlyRoot("/opt/plugin-store/skill", "/home/u");
    try testing.expectEqual(@as(usize, 1), c.read_only_roots.items.len);
}

test "golden: additionalDirectories 配置根算读+写（§13.3 11）" {
    var c = checker.Checker.init(testing.allocator, undefined, "/repo");
    defer c.deinit();
    c.clock_fn = &fixedClock;
    try c.grantWritableRoot("/opt/shared");
    const w = try c.evaluate(.{ .tool_name = "Write", .input = "{\"file_path\":\"/opt/shared/a.txt\"}" });
    try testing.expectEqual(Verdict.allow, w.verdict);
    const r = try c.evaluate(.{ .tool_name = "Read", .input = "{\"file_path\":\"/opt/shared/a.txt\"}" });
    try testing.expectEqual(Verdict.allow, r.verdict);
}

test "golden: 写类 label 在只读根内仍被拒（fail-closed，§13.3 18）" {
    var c = checker.Checker.init(testing.allocator, undefined, "/repo");
    defer c.deinit();
    c.clock_fn = &fixedClock;
    try c.grantReadOnlyRoot("/tmp/plans");
    // `notebook_edit` 由 `OperationLabel.fromToolName` 归成写类（未登记 → write）
    const out = try c.evaluate(.{ .tool_name = "notebook_edit", .input = "{\"notebook_path\":\"/tmp/plans/a.ipynb\"}" });
    try testing.expectEqual(Verdict.ask, out.verdict);
    // 写类（`notebook_edit` 是已知别名 → MODIFIES_FILES；未登记名字才是裸 `write`）。
    try testing.expectEqual(RiskLevel.modifies_files, out.risk_level);
    try testing.expect(!common.perm.OperationLabel.fromToolName("notebook_edit").isReadOnly());
}

// ── plan 闸门：必须在一切之前 ────────────────────────────────────────────────

test "golden: planGate 在最前 —— 危险命令也先报 plan（不弹卡片）" {
    var c = checker.Checker.init(testing.allocator, undefined, "/repo");
    defer c.deinit();
    c.clock_fn = &fixedClock;
    c.plan = .{ .active = true };

    // 若顺序错了，`rm -rf /` 会先在 L3 拿到 shell-analyzer 的 DENY；
    // 顺序对了，它必须先在 L1 被 plan-gate 拦下。
    const out = try c.evaluate(.{ .tool_name = "Bash", .input = "{\"command\":\"rm -rf /\"}" });
    try testing.expectEqual(Verdict.deny, out.verdict);
    try testing.expectEqualStrings(plan.PLAN_MODE_BLOCKED_REASON, out.reason);
    try testing.expectEqualStrings(checker.POLICY_SOURCE_ID, out.trace.?.provenance.source_id);

    // 越界写也一样：plan 先报，而不是 path-guard 先报。
    const w = try c.evaluate(.{ .tool_name = "Write", .input = "{\"file_path\":\"/etc/passwd\"}" });
    try testing.expectEqualStrings(plan.PLAN_MODE_BLOCKED_REASON, w.reason);
    try testing.expectEqualStrings(checker.POLICY_SOURCE_ID, w.trace.?.provenance.source_id);

    // plan 模式下只读工具照常放行
    const r = try c.evaluate(.{ .tool_name = "Read", .input = "{\"file_path\":\"/repo/a.zig\"}", .is_read_only = true });
    try testing.expectEqual(Verdict.allow, r.verdict);
}

test "golden: plan 激活时未登记工具也被拦（fail-closed）" {
    var c = checker.Checker.init(testing.allocator, undefined, "/repo");
    defer c.deinit();
    c.clock_fn = &fixedClock;
    c.plan = .{ .active = true };
    const out = try c.evaluate(.{ .tool_name = "SomeFutureTool", .input = "{}" });
    try testing.expectEqual(Verdict.deny, out.verdict);
    try testing.expectEqualStrings(plan.PLAN_MODE_BLOCKED_REASON, out.reason);
}

// ── BYPASS 回归防线 / 模式决策表 ─────────────────────────────────────────────

test "golden: BYPASS_PERMISSIONS 下的 Write 留下 decision=allow, source=policy 的 trace" {
    var c = checker.Checker.init(testing.allocator, undefined, "/repo");
    defer c.deinit();
    c.clock_fn = &fixedClock;
    c.mode = .bypass_permissions;
    const out = try c.evaluate(.{ .tool_name = "Write", .input = "{\"file_path\":\"/etc/passwd\"}" });
    try testing.expectEqual(Verdict.allow, out.verdict);
    const t = out.trace orelse return error.MissingTrace;
    try testing.expectEqual(Verdict.allow, t.decision);
    try testing.expectEqual(common.perm.Source.policy, t.provenance.source);
    try testing.expectEqualStrings("BYPASS_PERMISSIONS", t.provenance.key);
    try testing.expectEqualStrings("permission:Write", t.subject);
    // 元数据里能看出是 bypass 放的（不是沙箱隔离了）
    try testing.expectEqual(true, t.metadata.get("bypass").?.boolean);
}

test "golden: 直接结构体字面量构造（引擎用法）也能产出带 trace 的 Outcome" {
    // 引擎侧是 `perm.Checker{ .gpa = ..., .io = ..., .cwd = ..., .mode = ... }` 这样构造
    // （见 `engine/loop.zig`），**不走 `init`**。这里钉住那条构造路径仍然安全：
    // 所有可选字段都必须有默认值，否则那种构造会静默拿到未初始化内存。
    var c = checker.Checker{ .gpa = testing.allocator, .io = undefined, .cwd = "/repo" };
    c.clock_fn = &fixedClock;
    defer c.deinit();
    try testing.expectEqual(common.perm.Mode.ask, c.mode);
    try testing.expect(!c.plan.active);
    try testing.expectEqual(@as(usize, 0), c.allowed_roots.items.len);
    try testing.expectEqual(@as(usize, 0), c.read_only_roots.items.len);
    try testing.expect(c.deny_patterns.len == 0);
    try testing.expect(c.allow_tools.len == 0);
    try testing.expect(c.parent_mode == null);

    // 契约要求的字段一个都不能少（改字段名会让引擎编译失败，这里提前钉住）。
    const F = @typeInfo(checker.Checker).@"struct".fields;
    const required = [_][]const u8{
        "gpa",           "io",              "cwd",  "mode",
        "allowed_roots", "read_only_roots", "plan", "deny_patterns",
        "allow_tools",
    };
    inline for (required) |name| {
        const found = comptime blk: {
            for (F) |f| {
                if (std.mem.eql(u8, f.name, name)) break :blk true;
            }
            break :blk false;
        };
        try testing.expect(found);
    }

    const out = try c.evaluate(.{ .tool_name = "Read", .input = "{\"file_path\":\"/repo/a.zig\"}" });
    try testing.expectEqual(Verdict.allow, out.verdict);
    try testing.expect(out.trace != null);
    try testing.expect(out.trace.?.subject.len > 0);
}

test "golden: §3.2 四模式决策表逐格" {
    const T = struct {
        mode: common.perm.Mode,
        tool: []const u8,
        input: []const u8,
        path: ?[]const u8,
        want: Verdict,
        risk: RiskLevel,
    };
    const rows = [_]T{
        // ASK
        .{ .mode = .ask, .tool = "Read", .input = "{\"file_path\":\"/repo/a\"}", .path = null, .want = .allow, .risk = .read_only },
        .{ .mode = .ask, .tool = "Grep", .input = "{\"pattern\":\"x\"}", .path = null, .want = .allow, .risk = .read_only },
        .{ .mode = .ask, .tool = "Write", .input = "{\"file_path\":\"/repo/a\"}", .path = "/repo/a", .want = .ask, .risk = .modifies_files },
        .{ .mode = .ask, .tool = "Edit", .input = "{\"file_path\":\"/repo/a\"}", .path = "/repo/a", .want = .ask, .risk = .modifies_files },
        .{ .mode = .ask, .tool = "Bash", .input = "{\"command\":\"ls\"}", .path = null, .want = .allow, .risk = .high },
        .{ .mode = .ask, .tool = "Bash", .input = "{\"command\":\"rm -rf /\"}", .path = null, .want = .deny, .risk = .high },
        .{ .mode = .ask, .tool = "Task", .input = "{\"prompt\":\"x\"}", .path = null, .want = .ask, .risk = .agent_control },
        .{ .mode = .ask, .tool = "mcp__srv__do", .input = "{\"a\":1}", .path = null, .want = .ask, .risk = .mcp_tool },
        // ACCEPT_EDITS：写文件自动放行，Bash 刻意不自动放行
        .{ .mode = .accept_edits, .tool = "Write", .input = "{\"file_path\":\"/repo/a\"}", .path = "/repo/a", .want = .allow, .risk = .modifies_files },
        .{ .mode = .accept_edits, .tool = "Edit", .input = "{\"file_path\":\"/repo/a\"}", .path = "/repo/a", .want = .allow, .risk = .modifies_files },
        .{ .mode = .accept_edits, .tool = "Bash", .input = "{\"command\":\"rm -rf /tmp/x\"}", .path = null, .want = .deny, .risk = .high },
        .{ .mode = .accept_edits, .tool = "Bash", .input = "{\"command\":\"echo hi > f\"}", .path = null, .want = .ask, .risk = .high },
        .{ .mode = .accept_edits, .tool = "mcp__srv__do", .input = "{}", .path = null, .want = .ask, .risk = .mcp_tool },
        // BYPASS：全部 ALLOW
        .{ .mode = .bypass_permissions, .tool = "Write", .input = "{\"file_path\":\"/etc/passwd\"}", .path = "/etc/passwd", .want = .allow, .risk = .modifies_files },
        .{ .mode = .bypass_permissions, .tool = "Bash", .input = "{\"command\":\"rm -rf /\"}", .path = null, .want = .allow, .risk = .high },
        .{ .mode = .bypass_permissions, .tool = "mcp__srv__do", .input = "{}", .path = null, .want = .allow, .risk = .mcp_tool },
        // PLAN：只读工具放行，其余被闸门拦（先于一切）
        .{ .mode = .plan, .tool = "Read", .input = "{\"file_path\":\"/repo/a\"}", .path = null, .want = .allow, .risk = .read_only },
        .{ .mode = .plan, .tool = "Bash", .input = "{\"command\":\"ls -la\"}", .path = null, .want = .allow, .risk = .high },
        .{ .mode = .plan, .tool = "Bash", .input = "{\"command\":\"rm -rf /tmp/x\"}", .path = null, .want = .deny, .risk = .write },
        .{ .mode = .plan, .tool = "Write", .input = "{\"file_path\":\"/repo/a\"}", .path = "/repo/a", .want = .deny, .risk = .write },
        .{ .mode = .plan, .tool = "mcp__srv__do", .input = "{}", .path = null, .want = .deny, .risk = .write },
    };

    for (rows) |row| {
        var c = checker.Checker.init(testing.allocator, undefined, "/repo");
        defer c.deinit();
        c.clock_fn = &fixedClock;
        c.mode = row.mode;
        if (row.mode == .plan) c.plan = .{ .active = true };
        const out = try c.evaluate(.{
            .tool_name = row.tool,
            .input = row.input,
            .path = row.path,
        });
        try testing.expectEqual(row.want, out.verdict);
        try testing.expectEqual(row.risk, out.risk_level);
        try testing.expect(out.trace != null);
    }
}

test "golden: Verdict switch 穷尽 —— 加第五个变体会让本测试编译不过" {
    const cases = [_]Verdict{ .allow, .deny, .ask, .deferred };
    for (cases) |v| {
        // 穷尽 switch：**没有 else 分支**。`Verdict` 新增变体时这里必然编译失败。
        const wire = switch (v) {
            .allow => "allow",
            .deny => "deny",
            .ask => "ask",
            .deferred => "defer",
        };
        try testing.expectEqualStrings(v.wireName(), wire);
    }
    // 变体数量也钉死：加第五个变体时这里也会失败。
    try testing.expectEqual(@as(usize, 4), @typeInfo(Verdict).@"enum".fields.len);
    try testing.expectEqualStrings("defer", Verdict.deferred.wireName());
}

test "golden: 未登记 tool label 的两条路径都按写类（classify + checker）" {
    // classify：deferred + risk=.write
    const s = classify.deterministicClassify(.{ .tool_name = "SomeFutureTool", .input = "{}", .is_read_only = false, .is_destructive = false });
    try testing.expectEqual(Verdict.deferred, s.verdict);
    try testing.expectEqual(RiskLevel.write, s.risk_level);

    // checker：ASK + risk=.write（**不能**因为落在只读根里就变成 allow）
    var c = checker.Checker.init(testing.allocator, undefined, "/repo");
    defer c.deinit();
    c.clock_fn = &fixedClock;
    try c.grantReadOnlyRoot("/tmp/plans");
    const out = try c.evaluate(.{ .tool_name = "SomeFutureTool", .input = "{\"file_path\":\"/tmp/plans/a.txt\"}" });
    try testing.expectEqual(RiskLevel.write, out.risk_level);
    try testing.expectEqual(Verdict.ask, out.verdict);
}

test "golden: describeTool 摘要由内核生成且包含两张风险轴的信息" {
    const s = try @import("describe.zig").describeTool(testing.allocator, "Bash", "{\"command\":\"ls -la\"}", "/repo");
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "Classification: read-only") != null);
    // 工具级 HIGH 不在摘要文本里（它是独立字段 `RiskLevel.high`），这里反向确认：
    try testing.expect(std.mem.indexOf(u8, s, "destructive") == null);
}
