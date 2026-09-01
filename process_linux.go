//go:build linux

package main

import (
	"syscall"
	"unsafe"
)

// setProcessName sets the process name to "xapp" on Linux
func setProcessName(name string) {
	nameBytes := []byte(name)
	if len(nameBytes) > 15 {
		nameBytes = nameBytes[:15]
	}
	syscall.Syscall(syscall.SYS_PRCTL, 15, uintptr(unsafe.Pointer(&nameBytes[0])), 0)
}
