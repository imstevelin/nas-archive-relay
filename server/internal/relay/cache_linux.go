//go:build linux

package relay

import (
	"os"
	"syscall"
)

func invalidateCache(f *os.File) {
	_, _, _ = syscall.Syscall6(syscall.SYS_FADVISE64, f.Fd(), 0, 0, 4, 0, 0)
}
