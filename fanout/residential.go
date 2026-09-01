package main

// residential.go — nat 模式住宅 IP 自检（内化原 fout-guard.sh 功能）。
//
// 背景：pids.max=50 的容器里，外部守护脚本的周期性 curl fork 是进程耗尽的
// 主要推手。本文件把住宅判定做成 fout 内部能力：
//   - 经隧道 netns 拨号（dialerInNetns）访问 ippure API，看到的即是真实出口；
//   - 全程 Go goroutine，零 fork；
//   - 未命中住宅时复用 refreshFailedTunnel 整链重建；
//   - 连续未命中按指数退避（10m→20m→40m→…上限 60m），防重启风暴。

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"sync"
	"time"
)

const (
	resCheckEvery    = 10 * time.Minute  // 住宅检查常规间隔
	resFailBaseShift = 0                 // 首次失败后的重试等待 = base << (n-1)
	resFailBase      = 10 * time.Minute  // 退避基数
	resFailMaxWait   = 60 * time.Minute  // 退避上限
)

var (
	resMu      sync.Mutex
	resLastRun time.Time
	resFailCnt int
)

// residentialDue 到达下一次检查时间了吗（含失败指数退避）。
func residentialDue() bool {
	resMu.Lock()
	defer resMu.Unlock()
	wait := resCheckEvery
	if resFailCnt > 0 {
		wait = resFailBase << uint(resFailCnt-1+resFailBaseShift)
		if wait > resFailMaxWait || wait <= 0 {
			wait = resFailMaxWait
		}
	}
	return time.Since(resLastRun) >= wait
}

// markResidential 记录检查结果：命中清零退避；未命中递增退避。
func markResidential(ok bool) {
	resMu.Lock()
	defer resMu.Unlock()
	resLastRun = time.Now()
	if ok {
		resFailCnt = 0
	} else {
		resFailCnt++
	}
}

// dialerForTunnel 返回经本隧道 netns 出站的拨号器（nat 模式专用）。
func (t *Tunnel) dialerForTunnel() func(string, string) (net.Conn, error) {
	if !*natMode || t.ovpn == nil || t.ovpn.Process == nil {
		return nil
	}
	return dialerInNetns(fmt.Sprintf("/proc/%d/ns/net", t.ovpn.Process.Pid))
}

// checkResidentialNAT 经隧道访问 ippure 判断出口属性。
// 返回 (isResidential, decided)；decided=false 表示 API 不可达/IP 不一致等，
// 不做结论也不计入退避。
func checkResidentialNAT(t *Tunnel) (bool, bool) {
	dialer := t.dialerForTunnel()
	if dialer == nil {
		return false, false
	}
	client := &http.Client{
		Transport: &http.Transport{Dial: dialer},
		Timeout:   25 * time.Second,
	}
	req, err := http.NewRequest("GET", "https://my.ippure.com/v1/info", nil)
	if err != nil {
		return false, false
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
	resp, err := client.Do(req)
	if err != nil {
		return false, false
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if err != nil || len(body) == 0 {
		return false, false
	}
	var info struct {
		IP            string `json:"ip"`
		IsResidential bool   `json:"isResidential"`
	}
	if err := json.Unmarshal(body, &info); err != nil {
		return false, false
	}
	// 出口 IP 与探测记录不一致说明中间发生了切换，本轮结论不可信
	t.mu.Lock()
	exitIP := t.ExitIP
	t.mu.Unlock()
	if info.IP == "" || (exitIP != "" && info.IP != exitIP) {
		return false, false
	}
	return info.IsResidential, true
}