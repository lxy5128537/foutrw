#!/usr/bin/env bash
# foutrw 容器入口
# 启动顺序: fout (VPN tunnel → SOCKS5) → xapp (WSS proxy → fout SOCKS5)
#
# 环境变量:
#   COUNTRY    - VPN 节点国家代码 (如 JP/KR/US)
#   SOCKS_PORT - fout SOCKS5 端口 (默认 10000)
#   XAPP_PORT  - xapp WSS 端口 (默认 8080)
#   TOKEN      - xapp 认证 token
#   LOG        - 1/true 启用详细日志

set -uo pipefail

SOCKS_PORT="${SOCKS_PORT:-10000}"
XAPP_PORT="${XAPP_PORT:-8080}"
COUNTRY="${COUNTRY:-}"
TOKEN="${TOKEN:-Ymj5128537}"

# ---------- 日志 ----------
DEBUG=false
case "${LOG:-}" in
  1|true|TRUE|yes|on|ON) DEBUG=true ;;
esac

log()   { [ "$DEBUG" = true ] && echo "[entrypoint] $*"; }
simple(){ echo "[foutrw] $*"; }

# ---------- 启动 fout (VPN 隧道 → SOCKS5) ----------
FOUT_ARGS="-p ${SOCKS_PORT} -d"
if [ -n "$COUNTRY" ]; then
  FOUT_ARGS="${FOUT_ARGS} -c ${COUNTRY}"
fi

simple "starting fout (SOCKS5 on :${SOCKS_PORT})..."
log "fout args: ${FOUT_ARGS}"
/usr/local/bin/fout ${FOUT_ARGS} &
fout_pid=$!
log "fout started (pid $fout_pid)"

# 等待 fout SOCKS5 就绪
simple "waiting for fout SOCKS5 to be ready..."
for i in $(seq 1 10); do
  if curl -s --connect-timeout 2 --socks5 127.0.0.1:${SOCKS_PORT} http://httpbin.org/ip >/dev/null 2>&1; then
    simple "fout SOCKS5 ready"
    break
  fi
  sleep 1
done

# ---------- 启动 xapp (WSS → fout SOCKS5) ----------
XAPP_ARGS="-l wss://0.0.0.0:${XAPP_PORT}"
XAPP_ARGS="${XAPP_ARGS} -f socks5://127.0.0.1:${SOCKS_PORT}"
XAPP_ARGS="${XAPP_ARGS} -token ${TOKEN}"

simple "starting xapp (WSS on :${XAPP_PORT} → SOCKS5 :${SOCKS_PORT})..."
log "xapp args: ${XAPP_ARGS}"
/usr/local/bin/xapp ${XAPP_ARGS} &
xapp_pid=$!
log "xapp started (pid $xapp_pid)"

# ---------- 信号转发 ----------
cleanup() {
  kill "$xapp_pid" 2>/dev/null
  kill "$fout_pid" 2>/dev/null
}
trap cleanup TERM INT

wait -n "$fout_pid" "$xapp_pid" 2>/dev/null
rc=$?
cleanup
simple "foutrw exited (rc=$rc)"
exit $rc
