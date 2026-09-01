package main

// natmode.go — NAT 容器模式（-nat 标志启用）。
//
// 适用环境：无 mount 权限的精简容器（seccomp 禁 mount，ip netns add/exec
// 因 bind-mount /proc/<pid>/ns/net 失败而不可用）。原生 namespace syscall
// （unshare/setns/按 PID 迁移 veth）不受影响，已实测可用。
//
// 与默认模式的对应关系（行为不变，仅换底层机制）：
//   ip netns add foN            → openvpn 子进程自带 CLONE_NEWNET（进程即 ns 持有者）
//   ip link set fopN netns foN  → ip link set fopN netns <openvpn_pid>
//   ip netns exec foN <cmd>     → nsenter -t <pid> -n <cmd>
//   /etc/netns/foN/resolv.conf  → 无 mount 无法注入；改为启动前预解析域名传 IP
//
// 其余（veth 桥、iptables MASQUERADE、健康探测逻辑）完全复用原实现。

import (
	"fmt"
	"net"
	"os/exec"
	"strings"
	"syscall"
)

// natPreResolve 预解析 openvpn 配置里的 remote 域名并改写为 IP。
// 新 netns 内没有 resolv.conf 注入手段，DNS 不可用；在宿主 netns 解析后
// 把 remote host 直接替换成 IP，绕过 netns 内 DNS 依赖。
func natPreResolve(cfg string) string {
	lines := strings.Split(cfg, "\n")
	for i, ln := range lines {
		tf := strings.Fields(ln)
		if len(tf) >= 2 && tf[0] == "remote" {
			host := tf[1]
			if net.ParseIP(host) == nil {
				if ips, err := net.LookupIP(host); err == nil && len(ips) > 0 {
					// 优先 IPv4（VPN Gate 节点以 v4 为主）
					ip := ""
					for _, a := range ips {
						if a.To4() != nil {
							ip = a.String()
							break
						}
					}
					if ip == "" {
						ip = ips[0].String()
					}
					tf[1] = ip
					lines[i] = strings.Join(append([]string{"remote"}, tf[1:]...), " ")
				}
			}
		}
	}
	return strings.Join(lines, "\n")
}

// natSetupVeth 在 openvpn 子进程已进入新 netns 后调用：
// 建 veth 对并把 peer 按 PID 迁入子进程 netns（不依赖 mount/netns 文件）。
func (t *Tunnel) natSetupVeth() error {
	sub := t.subnet()
	veth := fmt.Sprintf("fov%d", t.Slot)
	peer := fmt.Sprintf("fop%d", t.Slot)
	pid := fmt.Sprintf("%d", t.ovpn.Process.Pid)

	steps := [][]string{
		{"ip", "link", "add", veth, "type", "veth", "peer", "name", peer},
		{"ip", "link", "set", peer, "netns", pid},
		{"ip", "addr", "add", sub + ".1/30", "dev", veth},
		{"ip", "link", "set", veth, "up"},
		{"nsenter", "-t", pid, "-n", "ip", "addr", "add", sub + ".2/30", "dev", peer},
		{"nsenter", "-t", pid, "-n", "ip", "link", "set", "lo", "up"},
		{"nsenter", "-t", pid, "-n", "ip", "link", "set", peer, "up"},
		{"nsenter", "-t", pid, "-n", "ip", "route", "replace", "default", "via", sub + ".1"},
	}
	for _, s := range steps {
		if err := run(s[0], s[1:]...); err != nil {
			return err
		}
	}
	return nil
}

// natTeardown 清理 nat 模式的隧道资源：杀 openvpn 进程、删 veth 和 iptables 规则。
// netns 随进程退出由内核自动回收，无需显式删除。
func (t *Tunnel) natTeardown() {
	if t.ovpn != nil && t.ovpn.Process != nil {
		_ = t.ovpn.Process.Kill()
	}
	runQuiet("ip", "link", "del", fmt.Sprintf("fov%d", t.Slot))
	cidr := t.subnet() + ".0/30"
	deleteRule("nat", "POSTROUTING", "-s", cidr, "-j", "MASQUERADE")
	deleteRule("filter", "FORWARD", "-s", cidr, "-j", "ACCEPT")
	deleteRule("filter", "FORWARD", "-d", cidr, "-j", "ACCEPT")
}

// nsExecCmd 返回执行 cmd 的 *exec.Cmd。
// 默认模式走 ip netns exec；nat 容器模式直接执行（openvpn 在同一 netns）。
func (t *Tunnel) nsExecCmd(name string, args ...string) *exec.Cmd {
	if *natMode {
		return exec.Command(name, args...)
	}
	return exec.Command("ip", append([]string{"netns", "exec", t.nsName(), name}, args...)...)
}

// ovpnDead 检查 nat 模式下 openvpn 子进程是否已死亡。
// 进程退出但 cmd.Wait() 的 goroutine 尚未把状态传播时，Status 可能仍停留在 "up"；
// 以进程表为准。默认模式(netns 由 ip 命令持有)恒返回 false。
func (t *Tunnel) ovpnDead() bool {
	if !*natMode {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.ovpn == nil || t.ovpn.Process == nil || t.ovpn.ProcessState != nil
}

var _ = syscall.StringSlicePtr // 保持 syscall import 占位