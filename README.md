# Zigent

[![CI](https://github.com/chhuax/Zigent/actions/workflows/ci.yml/badge.svg)](https://github.com/chhuax/Zigent/actions/workflows/ci.yml)

**用 Zig 从零实现的编码 Agent 内核** —— 对标 Claude Code：读写代码、执行命令、跨轮次保持上下文，并把过程实时流式吐给客户端。

**A coding-agent kernel built from scratch in Zig** — in the spirit of Claude Code: it reads and writes code, runs commands, keeps context across turns, and streams everything to the client in real time.

> **本仓库只做内核。** 设计文档（`docs/`）为本机专属，**不随仓库发布**，因此下文不含指向它们的链接。
> **This repository is the kernel only.** The design documents (`docs/`) live on the author's machine and are **not published with this repository**; no links to them appear below.

**AI Agent 请先读 [`AGENTS.md`](AGENTS.md)** —— 背景、已定决策、禁区、阅读顺序都在那里。
***AI agents: read [`AGENTS.md`](AGENTS.md) first** — background, settled decisions, no-go zones, reading order.*

---

## 状态 / Status

| 项 / Item | 状态 / Status |
|---|---|
| 内核实现 / Kernel | ✅ `src/` 12 个模块可编译 · **537 个测试全绿** · *12 modules compile · 537 tests green* |
| 端到端冒烟 / E2E smoke | ✅ **12/12**（`bash tests/smoke.sh`）|
| 架构约束检查 / Architecture guard | ✅ `zig build guard` |
| spike 契约测试 / Spike contract tests | ✅ **63 个**（`spike/zig-m0/`）· *63 tests* |
| 真实 provider / Real provider | ⏳ 未接；无凭据时自动退回 mock · *Not wired; falls back to mock without credentials* |
| 桌面壳 / Desktop shell | ⏳ 未做（计划 Tauri + Rust）· *Not started (planned: Tauri + Rust)* |

## 这是什么 / What this is

- **一个内核，不是平台。** 提供 `common/` 契约层、主循环、工具、权限、记忆、压缩、恢复、transcript，以及一个本地 HTTP + SSE 服务。
  *A kernel, not a platform: contract layer, main loop, tools, permissions, memory, compaction, recovery, transcript, plus a local HTTP + SSE server.*
- **8 个工具**：`Read` / `Write` / `Edit` / `Bash` / `Glob` / `Grep` / `TodoWrite` / `ask_user_question`。
  *Eight tools — `Read`, `Write`, `Edit`, `Bash`, `Glob`, `Grep`, `TodoWrite`, `ask_user_question`.*
- **`Turn` 配对不变量**：`tool_use` 与 `tool_result` 必须紧邻配对，由类型承载而非靠约定。
  *A `Turn` pairing invariant: every `tool_use` is paired with its `tool_result` by construction, not by convention.*
- **只依赖商用友好许可**（Apache / MIT / BSD / EPL）。
  *Commercial-friendly dependencies only (Apache / MIT / BSD / EPL).*

**不在范围内 / Out of scope**：平台外围（前端、kanban、企业认证、编译期反射元数据）、TUI、Windows / WSL、外部数据库。
*Out of scope: platform periphery (frontend, kanban, enterprise auth, compile-time reflection metadata), TUI, Windows / WSL, external databases.*

## 前置 / Prerequisites

**Zig 0.16.0**（开发基线；`build.zig.zon` 里锁了 `minimum_zig_version`）。
*Zig 0.16.0 — the pinned development baseline; see `minimum_zig_version` in `build.zig.zon`.*

## 快速开始 / Quick start

```bash
# 构建 / Build → zig-out/bin/zigent
zig build

# 测试 / Tests（12 个模块，537 个用例 / 12 modules, 537 cases）
zig build test

# 架构约束检查：std.posix 隔离、common/ 纯逻辑
# Architecture guard: std.posix isolation, common/ purity
zig build guard

# 版本 / Version
zig build run -- --version        # zigent 0.1.0 (protocol 1)
```

### 本地服务 / Local server

```bash
zig build run -- serve --port 0
# stdout 第一行 = 真实端口（桌面壳握手契约）
# First stdout line = the real port (desktop-shell handshake contract)
# {"event":"listening","port":61806,"pid":0,"version":"0.1.0"}
```

`/health` 免 token（返回 `zigent-ready`）；其余端点需要 token，取自 `ZIGENT_TOKEN`，未设置则自动生成。日志全部走 stderr，stdout 只走协议。
*`/health` needs no token (returns `zigent-ready`); every other endpoint requires one, read from `ZIGENT_TOKEN` and generated if unset. Logs go to stderr; stdout carries protocol only.*

### 零网络跑通完整闭环 / Full closed loop, zero network

回放一段录制好的 SSE，走完「流式 → tool_call → 权限 → 工具执行 → 配对落盘 → 第二轮」：
*Replays a recorded SSE stream through the whole path — streaming → tool_call → permission → tool execution → paired persistence → second turn:*

```bash
zig build run -- --print "读一下 src/main.zig" --output-format stream-json \
    --mock-sse tests/fixtures/sse/anthropic-tool-call.txt \
    --permission-mode BYPASS_PERMISSIONS
```

### 冒烟与演示 / Smoke and demo

```bash
bash tests/smoke.sh    # 交付契约 12 项 / 12 delivery-contract checks
bash tests/demo.sh     # 三个离线场景 / three offline scenarios
```

> 两个脚本默认用 `ZIG` 环境变量定位 Zig，可这样覆盖 / Both scripts locate Zig via `$ZIG`, overridable:
> `ZIG=/path/to/zig bash tests/smoke.sh`

## 配置 / Configuration

```bash
# 配置目录（默认 ~/.zigent）/ Config dir (default ~/.zigent)
ZIGENT_HOME=/custom/path
# 主配置文件 / Main config file
ZIGENT_CONFIG=/custom/path/config.json
# 提供方与凭据 / Provider and credentials
ZIGENT_PROVIDER=anthropic  ZIGENT_MODEL=...  ZIGENT_TOKEN=...
```

`~/.zigent/config.json` 里填 `providers`（`apiKeyEnv` 优先）。无凭据时自动退回 mock。
*Put `providers` in `~/.zigent/config.json` (`apiKeyEnv` takes precedence). Without credentials it falls back to mock.*

## 目录结构 / Layout

```
AGENTS.md          Agent 入场须知（背景 / 决策 / 禁区）/ Agent onboarding notes
README.md          本文件 / this file
LICENSE NOTICE     Apache-2.0 / license and attribution
build.zig          构建图：依赖方向在此强制，越界即编译失败
                   build graph: dependency direction is enforced here; violations fail the build
build.zig.zon      包清单（SPDX 许可 / Zig 版本）/ package manifest
src/               内核 12 个模块 / the 12 kernel modules
spike/zig-m0/      M0 技术验证 spike + 63 个契约测试 / M0 spike with 63 contract tests
tests/             smoke.sh · demo.sh · fixtures（SSE 回放）/ fixtures (SSE replay)
```

## 架构 / Architecture

分层依赖只向下，越界由 `build.zig` 直接编译失败：
*Layers depend downward only; violations fail compilation in `build.zig`:*

```
cli → {server, client_proto} → engine → {llm, tools, perm, memory, config} → common → util
```

| 模块 / Module | 文件 / Files | 行数 / Lines | 职责 / Responsibility |
|---|---:|---:|---|
| `common/` | 10 | 3,623 | L0 契约层：`Message` / `ContentBlock`(4) / `StreamEvent`(33) / `Tool` / `Schema` / `perm`<br>*L0 contract layer* |
| `util/` | 6 | 1,251 | L0′ 基座，**唯一的 OS 边界** / *the only OS boundary: io / proc / fsio / log / watch* |
| `config/` | 6 | 3,171 | 路径唯一出口 + 5 层 settings + `enc:1:` 兼容<br>*single path authority, layered settings, `enc:1:` compatibility* |
| `llm/` | 7 | 5,000 | SSE 读入 / 三家 tool_call 拼接 / Anthropic + OpenAI wire / 重试闸门<br>*SSE reader, tool-call assembly, both wire formats, retry gate* |
| `perm/` | 9 | 3,733 | 四级防御 + 22 条危险命令 + 两级授权缓存<br>*four defence layers, dangerous-command rules, two-level approval cache* |
| `tools/` | 14 | 4,116 | 8 个工具，`Spec` 单一真源<br>*eight tools, one source of truth for each spec* |
| `memory/` | 6 | 2,864 | 记忆热核 + 注入防护 + 归档检索 + `AGENTS.md` + `@include` 围栏<br>*memory hot core, injection guards, archive search, `AGENTS.md`* |
| `engine/` | 12 | 3,614 | **`Turn` 配对不变量** + 拉式主循环 + 三层压缩 + 恢复三态 + transcript<br>*pairing invariant, pull-based loop, compaction, recovery, transcript* |
| `server/` | 7 | 1,571 | 手写 HTTP/1.1 + 真流式 SSE + 一次性 token<br>*hand-rolled HTTP/1.1, real streaming SSE, one-shot token* |
| `client_proto/` | 3 | 526 | stream-json NDJSON + ACP（回放先于响应）<br>*stream-json NDJSON and ACP* |
| `cli/` | 5 | 1,146 | 入口、argv、`Rt` 组装（**唯一构造点**）<br>*entry point, argv, the single `Rt` construction site* |
| `ext/` | 4 | 253 | 子代理 / Skills / MCP 的**契约形状**（首期不执行）<br>*contract shapes for subagents / skills / MCP (not executed yet)* |

合计 / Total: **`src/` 90 个 `.zig` / 30,881 行**；全仓 / whole repo **104 个 `.zig` / 34,095 行**。

## 实测指标 / Measured metrics

ReleaseSafe, macOS arm64：

| 指标 / Metric | 实测 / Measured | 目标 / Target |
|---|---|---|
| 二进制体积 / Binary size | **1.8 MB** | 5–15 MB |
| 启动时间 / Startup | **2.20 ms**（含进程创建开销 / incl. process spawn）| < 10 ms |
| 峰值 RSS / Peak RSS (`--version`) | **1.9 MB** | — |
| 测试 / Tests | **537**（12 个模块 / 12 modules）| — |

## 下一步 / Roadmap

1. **接真实 provider** / *Wire a real provider* —— 在 `~/.zigent/config.json` 填 `providers`，即可 `--print` 实跑。
2. **golden fixture** —— 同一场景三种传输语义等价 + 双后端对等。
   *Semantic equivalence across three transports and parity between both backends.*
3. **真并发工具执行** —— 分批规划已实现（`engine/tool_exec.planBatches`），执行仍顺序。
   *Real concurrent tool execution — batching is planned, execution is still sequential.*
4. **压缩第三层的摘要器接线** —— `compactTurns` 已支持 `Summarizer`，目前传 `null`。
   *Wire the summarizer into the third compaction layer.*
5. **ACP 传输补全** —— 编解码与顺序契约已就绪，`cli/commands.zig` 的 `acpServe` 仍是空壳。
   *Complete the ACP transport; `acpServe` is still a stub.*

## 许可 / License

Apache License 2.0 —— 全文见 [`LICENSE`](LICENSE)，版权与商标归属见 [`NOTICE`](NOTICE)。
*Apache License 2.0 — see [`LICENSE`](LICENSE) for the full text and [`NOTICE`](NOTICE) for copyright and trademark attribution.*

"Zig" 是 Zig Software Foundation 的商标；本项目为独立作品，与 Zig Software Foundation 无隶属、背书或赞助关系。
*"Zig" is a trademark of the Zig Software Foundation. This project is an independent work and is not affiliated with, endorsed by, or sponsored by the Zig Software Foundation.*
