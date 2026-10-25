package relay

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"time"
)

type conflictError struct{ message string }
type payloadError struct{ message string }

func (e payloadError) Error() string { return e.message }

func (e conflictError) Error() string { return e.message }

type meter struct {
	s                    *Store
	id, stage            string
	done, total, initial int64
	start, last          time.Time
}

func newMeter(s *Store, id, stage string, total, initial int64) *meter {
	return &meter{s: s, id: id, stage: stage, total: total, done: initial, initial: initial, start: time.Now()}
}
func (m *meter) add(n int64) { m.done += n; _ = m.flush(false) }
func (m *meter) flush(force bool) error {
	if !force && time.Since(m.last) < time.Second {
		return nil
	}
	m.last = time.Now()
	elapsed := time.Since(m.start).Seconds()
	speed := float64(m.done-m.initial) / elapsed
	var eta *float64
	if speed > 0 && m.done < m.total {
		v := float64(m.total-m.done) / speed
		eta = &v
	}
	return m.s.Update(m.id, func(j *Job) error {
		if j.Action == "paused" {
			return ErrPaused
		}
		if j.Action == "cancelled" {
			return ErrCancelled
		}
		j.Stage = m.stage
		j.Done = m.done
		j.Total = m.total
		j.Speed = speed
		j.ETA = eta
		j.Error = ""
		return nil
	})
}

