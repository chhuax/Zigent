> **这是预发布版本（0.x / pre-release）。** 内核可运行，但尚未接通真实模型 provider。
> **This is a pre-release (0.x).** The kernel runs, but no real model provider has been wired up yet.

### 能做什么 / What works

- 内核可运行：`zigent --version`、`zigent serve --port 0`（本地 HTTP + SSE）、`--print` 一次性执行
  *Runnable kernel: version, local HTTP + SSE server, one-shot `--print`.*
- `src/` 12 个模块 · **537 个测试通过** · 交付契约冒烟 **12/12**
  *12 modules, 537 tests green, 12/12 delivery-contract smoke checks.*
- Linux / macOS × x86_64 / aarch64 四平台产物（单机交叉编译）
  *Four platform artifacts, cross-compiled from a single machine.*

### 不能做什么 / What does not work yet

- **从未连过真实 provider。** 不给凭据时自动退回 mock 回放（`--mock-sse`），**不会真的调用模型**。
  要接真实模型需自行在 `~/.zigent/config.json` 填 `providers`（`apiKeyEnv` 优先）。
  ***No real provider has ever been exercised.** Without credentials it falls back to mock SSE replay and does not call a model. Configure `providers` in `~/.zigent/config.json` to use a real one.*
- **Windows 不支持，本版未发布该平台产物。** `src/util/io.zig` 用了 `std.posix.HOST_NAME_MAX`
  与 `std.posix.sigaction`，二者在 Windows 上不存在。
  ***Windows is unsupported and has no artifact here.** The OS boundary uses POSIX-only APIs.*
- **macOS 产物未公证（notarization）**，首次运行会被 Gatekeeper 拦。
  绕过：`xattr -d com.apple.quarantine ./zigent`，或右键 → 打开。
  ***macOS binaries are not notarized.** Gatekeeper will block the first run; strip the quarantine attribute or right-click → Open.*
- 并发工具执行仍是顺序的；压缩第三层的摘要器未接线；ACP 传输的 `acpServe` 仍是空壳。
  *Tool execution is still sequential; the third compaction layer's summarizer is unwired; `acpServe` is a stub.*

### 校验下载 / Verify the download

```bash
sha256sum -c zigent-<版本>-<目标>.tar.xz.sha256
tar -xJf zigent-<版本>-<目标>.tar.xz
./zigent --version
```

---

## 变更 / Changes
