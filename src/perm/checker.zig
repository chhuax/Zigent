//! `perm/checker.zig` —— L4：规则 + 两级授权缓存 + 模式默认决策。
//!
//! 设计依据：`docs/analysis/2026-09-19-07-权限与安全设计.md` §2（四级顺序）、
//! §3.2（每模式决策表）、§5（两级缓存刻意不合并）、§10（trace 必须附上）、
//! §11.1（`describeTool` 生成摘要；Bash 两条风险轴）。
//!
//! ## ★ 四级顺序（顺序错会多弹卡片或漏拦）
//! `evaluate` 里的实际调用顺序：
//!   0. **L1 `plan.planGate`** —— 在一切之前（§2.2：plan 先于一切权限语义，
//!      「一个连调用资格都没有的工具不该产生权限卡片」）；
//!   1. `BYPASS_PERMISSIONS` 短路 —— 连 `deny_patterns` 都拦不住（§3.2 注 1）；
//!   2. `deny_patterns` —— 用户显式拒绝清单（排在 ACCEPT_EDITS / PLAN 快路径**之前**）；
//!   3. 路径越界守卫（两级授权缓存：`allowed_roots` = 读+写，`read_only_roots` = **仅读**）；
//!   4. **L3 `classify.deterministicClassify`** —— 22 条危险命令在这里直接 DENY；
//!   5. `allow_tools` 显式许可；
//!   6. 模式默认决策（§3.2 表）。
//!
//! ## 两条风险轴（**必须两个字段，不能把一条藏进摘要文本里**）
//!   * `Outcome.risk_level` = **工具级**：`Bash` 恒 `.high`（`ls` 也一样）；
//!   * `Outcome.command_risk_level` = **命令级**：`read_only` / `review` / `write`
//!     / `network` / `high`，非 shell 工具为 `null`。
//!
//! ## trace
//! **每一个从 `evaluate` 出来的 `Outcome` 都带 trace**，且
//! `trace.provenance.source` 一定被设置 —— 包括 `BYPASS_PERMISSIONS` 短路
//! （§10.3 明确：这是最该审计的一档，也是「防止有人为了省事直接 return
//! `Verdict.allow` 而不带 trace」的回归防线）。

const std = @import("std");
const common = @import("common");
const plan = @import("plan.zig");
const shell = @import("shell.zig");
const classify = @import("classify.zig");
const describe = @import("describe.zig");
const path_mod = @import("path.zig");

const Allocator = std.mem.Allocator;

/// `Checker.evaluate` 的输入（契约 `INTERFACES-v1.md` §4.3，逐字）。
pub const Request = struct {
    tool_name: []const u8,
    tool_use_id: []const u8 = "",
    input: []const u8,
    is_read_only: bool = false,
    is_destructive: bool = false,
    path: ?[]const u8 = null,
    command: ?[]const u8 = null,
};

/// 显式工具清单 / 拒绝模式的审计来源 id（对齐 §10.1 的 `explicitTrace`）。
pub const EXPLICIT_TOOLS_SOURCE_ID = "explicit-tools";
pub const SHELL_ANALYZER_SOURCE_ID = "shell-analyzer";
pub const SAFE_TOOL_LIST_SOURCE_ID = "safe-tool-list";
pub const PATH_GUARD_SOURCE_ID = "path-guard";
pub const DENY_PATTERN_SOURCE_ID = "deny-pattern";
pub const POLICY_SOURCE_ID = "permission-checker";

/// 优先级（越小越优先）：DENY=0x, ASK=1x, ALLOW=2x。
pub const PRIORITY_DENY: i32 = 0x00;
pub const PRIORITY_ASK: i32 = 0x10;
pub const PRIORITY_ALLOW: i32 = 0x20;

/// ★ 两级授权缓存**刻意不合并**（§5.1）：
///   * `allowed_roots` ← `ALLOWED_ROOTS_KEY` = `"allowedFileRoots"`，**读 + 写**；
///     只有用户在 `file_access` 卡片上批准 write/edit 才会往里加。
///   * `read_only_roots` ← `READ_ONLY_ROOTS_KEY` = `"readOnlyFileRoots"`，**只服务
///     `read` / `glob` / `grep` / `lsp`**；来源里有一条是**运行时自己披露**
///     （加载插件技能时 `grantReadOnlyRoot`，**没有任何用户确认**）。
///
/// 合并成一个 `Grant{ root, allow_write }` 集合是最容易被做错的地方：那样
/// 「读授权」与「读写授权」共享同一个桶，升级/合并时一次手滑就把一次**披露**
/// 升成插件 store 上的 `write`/`edit`。用两个独立集合，升级只能显式发生。
pub const ALLOWED_ROOTS_KEY = common.perm.ALLOWED_ROOTS_KEY;
pub const READ_ONLY_ROOTS_KEY = common.perm.READ_ONLY_ROOTS_KEY;

