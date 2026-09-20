# M0 Spike — Zigent 内核技术验证

> ⚠️ **这是一次性原型，不是产品代码。** 不要把它接进正式构建，不要基于它做渐进式修改。
> 验证目的达成后应**整体删除**或移出主仓（见文末）。

- **对应文档**：`docs/analysis/2026-09-19-16-M0技术验证计划.md`（执行计划）、`docs/analysis/2026-09-19-02-功能清单与核心优先.md`（核心清单）
- **最主要产出**：`移植雷区.md` —— 代码可以丢，那份契约不能丢
- **本轮范围**：已按 **Web-first** 决策重排 —— 原「E3 终端/TUI 原型」替换为 **「本地 HTTP/SSE 服务 + 桌面壳交付契约」**

---

## 1. 当前状态（重要，别误判）

| 项 | 状态 |
|---|---|
| 纯逻辑层（SSE 解析/写出、tool_call 拼接、握手契约、E1 取消、E4 内存、E5 加密、宽度表） | ✅ **完整实现 + 带 63 个契约测试**（`src/tests.zig` 里的聚合块不计） |
| 网络层（HTTP/SSE 服务） | ⚠️ **结构完整，且已被编译器检查过 —— 但当前在 Zig 0.16 下编译失败**（见下） |
| TUI | ❌ 已移出范围（TUI 不是核心；Web-first） |
| Windows / WSL | ❌ 已延后（只保留接口形状） |

### 1.1 编译状态（2026-09-19 实测，诚实记录）

已在 **Zig 0.16.0（macOS arm64，官方 tarball，SHA-256 校验通过）** 上真实跑过 `zig build test`：

- ✅ `build.zig` / `build.zig.zon` **通过**（fingerprint 已修正为 `0x372ed164c6b171fd`）
- ✅ 模块解析、测试聚合、测试发现 **通过**
- ❌ **编译失败，17 个错误** —— 全部是 **Zig 0.16 的 std 变动**，不是逻辑问题

**已修好的**：`ArrayListUnmanaged(T) = .{}` → `.empty`（11 处）、`Allocator.VTable` 新增 `remap` 字段、`std.crypto.utils.timingSafeEql` → `std.crypto.timing_safe.eql`、`Aes256Gcm.decrypt` 六参数签名、文档注释不能挂 `test`。

**尚未修完的（真实待办）**：

| 文件 | 待修 | 0.16 的新 API |
|---|---|---|
| `e1_io.zig` | `std.Thread.Mutex`/`Condition` 已删除 | `std.Io.Mutex` / `std.Io.Condition`，且 `lock(io)` / `wait(io, m)` 都要 **`io` 实例** |
| `handshake.zig` | `std.crypto.random` 已删除 | `io.random(buf)` |
| `e5_crypto.zig` | `std.posix.getenv` 已删除 | 改用 `src/e5_vector.zig` 向量文件（已改好） |
| `http_server.zig` | `std.posix.socket/bind/accept/read/write` 已迁移 | `std.Io.net.IpAddress.listen(&addr, io, .{})` → `Server` |
| `main.zig` | 依赖 `http_server` 的 VERSION | 建议抽 `src/version.zig` |

> **这本身就是 E1/E3 最重要的产出**：`std.Io` 吸收 IO/并发/随机/时间/网络已是既成事实，**架构必须按它设计**（详见 `docs/analysis/2026-09-19-11-stdIo贯穿方案.md`）。
> `0.17.0-dev.2163` 已下载并校验，`std.Io.Mutex` 在其中同样存在 → **改造已落地，不是过渡态**。

**作者环境没有 Zig 时写的这份代码，逻辑层是按契约写好的、且已带测试**；装上 Zig 后按 §4 的指引继续修完剩余 5 处即可跑通。

---

## 2. 怎么跑

```bash
# 0) 装 Zig 并锁定版本（pre-1.0，每版都有破坏性变更，必须锁）
zig version

# 1) 先跑纯逻辑测试 —— 不需要网络，这一步最有价值
zig build test

# 2) E1 数据竞争探针（需要编译器支持 -fsanitize-thread）
zig build test-tsan

# 3) E3：起本地 HTTP/SSE 服务（主命令）
zig build run -- serve
#    stdout 会输出一行（壳解析它拿端口）：
#    {"event":"listening","port":54321,"pid":1234,"version":"0.1.0-spike"}
#    日志全部走 stderr

# 4) 探针
zig build run -- e1
zig build run -- e4
zig build run -- e5

# 5) 契约 #5
zig build run -- --version
```

