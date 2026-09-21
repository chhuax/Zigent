# Zigent 开发路线图 / Development Roadmap

> **基准 / Basis**：`18-工作包清单`（WP-00 ~ WP-22，共 **89 条可执行验收**）。条目原文取自设计文档，因此正文为中文。
> **Item text is quoted verbatim from the Chinese design docs**, hence the Chinese wording below.
>
> **状态图例 / Status legend**：`[x]` 已完成 · `[ ]` 未完成（若部分完成会标注 🟡）· ⏸ 后置或不做

## 总览 / Summary

| WP | 名称 | 交付物（实际） | 条目 | 状态 |
|---|---|---|:--:|:--:|
| WP-00 | 契约冻结 | `src/common/` | 4 | ✅ 4/4 |
| WP-01 | `util/` 基座 | `src/util/` 6 文件 1,251 行 | 4 | 🟡 3/4 |
| WP-02 | `common/` 契约层 | `src/common/` 10 文件 3,623 行 | 5 | ✅ 5/5 |
| WP-03 | `llm/` Provider 传输 | `src/llm/` 7 文件 5,000 行 | 5 | 🟡 2/5 |
| WP-04 | `config/` 配置与鉴权 | `src/config/` 6 文件 3,171 行 | 5 | ✅ 5/5 |
| WP-05 | `perm/` 权限 | `src/perm/` 9 文件 3,733 行 | 5 | ✅ 5/5 |
| WP-06 | `tools/` 8 个工具 | `src/tools/` 14 文件 4,116 行 | 6 | 🟡 5/6 |
| WP-07 | `memory/` 记忆与归档 | `src/memory/` 6 文件 2,864 行 | 5 | ✅ 5/5 |
| WP-08 | `engine/loop` 主循环 | `src/engine/loop.zig` | 5 | ✅ 5/5 |
| WP-09 | `engine/pairing`（`Turn`） | `src/engine/turn.zig` | 4 | ✅ 4/4 |
| WP-10 | `engine/prompt` | `src/engine/prompt.zig` | 4 | ✅ 4/4 |
| WP-11 | `engine/tool_exec` | `src/engine/tool_exec.zig` | 5 | 🟡 3/5 |
| WP-12 | `budget` + `compact` | `src/engine/{budget,compact}.zig` | 7 | 🟡 5/7 |
| WP-13 | `recovery` | `src/engine/recovery.zig` | 5 | 🟡 4/5 |
| WP-14 | `transcript` | `src/engine/transcript.zig` | 6 | 🟡 4/6 |
| WP-15 | `cli/` 入口 | `src/cli/` 5 文件 1,146 行 | 4 | 🟡 3/4 |
| WP-16 | `server/` HTTP + SSE | `src/server/` 7 文件 1,571 行 | 7 | ✅ 7/7 |
| WP-17 | `client_proto/` | `src/client_proto/` 3 文件 526 行 | 4 | 🟡 3/4 |
| WP-18 | golden fixtures + 双后端对等 | — | 3 | ❌ 0/3 |
| WP-19 | benchmark 对齐 | — | 3 | ❌ 0/3 |
| WP-20 | TUI | ⏸ 外包，不进内核 | — | ⏸ |
| WP-21 | Web UI（Tauri + Rust） | — | — | ❌ |
| WP-22 | 桌面壳 | — | — | ❌ |

**已核验的总缺口（详见文末）**：7 处。

**测试基线 / Test baseline**：`zig build test` → 25/25 steps · **537/537 tests passed**；`zig build guard` → OK；`tests/smoke.sh` → **12/12**。

---

# 阶段 0

## WP-00 · 契约冻结

- [x] 1. `zig build test` 通过，且所有模块能用 stub 编译通过（G1 门禁）
- [x] 2. 33 种事件 + 4 种 block 的 `switch` 穷尽（故意删一个分支 → 必须编译失败）
- [x] 3. `Turn.init` 对 count/id 不匹配报错（三个 `PairingError` 变体各一条用例）
- [x] 4. §13 命名裁决的 6 个名字在代码里无一处用错（grep 校验）