pub const Checker = struct {
    gpa: Allocator,
    /// 运行时上下文里的 `io`（契约要求本字段存在）。⚠️ **首期 `evaluate` 不使用它**：
    /// unified diff 预览、文件大小上限等需要真实读文件的能力属引擎/工具侧，
    /// `perm` 只依赖 `common`（`build.zig` 强制），不碰 `util.io` / `util.fsio`。
    io: std.Io,
    cwd: []const u8,
    mode: common.perm.Mode = .ask,
    /// 读 + 写（`ALLOWED_ROOTS_KEY`）
    allowed_roots: std.ArrayListUnmanaged([]const u8) = .empty,
    /// **仅读类**（`READ_ONLY_ROOTS_KEY`）
    read_only_roots: std.ArrayListUnmanaged([]const u8) = .empty,
    plan: plan.PlanState = .{},
    /// 子串/工具名拒绝清单（大小写不敏感的子串匹配，命中即 DENY）
    deny_patterns: []const []const u8 = &.{},
    /// 显式许可的工具名
    allow_tools: []const []const u8 = &.{},
    /// 父会话档位（子代理钳制用，§3.3）。`null` = 无父会话 → **不钳制**。
    parent_mode: ?common.perm.Mode = null,
    /// 缓存里的工具名（`cacheAllowAlways` 且 `path == null` 时写入）。
    cached_tools: std.ArrayListUnmanaged([]const u8) = .empty,
    /// 墙钟来源（trace 的 `captured_at_ms`）。**测试注入点**：默认走 `io` 的 real 时钟；
    /// 单元测试没有 `io` 运行时，可注入一个固定值让 trace 断言保持确定性。
    clock_fn: *const fn (io: std.Io) i64 = defaultClock,
    /// trace 的存储区（`subject` 与 `metadata` 的 key/value）。**懒初始化**。
    ///
    /// 为什么用会话级 arena 而不是每次 `evaluate` 各自分配：`Trace` 通过
    /// `Outcome` 交给调用方（权限卡片 / tool metadata / transcript），**调用方
    /// 不知道也不该知道怎么释放它** —— 若逐次 `gpa.alloc`，就会变成一张张卡片
    /// 的小泄漏。放在 checker 的 arena 里，生命周期与会话一致，`deinit` 一次释放干净。
    ///
    /// 默认值是 `null`（不是未初始化的 `ArenaAllocator`）：引擎可以像
    /// `perm.Checker{ .gpa = ..., .io = ..., .cwd = ... }` 这样直接构造结构体字面量，
    /// 一个没有默认值的 arena 字段会让那种构造静默拿到野指针。
    arena_state: ?std.heap.ArenaAllocator = null,

    // ── 生命周期 ─────────────────────────────────────────────────────────────

    pub fn init(gpa: Allocator, io: std.Io, cwd: []const u8) Checker {
        return .{ .gpa = gpa, .io = io, .cwd = cwd, .arena_state = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Checker) void {
        for (self.allowed_roots.items) |r| self.gpa.free(r);
        self.allowed_roots.deinit(self.gpa);
        for (self.read_only_roots.items) |r| self.gpa.free(r);
        self.read_only_roots.deinit(self.gpa);
        for (self.cached_tools.items) |t| self.gpa.free(t);
        self.cached_tools.deinit(self.gpa);
        if (self.arena_state) |*a| a.deinit();
    }

    // ── 授权缓存 ─────────────────────────────────────────────────────────────

    /// **只有用户批准过 `file_access` 卡片（write/edit）才能调它。**
    /// 注意：**不会**顺带写 `read_only_roots`。
    pub fn grantWritableRoot(self: *Checker, root: []const u8) !void {
        const gpa = self.gpa;
        try appendUnique(gpa, &self.allowed_roots, root);
    }

    /// **用户批准过读**或**运行时披露**都能调它。绝不触碰 `allowed_roots`。
    pub fn grantReadOnlyRoot(self: *Checker, root: []const u8) !void {
        if (!isGrantableRoot(self.cwd, root)) return; // 静默拒绝（§5.1）
        const gpa = self.gpa;
        try appendUnique(gpa, &self.read_only_roots, root);
    }

    /// 运行时披露（对应朴素实现的 `grantReadOnlyRoot`）：拒绝文件系统根与用户 home，
    /// 否则一个畸形 skill root 会变成泛化白名单。`home` 由引擎传入（本模块不读 env）。
    pub fn discloseReadOnlyRoot(self: *Checker, root: []const u8, home: ?[]const u8) !void {
        if (home) |h| {
            if (std.mem.eql(u8, root, h)) return;
        }
        try self.grantReadOnlyRoot(root);
    }

    /// ★ "Allow always" 的落点。分类**由 `read_only` 决定**：
    ///   * `read_only = true` → 只进 `read_only_roots`（读授权**不得升级成写授权**）；
    ///   * `read_only = false` → 进 `allowed_roots`（读 + 写）。
    /// `path` 为 null 时记工具名到 `cached_tools`。
    pub fn cacheAllowAlways(
        self: *Checker,
        gpa: Allocator,
        tool_name: []const u8,
        path: ?[]const u8,
        read_only: bool,
    ) !void {
        _ = gpa;
        const label = common.perm.OperationLabel.fromToolName(tool_name);
        // fail-closed：未登记 label 会被 `fromToolName` 归成 `write`，因此
        // 「以为在缓存读授权、实际缓存了写授权」这种升级不可能发生 —— 反过来才可能，
        // 即读类 label 只能进只读集合。
        const effective_read_only = read_only and label.isReadOnly();
        if (path) |p| {
            const root = parentDir(p);
            if (effective_read_only) {
                try appendUnique(self.gpa, &self.read_only_roots, root);
            } else {
                try appendUnique(self.gpa, &self.allowed_roots, root);
            }
            return;
        }
        try appendUnique(self.gpa, &self.cached_tools, tool_name);
    }

    pub fn hasCachedTool(self: *const Checker, tool_name: []const u8) bool {
        for (self.cached_tools.items) |t| {
            if (std.mem.eql(u8, t, tool_name)) return true;
        }
        return false;
    }

    // ── 子代理继承（§5.3）─────────────────────────────────────────────────────

    /// 把父会话的授权快照按**类别、同级强度**灌进本 checker：
    /// `writable` 只进 `writable`，`read_only` 只进 `read_only`，**不升级也不降级**。
    /// 空集是 no-op（不能塞空集合实体）。
    pub fn inheritFrom(self: *Checker, parent: *const Checker) !void {
        for (parent.allowed_roots.items) |r| try appendUnique(self.gpa, &self.allowed_roots, r);
        for (parent.read_only_roots.items) |r| try appendUnique(self.gpa, &self.read_only_roots, r);
    }

    /// 档位钳制：取自身声明与父档位中**更紧**的一个（子代理永远不比父更松）。
    pub fn effectiveMode(self: *const Checker) common.perm.Mode {
        const parent = self.parent_mode orelse return self.mode;
        return if (modeRank(parent) > modeRank(self.mode)) parent else self.mode;
    }

    // ── ★ L1 + L2 + L3 + L4 ──────────────────────────────────────────────────

    /// 四级判定的唯一入口。**每个返回值都带 trace。**
    pub fn evaluate(self: *Checker, req: Request) !common.perm.Outcome {
        const label = common.perm.OperationLabel.fromToolName(req.tool_name);
        const tool_risk = classify.riskLevelOf(req.tool_name);
        const is_write_class = !label.isReadOnly();

        // L3 的结论**先算**，但**不因为它的结论就跳过前面的层**（guarded 只在 L1 使用）。
        // 这样既保住 §2.2 的顺序（L1 在一切之前），又让 plan 闸门能看见
        // 「`ls -la` 虽然工具类非只读、但这条命令是只读的」。
        const safety = classify.deterministicClassify(.{
            .tool_name = req.tool_name,
            .input = req.input,
            .is_read_only = req.is_read_only and label.isReadOnly(),
            .is_destructive = req.is_destructive,
        });
        const read_only_effective = label.isReadOnly() or
            (safety.verdict == .deferred and safety.command_risk_level != null and safety.command_risk_level.? == .read_only);

        // ── L1：Plan 只读闸门（**在一切之前**）──
        if (plan.planGate(&self.plan, req.tool_name, read_only_effective) == .deny) {
            var out = common.perm.Outcome.deny(plan.PLAN_MODE_BLOCKED_REASON, .write, .policy);
            out.trace = self.makeTrace(req, .deny, false, .policy, POLICY_SOURCE_ID, "plan-gate", PRIORITY_DENY, out.reason);
            return out;
        }

        // ── 设备/特殊文件（fail-closed，**在 BYPASS 之前**）──
        // `BYPASS_PERMISSIONS` 是「最前的短路」，但它短路的对象是**权限语义**；
        // `/dev/zero`（读爆内存）、`/proc/<pid>/environ`（泄漏 API key）不是权限问题，
        // 是「这个路径根本不许出现」，所以这一条排在 BYPASS 之前。
        if (try self.devicePathStage(req, tool_risk)) |out| return out;

        // ── 早退：BYPASS_PERMISSIONS 是最前的短路（连 deny_patterns 都拦不住）──
        // ★ 仍然必须留 trace：`decision=allow, source=policy`（§10.3 的回归防线）。
        if (self.effectiveMode() == .bypass_permissions) {
            const meta = [_]common.json.Map.Entry{
                .{ .key = "mode", .value = .{ .string = "BYPASS_PERMISSIONS" } },
                .{ .key = "bypass", .value = .{ .boolean = true } },
            };
            var out = common.perm.Outcome.allow("permissions bypassed by mode", tool_risk);
            out.trace = self.makeTraceAt(req, .allow, true, .policy, POLICY_SOURCE_ID, "BYPASS_PERMISSIONS", PRIORITY_ALLOW, out.reason, &meta);
            return out;
        }

        // ── L4a：用户显式拒绝清单（排在 ACCEPT_EDITS / PLAN 快路径**之前**）──
        if (self.matchesDeny(req)) |pattern| {
            const meta = [_]common.json.Map.Entry{
                .{ .key = "pattern", .value = .{ .string = pattern } },
            };
            var out = common.perm.Outcome.deny("tool or input matches a denied pattern", tool_risk, .policy);
            out.trace = self.makeTraceAt(req, .deny, false, .user, DENY_PATTERN_SOURCE_ID, pattern, PRIORITY_DENY, out.reason, &meta);
            return out;
        }

        // ── 路径越界守卫 + 两级授权缓存 ──
        if (try self.pathStage(req, is_write_class, tool_risk)) |out| return out;

        // ── L3：确定性分类器（22 条危险命令在这里 DENY）──
        if (safety.verdict == .deny) {
            const meta = shellTraceMeta(req);
            var out = safety;
            // ★ 命令级风险轴必须在 DENY 上也有值（它来自 L3.5 的分级）。
            out.command_risk_level = shellCommandRiskOf(req);
            out.trace = self.makeTraceAt(req, .deny, false, .builtin, SHELL_ANALYZER_SOURCE_ID, req.tool_name, PRIORITY_DENY, out.reason, meta.slice());
            return out;
        }

        // ── L4b：显式许可清单 ──
        if (self.isExplicitlyAllowed(req.tool_name)) {
            var out = common.perm.Outcome.allow("tool is explicitly allowed", tool_risk);
            out.command_risk_level = safety.command_risk_level;
            out.trace = self.makeTrace(req, .allow, true, .cli, EXPLICIT_TOOLS_SOURCE_ID, req.tool_name, PRIORITY_ALLOW, out.reason);
            return out;
        }

        // ── L4c：模式默认决策（§3.2 表）──
        return self.modeDecision(req, label, tool_risk, safety);
    }

    fn modeDecision(
        self: *Checker,
        req: Request,
        label: common.perm.OperationLabel,
        tool_risk: common.perm.RiskLevel,
        safety: common.perm.Outcome,
    ) !common.perm.Outcome {
        const canon = classify.canonicalOf(req.tool_name);
        const mode = self.effectiveMode();

        // 读类工具（含 LSP / Glob / Grep）在 ASK 与 PLAN 下都免检（SAFE_TOOLS）。
        if (label.isReadOnly()) {
            var out = common.perm.Outcome.allow("read-only tool is always allowed", tool_risk);
            out.command_risk_level = safety.command_risk_level;
            out.trace = self.makeTrace(req, .allow, true, .builtin, SAFE_TOOL_LIST_SOURCE_ID, req.tool_name, PRIORITY_ALLOW, out.reason);
            return out;
        }

        // 只读 shell 命令（`ls -la && pwd`）：allowed 但**命令级**风险是 READ_ONLY。
        if ((canon == .bash or canon == .powershell) and safety.command_risk_level != null and
            safety.command_risk_level.? == .read_only)
        {
            var out = common.perm.Outcome.allow("read-only shell command", tool_risk);
            out.command_risk_level = safety.command_risk_level;
            out.trace = self.makeTrace(req, .allow, true, .builtin, SHELL_ANALYZER_SOURCE_ID, req.tool_name, PRIORITY_ALLOW, out.reason);
            return out;
        }

        // `ACCEPT_EDITS` 只自动放行**写文件**类；Bash 刻意**不进** EDIT_TOOLS（§3.2）。
        if (mode == .accept_edits and (canon == .write or canon == .edit)) {
            var out = common.perm.Outcome.allow("ACCEPT_EDITS auto-approves file edits", tool_risk);
            out.command_risk_level = safety.command_risk_level;
            out.trace = self.makeTrace(req, .allow, true, .session, "accept-edits", req.tool_name, PRIORITY_ALLOW, out.reason);
            return out;
        }

        // 其余：ASK（没有交互通道时由引擎退化成 deny，见 §2.6 的 NEEDS_PERMISSION 三态）。
        var out = common.perm.Outcome.ask("confirmation required by permission mode", tool_risk);
        out.command_risk_level = safety.command_risk_level;
        const source: common.perm.Source = if (safety.command_risk_level != null) .builtin else .policy;
        const source_id: []const u8 = if (safety.command_risk_level != null) SHELL_ANALYZER_SOURCE_ID else POLICY_SOURCE_ID;
        out.trace = self.makeTrace(req, .ask, false, source, source_id, req.tool_name, PRIORITY_ASK, out.reason);
        return out;
    }

    fn matchesDeny(self: *const Checker, req: Request) ?[]const u8 {
        for (self.deny_patterns) |p| {
            if (p.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(p, req.tool_name)) return p;
            if (containsIgnoreCase(req.input, p)) return p;
            if (containsIgnoreCase(req.tool_name, p)) return p;
        }
        return null;
    }

    fn isExplicitlyAllowed(self: *const Checker, tool_name: []const u8) bool {
        for (self.allow_tools) |t| {
            if (std.ascii.eqlIgnoreCase(t, tool_name)) return true;
        }
        return self.hasCachedTool(tool_name);
    }

    // ── 路径阶段 ─────────────────────────────────────────────────────────────

    /// 设备/特殊文件守卫（在 BYPASS 之前）。返回 `null` = 这一层不表态。
    fn devicePathStage(self: *Checker, req: Request, tool_risk: common.perm.RiskLevel) !?common.perm.Outcome {
        const p = try self.resolvedRequestPath(req) orelse return null;
        defer self.gpa.free(p);
        if (!path_mod.isBlockedDevicePath(p)) return null;
        const meta = [_]common.json.Map.Entry{
            .{ .key = "path", .value = .{ .string = p } },
            .{ .key = "error", .value = .{ .string = "BlockedDevicePath" } },
        };
        var out = common.perm.Outcome.deny("reading device or special files is blocked", tool_risk, .policy);
        out.trace = self.makeTraceAt(req, .deny, false, .policy, PATH_GUARD_SOURCE_ID, p, PRIORITY_DENY, out.reason, &meta);
        return out;
    }

    /// 路径越界守卫 + 两级授权缓存。返回 `null` = 这一层不表态，继续往 L3 / L4 走。
    fn pathStage(
        self: *Checker,
        req: Request,
        is_write_class: bool,
        tool_risk: common.perm.RiskLevel,
    ) !?common.perm.Outcome {
        const p = try self.resolvedRequestPath(req) orelse return null;
        defer self.gpa.free(p);

        const within_base = lexicalWithin(self.cwd, p);
        const writable = self.findWritableRoot(p);
        const readable = self.findReadableRoot(p);

        if (!within_base and readable == null) {
            // cwd 之外、且没有任何授权根覆盖 → 越界（§13.3 用例 2）。
            const meta = [_]common.json.Map.Entry{
                .{ .key = "path", .value = .{ .string = p } },
                .{ .key = "error", .value = .{ .string = "OutsideBase" } },
            };
            var out = common.perm.Outcome.deny("path is outside the working directory", tool_risk, .policy);
            out.trace = self.makeTraceAt(req, .deny, false, .policy, PATH_GUARD_SOURCE_ID, p, PRIORITY_DENY, out.reason, &meta);
            return out;
        }

        if (!is_write_class and readable != null) {
            // 读类 + 有读授权（cwd 内、或 `allowed_roots`、或 `read_only_roots`）→ 放行。
            var out = common.perm.Outcome.allow("read within the authorized roots", .read_only);
            out.trace = self.makeTrace(req, .allow, true, .session, PATH_GUARD_SOURCE_ID, p, PRIORITY_ALLOW, out.reason);
            return out;
        }

        if (is_write_class and writable != null and !within_base) {
            // 写类 + 显式授权的**读+写**根 → 放行。
            var out = common.perm.Outcome.allow("write within an explicitly authorized root", .modifies_files);
            out.trace = self.makeTrace(req, .allow, true, .session, ALLOWED_ROOTS_KEY, p, PRIORITY_ALLOW, out.reason);
            return out;
        }

        // 其余情况不表态：
        //   * 写类在 cwd 内 → 交 L3/L4 按模式决策（写文件本来就该问）；
        //   * 写类只落在 `read_only_roots` 里 → **绝不在这里放行**。
        //     ★ 读授权不得升级成写授权（§5.1）：只读根不产生任何写侧结论，
        //       于是它会走到 L4 的模式决策（ASK 模式 → 弹卡片）。
        return null;
    }

    /// 请求路径的绝对词法归一化形态（不做 realpath）。
    fn resolvedRequestPath(self: *Checker, req: Request) !?[]const u8 {
        const raw = try resolveRequestPath(self.gpa, req) orelse return null;
        defer self.gpa.free(raw);
        return try path_mod.resolve(self.gpa, self.cwd, raw);
    }

    /// 写侧查询：**只看 `allowed_roots`**（读+写），永远不看 `read_only_roots`。
    fn findWritableRoot(self: *const Checker, path: []const u8) ?[]const u8 {
        for (self.allowed_roots.items) |root| {
            if (lexicalWithin(root, path)) return root;
        }
        return null;
    }

    /// 读侧查询：`allowed_roots` + `read_only_roots` 都可以。
    pub fn findReadableRoot(self: *const Checker, path: []const u8) ?[]const u8 {
        if (self.findWritableRoot(path)) |r| return r;
        for (self.read_only_roots.items) |root| {
            if (lexicalWithin(root, path)) return root;
        }
        return null;
    }

    /// shell 判定的结构化 trace 元数据（`class` + 命中的 `rule`）。
    /// 审计与权限卡片要能读到**稳定 rule id**，而不是把正则/实现细节塞进文本。
    const ShellMeta = struct {
        items: [2]common.json.Map.Entry = undefined,
        len: usize = 0,

        pub fn slice(self: *const ShellMeta) []const common.json.Map.Entry {
            return self.items[0..self.len];
        }
    };

    /// 命令级风险（仅 shell 工具；其它工具返回 `null`）。
    fn shellCommandRiskOf(req: Request) ?common.perm.RiskLevel {
        const canon = classify.canonicalOf(req.tool_name);
        if (canon != .bash and canon != .powershell) return null;
        const command = shell.commandFromInput(req.input) orelse return null;
        return shell.assess(command).risk_level;
    }

    fn shellTraceMeta(req: Request) ShellMeta {
        var meta = ShellMeta{};
        const command = shell.commandFromInput(req.input) orelse return meta;
        const a = shell.assess(command);
        meta.items[0] = .{ .key = "class", .value = .{ .string = a.class.wireName() } };
        meta.len = 1;
        if (a.rule_id) |id| {
            meta.items[1] = .{ .key = "rule", .value = .{ .string = id } };
            meta.len = 2;
        }
        return meta;
    }

    // ── trace ────────────────────────────────────────────────────────────────

    /// trace 的分配器：懒初始化 arena（见 `arena_state` 注释）。
    fn traceAllocator(self: *Checker) Allocator {
        if (self.arena_state == null) self.arena_state = std.heap.ArenaAllocator.init(self.gpa);
        return self.arena_state.?.allocator();
    }

    /// 构造 trace。`meta_items` 的 key 必须是**编译期字符串字面量**，
    /// value 是静态的 `common.json.Value` —— 存储区是 checker 的 arena（见 `arena` 注释）。
    fn makeTraceAt(
        self: *Checker,
        req: Request,
        decision: common.perm.Verdict,
        allowed: bool,
        source: common.perm.Source,
        source_id: []const u8,
        key: []const u8,
        priority: i32,
        reason: []const u8,
        meta_items: []const common.json.Map.Entry,
    ) common.perm.Trace {
        const a = self.traceAllocator();
        const subject = std.fmt.allocPrint(a, "permission:{s}", .{req.tool_name}) catch "permission:?";
        var metadata = common.json.Map{};
        for (meta_items) |item| {
            metadata.put(a, item.key, item.value) catch {};
        }
        return .{
            .subject = subject,
            .decision = decision,
            .allowed = allowed,
            .provenance = .{
                .source = source,
                .source_id = source_id,
                .path = self.cwd,
                .key = key,
                .priority = priority,
                .captured_at_ms = self.clock_fn(self.io),
            },
            .reason = reason,
            .metadata = metadata,
        };
    }

    fn makeTrace(
        self: *Checker,
        req: Request,
        decision: common.perm.Verdict,
        allowed: bool,
        source: common.perm.Source,
        source_id: []const u8,
        key: []const u8,
        priority: i32,
        reason: []const u8,
    ) common.perm.Trace {
        return self.makeTraceAt(req, decision, allowed, source, source_id, key, priority, reason, &.{});
    }
};

// ── 纯辅助 ───────────────────────────────────────────────────────────────────

/// 墙钟 epoch 毫秒（`std.time` 在 0.16 已并入 `std.Io`，且原语要 `io` 实例）。
pub fn defaultClock(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn fixedClock(_: std.Io) i64 {
    return 1_700_000_000_000;
}

/// 档位强度序（§3.1，数值已冻结：越大越紧）。
pub fn modeRank(m: common.perm.Mode) u8 {
    return switch (m) {
        .bypass_permissions => 0,
        .accept_edits => 1,
        .ask => 2,
        .plan => 3,
    };
}

fn appendUnique(gpa: Allocator, list: *std.ArrayListUnmanaged([]const u8), value: []const u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try list.append(gpa, try gpa.dupe(u8, value));
}

/// `isGrantableRoot`（§5.1）：文件系统根与 **cwd 的祖先**一律拒绝，
/// 否则一个畸形 skill root 会变成泛化白名单。
fn isGrantableRoot(cwd: []const u8, root: []const u8) bool {
    if (root.len == 0) return false;
    if (std.mem.eql(u8, root, "/")) return false; // 文件系统根
    if (path_mod.isWithin(root, cwd)) return false; // root 是 cwd 的祖先
    return true;
}

/// `base` 的父目录（`/a/b` → `/a`）。相对路径无父目录时返回 `.`。
fn parentDir(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        if (idx == 0) return "/";
        return path[0..idx];
    }
    return ".";
}

/// 词法「在根内」判定。**不做 realpath** —— 见 `path.zig` 的 macOS `/tmp` caveat。
fn lexicalWithin(root: []const u8, path: []const u8) bool {
    return path_mod.isWithin(root, path);
}

/// 请求里的路径：优先 `req.path`，其次输入 JSON 的 `file_path` / `path` / `notebook_path`。
fn resolveRequestPath(gpa: Allocator, req: Request) !?[]const u8 {
    if (req.path) |p| return try gpa.dupe(u8, p);
    const canon = classify.canonicalOf(req.tool_name);
    if (canon != .read and canon != .write and canon != .edit and canon != .glob and canon != .grep) return null;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const keys = [_][]const u8{ "file_path", "path", "notebook_path", "pattern", "target_file" };
    for (keys) |k| {
        if (describe.inputField(arena, req.input, k)) |v| return try gpa.dupe(u8, v);
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testChecker() Checker {
    var c = Checker.init(testing.allocator, undefined, "/repo");
    c.clock_fn = fixedClock;
    return c;
}

test "checker: BYPASS_PERMISSIONS 短路**仍然**留 trace（回归防线）" {
    var c = testChecker();
    defer c.deinit();
    c.mode = .bypass_permissions;
    // 连显式拒绝清单都拦不住 BYPASS。
    c.deny_patterns = &.{"Write"};
    const out = try c.evaluate(.{ .tool_name = "Write", .input = "{\"file_path\":\"/repo/a\"}", .path = "/repo/a" });
    try testing.expectEqual(common.perm.Verdict.allow, out.verdict);
    const t = out.trace orelse return error.MissingTrace;
    try testing.expectEqual(common.perm.Verdict.allow, t.decision);
    try testing.expectEqual(common.perm.Source.policy, t.provenance.source);
    try testing.expect(t.provenance.source_id.len > 0);
}

test "checker: deny_patterns 早于 ACCEPT_EDITS 快路径" {
    var c = testChecker();
    defer c.deinit();
    c.mode = .accept_edits;
    c.deny_patterns = &.{"Write"};
    const out = try c.evaluate(.{ .tool_name = "Write", .input = "{\"file_path\":\"/repo/a\"}", .path = "/repo/a" });
    try testing.expectEqual(common.perm.Verdict.deny, out.verdict);
}

test "checker: 只读根不得授权写（读授权不得升级）" {
    var c = testChecker();
    defer c.deinit();
    try c.grantReadOnlyRoot("/tmp/plans");
    // 读：放行
    const r = try c.evaluate(.{ .tool_name = "Read", .input = "{\"file_path\":\"/tmp/plans/a.md\"}" });
    try testing.expectEqual(common.perm.Verdict.allow, r.verdict);
    // 写：仍然要 ASK（不能被只读授权升级成 ALLOW）
    const w = try c.evaluate(.{ .tool_name = "Write", .input = "{\"file_path\":\"/tmp/plans/b.md\"}" });
    try testing.expectEqual(common.perm.Verdict.ask, w.verdict);
}

test "checker: 写授权覆盖读写" {
    var c = testChecker();
    defer c.deinit();
    try c.grantWritableRoot("/tmp/plans");
    const w = try c.evaluate(.{ .tool_name = "Write", .input = "{\"file_path\":\"/tmp/plans/b.md\"}" });
    try testing.expectEqual(common.perm.Verdict.allow, w.verdict);
}

test "checker: cacheAllowAlways(read_only=true) 只进只读集合" {
    var c = testChecker();
    defer c.deinit();
    try c.cacheAllowAlways(testing.allocator, "Read", "/tmp/plans/a.md", true);
    try testing.expectEqual(@as(usize, 0), c.allowed_roots.items.len);
    try testing.expectEqual(@as(usize, 1), c.read_only_roots.items.len);
    try testing.expectEqualStrings("/tmp/plans", c.read_only_roots.items[0]);

    try c.cacheAllowAlways(testing.allocator, "Write", "/tmp/plans/b.md", false);
    try testing.expectEqual(@as(usize, 1), c.allowed_roots.items.len);
}

test "checker: 未登记 tool label 按写类 fail-closed" {
    var c = testChecker();
    defer c.deinit();
    try c.grantReadOnlyRoot("/tmp/x");
    const out = try c.evaluate(.{ .tool_name = "SomeFutureTool", .input = "{}", .path = "/tmp/x/f" });
    try testing.expectEqual(common.perm.RiskLevel.write, out.risk_level);
    try testing.expectEqual(common.perm.Verdict.ask, out.verdict);
}

test "checker: 子代理按类别同级继承（读不升级、写不下放）" {
    var parent = testChecker();
    defer parent.deinit();
    try parent.grantReadOnlyRoot("/tmp/plans");
    try parent.grantWritableRoot("/opt/shared");
    var child = testChecker();
    defer child.deinit();
    try child.inheritFrom(&parent);
    try testing.expectEqual(@as(usize, 1), child.allowed_roots.items.len);
    try testing.expectEqual(@as(usize, 1), child.read_only_roots.items.len);
    // 父只有读授权的路径：子代理读成功、写仍被拒（§13.3 用例 5/6）
    const r = try child.evaluate(.{ .tool_name = "Read", .input = "{\"file_path\":\"/tmp/plans/a.md\"}" });
    try testing.expectEqual(common.perm.Verdict.allow, r.verdict);
    const w = try child.evaluate(.{ .tool_name = "Write", .input = "{\"file_path\":\"/tmp/plans/b.md\"}" });
    try testing.expectEqual(common.perm.Verdict.ask, w.verdict);
}

test "checker: 空集继承是 no-op（不物化空集合）" {
    var parent = testChecker();
    defer parent.deinit();
    var child = testChecker();
    defer child.deinit();
    try child.inheritFrom(&parent);
    try testing.expectEqual(@as(usize, 0), child.allowed_roots.items.len);
    try testing.expectEqual(@as(usize, 0), child.read_only_roots.items.len);
}

test "checker: 档位钳制 —— 子代理永不比父松" {
    var c = testChecker();
    defer c.deinit();
    c.mode = .bypass_permissions;
    c.parent_mode = .plan;
    try testing.expectEqual(common.perm.Mode.plan, c.effectiveMode());
    c.mode = .plan;
    c.parent_mode = .bypass_permissions;
    try testing.expectEqual(common.perm.Mode.plan, c.effectiveMode());
    c.parent_mode = null;
    try testing.expectEqual(common.perm.Mode.plan, c.effectiveMode());
}

test "checker: 每个 Outcome 都带合法 provenance" {
    var c = testChecker();
    defer c.deinit();
    const cases = [_]Request{
        .{ .tool_name = "Read", .input = "{\"file_path\":\"/repo/a\"}" },
        .{ .tool_name = "Write", .input = "{\"file_path\":\"/repo/a\"}", .path = "/repo/a" },
        .{ .tool_name = "Bash", .input = "{\"command\":\"ls\"}" },
        .{ .tool_name = "Bash", .input = "{\"command\":\"rm -rf /\"}" },
        .{ .tool_name = "WeirdTool", .input = "{}" },
    };
    for (cases) |req| {
        const out = try c.evaluate(req);
        const t = out.trace orelse return error.MissingTrace;
        try testing.expect(t.subject.len > 0);
        // `source` 是枚举，取值天然合法；这里断言它确实被写入（非默认漂移）。
        _ = t.provenance.source.wireName();
        try testing.expect(t.provenance.source_id.len > 0);
        try testing.expect(t.provenance.captured_at_ms != 0);
    }
}

test "checker: 路径越界被拒（含 ../ 与绝对路径）" {
    var c = testChecker();
    defer c.deinit();
    const out = try c.evaluate(.{ .tool_name = "Write", .input = "{\"file_path\":\"../etc/passwd\"}" });
    try testing.expectEqual(common.perm.Verdict.deny, out.verdict);
    try testing.expectEqual(common.perm.DenialReason.policy, out.denial_reason.?);
    const abs = try c.evaluate(.{ .tool_name = "Read", .input = "{\"file_path\":\"/etc/passwd\"}" });
    try testing.expectEqual(common.perm.Verdict.deny, abs.verdict);
}

test "checker: 设备文件在 BYPASS 之后仍被拒（fail-closed）" {
    var c = testChecker();
    defer c.deinit();
    c.mode = .bypass_permissions;
    const out = try c.evaluate(.{ .tool_name = "Read", .input = "{\"file_path\":\"/dev/zero\"}" });
    try testing.expectEqual(common.perm.Verdict.deny, out.verdict);
}
