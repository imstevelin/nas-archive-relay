package relay

import (
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

func (a *Server) preflight(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Name     string `json:"name"`
		TargetID string `json:"target_id"`
		Folder   string `json:"folder"`
	}
	if err := decode(w, r, &b); err != nil {
		problem(w, 400, err)
		return
	}
	if !safePath(b.Name, false) || strings.Contains(b.Name, "/") || !safePath(b.Folder, true) {
		problem(w, 400, errors.New("invalid destination"))
		return
	}
	target, ok := a.Store.Target(b.TargetID)
	if !ok || !target.Enabled {
		problem(w, 400, errors.New("target unavailable"))
		return
	}
	select {
	case a.preflightSlots <- struct{}{}:
	default:
		problem(w, 503, errors.New("NAS check busy; handoff can proceed"))
		return
	}
	type result struct {
		exists bool
		err    error
	}
	done := make(chan result, 1)
	go func() {
		defer func() { <-a.preflightSlots }()
		point, err := a.ResolveTarget(target)
		if err != nil {
			done <- result{err: err}
			return
		}
		// A check must not create user destination folders.
		current := point
		for _, part := range strings.Split(b.Folder, "/") {
			if part == "" {
				continue
			}
			current = filepath.Join(current, part)
			info, err := os.Lstat(current)
			if os.IsNotExist(err) {
				done <- result{}
				return
			}
			if err != nil {
				done <- result{err: err}
				return
			}
			if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
				done <- result{err: errors.New("unsafe destination")}
				return
			}
		}
		_, err = os.Lstat(filepath.Join(current, b.Name))
		if os.IsNotExist(err) {
			done <- result{}
			return
		}
		done <- result{exists: err == nil, err: err}
	}()
	select {
	case out := <-done:
		if out.err != nil {
			problem(w, 503, out.err)
		} else {
			write(w, 200, map[string]bool{"exists": out.exists})
		}
	case <-r.Context().Done():
		return
	}
}