---

## 3. E3 验收清单（桌面壳交付契约，8 项）

服务起好后（假设端口是 `PORT`、token 是 `TOKEN`）：

| # | 契约 | 命令 | 期望 |
|:--:|---|---|---|
| 1 | **端口 0 + 回报** | `zig build run -- serve` | stdout **只有一行** JSON，含 `"port":<真实端口>`；日志全在 stderr |
| 2 | **`/health` 免 token** | `curl -s localhost:PORT/health` | `{"status":"zigent-ready","version":"..."}` |
| 3a | **REST 要 token** | `curl -s -o /dev/null -w '%{http_code}' localhost:PORT/api/session` | `401` |
| 3b | **带 token 通过** | `curl -s -H "Authorization: Bearer TOKEN" localhost:PORT/api/session` | `200` + sessionId |
| 3c | **SSE 也要 token** | `curl -s -o /dev/null -w '%{http_code}' 'localhost:PORT/api/events'` | `401` |
| 4 | **优雅关闭** | `curl -s -X POST -H "Authorization: Bearer TOKEN" localhost:PORT/internal/shutdown` | `{"shuttingDown":true}`，进程退出码 0 |
| 5 | **`--version`** | `zig build run -- --version` | 输出含版本号 |
| 6 | **不留孤儿**（**必须真机验证**） | 见 §3.1 | 父进程 `kill -9` 后子进程自行退出 |
| 7 | **stdout/stderr 分离** | `zig build run -- serve 1>/dev/null` | 日志照常可见（说明没混进 stdout） |

### 3.1 第 5 项（真流式）才是核心判据 —— 不是上面表格里的 4 号

```bash
# 关键：-N 关闭 curl 自己的缓冲。若事件是"连接关闭后一次性出现"，
# 说明链路上有缓冲 —— 这是 Web-first 的**实质性障碍**，必须在 D4 前给出结论。
time curl -N "localhost:PORT/api/events?token=TOKEN"
```

**期望**：每 ~200ms 出现一条 `data:`，**不是**最后一次性全出现。同时应能看到一条 `: ping` 注释帧且客户端解析不受影响。

### 3.2 第 6 项：孤儿进程验证（最容易被跳过，但事故率最高）

```bash
# 终端 A
zig build run -- serve
# 记下 stdout 里的 pid

# 终端 B：模拟"桌面壳崩溃"
kill -9 <shell_pid>          # 若有壳
# 或直接杀父进程：
kill -9 $PPID

# 期望：内核进程随后自行退出（不能变成孤儿一直挂着）
ps -p <kernel_pid>           # 应为空
```

**设计点**（`handshake.zig` 已留好）：Linux 用 `prctl(PR_SET_PDEATHSIG, SIGTERM)`；macOS 无等价物，需轮询 `getppid() == 1`。**这个结论要写进 SPIKE-E3。**

---

## 4. 编译失败时的适配指引（按优先级）

Zig 0.15→0.16→0.17 连续有大改动（`std.Io`/"Writergate" 的 Writer 参数化、0.17 的 build system 重写）。如果编译报错，按这个顺序处理：

1. **`build.zig` 的 `root_module`**
   - 若报 `no field named 'root_module'` → 切到注释里的旧写法（`root_source_file`/`target`/`optimize` 平铺）。
2. **`std.posix.*`（`http_server.zig`）**
   - `socket` / `bind` / `listen` / `accept` / `getsockname` 的参数顺序或类型（如 `socklen_t`、`flags: u32`）。
   - 若 `std.posix` 变动过大 → **退路是链接 C 库（civetweb/llhttp）**，但要在结论里注明「引入 C 依赖会影响交叉编译与静态链接」。
3. **`std.crypto.*`（`e5_crypto.zig`）**
   - `pbkdf2` 的参数顺序、`Aes256Gcm.encrypt/decrypt` 的返回值语义（GCM 是**就地**加解密）。
4. **`std.mem.Allocator.VTable`（`e4_memory.zig`）**
   - `alloc` 的 `Alignment` 类型（0.14 起从 `u8`/`u5` 改成了 `std.mem.Alignment`）。
5. **`std.atomic.Value` / `std.Thread`（`e1_io.zig`）** —— 这两个长期稳定，基本不用动。

