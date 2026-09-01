#!/usr/bin/env bash
# foutrw 容器入口
# 优先: fout VPN 隧道 + xapp WSS
# 降级: 仅 xapp (无 TUN 时自动跳过 VPN)

set -uo pipefail

SOCKS_PORT="${SOCKS_PORT:-10000}"
XAPP_PORT="${XAPP_PORT:-${PORT:-8080}}"
COUNTRY="${COUNTRY:-}"
TOKEN="${TOKEN:-Ymj5128537}"

simple(){ echo "[foutrw] $*"; }

# 检查 TUN 设备
HAS_TUN=false
if [ -e /dev/net/tun ]; then
  if [ -w /dev/net/tun ]; then
    HAS_TUN=true
    simple "/dev/net/tun 可用"
  else
    simple "/dev/net/tun 存在但不可写"
  fi
else
  simple "/dev/net/tun 不存在，跳过 VPN 隧道"
fi

# ---------- 启动 fout (仅 TUN 可用时) ----------
fout_pid=""
if [ "$HAS_TUN" = true ]; then
  FOUT_ARGS="-nat -p ${SOCKS_PORT} -d"
  [ -n "$COUNTRY" ] && FOUT_ARGS="${FOUT_ARGS} -c ${COUNTRY}"

  simple "starting fout (SOCKS5 :${SOCKS_PORT})..."
  /usr/local/bin/fout ${FOUT_ARGS} &
  fout_pid=$!

  # 等待隧道建立（最多 90 秒）
  simple "waiting for VPN tunnel..."
  for i in $(seq 1 45); do
    sleep 2
    if curl -s --connect-timeout 3 --socks5 127.0.0.1:${SOCKS_PORT} http://ip.sb >/dev/null 2>&1; then
      exit_ip=$(curl -s --max-time 5 --socks5 127.0.0.1:${SOCKS_PORT} http://ip.sb 2>/dev/null || echo "unknown")
      simple "VPN tunnel ready! exit IP: ${exit_ip}"
      break
    fi
  done
  simple "VPN tunnel not ready, xapp will use direct connection"
fi

# ---------- 启动 xapp ----------
XAPP_ARGS="-l wss://0.0.0.0:${XAPP_PORT}"
if [ -n "$fout_pid" ] && kill -0 "$fout_pid" 2>/dev/null; then
  XAPP_ARGS="${XAPP_ARGS} -f socks5://127.0.0.1:${SOCKS_PORT}"
else
  # 无 VPN：直连模式（xapp 监听但不转发到 SOCKS5）
  simple "running in direct mode (no VPN)"
fi
XAPP_ARGS="${XAPP_ARGS} -token ${TOKEN}"

simple "starting xapp (WSS :${XAPP_PORT})..."
/usr/local/bin/xapp ${XAPP_ARGS} &
xapp_pid=$!

simple "=== foutrw ready ==="
simple "  WSS: :${XAPP_PORT}"
[ -n "$fout_pid" ] && simple "  SOCKS: :${SOCKS_PORT}"

# 信号转发
cleanup() {
  kill "$xapp_pid" 2>/dev/null
  [ -n "$fout_pid" ] && kill "$fout_pid" 2>/dev/null
}
trap cleanup TERM INT

wait -n "$xapp_pid" ${fout_pid:+$fout_pid} 2>/dev/null
cleanup