func verifyTree(base string, m Manifest, check func() error, progress func(int64), durable, allowMarker bool) error {
	expected := map[string]Entry{}
	for _, e := range m.Entries {
		expected[e.Path] = e
	}
	seen := map[string]bool{}
	err := filepath.WalkDir(filepath.Join(base, m.Name), func(p string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if check != nil {
			if err := check(); err != nil {
				return err
			}
		}
		rel, err := filepath.Rel(base, p)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if allowMarker && rel == m.Name+"/.nas-relay-incomplete.json" {
			return nil
		}
		e, ok := expected[rel]
		if !ok {
			return fmt.Errorf("unexpected archive entry: %s", rel)
		}
		if d.Type()&os.ModeSymlink != 0 {
			return errors.New("symlinks are not allowed")
		}
		seen[rel] = true
		if e.Type == "dir" {
			if !d.IsDir() {
				return errors.New("directory type mismatch")
			}
			return nil
		}
		return fileDigestMatches(p, e, check, progress, durable)
	})
	if err != nil {
		return err
	}
	if len(seen) != len(expected) {
		return errors.New("archive listing differs from manifest")
	}
	return nil
}
func (a *Server) Run(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		a.dispatch()
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
func (a *Server) dispatch() {
	a.Store.mu.Lock()
	jobs := []Job{}
	for _, j := range a.Store.Jobs {
		jobs = append(jobs, j)
	}
	a.Store.mu.Unlock()
	sort.Slice(jobs, func(i, j int) bool { return jobs[i].Created < jobs[j].Created })
	for _, j := range jobs {
		if (j.Stage == "completed" || j.Stage == "cancelled") && (!j.RelayClean || !j.NASClean) {
			if j.RetryAt > time.Now().UnixMilli() {
				continue
			}
			if _, loaded := a.active.LoadOrStore(j.ID, true); loaded {
				continue
			}
			select {
			case a.cleanup <- struct{}{}:
				go func(id string) {
					defer func() { <-a.cleanup; a.active.Delete(id) }()
					lock := a.Store.lock(id)
					lock.Lock()
					defer lock.Unlock()
					if err := a.cleanupFinished(id, "", true); err != nil {
						_ = a.Store.Update(id, func(v *Job) error {
							v.Error = "temporary cleanup pending: " + err.Error()
							v.RetryAt = time.Now().Add(30 * time.Second).UnixMilli()
							return nil
						})
					}
				}(j.ID)
			default:
				a.active.Delete(j.ID)
			}
			continue
		}
		if j.Action == "cancelled" && j.Stage != "cancelled" {
			if _, busy := a.active.Load(j.ID); !busy {
				lock := a.Store.lock(j.ID)
				if lock.TryLock() {
					_ = a.cancelLocked(j.ID)
					lock.Unlock()
				}
			}
			continue
		}
		if j.Action != "running" || j.RetryAt > time.Now().UnixMilli() || j.Stage == "receiving" || j.Stage == "completed" || j.Stage == "cancelled" || j.Stage == "failed" || j.Stage == "conflict" {
			continue
		}
		if _, loaded := a.active.LoadOrStore(j.ID, true); loaded {
			continue
		}
		pool := a.archive
		if !j.Accepted {
			pool = a.ingest
		}
		select {
		case pool <- struct{}{}:
			go func(id string, pool chan struct{}) { defer func() { <-pool; a.active.Delete(id) }(); a.work(id) }(j.ID, pool)
		default:
			a.active.Delete(j.ID)
		}
	}
}
func (a *Server) work(id string) {
	lock := a.Store.lock(id)
	lock.Lock()
	defer lock.Unlock()
	j, ok := a.Store.Job(id)
	if !ok {
		return
	}
	var err error
	if err = a.Store.Check(id); err == nil {
		if !j.Accepted {
			err = a.verifyReceive(id)
		} else {
			err = a.archiveJob(id)
		}
	}
	if err == nil {
		return
	}
	if errors.Is(err, ErrCancelled) {
		_ = a.cancelLocked(id)
		return
	}
	if errors.Is(err, ErrPaused) {
		_ = a.Store.Update(id, func(j *Job) error { j.Stage = "paused"; j.Speed = 0; j.ETA = nil; return nil })
		return
	}
	var conflict conflictError
	var damaged payloadError
	_ = a.Store.Update(id, func(j *Job) error {
		j.Error = err.Error()
		j.Speed = 0
		j.ETA = nil
		if j.Stage == "completed" || j.Stage == "cancelled" {
			j.Error = "temporary cleanup pending: " + err.Error()
			j.RetryAt = time.Now().Add(30 * time.Second).UnixMilli()
		} else if errors.As(err, &conflict) {
			j.Stage = "conflict"
		} else if !j.Accepted || errors.As(err, &damaged) {
			j.Stage = "failed"
		} else {
			j.Stage = "retry_pending"
			j.RetryAt = time.Now().Add(30 * time.Second).UnixMilli()
		}
		return nil
	})
	log.Printf("job %s retained: %v", id, err)
}
func (a *Server) verifyReceive(id string) error {
	m, err := a.Store.Manifest(id)
	if err != nil {
		return err
	}
	j, _ := a.Store.Job(id)
	meter := newMeter(a.Store, id, "verifying_receive", j.Bytes, 0)
	if err = meter.flush(true); err != nil {
		return err
	}
	if err = verifyTree(a.Store.jobPath(id, "payload"), m, func() error { return a.Store.Check(id) }, meter.add, false, false); err != nil {
		return err
	}
	return a.Store.Update(id, func(j *Job) error {
		if j.Action == "paused" {
			return ErrPaused
		}
		if j.Action == "cancelled" {
			return ErrCancelled
		}
		j.Accepted = true
		j.Stage = "queued"
		j.Done = 0
		j.Total = j.Bytes
		j.Speed = 0
		j.ETA = nil
		return nil
	})
}
func internalDirectory(base, name string) (string, error) {
	p := filepath.Join(base, name)
	info, err := os.Lstat(p)
	if os.IsNotExist(err) {
		if err = os.Mkdir(p, 0770); err != nil {
			return "", err
		}
		return p, nil
	}
	if err != nil {
		return "", err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("internal NAS path is not a directory")
	}
	return p, nil
}
func (a *Server) archiveJob(id string) error {
	j, _ := a.Store.Job(id)
	t, ok := a.Store.Target(j.TargetID)
	if !ok || !t.Enabled {
		return errors.New("NAS target is disabled or missing")
	}
	targetLock := a.Store.targetLock(t.ID)
	targetLock.Lock()
	defer targetLock.Unlock()
	if err := a.Store.Check(id); err != nil {
		return err
	}
	point, err := a.ResolveTarget(t)
	if err != nil {
		return err
	}
	destination, err := ensureDirs(point, j.Folder)
	if err != nil {
		return err
	}
	m, err := a.Store.Manifest(id)
	if err != nil {
		return err
	}
	check := func() error { return a.Store.Check(id) }
	final := filepath.Join(destination, m.Name)
	marker := filepath.Join(final, ".nas-relay-incomplete.json")
	var ownership struct {
		ID string `json:"id"`
	}
	own := readJSON(marker, &ownership) == nil && ownership.ID == id
	exists := false
	if _, err := os.Lstat(final); err == nil {
		exists = true
	} else if !os.IsNotExist(err) {
		return err
	}
	stageRoot, err := internalDirectory(destination, ".nas-relay-staging")
	if err != nil {
		return err
	}
	stage, err := ensureDirs(stageRoot, id+"/payload")
	if err != nil {
		return err
	}
	if exists && !own {
		meter := newMeter(a.Store, id, "checking_existing", j.Bytes, 0)
		_ = meter.flush(true)
		if err = verifyTree(destination, m, check, meter.add, true, false); err != nil {
			if errors.Is(err, ErrPaused) || errors.Is(err, ErrCancelled) {
				return err
			}
			return conflictError{err.Error()}
		}
	} else {
		verifyMeter := newMeter(a.Store, id, "checking_relay", j.Bytes, 0)
		_ = verifyMeter.flush(true)
		if err = verifyTree(a.Store.jobPath(id, "payload"), m, check, verifyMeter.add, false, false); err != nil {
			if errors.Is(err, ErrPaused) || errors.Is(err, ErrCancelled) {
				return err
			}
			return payloadError{"relay payload is damaged: " + err.Error()}
		}
		var initial int64
		for _, e := range m.Entries {
			if e.Type == "file" {
				if info, err := os.Lstat(filepath.Join(stage, e.Path)); err == nil && info.Mode().IsRegular() && info.Size() <= e.Size {
					initial += info.Size()
				}
			}
		}
		meter := newMeter(a.Store, id, "copying", j.Bytes, initial)
		if err = meter.flush(true); err != nil {
			return err
		}
		for _, e := range m.Entries {
			if err = check(); err != nil {
				return err
			}
			if e.Type == "dir" {
				if _, err = ensureDirs(stage, e.Path); err != nil {
					return err
				}
				continue
			}
			if _, err = ensureDirs(stage, filepath.ToSlash(filepath.Dir(e.Path))); err != nil {
				return err
			}
			if err = copyResume(a.Store.jobPath(id, "payload", e.Path), filepath.Join(stage, e.Path), e, check, meter.add); err != nil {
				return err
			}
		}
		meter = newMeter(a.Store, id, "verifying_nas", j.Bytes, 0)
		if err = meter.flush(true); err != nil {
			return err
		}
		if err = verifyTree(stage, m, check, meter.add, true, false); err != nil {
			if !errors.Is(err, ErrPaused) && !errors.Is(err, ErrCancelled) {
				_ = os.RemoveAll(stage)
			}
			return err
		}
		meter = newMeter(a.Store, id, "publishing", j.Bytes, 0)
		if err = meter.flush(true); err != nil {
			return err
		}
		if err = publishTree(stage, destination, m, check, meter.add); err != nil {
			return err
		}
	}
	if err = check(); err != nil {
		return err
	}
	receipts, err := internalDirectory(destination, ".nas-relay-receipts")
	if err != nil {
		return err
	}
	receipt := map[string]any{"id": id, "owner": j.Owner, "manifest_sha256": j.ManifestSHA, "verified_at": time.Now().UTC(), "manifest": m}
	if err = atomicJSON(filepath.Join(receipts, id+".json"), receipt); err != nil {
		return err
	}
	if err = atomicJSON(filepath.Join(a.Store.Root, "receipts", id+".json"), receipt); err != nil {
		return err
	}
	if err = a.Store.Update(id, func(v *Job) error {
		if v.Action == "paused" {
			return ErrPaused
		}
		if v.Action == "cancelled" {
			return ErrCancelled
		}
		v.Stage = "completed"
		v.Done = v.Bytes
		v.Total = v.Bytes
		v.Speed = 0
		v.ETA = nil
		v.Error = ""
		return nil
	}); err != nil {
		return err
	}
	// A completion record must be durable before removing the only relay payload.
	return a.cleanupFinished(id, destination, false)
}
func copyResume(source, dest string, e Entry, check func() error, progress func(int64)) error {
	src, err := os.Open(source)
	if err != nil {
		return err
	}
	defer src.Close()
	if info, err := src.Stat(); err != nil || !info.Mode().IsRegular() || info.Size() != e.Size {
		return errors.New("relay payload changed")
	}
	if info, err := os.Lstat(dest); err == nil && (!info.Mode().IsRegular() || info.Size() > e.Size) {
		return errors.New("invalid NAS partial file")
	}
	out, err := os.OpenFile(dest, os.O_CREATE|os.O_WRONLY, 0660)
	if err != nil {
		return err
	}
	defer out.Close()
	info, err := out.Stat()
	if err != nil {
		return err
	}
	offset := info.Size()
	if _, err = src.Seek(offset, io.SeekStart); err != nil {
		return err
	}
	if _, err = out.Seek(offset, io.SeekStart); err != nil {
		return err
	}
	buf := make([]byte, 256<<10)
	for {
		if err = check(); err != nil {
			_ = out.Sync()
			return err
		}
		n, e2 := src.Read(buf)
		if n > 0 {
			if _, err = out.Write(buf[:n]); err != nil {
				return err
			}
			progress(int64(n))
		}
		if e2 == io.EOF {
			break
		}
		if e2 != nil {
			return e2
		}
	}
	if err = out.Sync(); err != nil {
		return err
	}
	if e.Mtime > 0 {
		stamp := time.UnixMilli(e.Mtime)
		_ = os.Chtimes(dest, stamp, stamp)
	}
	return nil
}
func publishTree(stage, destination string, m Manifest, check func() error, progress func(int64)) error {
	root := filepath.Join(destination, m.Name)
	var top Entry
	for _, e := range m.Entries {
		if e.Path == m.Name {
			top = e
			break
		}
	}
	if top.Type == "file" {
		if err := check(); err != nil {
			return err
		}
		if err := os.Link(filepath.Join(stage, m.Name), root); err != nil && !errors.Is(err, os.ErrExist) {
			return err
		}
		if err := verifyTree(destination, m, check, progress, true, false); err != nil {
			if errors.Is(err, ErrPaused) || errors.Is(err, ErrCancelled) {
				return err
			}
			return conflictError{err.Error()}
		}
		return syncDir(destination)
	}
	marker := filepath.Join(root, ".nas-relay-incomplete.json")
	if err := os.Mkdir(root, 0770); err != nil {
		if !os.IsExist(err) {
			return err
		}
		var owner struct {
			ID string `json:"id"`
		}
		if readJSON(marker, &owner) != nil || owner.ID != m.ID {
			return conflictError{"archive directory belongs to another job"}
		}
	} else {
		if err := atomicJSON(marker, map[string]string{"id": m.ID}); err != nil {
			return err
		}
	}
	entries := append([]Entry(nil), m.Entries...)
	sort.Slice(entries, func(i, j int) bool { return len(entries[i].Path) < len(entries[j].Path) })
	for _, e := range entries {
		if err := check(); err != nil {
			return err
		}
		if e.Path == m.Name {
			continue
		}
		if e.Type == "dir" {
			if _, err := ensureDirs(destination, e.Path); err != nil {
				return err
			}
			continue
		}
		if err := os.Link(filepath.Join(stage, e.Path), filepath.Join(destination, e.Path)); err != nil {
			if !os.IsExist(err) {
				return err
			}
			if err = fileDigestMatches(filepath.Join(destination, e.Path), e, check, nil, true); err != nil {
				return conflictError{err.Error()}
			}
		}
	}
	if err := verifyTree(destination, m, check, progress, true, true); err != nil {
		return err
	}
	if err := os.Remove(marker); err != nil {
		return err
	}
	if err := syncDir(root); err != nil {
		return err
	}
	return syncDir(destination)
}
func (a *Server) cancelLocked(id string) error {
	j, ok := a.Store.Job(id)
	if !ok {
		return os.ErrNotExist
	}
	if j.Stage == "completed" || j.Stage == "cancelled" {
		return nil
	}
	// Only private relay payload is removed. Already published NAS contents remain.
	if err := a.Store.Update(id, func(v *Job) error {
		v.Stage = "cancelled"
		v.Action = "cancelled"
		v.Speed = 0
		v.ETA = nil
		return nil
	}); err != nil {
		return err
	}
	if err := os.RemoveAll(a.Store.jobPath(id, "payload")); err != nil {
		return err
	}
	return a.Store.Update(id, func(v *Job) error { v.RelayClean = true; v.NASClean = !v.Accepted; return nil })
}

func (a *Server) cleanupFinished(id, destination string, recheck bool) error {
	j, ok := a.Store.Job(id)
	if !ok {
		return os.ErrNotExist
	}
	if j.Stage != "completed" && j.Stage != "cancelled" {
		return nil
	}
	if !j.Accepted && j.Stage == "cancelled" {
		if err := os.RemoveAll(a.Store.jobPath(id, "payload")); err != nil {
			return err
		}
		return a.Store.Update(id, func(v *Job) error { v.RelayClean = true; v.NASClean = true; return nil })
	}
	if destination == "" {
		t, ok := a.Store.Target(j.TargetID)
		if !ok {
			return errors.New("NAS target unavailable for cleanup")
		}
		point, err := a.ResolveTarget(t)
		if err != nil {
			return err
		}
		destination, err = ensureDirs(point, j.Folder)
		if err != nil {
			return err
		}
	}
	if recheck && j.Stage == "completed" && !j.RelayClean {
		m, err := a.Store.Manifest(id)
		if err != nil {
			return err
		}
		if err = verifyTree(destination, m, nil, nil, true, false); err != nil {
			return err
		}
	}
	parent := filepath.Join(destination, ".nas-relay-staging")
	if info, err := os.Lstat(parent); err == nil {
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("unsafe staging cleanup path")
		}
		path := filepath.Join(parent, id)
		if info, err = os.Lstat(path); err == nil {
			if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
				return errors.New("unsafe job cleanup path")
			}
			if err = os.RemoveAll(path); err != nil {
				return err
			}
		} else if !os.IsNotExist(err) {
			return err
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := os.RemoveAll(a.Store.jobPath(id, "payload")); err != nil {
		return err
	}
	return a.Store.Update(id, func(v *Job) error { v.RelayClean = true; v.NASClean = true; v.Error = ""; return nil })
}
