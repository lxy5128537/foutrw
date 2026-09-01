#!/usr/bin/env bash
# foutrw 容器入口
# 自动检测/创建 TUN → fout VPN 隧道 → xapp WSS

set -uo pipefail

SOCKS_PORT="${SOCKS_PORT:-10000}"
XAPP_PORT="${XAPP_PORT:-${PORT:-8080}}"
COUNTRY="${COUNTRY:-}"
TOKEN="${TOKEN:-Ymj5128537}"

simple(){ echo "[foutrw] $*"; }

# ---------- TUN 设备检查/创建 ----------
HAS_TUN=false
if [ -e /dev/net/tun ] && [ -w /dev/net/tun ]; then
  HAS_TUN=true
  simple "/dev/net/tun 可用"
else
  simple "尝试创建 /dev/net/tun..."
  mkdir -p /dev/net 2>/dev/null
  if mknod /dev/net/tun c 10 200 2>/dev/null; then
    chmod 666 /dev/net/tun
    HAS_TUN=true
    simple "/dev/net/tun 已创建"
  elif [ -e /dev/net/tun ]; then
    chmod 666 /dev/net/tun 2>/dev/null
    HAS_TUN=true
    simple "/dev/net/tun 已修复权限"
  else
    simple "/dev/net/tun 不可用，运行在直连模式"
  fi
fi

# ---------- 启动 fout (仅 TUN 可用时) ----------
fout_pid=""
if [ "$HAS_TUN" = true ]; then
  FOUT_ARGS="-nat -p ${SOCKS_PORT} -d"
  [ -n "$COUNTRY" ] && FOUT_ARGS="${FOUT_ARGS} -c ${COUNTRY}"

  simple "starting fout (SOCKS5 :${SOCKS_PORT})..."
  /usr/local/bin/fout ${FOUT_ARGS} &
  fout_pid=$!

  simple "waiting for VPN tunnel..."
  for i in $(seq 1 45); do
    sleep 2
    if curl -s --connect-timeout 3 --socks5 127.0.0.1:${SOCKS_PORT} http://ip.sb >/dev/null 2>&1; then
      exit_ip=$(curl -s --max-time 5 --socks5 127.0.0.1:${SOCKS_PORT} http://ip.sb 2>/dev/null || echo "unknown")
      simple "VPN ready! exit IP: ${exit_ip}"
      break
    fi
  done
fi

# ---------- 启动 xapp ----------
XAPP_ARGS="-l wss://0.0.0.0:${XAPP_PORT}"
if [ -n "$fout_pid" ] && kill -0 "$fout_pid" 2>/dev/null; then
  XAPP_ARGS="${XAPP_ARGS} -f socks5://127.0.0.1:${SOCKS_PORT}"
  simple "xapp → SOCKS5 → VPN tunnel"
else
  simple "xapp direct mode (no VPN)"
fi
XAPP_ARGS="${XAPP_ARGS} -token ${TOKEN}"

simple "starting xapp (WSS :${XAPP_PORT})..."
/usr/local/bin/xapp ${XAPP_ARGS} &
xapp_pid=$!

simple "=== foutrw ready ==="
simple "  WSS: :${XAPP_PORT}"
[ -n "$fout_pid" ] && kill -0 "$fout_pid" 2>/dev/null && simple "  VPN: active"

cleanup() {
  kill "$xapp_pid" 2>/dev/null
  [ -n "$fout_pid" ] && kill "$fout_pid" 2>/dev/null
}
trap cleanup TERM INT

wait -n "$xapp_pid" ${fout_pid:+$fout_pid} 2>/dev/null
cleanup