# 阶段 1 · 五条流并行

## WP-01 · `util/` 基座

- [x] 1. 除 `util/io.zig` 外，全仓不 import `std.posix`（CI grep 检查）→ `zig build guard` OK
- [ ] 2. `zig build test` 在 **0.16.0 与 0.17.0-dev 上都通过** ← **从未在 0.17 上跑过**
- [x] 3. `atomicWrite` 的原子性测试（并发写 + 崩溃模拟）
- [x] 4. `proc.zig` 的 argv 构造测试覆盖 POSIX 与（留形状的）Windows 分支

## WP-02 · `common/` 契约层实现

- [x] 1. transcript 逐字节 round-trip（parse → 重建 → 序列化 → 对比）
- [x] 2. 未知字段保留（喂含未来字段的 JSON → 序列化回来字段仍在）
- [x] 3. 三套时间戳键名（`timestamp`/`createdAt`/`created_at`）都能认
- [x] 4. 枚举 `wireName`/`fromWire` 往返 + unknown 不 panic
- [x] 5. `ToolUseBlock.input` 保真（带空格/key 顺序/大数字全程不被改写）

## WP-03 · `llm/` Provider 传输

- [ ] 1. **真实 provider 连续 3 轮**（Anthropic **和** 一个 OpenAI 兼容网关）全成功 ← **从未跑通**，见 WP-03 缺口
- [x] 2. 流式是真流式（不是攒完再吐）→ 冒烟第 4 项：SSE 首帧 < 1s
- [x] 3. tool_call 三家语义各有用例（id 后续帧才到 / 空参数补 `{}` / 终态快照覆盖 / id 为空报协议错误）
- [x] 4. `emittedOnAttempt` 闸门生效（吐过 token 后不重试）
- [x] 5. thinking `signature` 往返（两轮对话验证，丢了会 400）

## WP-04 · `config/` 配置与鉴权

- [x] 1. `enc:1:` 加解密往返（既有密文 → Zig 解密；Zig 加密 → 既有实现解密）
- [x] 2. 分层合并优先级正确 + 内容 SHA-256 指纹判失效（不是 mtime）
- [x] 3. `apiKeyEnv` **优先于**内联 `apiKey` → `src/config/auth.zig:41`
- [x] 4. 未知字段保留（本机 `config.json` 里就有未知字段）
- [x] 5. `config.json` 写侧 `chmod 600` + 临时文件 0600 + 目录 0700

## WP-05 · `perm/` 权限

- [x] 1. 四级防御顺序正确：Plan 闸门在 `checkPermissions` **之前**
- [x] 2. 危险命令 golden 表全过（含"已知放行/漏报"用例）→ 实际 **67 条**（设计写 64）
- [x] 3. 越界用例（含两级缓存 + 子代理继承）→ 实际 **88 条**（设计写 23）
- [x] 4. 未登记的 operation label **fail-closed 按写类**处理
- [x] 5. 大小写敏感：`git branch -D` DENY / `-d` 放行；`git checkout -B` DENY / `-b` 放行

## WP-06 · `tools/` 8 个工具

- [x] 1. **单一 schema 真源**：一个 `Spec` 同时产出模型 schema 与校验器
- [x] 2. 每个工具有：输入 schema 校验用例 + 只读/危险/并发标记用例 + 结果上限用例 → `tools` **90 测试**
- [x] 3. `Read` 输出格式 `String.format("%6d\t%s", …)` 保真
- [x] 4. `Edit` 的写前过期检查（外部改动 → 拒绝盲改）
- [ ] 5. 🟡 **`Bash` 的进程树终止 + 超时 + 后台会话** → 超时 ✅、signal 记录 ✅；**进程组终止未见实现**，后台会话未核验
- [x] 6. 工具别名表（`Read`↔`read_file` 等）双向解析 → `src/tools/root.zig:177`

## WP-07 · `memory/` 记忆与归档

