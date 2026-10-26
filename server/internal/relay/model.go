package relay

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

const Version = "0.4.0"
const ChunkSize int64 = 8 << 20

var idPattern = regexp.MustCompile(`^[a-f0-9]{32}$`)
var hashPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)
var ErrPaused = errors.New("task paused")
var ErrCancelled = errors.New("task cancelled")

type Entry struct {
	Path     string            `json:"path"`
	Type     string            `json:"type"`
	Size     int64             `json:"size,omitempty"`
	SHA256   string            `json:"sha256,omitempty"`
	Mtime    int64             `json:"mtime,omitempty"`
	Metadata map[string]string `json:"metadata,omitempty"`
}
type Manifest struct {
	ID              string  `json:"id"`
	Name            string  `json:"name"`
	TargetID        string  `json:"target_id"`
	Folder          string  `json:"folder"`
	Entries         []Entry `json:"entries"`
	CollisionPolicy string  `json:"collision_policy,omitempty"`
}
type Job struct {
	ID              string   `json:"id"`
	Owner           string   `json:"owner"`
	Name            string   `json:"name"`
	TargetID        string   `json:"target_id"`
	Folder          string   `json:"folder"`
	ManifestSHA     string   `json:"manifest_sha256"`
	Stage           string   `json:"stage"`
	Action          string   `json:"action"`
	ResumeStage     string   `json:"resume_stage,omitempty"`
	Accepted        bool     `json:"accepted"`
	Bytes           int64    `json:"bytes"`
	Done            int64    `json:"bytes_done"`
	Total           int64    `json:"bytes_total"`
	Speed           float64  `json:"speed_bps"`
	ETA             *float64 `json:"eta_seconds"`
	Error           string   `json:"error,omitempty"`
	Created         int64    `json:"created"`
	Updated         int64    `json:"updated"`
	RetryAt         int64    `json:"retry_at,omitempty"`
	RelayClean      bool     `json:"relay_clean"`
	NASClean        bool     `json:"nas_clean"`
	DuplicateChoice string   `json:"duplicate_choice,omitempty"`
	ArchiveName     string   `json:"archive_name,omitempty"`
	Published       bool     `json:"published,omitempty"`
	CleanupError    string   `json:"cleanup_error,omitempty"`
}
type Target struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	Protocol       string `json:"protocol"`
	Host           string `json:"host"`
	Share          string `json:"share"`
	Export         string `json:"export"`
	NFSVersion     string `json:"nfs_version"`
	Username       string `json:"username,omitempty"`
	Domain         string `json:"domain,omitempty"`
	DefaultFolder  string `json:"default_folder"`
	HasCredentials bool   `json:"has_credentials"`
	Enabled        bool   `json:"enabled"`
}
type TargetInput struct {
	Target
	Password string `json:"password,omitempty"`
}
type Client struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Role      string `json:"role"`
	TokenHash string `json:"token_hash,omitempty"`
	Revoked   bool   `json:"revoked"`
	Created   int64  `json:"created"`
}
type Config struct {
	ID            string   `json:"id"`
	Name          string   `json:"name"`
	Endpoints     []string `json:"endpoints"`
	DefaultTarget string   `json:"default_target"`
	DefaultFolder string   `json:"default_folder"`
	ReserveBytes  int64    `json:"reserve_bytes"`
	Workers       int      `json:"workers"`
	Clients       []Client `json:"clients"`
	Targets       []Target `json:"targets"`
}
type Connection struct {
	Schema      int      `json:"schema"`
	ServerID    string   `json:"server_id"`
	Name        string   `json:"name"`
	Endpoints   []string `json:"endpoints"`
	Fingerprint string   `json:"fingerprint"`
	Certificate string   `json:"certificate"`
	Token       string   `json:"token"`
	ClientID    string   `json:"client_id"`
	Role        string   `json:"role"`
}
type Store struct {
	mu          sync.Mutex
	management  sync.RWMutex
	Root        string
	Config      Config
	Jobs        map[string]Job
	locks       sync.Map
	targetLocks sync.Map
}

func NewID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
func Hash(data []byte) string { h := sha256.Sum256(data); return hex.EncodeToString(h[:]) }
func atomicJSON(p string, value any) error {
	if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(p), ".state-*")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	if err = json.NewEncoder(f).Encode(value); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = os.Rename(name, p); err != nil {
		return err
	}
	return syncDir(filepath.Dir(p))
}
func syncDir(p string) error {
	f, err := os.Open(p)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}
func readJSON(p string, v any) error {
	b, err := os.ReadFile(p)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}
