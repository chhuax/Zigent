# Zigent

Zigent 是一个智能编码 Agent（对标 Claude Code），用 **Zig 从零实现**。

> **本仓库自包含**：设计文档、契约、工作包、spike 骨架都在这里，**不依赖任何其它仓库**。
> 设计前做过一轮逐文件的工程盘点（主代码 26.8 万行 + 测试 31.5 万行量级），结论沉淀在 `docs/analysis/` 与 `AGENTS.md`。

---

## 🤖 如果你是 AI Agent

**先读 [`AGENTS.md`](AGENTS.md)** —— 它给你背景、已定决策、禁区、阅读顺序、路径约定与下一步。
（很多 Agent 运行时会自动加载仓库根的 `AGENTS.md`；若没有，请手动读。）

## 👤 如果你是人

**入口文档 → [`docs/analysis/2026-09-19-00-入口文档.md`](docs/analysis/2026-09-19-00-入口文档.md)**

它包含：
- 按角色的阅读路径（决策者 3 份 / 写内核 8 份 / 写前端 2 份 / 测试 3 份 / 学架构完整路径）
- 整体架构一页图
- **AI / Agent 概念详解**（15 节：ReAct、工具调用、配对不变量、上下文工程、thinking、记忆、检索、多 Agent、MCP/ACP/LSP…）
- 全文档索引 + 关键数字速查 + 已定决策 + 术语表 + FAQ

---

## ⚠️ 路径约定（最容易踩的坑）

**本仓库文档里所有相对路径，都相对本仓库根目录。**

| 你看到的写法 | 实际位置 |
|---|---|
| `docs/analysis/…` | 本仓库 `docs/analysis/…` |
| `spike/zig-m0/src/sse.zig` | 本仓库 `spike/zig-m0/src/sse.zig` |
| `docs/web/` | 本仓库 `docs/web/` |

**判别**：以 `spike/` / `docs/` / `src/` 开头 → 本仓库内文件。

---

## 目录结构

```
AGENTS.md ★ Agent 入场须知（背景/决策/禁区/路径约定）
README.md 本文件
docs/analysis/
 2026-09-19-00-入口文档.md ★ 唯一入口（含 AI 概念详解）
 2026-09-19-01-总体方案与并行开发.md
 2026-09-19-02-功能清单与核心优先.md
 2026-09-19-03-架构详解.md 逐模块 + 10 条 ADR
 2026-09-19-04-核心数据模型设计.md ★ L0 契约层（含 Turn 配对不变量）
 2026-09-19-05-工具契约设计.md
 2026-09-19-06-对外协议.md ★ TUI/Web 团队的契约
 2026-09-19-07-权限与安全设计.md
 2026-09-19-08-上下文与压缩设计.md
 2026-09-19-09-错误与恢复设计.md
 2026-09-19-10-配置与落盘布局.md
 2026-09-19-11-stdIo贯穿方案.md
 2026-09-19-12-测试与验收设计.md
 2026-09-19-13-持久化格式设计.md
 2026-09-19-14-CLI与命令清单.md
 2026-09-19-15-协议边界与TUI交接.md
 2026-09-19-16-M0技术验证计划.md
 2026-09-19-17-主设计方案.md
 2026-09-19-18-工作包清单.md ★ 可执行任务分解（WP-00 ~ WP-22）
spike/zig-m0/
 README.md spike 使用说明 + 8 项验收命令移植雷区.md ★ 移植必须避开的 11 类坑 + 不可信旧文档清单
 src/*.zig 63 个契约测试
```

---

## 当前状态

| 项 | 状态 |
|---|---|
| 设计文档 | ✅ 19 份 / 约 17,700 行 / 32 张 Mermaid 图 + 21 张手绘真图 |
| 工作包 | ✅ 23 个（WP-00 ~ WP-22），含背景/输入/交付物/可执行验收 |
| spike 契约测试 | ✅ 63 个（纯逻辑层完整；0.16 的 5 处 `std.Io` 适配已在新实现中一次性做对） |
| **v1 内核实现** | ✅ **`src/` 全 12 个模块可编译、527 个测试全绿、端到端冒烟 12/12** |

### v1 实现速览