- [x] 1. `AGENTS.md` 加载 + `@include` 递归（深度 ≤5、循环检测、单文件 12000 字截断）
- [x] 2. 热核：`\n§\n` 分隔 + 字符预算（按 code point 计）+ `memory.lock` + SHA-256 `baseHash` 二次校验
- [x] 3. 注入防护：零宽/方向控制字符检测 + **13 条威胁正则**命中即拒；读取侧过滤成 `[BLOCKED: …]`
- [x] 4. 归档（方案 A）：JSONL + grep + 打分，能在历史 transcript 上召回
- [x] 5. 长度语义：CJK（BMP 内）零差异的边界用例，emoji 场景按 code point 计

# 阶段 2 · 内核集成

## WP-08 · `engine/loop` 主循环

- [x] 1. 用假 provider 跑通三轮自主循环（读→改→再读），事件序列符合预期
- [x] 2. **5 类退出条件**各有用例（maxTurns / 自然终止 / 恢复耗尽 / 取消 / 熔断）
- [x] 3. `turnCount--` 陷阱：turn 计数与重试计数彻底分离，熔断走专用出口
- [x] 4. 新错误路径不重犯无界循环：`RATE_LIMITED`/`MODEL_OVERLOADED` 有显式上限
- [x] 5. 模型回退单一 owner

## WP-09 · `engine/pairing`（`Turn` 原子单元）

- [x] 1. `Turn.init` 校验 count/id，三个 `PairingError` 变体各有用例
- [x] 2. 四类破坏窗口全部有回归测试（已落盘/未落盘异常、流式中断、压缩改写前缀、取消时混写）
- [x] 3. `appendTo` 是一次原子写两条（不存在中间态）
- [x] 4. 压缩只接受/产出 `[]Turn`

## WP-10 · `engine/prompt`

- [x] 1. 8 段顺序正确（有断言）→ `src/engine/prompt.zig:138`
- [x] 2. 静态/动态边界：边界前可缓存、边界后不可
- [x] 3. 压缩后统一清 prompt cache
- [x] 4. `AGENTS.md` 段单独装配（不经 `MemoryPromptProvider`）

## WP-11 · `engine/tool_exec`

- [ ] 1. **并发安全工具并跑、非并发工具形成 barrier** ← `tool_exec.zig:126` 仍是 `for` + `executeOne` 顺序执行
- [x] 2. 结果按原序回填（乱序到达也能对上下标）→ `planBatches` 已固定顺序语义
- [x] 3. 权限链完整：Plan 闸门 → `checkPermissions` → 安全分类 → 规则引擎
- [ ] 4. **工具抢跑**：`tool_call` 参数一完整就派发（不等整轮结束）← 全仓无实现
- [x] 5. 取消三档语义（`BLOCK`/`CANCEL` + 关闭宽限）

## WP-12 · `budget` + `compact`

- [x] 1. 三重换算正确：触发规模 = `锚点wire + max(0, rawEst − 锚点rawEst)`，不是全量重估
- [x] 2. 阈值公式（配了 `compactWindow` 则原值即线；否则 `effectiveCeiling − min(40_000, ceiling×0.25)`）
- [x] 3. ⚠️ `AUTOCOMPACT_BUFFER_TOKENS = 40_000`（不是参考文档说的 13,000）→ `src/engine/budget.zig:18`
- [x] 4. ratio 非对称更新的分母必须是原始估算
- [x] 5. 压缩成功判据 = 最终 provider 上下文确实缩小
- [ ] 6. 🟡 **压缩三层梯度（零成本优先）** → 第 1/2 层 ✅；**第 3 层 LLM 摘要未接线**（`loop.zig:547` 传 `null`）
- [ ] 7. 🟡 大结果落盘 + `<persisted-output>` 占位；`Read` 结果**禁止二次落盘** → 落盘 ✅（`truncate.zig:38`）；二次落盘守卫未核验

## WP-13 · `recovery`

- [x] 1. 错误分类用 error set + 显式分类函数
- [x] 2. 三态 + 6 重试修饰器的决策表
- [ ] 3. ⚠️ 退避参数：**引擎层 cap 32s + 25% jitter** ← 实际 `DEFAULT_BACKOFF_CAP_MS = 30_000`、`DEFAULT_JITTER = 0.0`，且 `:173 _ = DEFAULT_JITTER;`（**定义了却没用**）
- [x] 4. `Retry-After` 优先级：响应头 > 异常携带 > 本地退避
- [x] 5. 注入测试：断网 / 限流 / 超窗 / 畸形工具输入各一条