> **刻意规避的选择**（这些是设计决策，不是妥协）：
> - **不用 `std.json`** —— SSE/tool_call 都是手写解析与拼接（也正是本方案里的设计意图）；
> - **不用 `std.Io.Writer`** —— 全部用固定 buffer + 手写 `Sink`，绕开 Writer 参数化churn；
> - **不用 `std.http.Server`** —— 手写 HTTP/1.1 子集（约 250 行），因为**第三方 HTTP 层的最大风险正是"它替你决定缓冲"，而 SSE 最怕缓冲**。

---

## 5. 文件地图

| 文件 | 内容 | 可验证性 |
|---|---|---|
| `移植雷区.md` | **← 最有价值的一份**。本设计必须逐字对齐的 11 类「雷」，每条给出违反后果 | — |
| `src/sse.zig` | SSE **读入侧**状态机（空行提交/多行拼接/EOF flush/CRLF/注释/恰好一个空格） | ✅ 8 测试 |
| `src/sse_writer.zig` | SSE **写出侧**（多行拆行、注释心跳、`Content-Length` 必须缺席、401 不泄漏）+ **读写对称测试** | ✅ 10 测试 |
| `src/toolcalls.zig` | 三家 provider 的 tool_call 增量拼接（OpenAI 按 index / Anthropic 按 content_block / Responses 按 item_id；空参数补 `{}`；id 非空才覆盖） | ✅ 9 测试 |
| `src/handshake.zig` | 桌面壳交付契约：端口回报、健康标记、token（生成/常量时间比较/header+query 提取）、孤儿策略 | ✅ 7 测试 |
| `src/http_server.zig` | **E3 主体**：手写 HTTP/1.1 + 路由 + SSE 真流式 + 优雅关闭 | ⚠️ 未编译（无测试） |
| `src/e1_io.zig` | E1：`CancellationToken` + `EventQueue`（close 必须 broadcast 唤醒消费者） | ✅ 5 测试 |
| `src/e4_memory.zig` | E4：计数分配器 + 策略 A（全 arena 整体重建）vs 策略 C（per-turn arena）+ 200 轮模拟（含"不压缩会线性增长"的对照） | ✅ 7 测试 |
| `src/e5_crypto.zig` | E5：`enc:1:` 的 PBKDF2(120k)/AES-256-GCM/16B 硬编码 SALT + 双向兼容钩子 + RFC 已知向量 | ✅ 8 测试 |
| `src/width.zig` | 显示宽度（EAW/emoji/ZWJ/国旗）。**本期非核心**，保留作将来 CLI `--print` 渲染参考 | ✅ 9 测试 |
| `src/main.zig` / `src/tests.zig` | 入口与测试聚合 | — |

**合计 63 个契约测试**（8+10+9+7+5+7+8+9；`src/tests.zig` 的聚合块不计）。全部不需要网络、不需要真实 provider，可在 CI 跑。

---

## 6. E5 密码学兼容：跑之前必须做的一步

`src/e5_crypto.zig` 里有两个**占位常量**（示意如下），必须替换成真实值，否则一定解不开：

```zig
pub const APP_SECRET_PLACEHOLDER = "REPLACE_WITH_APP_SECRET";
pub const SALT_PLACEHOLDER = [_]u8{0} ** SALT_LEN; // 硬编码的 16 字节常量
```

然后生成一条真实向量：

```bash
export SPIKE_ENC1_VECTOR='<home>|<hostname>|<enc:1:...>|sk-test'
zig build test    # 有向量就跑真实兼容断言；没有则自动跳过
```

> 用 `|` 而不是 `:` 分隔，因为 `enc:1:` 本身自带冒号。

> **`enc:1:` 解不开 = 所有存量用户的 provider 密钥失效。** 这是整个设计里唯一「无法重新设计、只能逐字复刻」的部分。

---

## 7. 验证完成后怎么处置

1. 把 5 个实验的结论写进 `SPIKE-GONOGO.md`（模板见执行计划 §5）；
2. 把新发现的契约追加进 `移植雷区.md`（**这份要带走**）；
3. **删除本目录**（或整体移到 `~/zigent-zig-spike/`）—— 不要让一次性原型留在主仓；
4. 若结论是 Go → 开正式 spec：`docs/superpowers/specs/` + 每阶段 plan。