```
$ zig build test          # 527 tests passed（25/25 steps）
$ zig build guard         # 架构约束检查：std.posix 隔离 / common 纯逻辑
$ zig build run -- --version
$ zig build run -- --print "读一下 src/main.zig" --output-format stream-json
$ zig build run -- serve --port 0        # stdout 第一行 = 真实端口（桌面壳握手）
$ bash tests/smoke.sh                    # 交付契约 12 项冒烟

# 浏览器打开 UI（设计产物放 web/，内核同源发出 → 不需要 CORS）
$ zig build run -- serve --port 0        # 然后打开 http://127.0.0.1:<port>/

# 零网络跑通完整闭环（流式 → tool_call → 权限 → 工具执行 → 配对落盘 → 第二轮）
$ zig build run -- --print "读一下 src/main.zig" --output-format stream-json \
    --mock-sse tests/fixtures/sse/anthropic-tool-call.txt \
    --permission-mode BYPASS_PERMISSIONS
```

| 指标 | 实测（ReleaseSafe, macOS arm64） |
|---|---|
| 二进制体积 | **1.8 MB**（目标 5–15 MB） |
| 启动时间 | **< 2 ms**（目标 < 10 ms） |
| 峰值 RSS（`--version`） | ~2 MB |
| 代码量 | 87 个 `.zig` / 约 30,000 行 / 527 个测试 |

模块分层（依赖只向下，`build.zig` 强制）：

```
cli → {server, client_proto} → engine → {llm, tools, perm, memory, config} → common → util
```

| 模块 | 行数 | 职责 |
|---|---:|---|
| `common/` | 3,623 | L0 契约层：`Message` / `ContentBlock`(4) / `StreamEvent`(33) / `Tool` / `Schema` / `perm` |
| `util/` | 1,191 | L0′ 基座：**唯一的 OS 边界**（io / proc / fsio / log / watch） |
| `config/` | 3,171 | 路径唯一出口 + 5 层 settings + `enc:1:` 兼容 |
| `llm/` | 5,000 | SSE 读入 / 三家 tool_call 拼接 / Anthropic + OpenAI wire / 重试闸门 |
| `perm/` | 3,733 | 四级防御 + 22 条危险命令 + 两级授权缓存（**刻意不合并**） |
| `tools/` | 4,116 | 8 个工具，`Spec` 单一真源（模型 schema 与校验器同源） |
| `memory/` | 2,864 | 记忆热核 + 注入防护（13 条规则）+ 归档检索 + `AGENTS.md` + `@include` 围栏 |
| `engine/` | 3,610 | **`Turn` 配对不变量** + 拉式主循环 + 三层压缩 + 恢复三态 + transcript |
| `server/` | 1,345 | 手写 HTTP/1.1 + 真流式 SSE + 一次性 token |
| `client_proto/` | 526 | stream-json NDJSON + ACP（回放先于响应） |
| `cli/` | 568 | 入口、argv、`Rt` 组装（**唯一构造点**） |
| `ext/` | 253 | 子代理 / Skills / MCP 的**契约形状**（首期不执行） |

> 并行实现的接口真源：`docs/internal/INTERFACES-v1.md`（含冻结后的 10 条变更记录）。
> Zig 0.16 的实测坑（含 HTTP 读缓冲死锁、`currentPathAlloc` 释放尺寸不匹配等）见
> `spike/zig-m0/移植雷区.md` §N。

## 下一步

1. **接真实 provider 跑通**：`~/.zigent/config.json` 填 `providers`（`apiKeyEnv` 优先），
   `zig build run -- --print "..." --output-format stream-json` 即可；当前无凭据时自动退回 mock。
2. **golden fixture**（`tests/fixtures/`）：同一场景三传输语义等价 + 双后端对等（文档 06 §7）。
3. **真并发工具执行**：分批规划已实现（`engine/tool_exec.planBatches`），执行仍是顺序的。
4. **压缩第三层的摘要器接线**：`compactTurns` 已支持 `Summarizer`，`engine` 目前传 `null`。
5. **ACP 传输补全**：`client_proto/acp.zig` 的编解码与顺序契约已就绪，`cli/commands.zig`
   的 `acpServe` 仍是空壳。

---

## 许可

本项目采用 **Apache License 2.0**（全文见 [`LICENSE`](LICENSE)，版权与归属见 [`NOTICE`](NOTICE)）。

```
Copyright 2026 huaxin

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