## WP-14 · `transcript`

- [x] 1. `Entry{uuid,parentUuid,type,sessionId,timestamp,message,metadata}` 逐字段一致
- [x] 2. `parentUuid` 链重建（不靠行序）+ 去环 + `repairMessages` 剔除孤儿 `tool_result`
- [x] 3. `type` 分流正确（`message`/`compact_boundary`/`replay` 参与链；其余跳过）
- [x] 4. 旧文件 round-trip（含幂等性预检）
- [ ] 5. 🟡 **resume / resumeAt / fork / delta 四个操作** → resume ✅（`open` + `latestLeafUuid`）、resumeAt ✅（`messagesAt`）；**`fork` / `delta` 未实现**
- [x] 6. 持久化失败不炸主循环（所有 store 写异常都 warn 吞掉）

# 阶段 3 · 服务与协议

## WP-15 · `cli/` 入口

- [ ] 1. 🟡 **7 个入口** → `--print` + `--output-format stream-json` ✅、`serve` ✅、`acp serve` ✅、`--version` ✅；**`doctor` 与 6 个 `--internal-*` 未实现**（仅注释）
- [x] 2. `--sdk-url` / `--teleport` → `exit 2`（不是"忽略"）→ **实测 `exit=2`**，stderr `error: unsupported flag`。两者以 `--` 开头，走 `args.zig` 的未知 flag 分支后由 `root.zig` 返回 2。（设计原文另要求信息以 `Unsupported` 开头，当前前缀是 `error: ` —— 语义等价，未改。）
- [x] 3. stream-json 必配 `--verbose`；input=stream-json 必配 output=stream-json
- [ ] 4. 6 个 `--internal-*` fast path 在命令解析之前精确匹配 `args[0]`；`--internal-resume-check` exit 1 = 已触发恢复 ← 未实现

## WP-16 · `server/` HTTP + SSE

交付物齐（7 文件 1,571 行），**桌面壳交付契约 7 条**全部通过 `tests/smoke.sh`（12/12）：

- [x] 1. 端口可写 `0` 并由内核回报真实端口，stdout 恰好一行 JSON
- [x] 2. `/health` 免 token，返回 `zigent-ready`
- [x] 3. 一次性 token（除 `/health` 外所有端点都要 token；无 token → 401 且不先写 SSE 头）
- [x] 4. 优雅关闭（`/internal/shutdown` 后进程真的退出）
- [x] 5. `--version` 可用
- [x] 6. 真流式 SSE（首帧 1s 内到达，不被缓冲）
- [x] 7. stdout 只走协议、日志全部走 stderr

## WP-17 · `client_proto/`

- [x] 1. 33 种事件的字段名逐字对齐
- [x] 2. 三个契约保真雷（camelCase 直出 / null 抑制不发通知 / `session/load` 回放先于响应）
- [x] 3. ACP 帧格式是 **NDJSON**（不是 LSP 的 Content-Length）
- [ ] 4. `initialize` 版本协商 ← **`acpServe` 是空函数**（`src/cli/commands.zig:283`，参数全 `_ =`）

# 阶段 4 · 验证

## WP-18 · golden fixtures + 双后端对等

- [ ] 1. **≥6 个场景** × 3 种传输；时间戳/随机 id 用占位符
- [ ] 2. `run-dual.sh {java,zig}` + `diff` 能跑通
- [ ] 3. ⚠️ 新建 transcript golden `.jsonl`（现有 fixture 里没有任何一份）—— 设计标注这是**最该先做的事**

## WP-19 · benchmark 对齐

- [ ] 1. ⚠️ **基线必须在 M0 收尾前采**（`benchmark/` 里当前没有任何基线数字）—— 已错过窗口
- [ ] 2. Zig 版 **≥ 基线**
- [ ] 3. 启动时间 / 峰值 RSS / 二进制体积三项对照表

