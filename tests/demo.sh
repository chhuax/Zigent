#!/usr/bin/env bash
# Zigent v1 演示 —— 三个场景，全部零网络、可离线复现。
#
#   bash tests/demo.sh
#
# 场景 1：完整闭环（流式 → tool_call → 权限 → 工具真读文件 → 配对落盘 → 第二轮）
# 场景 2：transcript 的 parentUuid 配对链（磁盘证据）
# 场景 3：本地 HTTP + SSE 服务的 7 个端点
set -uo pipefail

ZIG="${ZIG:-$HOME/.local/toolchains/zig/zig}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

FIXTURE="tests/fixtures/sse/anthropic-tool-call.txt"
BIN="$ROOT/zig-out/bin/zigent"

hr() { printf '\n\033[1m%s\033[0m\n' "────────────────────────────────────────────────────────────"; }

hr
echo "构建（Debug）"
"$ZIG" build >/dev/null 2>&1 && echo "  ✅ zig build 完成" || { echo "  ❌ 构建失败"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
hr
echo "场景 1：完整闭环（--mock-sse 回放录制好的 SSE，零网络）"
echo
echo "  命令："
echo "    zigent --print \"读一下 src/main.zig\" \\"
echo "        --output-format stream-json \\"
echo "        --mock-sse $FIXTURE \\"
echo "        --permission-mode BYPASS_PERMISSIONS"
echo
echo "  原始 stdout（NDJSON，逐行）："
echo

"$BIN" --print "读一下 src/main.zig" \
  --output-format stream-json \
  --mock-sse "$FIXTURE" \
  --permission-mode BYPASS_PERMISSIONS 2>/tmp/zigent-demo.err \
| python3 -c '
import sys, json
for i, line in enumerate(sys.stdin, 1):
    line = line.strip()
    if not line:
        continue
    o = json.loads(line)
    t = o.get("type")
    extra = ""
    if t == "text_delta":        extra = repr(o["text"][:58])
    elif t == "tool_call":       extra = o["tool_name"] + " " + o["input"][:58]
    elif t == "tool_result":     extra = "is_error=%s  %s" % (o["is_error"], repr(o["output"][:52]))
    elif t == "turn_complete":   extra = "output_tokens=%s" % o["usage"]["outputTokens"]
    elif t == "end_turn":        extra = "turn=%s tool_calls=%s" % (o["turn_number"], o["tool_call_count"])
    elif t == "stream_request_start": extra = "system_prompt_tokens=%s" % o["system_prompt_tokens"]
    print("  %2d  %-20s %s" % (i, t, extra))
'
echo
echo "  stderr（应只有 WARN，stdout 保持纯协议）："
sed 's/^/    /' /tmp/zigent-demo.err

# ─────────────────────────────────────────────────────────────────────────────
hr
echo "场景 2：磁盘上的配对不变量（transcript 的 parentUuid 链）"
echo
LATEST="$(ls -t "$HOME"/.zigent/projects/*/transcripts/*.jsonl 2>/dev/null | head -1)"
echo "  文件：${LATEST/#$HOME/~}"
echo
python3 - "$LATEST" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    o = json.loads(line)
    m = o.get("message") or {}
    c = m.get("content")
    kinds = [b.get("type") for b in c] if isinstance(c, list) else c
    print("  %-9s | %-9s | %-26s | parent=%s" % (
        o.get("type"), m.get("role") or "-", kinds, (o.get("parentUuid") or "-")[:8]))
PY
echo
echo "  ↑ 关键：assistant 带 tool_use 的下一条**紧邻**就是 user 带 tool_result ——"
echo "    engine.Turn 让这个违反在结构上不可表示（一次原子写两条）。"

# ─────────────────────────────────────────────────────────────────────────────
hr
echo "场景 3：本地 HTTP + SSE 服务"
echo
export ZIGENT_TOKEN="demo-token-$$"
"$BIN" serve --port 0 --mock-sse "$FIXTURE" >/tmp/zigent-demo.out 2>/tmp/zigent-demo-serve.err &
SERVER=$!
for _ in $(seq 1 50); do [ -s /tmp/zigent-demo.out ] && break; sleep 0.1; done
PORT="$(sed -n 's/.*"port":\([0-9]*\).*/\1/p' /tmp/zigent-demo.out | head -1)"
echo "  握手行（stdout 只有这一行，壳靠它拿端口）："
sed 's/^/    /' /tmp/zigent-demo.out

echo
echo "  GET /health（免 token）      → $(curl -s --max-time 4 "http://127.0.0.1:$PORT/health")"
echo "  GET /api/session 无 token    → HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://127.0.0.1:$PORT/api/session")"
echo "  GET /api/session 带 token    → HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 4 -H "Authorization: Bearer $ZIGENT_TOKEN" "http://127.0.0.1:$PORT/api/session")"

SID="$(curl -s --max-time 4 -X POST -H "Authorization: Bearer $ZIGENT_TOKEN" "http://127.0.0.1:$PORT/api/session" | sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p')"
echo "  POST /api/session            → sessionId=$SID"

curl -sN --max-time 4 "http://127.0.0.1:$PORT/api/session/$SID/events?token=$ZIGENT_TOKEN" >/tmp/zigent-demo.sse 2>&1 &
CURL=$!
sleep 0.4
curl -s --max-time 4 -X POST -H "Authorization: Bearer $ZIGENT_TOKEN" \
  -d '{"prompt":"hello"}' "http://127.0.0.1:$PORT/api/session/$SID/prompt" >/dev/null
sleep 2
wait $CURL 2>/dev/null

echo
echo "  SSE 流（真流式，首帧 <1s 到达）："
python3 -c '
import json
cur=None
for line in open("/tmp/zigent-demo.sse"):
    line=line.rstrip("\n")
    if line.startswith("event: "): cur=line[7:]
    elif line.startswith("data: ") and cur=="message":
        o=json.loads(line[6:]); print("    %-20s" % o.get("type"))
    elif line.startswith("data: ") and cur=="status":
        print("    status               %s" % line[6:])
' | head -12

echo
echo "  POST /internal/shutdown      → $(curl -s --max-time 4 -X POST -H "Authorization: Bearer $ZIGENT_TOKEN" "http://127.0.0.1:$PORT/internal/shutdown")"
sleep 0.6
if kill -0 "$SERVER" 2>/dev/null; then echo "  ❌ 进程仍在（未优雅退出）"; kill -9 "$SERVER" 2>/dev/null; else echo "  ✅ 进程已优雅退出"; fi

hr
echo "演示结束。以上三个场景全部离线可复现：bash tests/demo.sh"
echo
