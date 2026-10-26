package relay

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

var hostName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.-]*$`)

func ValidateTarget(t Target) error {
	if t.ID != "" && !idPattern.MatchString(t.ID) {
		return errors.New("invalid target id")
	}
	if strings.TrimSpace(t.Name) == "" || len(t.Name) > 160 || (!hostName.MatchString(t.Host) && net.ParseIP(t.Host) == nil) {
		return errors.New("invalid target name/host")
	}
	if !safePath(t.DefaultFolder, true) {
		return errors.New("invalid default folder")
	}
	switch t.Protocol {
	case "nfs":
		if !strings.HasPrefix(t.Export, "/") || strings.ContainsAny(t.Export, ",\\\x00\r\n") || filepath.Clean(t.Export) != t.Export {
			return errors.New("NFS export must be an absolute normalized path")
		}
		if t.NFSVersion != "4.2" && t.NFSVersion != "4.1" && t.NFSVersion != "4" && t.NFSVersion != "3" {
			return errors.New("unsupported NFS version")
		}
	case "smb":
		if t.Share == "" || strings.ContainsAny(t.Share, "/\\,\x00\r\n") || strings.ContainsAny(t.Username+t.Domain, "\x00\r\n") {
			return errors.New("invalid SMB share/credentials")
		}
	default:
		return errors.New("protocol must be smb or nfs")
	}
	return nil
}
func (s *Store) Target(id string) (Target, bool) {
	for _, t := range s.Snapshot().Targets {
		if t.ID == id {
			return t, true
		}
	}
	return Target{}, false
}
func (s *Store) mountPoint(id string) string { return filepath.Join(s.Root, "mounts", id) }
func mountSource(t Target) string {
	host := t.Host
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	if t.Protocol == "smb" {
		return "//" + host + "/" + t.Share
	}
	return host + ":" + t.Export
}
func actualMount(point string) (string, string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	b, err := exec.CommandContext(ctx, "findmnt", "--json", "-T", point, "-o", "SOURCE,FSTYPE,TARGET").Output()
	if err != nil {
		return "", "", err
	}
	var result struct {
		Filesystems []struct {
			Source string `json:"source"`
			FSType string `json:"fstype"`
			Target string `json:"target"`
		} `json:"filesystems"`
	}
	if err = json.Unmarshal(b, &result); err != nil || len(result.Filesystems) != 1 {
		return "", "", errors.New("cannot determine mount identity")
	}
	f := result.Filesystems[0]
	if filepath.Clean(f.Target) != filepath.Clean(point) {
		return "", "", nil
	}
	return f.Source, f.FSType, nil
}
func (s *Store) EnsureMount(t Target) (string, error) {
	lock := s.lock("mount-" + t.ID)
	lock.Lock()
	defer lock.Unlock()
	if err := ValidateTarget(t); err != nil {
		return "", err
	}
	point := s.mountPoint(t.ID)
	if err := os.MkdirAll(point, 0700); err != nil {
		return "", err
	}
	source, kind, _ := actualMount(point)
	if source != "" {
		if source == mountSource(t) && ((t.Protocol == "smb" && kind == "cifs") || (t.Protocol == "nfs" && (kind == "nfs4" || kind == "nfs"))) {
			return point, nil
		}
		return "", errors.New("mount identity mismatch; refusing local writes")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	args := []string{"-t", "nfs", "-o", "vers=" + t.NFSVersion + ",proto=tcp,hard,nosuid,nodev,noexec", mountSource(t), point}
	if t.Protocol == "smb" {
		cred := filepath.Join(s.Root, "credentials", t.ID)
		if _, err := os.Stat(cred); err != nil {
			return "", errors.New("SMB credentials are not configured")
		}
		args = []string{"-t", "cifs", "-o", "credentials=" + cred + ",vers=3.1.1,cache=none,actimeo=0,closetimeo=0,nolease,nosuid,nodev,noexec", mountSource(t), point}
	}
	output, err := exec.CommandContext(ctx, "mount", args...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("mount failed: %s", strings.TrimSpace(string(output)))
	}
	source, kind, err = actualMount(point)
	if err != nil || source != mountSource(t) || !((t.Protocol == "smb" && kind == "cifs") || (t.Protocol == "nfs" && (kind == "nfs4" || kind == "nfs"))) {
		return "", errors.New("mounted filesystem identity does not match target")
	}
	return point, nil
}
func (s *Store) TargetInUse(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, j := range s.Jobs {
		if j.TargetID == id && ((j.Stage != "completed" && j.Stage != "cancelled") || !j.RelayClean || !j.NASClean) {
			return true
		}
	}
	return false
}
func (s *Store) SaveTarget(input TargetInput) (result Target, resultErr error) {
	var credentialPath string
	var previousCredential []byte
	var previousExists bool
	s.management.Lock()
	defer s.management.Unlock()
	defer func() {
		if resultErr != nil && credentialPath != "" {
			if previousExists {
				_ = os.WriteFile(credentialPath, previousCredential, 0600)
			} else {
				_ = os.Remove(credentialPath)
			}
		}
	}()
	t := input.Target
	if t.ID == "" {
		t.ID = NewID()
	}
	if t.Protocol == "nfs" && t.NFSVersion == "" {
		t.NFSVersion = "4.2"
	}
	if err := ValidateTarget(t); err != nil {
		return t, err
	}
	old, exists := s.Target(t.ID)
	if exists && s.TargetInUse(t.ID) {
		return t, errors.New("target is used by unfinished jobs; finish or cancel them first")
	}
	if input.Password != "" && strings.ContainsAny(input.Password, "\x00\r\n") {
		return t, errors.New("credential contains unsupported line breaks")
	}
	if t.Protocol == "smb" {
		cred := filepath.Join(s.Root, "credentials", t.ID)
		if input.Password == "" {
			if !exists || !old.HasCredentials {
				return t, errors.New("SMB password required")
			}
			if t.Username != old.Username || t.Domain != old.Domain {
				return t, errors.New("re-enter password when changing SMB account")
			}
		}
		if input.Password != "" {
			previousCredential, resultErr = os.ReadFile(cred)
			previousExists = resultErr == nil
			if resultErr != nil && !os.IsNotExist(resultErr) {
				return t, resultErr
			}
			credentialPath = cred
			contents := "username=" + t.Username + "\npassword=" + input.Password + "\ndomain=" + t.Domain + "\n"
			if err := os.WriteFile(cred, []byte(contents), 0600); err != nil {
				return t, err
			}
			if err := os.Chmod(cred, 0600); err != nil {
				return t, err
			}
		}
		t.HasCredentials = true
	}
	if exists {
		point := s.mountPoint(t.ID)
		if source, _, _ := actualMount(point); source != "" {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			if b, err := exec.CommandContext(ctx, "umount", point).CombinedOutput(); err != nil {
				return t, fmt.Errorf("target busy: %s", strings.TrimSpace(string(b)))
			}
		}
	}
	err := s.SaveConfig(func(c *Config) error {
		for i, v := range c.Targets {
			if v.ID == t.ID {
				c.Targets[i] = t
				return nil
			}
		}
		c.Targets = append(c.Targets, t)
		if c.DefaultTarget == "" {
			c.DefaultTarget = t.ID
		}
		return nil
	})
	return t, err
}
func (s *Store) DeleteTarget(id string) error {
	s.management.Lock()
	defer s.management.Unlock()
	if s.TargetInUse(id) {
		return errors.New("target is used by unfinished jobs")
	}
	t, ok := s.Target(id)
	if !ok {
		return os.ErrNotExist
	}
	_ = t
	point := s.mountPoint(id)
	if source, _, _ := actualMount(point); source != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if err := exec.CommandContext(ctx, "umount", point).Run(); err != nil {
			return err
		}
	}
	if err := s.SaveConfig(func(c *Config) error {
		out := []Target{}
		for _, v := range c.Targets {
			if v.ID != id {
				out = append(out, v)
			}
		}
		c.Targets = out
		if c.DefaultTarget == id {
			c.DefaultTarget = ""
		}
		return nil
	}); err != nil {
		return err
	}
	_ = os.Remove(filepath.Join(s.Root, "credentials", id))
	return nil
}
func ensureDirs(base, relative string) (string, error) {
	if !safePath(relative, true) {
		return "", errors.New("unsafe destination path")
	}
	current := base
	for _, component := range strings.Split(relative, "/") {
		if component == "" {
			continue
		}
		current = filepath.Join(current, component)
		info, err := os.Lstat(current)
		if os.IsNotExist(err) {
			if err = os.Mkdir(current, 0770); err != nil {
				return "", err
			}
			continue
		}
		if err != nil {
			return "", err
		}
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return "", errors.New("destination contains symlink or non-directory")
		}
	}
	return current, nil
}
func freeSpace(p string) (int64, error) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(p, &stat); err != nil {
		return 0, err
	}
	return int64(stat.Bavail) * int64(stat.Bsize), nil
}
func (s *Store) TestTarget(t Target) (map[string]any, error) {
	s.management.RLock()
	defer s.management.RUnlock()
	start := time.Now()
	point, err := s.EnsureMount(t)
	if err != nil {
		return nil, err
	}
	root, err := ensureDirs(point, t.DefaultFolder)
	if err != nil {
		return nil, err
	}
	test, err := os.MkdirTemp(root, ".nas-relay-test-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(test)
	a, b := filepath.Join(test, "data"), filepath.Join(test, "link")
	data := []byte("NAS relay write/fsync/read/link verification\n")
	f, err := os.OpenFile(a, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0660)
	if err != nil {
		return nil, err
	}
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	_ = f.Close()
	if err != nil {
		return nil, err
	}
	if err = os.Link(a, b); err != nil {
		return nil, fmt.Errorf("NAS must support hard links for safe publication: %w", err)
	}
	h, err := hashFile(b, nil, nil)
	if err != nil {
		return nil, fmt.Errorf("NAS verification failed: %w", err)
	}
	if h != Hash(data) {
		return nil, errors.New("NAS verification SHA-256 mismatch")
	}
	free, err := freeSpace(root)
	if err != nil {
		return nil, err
	}
	return map[string]any{"ok": true, "free_bytes": free, "latency_ms": float64(time.Since(start).Microseconds()) / 1000, "protocol": t.Protocol}, nil
}