# 外部团队 / 后续

## WP-20 · TUI

- [ ] ⏸ **外包，不进内核**（只依赖 `06-对外协议.md`）

## WP-21 · Web UI（Tauri + Rust）

- [ ] 1. 对话流渲染
- [ ] 2. 工具卡片
- [ ] 3. 差异（diff）呈现
- [ ] 4. 会话列表（需要 `/api/sessions` 补标题/时间）
- [ ] 5. 权限卡片应答
- [ ] 6. 问答卡片（`ask_user_question` 的 `interaction_request` 通道尚未接）

## WP-22 · 桌面壳

- [ ] 1. sidecar 拉起内核（契约 7 条已就绪，见 WP-16）
- [ ] 2. 端口 0 + 一次性 token 握手
- [ ] 3. macOS dmg 分发 + 签名与公证（需 Apple 开发者账号）
- [ ] 4. 进程组清理（关壳不留孤儿进程）

---

# ⚠️ 已核验的真实缺口

按严重度排序。每条都有代码位置或缺失 grep 作证。

| # | WP | 缺口 | 位置 / 证据 | 严重度 |
|:--:|---|---|---|:--:|
| 1 | WP-03.1 | **真实 provider 从未跑通**：`std.http.Client` 生命周期断言 + 报文形状非法 | `src/llm/http.zig:235` 等 | 🔴 阻塞"可用" |
| 2 | WP-13.3 | 退避 **jitter 定义了却未使用**；cap 30s ≠ 设计要求的 32s | `src/engine/recovery.zig:55-56,173` | 🟠 |
| 3 | WP-12.6 | 压缩**第三层 LLM 摘要未接线** | `src/engine/loop.zig:547` 传 `null` | 🟠 |
| 4 | WP-11.1 / 11.4 | 工具**真并发**与**抢跑**均未实现 | `src/engine/tool_exec.zig:126` | 🟠 |
| 5 | WP-15.1 / 15.4 | `doctor`、6 个 `--internal-*` 未实现（15.2 已实测通过，见下） | `src/cli/args.zig` | 🟡 |
| 6 | WP-14.5 | transcript **`fork` / `delta` 未实现** | `src/engine/transcript.zig` | 🟡 |
| 7 | WP-01.2 | 从未在 **0.17.0-dev** 上跑过测试（验收明确要求两版都过） | — | 🟡 |

**反向发现（代码比设计更严，非缺口）**：危险命令 golden 实际 **67** 条（设计 64）；越界用例实际 **88** 条（设计 23）。

---

# 提交纪律 / Commit discipline

## 分支模型 / Branch model

- **`dev`** —— 所有开发在这里进行，一条目一提交
- **`main`** —— 稳定分支，**只接受来自 `dev` 的合并**；已设保护规则：禁止直接 push、禁止 force push、禁止删除
- 流程：在 `dev` 上提交 → REVIEW → 合并进 `main`

## 提交信息 / Commit messages

遵循[约定式提交 / Conventional Commits](https://www.conventionalcommits.org/zh-hans/)：`<类型>[可选 范围]: <描述>`。

- 类型**小写**；常用：`feat` / `fix` / `refactor` / `perf` / `test` / `docs` / `build` / `ci` / `chore` / `revert` / `style`
- 冒号后**有一个空格**
- 破坏性变更用 `!`（如 `feat!:`），或在脚注写 `BREAKING CHANGE:`
- **正文里写明对应的工作包编号**，便于对照本文件

示例：

```
fix(recovery): 退避接上 25% jitter

WP-13.3。引擎层退避此前 jitter 恒为 0（DEFAULT_JITTER 定义了但未使用），
且 cap 为 30s；设计要求的是引擎层 cap 32s + 25% jitter。
```

## 操作要求 / Rules

1. **一条目 = 一个提交**
2. 只用**显式路径** `git add <文件>`，**禁用 `git add -A`**（避免卷入并行会话的未完成改动）
3. 每个提交后附 `git show --stat` 与验收命令输出，待 review 后再进下一条
4. 每个 WP 结束时停下来等确认
