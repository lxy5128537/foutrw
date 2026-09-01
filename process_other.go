//go:build !linux

package main

// setProcessName is a no-op on non-Linux platforms
func setProcessName(name string) {
}
