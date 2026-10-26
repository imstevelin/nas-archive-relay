//go:build !linux

package relay

import "os"

func invalidateCache(f *os.File) {}