func Open(root string) (*Store, error) {
	root, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	for _, dir := range []string{"jobs", "mounts", "credentials", "receipts"} {
		if err = os.MkdirAll(filepath.Join(root, dir), 0700); err != nil {
			return nil, err
		}
	}
	s := &Store{Root: root, Jobs: map[string]Job{}}
	if err = readJSON(filepath.Join(root, "config.json"), &s.Config); err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(filepath.Join(root, "jobs"))
	if err != nil {
		return nil, err
	}
	for _, e := range entries {
		if !e.IsDir() || !idPattern.MatchString(e.Name()) {
			continue
		}
		var j Job
		if err := readJSON(s.jobPath(e.Name(), "state.json"), &j); err != nil {
			return nil, fmt.Errorf("load job %s: %w", e.Name(), err)
		}
		// Recover from process interruption, preserving explicit pause/cancel intent.
		if j.Action == "paused" {
			if j.Stage != "awaiting_duplicate" {
				j.Stage = "paused"
			}
			j.Speed = 0
			j.ETA = nil
		} else if j.Action == "cancelled" && j.Stage != "completed" {
			j.Stage = "cancelling"
		} else if j.Stage != "completed" && j.Stage != "cancelled" && j.Stage != "receiving" && j.Stage != "failed" && j.Stage != "conflict" {
			if j.Accepted {
				j.Stage = "queued"
			} else {
				j.Stage = "verifying_receive"
			}
		}
		s.Jobs[j.ID] = j
	}
	return s, nil
}
func (s *Store) jobPath(id string, parts ...string) string {
	p := []string{s.Root, "jobs", id}
	return filepath.Join(append(p, parts...)...)
}
func (s *Store) lock(id string) *sync.Mutex {
	v, _ := s.locks.LoadOrStore(id, &sync.Mutex{})
	return v.(*sync.Mutex)
}
func (s *Store) targetLock(id string) *sync.Mutex {
	v, _ := s.targetLocks.LoadOrStore(id, &sync.Mutex{})
	return v.(*sync.Mutex)
}
func (s *Store) Snapshot() Config {
	s.mu.Lock()
	defer s.mu.Unlock()
	var fresh Config
	if readJSON(filepath.Join(s.Root, "config.json"), &fresh) == nil {
		s.Config = fresh
	}
	b, _ := json.Marshal(s.Config)
	var c Config
	_ = json.Unmarshal(b, &c)
	return c
}
func (s *Store) Job(id string) (Job, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	j, ok := s.Jobs[id]
	return j, ok
}
func (s *Store) Update(id string, fn func(*Job) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	j, ok := s.Jobs[id]
	if !ok {
		return os.ErrNotExist
	}
	if err := fn(&j); err != nil {
		return err
	}
	j.Updated = time.Now().UnixMilli()
	if err := atomicJSON(s.jobPath(id, "state.json"), j); err != nil {
		return err
	}
	s.Jobs[id] = j
	return nil
}
func (s *Store) SaveConfig(fn func(*Config) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	lock, err := os.OpenFile(filepath.Join(s.Root, "config.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	var next Config
	if err = readJSON(filepath.Join(s.Root, "config.json"), &next); err != nil {
		return err
	}
	if err = fn(&next); err != nil {
		return err
	}
	if err = atomicJSON(filepath.Join(s.Root, "config.json"), next); err != nil {
		return err
	}
	s.Config = next
	return nil
}
func (s *Store) Manifest(id string) (Manifest, error) {
	var m Manifest
	err := readJSON(s.jobPath(id, "manifest.json"), &m)
	return m, err
}
func (s *Store) Check(id string) error {
	j, ok := s.Job(id)
	if !ok {
		return os.ErrNotExist
	}
	if j.Action == "cancelled" {
		return ErrCancelled
	}
	if j.Action == "paused" {
		return ErrPaused
	}
	return nil
}
func safePath(p string, allowEmpty bool) bool {
	if p == "" {
		return allowEmpty
	}
	if strings.HasPrefix(p, "/") || strings.ContainsAny(p, "\\\x00\r\n") {
		return false
	}
	for _, component := range strings.Split(p, "/") {
		if component == "" || component == "." || component == ".." || strings.HasPrefix(strings.ToLower(component), ".nas-relay") || strings.EqualFold(component, ".relay-partial") {
			return false
		}
	}
	return path.Clean(p) == p
}
func ValidateManifest(m Manifest) (int64, error) {
	if m.CollisionPolicy != "" && m.CollisionPolicy != "use-existing" && m.CollisionPolicy != "keep-both" {
		return 0, errors.New("invalid collision policy")
	}
	if !idPattern.MatchString(m.ID) || !safePath(m.Name, false) || strings.Contains(m.Name, "/") || !safePath(m.Folder, true) || !idPattern.MatchString(m.TargetID) || len(m.Entries) == 0 || len(m.Entries) > 100000 {
		return 0, errors.New("invalid manifest")
	}
	seen := map[string]Entry{}
	var total int64
	for _, e := range m.Entries {
		if !safePath(e.Path, false) || (e.Path != m.Name && !strings.HasPrefix(e.Path, m.Name+"/")) || (e.Type != "file" && e.Type != "dir") {
			return 0, errors.New("invalid manifest path")
		}
		key := strings.ToLower(e.Path)
		if _, ok := seen[key]; ok {
			return 0, errors.New("duplicate path")
		}
		seen[key] = e
		if e.Type == "file" {
			if e.Size < 0 || e.Size > 1<<60 || !hashPattern.MatchString(e.SHA256) || total > (1<<60)-e.Size {
				return 0, errors.New("invalid file digest/size")
			}
			total += e.Size
		}
	}
	if _, ok := seen[strings.ToLower(m.Name)]; !ok {
		return 0, errors.New("missing top-level entry")
	}
	for _, e := range m.Entries {
		if e.Path == m.Name {
			continue
		}
		parent, ok := seen[strings.ToLower(path.Dir(e.Path))]
		if !ok || parent.Type != "dir" {
			return 0, errors.New("missing parent directory")
		}
	}
	return total, nil
}
func hashFile(p string, check func() error, progress func(int64)) (string, error) {
	info, err := os.Lstat(p)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "", errors.New("not a regular file")
	}
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	buf := make([]byte, 256<<10)
	for {
		if check != nil {
			if err := check(); err != nil {
				return "", err
			}
		}
		n, err := f.Read(buf)
		if n > 0 {
			_, _ = h.Write(buf[:n])
			if progress != nil {
				progress(int64(n))
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", err
		}
	}
	after, err := f.Stat()
	if err != nil {
		return "", err
	}
	if info.Size() != after.Size() || !info.ModTime().Equal(after.ModTime()) {
		return "", errors.New("file changed while hashing")
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
