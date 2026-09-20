//! perm/ —— L2 能力
//!
//! 权限判定：`Verdict` / `Outcome` + 四级深度防御 + shell 危险命令分类 + 路径越界守卫。
//!
//! 允许的依赖（由 `build.zig` 声明；**别的模块 import 不进来**）：
//!   ← common
//!
//! ⚠️ **本模块不 import `util`**（`build.zig` 强制）。因此路径归一化/前缀判定
//! 在 `path.zig` 里自实现一份 —— 语义与 `util/fsio.zig` 的 `normalize` / `isWithin`
//! 一致，但**不解析符号链接**（见 `path.zig` 顶部关于 macOS `/tmp → /private/tmp`
//! 的 caveat）。同理，`Request.input_summary` 的 unified diff 预览需要读文件，
//! 首期只留接口形状，由引擎侧补齐。
//!
//! 文件分工：
//!   * `plan.zig`     L1 Plan 只读闸门（**唯一出口**，且必须在一切之前）
//!   * `shell.zig`    L3.5 shell 危险命令检测（22 条谓词，3 处大小写敏感）
//!   * `classify.zig` L3 确定性分类器 + 工具级 `RiskLevel`
//!   * `describe.zig` 人类可读摘要（**由内核生成，客户端不得自行拼**）
//!   * `path.zig`     越界守卫（词法口径 + 两级授权缓存判定）
//!   * `checker.zig`  L4 `Checker`：四级顺序 + 缓存 + trace
//!   * `sandbox.zig`  沙箱存根（恒 allow + `sandboxEnabled:false`）

const std = @import("std");
const common = @import("common");

/// 模块自述 —— 也用来**强制引用每个声明的依赖**：
/// 没有下面这段 comptime 触碰，Zig 的惰性编译会让 `build.zig` 的声明形同虚设。
pub const module_info = .{
    .name = "perm",
    .layer = "L2 能力",
    .deps = &[_][]const u8{"common"},
};

pub const plan = @import("plan.zig");
pub const shell = @import("shell.zig");
pub const classify = @import("classify.zig");
pub const describe = @import("describe.zig");
pub const path = @import("path.zig");
pub const checker = @import("checker.zig");
pub const sandbox = @import("sandbox.zig");
pub const golden = @import("golden_test.zig");

// ── 直达 re-export（消费点不必写两级路径）────────────────────────────────────
pub const PlanState = plan.PlanState;
pub const planGate = plan.planGate;
pub const SafetyInput = classify.SafetyInput;
pub const deterministicClassify = classify.deterministicClassify;
pub const riskLevelOf = classify.riskLevelOf;
pub const canonicalToolName = classify.canonicalToolName;
pub const dangerousCommandReason = shell.dangerousCommandReason;
pub const isReadOnlyCommand = shell.isReadOnlyCommand;
pub const ShellAssessment = shell.Assessment;
pub const RiskFlags = shell.RiskFlags;
pub const describeTool = describe.describeTool;
pub const Checker = checker.Checker;
pub const Request = checker.Request;
pub const ResolveError = path.ResolveError;
pub const resolveAndValidate = path.resolveAndValidate;

// 契约类型的转发（**不是重定义** —— 它们的真源在 `common/perm.zig`）。
pub const Verdict = common.perm.Verdict;
pub const Outcome = common.perm.Outcome;
pub const RiskLevel = common.perm.RiskLevel;
pub const DenialReason = common.perm.DenialReason;
pub const Mode = common.perm.Mode;
pub const OperationLabel = common.perm.OperationLabel;
pub const Trace = common.perm.Trace;
pub const Provenance = common.perm.Provenance;
pub const Source = common.perm.Source;
pub const ALLOWED_ROOTS_KEY = common.perm.ALLOWED_ROOTS_KEY;
pub const READ_ONLY_ROOTS_KEY = common.perm.READ_ONLY_ROOTS_KEY;

comptime {
    _ = common.module_info.name;
}

test "perm: 依赖链可解析" {
    try std.testing.expectEqualStrings("perm", module_info.name);
}

// 参考每个子模块，让它们的测试一起跑（`refAllDecls` 会递归进 `pub const` 声明）。
test {
    std.testing.refAllDecls(@This());
}
