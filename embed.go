package main

import (
	"embed"
	"os"
	"path/filepath"
)

//go:embed dlxapp.html
var embeddedLanding embed.FS

// 入口静态网页内容（内嵌默认，可被同路径 dlxapp.html 覆盖）
var landingHTML []byte

// loadLandingPage 加载入口静态网页：
//  1. 优先使用二进制同路径下的 dlxapp.html（外部文件，可定制）
//  2. 不存在则回退到内嵌的静态网页
func loadLandingPage() {
	// 默认用内嵌内容
	if data, err := embeddedLanding.ReadFile("dlxapp.html"); err == nil {
		landingHTML = data
	}

	// 尝试用二进制同路径下的外部 dlxapp.html 覆盖
	if exe, err := os.Executable(); err == nil {
		extPath := filepath.Join(filepath.Dir(exe), "dlxapp.html")
		if data, err := os.ReadFile(extPath); err == nil {
			landingHTML = data
			return
		}
	}
}
