package relay

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"
)

var errDuplicateDecision = errors.New("duplicate decision required")

func shortName(name string) string {
	for len(name) > 160 {
		_, n := utf8.DecodeLastRuneInString(name)
		name = name[:len(name)-n]
	}
	return name
}
func copyName(name, id string) string { return shortName(name) + "（副本 " + id[:8] + "）" }
func workName(name, id, phase string) string {
	return shortName(name) + "（" + phase + "）.nasrelay-" + id
}
func renameManifest(m Manifest, name string) Manifest {
	old := m.Name
	m.Name = name
	m.Entries = append([]Entry(nil), m.Entries...)
	for i, e := range m.Entries {
		m.Entries[i].Path = name + strings.TrimPrefix(e.Path, old)
	}
	return m
}
func dataPath(root, name, entry string) string {
	if entry == name {
		return root
	}
	return filepath.Join(root, strings.TrimPrefix(entry, name+"/"))
}
func owned(path, id string) bool {
	var marker struct {
		ID string `json:"id"`
	}
	info, err := os.Lstat(path)
	return err == nil && info.IsDir() && info.Mode()&os.ModeSymlink == 0 && readJSON(filepath.Join(path, ".nas-relay-incomplete.json"), &marker) == nil && marker.ID == id
}
func removeOwned(path, id string) error {
	if _, err := os.Lstat(path); os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return err
	}
	if !owned(path, id) {
		return fmt.Errorf("refusing to remove unowned NAS directory: %s", filepath.Base(path))
	}
	if err := os.RemoveAll(path); err != nil {
		return err
	}
	return syncDir(filepath.Dir(path))
}
func directoryManifest(m Manifest, workspace string) Manifest {
	for _, e := range m.Entries {
		if e.Path == m.Name && e.Type == "dir" {
			return renameManifest(m, workspace)
		}
	}
	result := m
	result.Name = workspace
	result.Entries = []Entry{{Path: workspace, Type: "dir"}}
	for _, e := range m.Entries {
		e.Path = workspace + "/" + e.Path
		result.Entries = append(result.Entries, e)
	}
	return result
}
func (a *Server) cleanupNASWork(id, destination string) error {
	j, ok := a.Store.Job(id)
	if !ok {
		return os.ErrNotExist
	}
	if !j.Accepted {
		return nil
	}
	m, err := a.Store.Manifest(id)
	if err != nil {
		return err
	}
	if destination == "" {
		t, ok := a.Store.Target(j.TargetID)
		if !ok {
			return errors.New("target unavailable")
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
	for _, phase := range []string{"上傳中", "校驗中"} {
		if err := removeOwned(filepath.Join(destination, workName(m.Name, id, phase)), id); err != nil {
			return err
		}
	}
	// Older versions could publish a partial directory. Only its exact ownership marker permits cleanup.
	if j.Stage == "completed" {
		name := m.Name
		if j.ArchiveName != "" {
			name = j.ArchiveName
		}
		final := filepath.Join(destination, name)
		if owned(final, id) {
			if err := os.Remove(filepath.Join(final, ".nas-relay-incomplete.json")); err != nil {
				return err
			}
			if err := syncDir(final); err != nil {
				return err
			}
		}
	} else {
		name := m.Name
		if j.ArchiveName != "" {
			name = j.ArchiveName
		}
		p := filepath.Join(destination, name)
		if owned(p, id) {
			allowed := map[string]bool{".": true, ".nas-relay-incomplete.json": true}
			for _, entry := range m.Entries {
				if entry.Path != m.Name {
					allowed[strings.TrimPrefix(entry.Path, m.Name+"/")] = true
				}
			}
			if err := filepath.WalkDir(p, func(path string, d os.DirEntry, walkErr error) error {
				if walkErr != nil {
					return walkErr
				}
				rel, err := filepath.Rel(p, path)
				if err != nil {
					return err
				}
				if !allowed[filepath.ToSlash(rel)] {
					return fmt.Errorf("unrecognized content in old partial archive: %s", rel)
				}
				return nil
			}); err != nil {
				return err
			}
			if err := removeOwned(p, id); err != nil {
				return err
			}
		}
	}
	return nil
}
func (a *Server) archiveJob(id string) error {
	j, _ := a.Store.Job(id)
	target, ok := a.Store.Target(j.TargetID)
	if !ok || !target.Enabled {
		return errors.New("NAS target unavailable")
	}
	lock := a.Store.targetLock(target.ID)
	lock.Lock()
	defer lock.Unlock()
	check := func() error { return a.Store.Check(id) }
	if err := check(); err != nil {
		return err
	}
	point, err := a.ResolveTarget(target)
	if err != nil {
		return err
	}
	destination, err := ensureDirs(point, j.Folder)
	if err != nil {
		return err
	}
	original, err := a.Store.Manifest(id)
	if err != nil {
		return err
	}
	m := original
	if j.ArchiveName != "" {
		m = renameManifest(m, j.ArchiveName)
	}
	if _, err = internalDirectory(destination, ".nas-relay-staging"); err != nil {
		return err
	}
	final := filepath.Join(destination, m.Name)
	if _, err = os.Lstat(final); err == nil && !owned(final, id) {
		if j.DuplicateChoice == "" && !j.Published {
			err = a.Store.Update(id, func(v *Job) error {
				v.Stage = "awaiting_duplicate"
				v.Action = "paused"
				v.Error = "NAS already contains this name; choose compare, keep both, or cancel"
				v.Speed = 0
				v.ETA = nil
				return nil
			})
			if err != nil {
				return err
			}
			return errDuplicateDecision
		}
		meter := newMeter(a.Store, id, "checking_existing", j.Bytes, 0)
		_ = meter.flush(true)
		if err = verifyTree(destination, m, check, meter.add, true, false); err != nil {
			if errors.Is(err, ErrPaused) || errors.Is(err, ErrCancelled) {
				return err
			}
			return conflictError{err.Error()}
		}
	} else if err != nil && !os.IsNotExist(err) {
		return err
	} else if owned(final, id) {
		// Publication may have finished just before a daemon restart.
		if err = verifyTree(destination, m, check, nil, true, true); err != nil {
			return err
		}

	} else {
		verifyMeter := newMeter(a.Store, id, "checking_relay", j.Bytes, 0)
		_ = verifyMeter.flush(true)
		if err = verifyTree(a.Store.jobPath(id, "payload"), original, check, verifyMeter.add, false, false); err != nil {
			if errors.Is(err, ErrPaused) || errors.Is(err, ErrCancelled) {
				return err
			}
			return payloadError{"relay payload is damaged: " + err.Error()}
		}
		upload := filepath.Join(destination, workName(original.Name, id, "上傳中"))
		checking := filepath.Join(destination, workName(original.Name, id, "校驗中"))
		workspace := upload
		if _, e := os.Lstat(checking); e == nil {
			workspace = checking
		} else if !os.IsNotExist(e) {
			return e
		}
		if _, e := os.Lstat(workspace); os.IsNotExist(e) {
			if err = os.Mkdir(workspace, 0770); err != nil {
				return err
			}
			if err = atomicJSON(filepath.Join(workspace, ".nas-relay-incomplete.json"), map[string]string{"id": id}); err != nil {
				return err
			}
		} else if e != nil {
			return e
		}
		if !owned(workspace, id) {
			return errors.New("NAS work directory ownership mismatch")
		}
		dataRoot := workspace
		for _, e := range original.Entries {
			if e.Path == original.Name && e.Type == "file" {
				dataRoot = filepath.Join(workspace, original.Name)
			}
		}
		_ = a.Store.Update(id, func(v *Job) error { v.NASClean = false; v.CleanupError = ""; return nil })
		var initial int64
		for _, e := range original.Entries {
			if e.Type == "file" {
				if info, e2 := os.Lstat(dataPath(dataRoot, original.Name, e.Path)); e2 == nil && info.Mode().IsRegular() && info.Size() <= e.Size {
					initial += info.Size()
				}
			}
		}
		meter := newMeter(a.Store, id, "copying", j.Bytes, initial)
		if err = meter.flush(true); err != nil {
			return err
		}
		for _, e := range original.Entries {
			if err = check(); err != nil {
				return err
			}
			dest := dataPath(dataRoot, original.Name, e.Path)
			if e.Type == "dir" {
				rel, e2 := filepath.Rel(workspace, dest)
				if e2 != nil {
					return e2
				}
				if rel != "." {
					if _, err = ensureDirs(workspace, filepath.ToSlash(rel)); err != nil {
						return err
					}
				}
				continue
			}
			if rel, e2 := filepath.Rel(workspace, filepath.Dir(dest)); e2 != nil {
				return e2
			} else if rel != "." {
				if _, e2 = ensureDirs(workspace, filepath.ToSlash(rel)); e2 != nil {
					return e2
				}
			}
			if err = copyResume(a.Store.jobPath(id, "payload", e.Path), dest, e, check, meter.add); err != nil {
				return err
			}
		}
		if workspace != checking {
			if _, e := os.Lstat(checking); !os.IsNotExist(e) {
				return errors.New("checking workspace already exists")
			}
			if err = os.Rename(workspace, checking); err != nil {
				return err
			}
			workspace = checking
		}
		staged := directoryManifest(original, filepath.Base(workspace))
		meter = newMeter(a.Store, id, "verifying_nas", j.Bytes, 0)
		if err = meter.flush(true); err != nil {
			return err
		}
		if err = verifyTree(destination, staged, check, meter.add, true, true); err != nil {
			return err
		}
		dataRoot = workspace
		for _, e := range original.Entries {
			if e.Path == original.Name && e.Type == "file" {
				dataRoot = filepath.Join(workspace, original.Name)
			}
		}
		meter = newMeter(a.Store, id, "publishing", j.Bytes, 0)
		if err = meter.flush(true); err != nil {
			return err
		}
		if err = publishTreeFrom(dataRoot, destination, m, check, meter.add); err != nil {
			return err
		}
		if err = a.Store.Update(id, func(v *Job) error { v.Published = true; return nil }); err != nil {
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
	receipt := map[string]any{"id": id, "owner": j.Owner, "manifest_sha256": j.ManifestSHA, "verified_at": time.Now().UTC(), "manifest": original, "archived_name": m.Name}
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
	return a.cleanupFinished(id, destination, false)
}
