#!/usr/bin/env bash
# foutrw 容器入口
# 启动顺序: fout (VPN tunnel → SOCKS5) → xapp (WSS proxy → fout SOCKS5)
#
# 环境变量:
#   COUNTRY    - VPN 节点国家代码 (如 JP/KR/US，空=不限)
#   SOCKS_PORT - fout SOCKS5 端口 (默认 10000)
#   XAPP_PORT  - xapp WSS 端口 (默认 8080，Railway 注入 $PORT)
#   TOKEN      - xapp 认证 token (默认 Ymj5128537)
#   LOG        - 1/true 启用详细日志

set -uo pipefail

SOCKS_PORT="${SOCKS_PORT:-10000}"
XAPP_PORT="${XAPP_PORT:-${PORT:-8080}}"
COUNTRY="${COUNTRY:-}"
TOKEN="${TOKEN:-Ymj5128537}"

# 日志
DEBUG=false
case "${LOG:-}" in
  1|true|TRUE|yes|on|ON) DEBUG=true ;;
esac
log()   { [ "$DEBUG" = true ] && echo "[entrypoint] $*"; }
simple(){ echo "[foutrw] $*"; }

# ---------- 启动 fout (VPN 隧道 → SOCKS5) ----------
# -nat: 容器模式，openvpn 直接在容器 netns 内运行（不需要 --privileged）
# -d:  daemon 模式（不监控父进程）
FOUT_ARGS="-nat -p ${SOCKS_PORT} -d"
if [ -n "$COUNTRY" ]; then
  FOUT_ARGS="${FOUT_ARGS} -c ${COUNTRY}"
fi

simple "starting fout (SOCKS5 :${SOCKS_PORT}, country=${COUNTRY:-all})..."
log "fout args: ${FOUT_ARGS}"
/usr/local/bin/fout ${FOUT_ARGS} &
fout_pid=$!
log "fout started (pid $fout_pid)"

# 等待 VPN 隧道建立（最多 120 秒）
simple "waiting for VPN tunnel..."
tunnel_ok=false
for i in $(seq 1 60); do
  sleep 2
  if curl -s --connect-timeout 3 --socks5 127.0.0.1:${SOCKS_PORT} http://ip.sb >/dev/null 2>&1; then
    exit_ip=$(curl -s --max-time 5 --socks5 127.0.0.1:${SOCKS_PORT} http://ip.sb 2>/dev/null || echo "unknown")
    simple "VPN tunnel ready! exit IP: ${exit_ip}"
    tunnel_ok=true
    break
  fi
  log "  waiting... ($((i*2))s)"
done
if [ "$tunnel_ok" = false ]; then
  simple "WARNING: VPN tunnel timeout, xapp will use direct connection"
fi

# ---------- 启动 xapp (WSS → fout SOCKS5) ----------
XAPP_ARGS="-l wss://0.0.0.0:${XAPP_PORT}"
XAPP_ARGS="${XAPP_ARGS} -f socks5://127.0.0.1:${SOCKS_PORT}"
XAPP_ARGS="${XAPP_ARGS} -token ${TOKEN}"

simple "starting xapp (WSS :${XAPP_PORT} → SOCKS5 :${SOCKS_PORT})..."
log "xapp args: ${XAPP_ARGS}"
/usr/local/bin/xapp ${XAPP_ARGS} &
xapp_pid=$!
log "xapp started (pid $xapp_pid)"

simple "=== foutrw ready ==="
simple "  WSS:  :${XAPP_PORT}"
simple "  SOCKS: :${SOCKS_PORT}"

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
