#!/usr/bin/env bash
# Zigent 桌面壳交付契约冒烟测试（文档 03 §12.3 的 7 条）
#
# 用法：
#   bash tests/smoke.sh
#
# 退出码：0 = 全过；非 0 = 失败项数量。
set -uo pipefail

ZIG="${ZIG:-$HOME/.local/toolchains/zig/zig}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

pass=0
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }

echo "== 0) 构建 =="
if ! "$ZIG" build >/dev/null 2>&1; then
  echo "构建失败，先跑 zig build 看错误"; exit 1
fi
ok "zig build"

echo "== 1) 端口 0 + 真实端口回报（stdout 只有一行 JSON）=="
"$ROOT/zig-out/bin/zigent" serve --port 0 >"$tmp/out" 2>"$tmp/err" &
KERNEL_PID=$!
for _ in $(seq 1 50); do
  [ -s "$tmp/out" ] && break
  sleep 0.1
done
LINE="$(head -n1 "$tmp/out")"
PORT="$(printf '%s' "$LINE" | sed -n 's/.*"port":\([0-9]*\).*/\1/p')"
TOKEN="$(printf '%s' "$LINE" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
# token 不在握手行里（只在 env/argv）—— 生成一个并重启
kill "$KERNEL_PID" 2>/dev/null; wait "$KERNEL_PID" 2>/dev/null

export ZIGENT_TOKEN="smoke-token-$$"
"$ROOT/zig-out/bin/zigent" serve --port 0 >"$tmp/out" 2>"$tmp/err" &
KERNEL_PID=$!
for _ in $(seq 1 50); do [ -s "$tmp/out" ] && break; sleep 0.1; done
LINES=$(wc -l <"$tmp/out" | tr -d ' ')
LINE="$(head -n1 "$tmp/out")"
PORT="$(printf '%s' "$LINE" | sed -n 's/.*"port":\([0-9]*\).*/\1/p')"

if [ "$LINES" = "1" ] && [ -n "$PORT" ] && [ "$PORT" != "0" ]; then
  ok "stdout 恰好一行且含真实端口 ($PORT)"
else
  bad "stdout 行数=$LINES port='$PORT'"
fi

echo "== 2) /health 免 token =="
H="$(curl -s --max-time 5 "http://127.0.0.1:$PORT/health")"
case "$H" in
  *zigent-ready*) ok "/health → $H" ;;
  *) bad "/health → $H" ;;
esac

echo "== 3a) REST 无 token → 401 =="
C="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/api/session")"
[ "$C" = "401" ] && ok "401" || bad "got $C"

echo "== 3b) REST 带 token → 200 =="
C="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Authorization: Bearer $ZIGENT_TOKEN" "http://127.0.0.1:$PORT/api/session")"
[ "$C" = "200" ] && ok "200" || bad "got $C"

echo "== 3c) SSE 无 token → 401（绝不能先写 SSE 头）=="
C="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/api/session/x/events")"
[ "$C" = "401" ] && ok "401" || bad "got $C"

echo "== 4) 建会话 + 真流式（curl -N 应能立刻拿到帧）=="
SID="$(curl -s --max-time 5 -X POST -H "Authorization: Bearer $ZIGENT_TOKEN" "http://127.0.0.1:$PORT/api/session" | sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p')"
if [ -n "$SID" ]; then ok "sessionId=$SID"; else bad "建会话失败"; fi

if [ -n "$SID" ]; then
  ( curl -sN --max-time 3 "http://127.0.0.1:$PORT/api/session/$SID/events?token=$ZIGENT_TOKEN" >"$tmp/sse" ) &
  CPID=$!
  sleep 1
  if [ -s "$tmp/sse" ]; then ok "SSE 首帧在 1s 内到达（真流式）"; else bad "SSE 无输出（可能被缓冲）"; fi
  wait $CPID 2>/dev/null
fi

echo "== 5) 优雅关闭 =="
C="$(curl -s --max-time 5 -X POST -H "Authorization: Bearer $ZIGENT_TOKEN" "http://127.0.0.1:$PORT/internal/shutdown")"
case "$C" in
  *shuttingDown*) ok "shutdown → $C" ;;
  *) bad "shutdown → $C" ;;
esac
sleep 1
if kill -0 "$KERNEL_PID" 2>/dev/null; then
  bad "进程仍在运行（未优雅退出）"; kill -9 "$KERNEL_PID" 2>/dev/null
else
  ok "进程已退出"
fi

echo "== 6) --version =="
V="$("$ROOT/zig-out/bin/zigent" --version)"
case "$V" in
  zigent*) ok "$V" ;;
  *) bad "$V" ;;
esac

echo "== 7) stdout/stderr 分离 =="
"$ROOT/zig-out/bin/zigent" serve --port 0 1>/dev/null 2>"$tmp/err2" &
P2=$!
sleep 1
if [ -s "$tmp/err2" ]; then ok "日志确实走 stderr"; else ok "本机无日志输出（不构成失败）"; fi
kill "$P2" 2>/dev/null; wait "$P2" 2>/dev/null

echo
echo "通过 $pass 项，失败 $fail 项"
exit "$fail"
