package relay

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
)

type fixture struct {
	s                    *Store
	a                    *Server
	http                 *httptest.Server
	admin, first, second Connection
	target               Target
	nas                  string
}

func setup(t *testing.T) *fixture {
	t.Helper()
	s, err := Initialize(t.TempDir(), "Test relay", []string{"https://127.0.0.1:8743"})
	if err != nil {
		t.Fatal(err)
	}
	admin, err := s.AddClient("Admin", "admin")
	if err != nil {
		t.Fatal(err)
	}
	first, _ := s.AddClient("First", "client")
	second, _ := s.AddClient("Second", "client")
	target := Target{ID: NewID(), Name: "NAS", Protocol: "nfs", Host: "127.0.0.1", Export: "/archive", NFSVersion: "4.2", Enabled: true}
	err = s.SaveConfig(func(c *Config) error {
		c.ReserveBytes = 0
		c.DefaultTarget = target.ID
		c.Targets = []Target{target}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	a := NewServer(s)
	nas := t.TempDir()
	a.ResolveTarget = func(Target) (string, error) { return nas, nil }
	h := httptest.NewServer(a.Handler())
	t.Cleanup(h.Close)
	return &fixture{s: s, a: a, http: h, admin: admin, first: first, second: second, target: target, nas: nas}
}
func (f *fixture) request(t *testing.T, token, method, path string, body any, headers map[string]string) (int, []byte) {
	t.Helper()
	var data []byte
	if body != nil {
		switch b := body.(type) {
		case []byte:
			data = b
		default:
			data, _ = json.Marshal(body)
		}
	}
	req, _ := http.NewRequest(method, f.http.URL+path, bytes.NewReader(data))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	r, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Body.Close()
	b, _ := io.ReadAll(r.Body)
	return r.StatusCode, b
}
func (f *fixture) manifest(data []byte) Manifest {
	id := NewID()
	return Manifest{ID: id, Name: "Episode 素材", TargetID: f.target.ID, Folder: "Podcast", Entries: []Entry{{Path: "Episode 素材", Type: "dir"}, {Path: "Episode 素材/empty", Type: "dir"}, {Path: "Episode 素材/camera.mov", Type: "file", Size: int64(len(data)), SHA256: Hash(data)}}}
}
func (f *fixture) create(t *testing.T, m Manifest) {
	code, b := f.request(t, f.first.Token, "POST", "/v1/jobs", m, nil)
	if code != 201 {
		t.Fatalf("create %d %s", code, b)
	}
}
func (f *fixture) chunk(t *testing.T, m Manifest, offset int64, data []byte) (int, []byte) {
	return f.request(t, f.first.Token, "PUT", "/v1/jobs/"+m.ID+"/files/2", data, map[string]string{"Upload-Offset": strconv.FormatInt(offset, 10), "X-Chunk-SHA256": Hash(data)})
}
func (f *fixture) accept(t *testing.T, m Manifest, data []byte) {
	f.create(t, m)
	if len(data) > 0 {
		code, b := f.chunk(t, m, 0, data)
		if code != 200 {
			t.Fatalf("chunk %d %s", code, b)
		}
	}
	code, b := f.request(t, f.first.Token, "POST", "/v1/jobs/"+m.ID+"/commit", nil, nil)
	if code != 202 {
		t.Fatalf("commit %d %s", code, b)
	}
	f.a.work(m.ID)
	j, _ := f.s.Job(m.ID)
	if !j.Accepted || j.Stage != "queued" {
		t.Fatalf("not accepted: %+v", j)
	}
}
func TestVerifiedHandoffAndArchive(t *testing.T) {
	f := setup(t)
	data := bytes.Repeat([]byte("verified"), 100)
	m := f.manifest(data)
	f.accept(t, m, data)
	f.a.work(m.ID)
	j, _ := f.s.Job(m.ID)
	if j.Stage != "completed" {
		t.Fatalf("not completed: %+v", j)
	}
	b, err := os.ReadFile(filepath.Join(f.nas, m.Folder, m.Name, "camera.mov"))
	if err != nil || !bytes.Equal(b, data) {
		t.Fatal("NAS data mismatch", err)
	}
	if _, err = os.Stat(f.s.jobPath(m.ID, "payload")); !os.IsNotExist(err) {
		t.Fatal("relay payload not cleaned")
	}
	if _, err = os.Stat(filepath.Join(f.nas, m.Folder, ".nas-relay-receipts", m.ID+".json")); err != nil {
		t.Fatal(err)
	}
}
func TestClientIsolationAndAdminRoles(t *testing.T) {
	f := setup(t)
	m := f.manifest([]byte("data"))
	f.create(t, m)
	for _, path := range []string{"/v1/jobs/" + m.ID, "/v1/jobs/" + m.ID + "/upload"} {
		code, _ := f.request(t, f.second.Token, "GET", path, nil, nil)
		if code != 404 {
			t.Fatalf("private job exposed: %d", code)
		}
	}
	code, b := f.request(t, f.second.Token, "GET", "/v1/jobs", nil, nil)
	if code != 200 || strings.TrimSpace(string(b)) != "[]" {
		t.Fatal("other client can list job", string(b))
	}
	code, _ = f.request(t, f.first.Token, "POST", "/v1/targets", TargetInput{Target: f.target}, nil)
	if code != 403 {
		t.Fatal("non-admin can change mounts")
	}
	code, _ = f.request(t, "", "GET", "/v1/info", nil, nil)
	if code != 401 {
		t.Fatal("anonymous access")
	}
}
func TestBadChunkRollsBackAndPartialCannotCommit(t *testing.T) {
	f := setup(t)
	data := []byte("correct data")
	m := f.manifest(data)
	f.create(t, m)
	code, _ := f.request(t, f.first.Token, "PUT", "/v1/jobs/"+m.ID+"/files/2", data, map[string]string{"Upload-Offset": "0", "X-Chunk-SHA256": Hash([]byte("other"))})
	if code != 422 {
		t.Fatal(code)
	}
	info, _ := os.Stat(f.s.jobPath(m.ID, "payload", m.Entries[2].Path))
	if info.Size() != 0 {
		t.Fatal("bad bytes retained as acknowledged data")
	}
	code, _ = f.request(t, f.first.Token, "POST", "/v1/jobs/"+m.ID+"/commit", nil, nil)
	if code != 409 {
		t.Fatal("partial handoff accepted")
	}
}
func TestCrashTailIsTruncatedToDurableChunkJournal(t *testing.T) {
	f := setup(t)
	data := []byte("first-second")
	m := f.manifest(data)
	f.create(t, m)
	if code, b := f.chunk(t, m, 0, data[:5]); code != 200 {
		t.Fatal(code, string(b))
	}
	p := f.s.jobPath(m.ID, "payload", m.Entries[2].Path)
	out, _ := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0600)
	_, _ = out.Write([]byte("uncommitted crash tail"))
	_ = out.Close()
	code, b := f.request(t, f.first.Token, "GET", "/v1/jobs/"+m.ID+"/upload", nil, nil)
	if code != 200 {
		t.Fatal(string(b))
	}
	info, _ := os.Stat(p)
	if info.Size() != 5 {
		t.Fatal("unverified tail exposed as resume offset")
	}
	if code, b = f.chunk(t, m, 5, data[5:]); code != 200 {
		t.Fatal(code, string(b))
	}
	code, _ = f.request(t, f.first.Token, "POST", "/v1/jobs/"+m.ID+"/commit", nil, nil)
	if code != 202 {
		t.Fatal(code)
	}
	f.a.work(m.ID)
	j, _ := f.s.Job(m.ID)
	if !j.Accepted {
		t.Fatal("resumed bytes rejected")
	}
}
func TestPauseResumeAndCancellation(t *testing.T) {
	f := setup(t)
	data := []byte("pause and resume")
	m := f.manifest(data)
	f.create(t, m)
	code, _ := f.chunk(t, m, 0, data[:4])
	if code != 200 {
		t.Fatal(code)
	}
	code, _ = f.request(t, f.first.Token, "POST", "/v1/jobs/"+m.ID+"/pause", nil, nil)
	if code != 200 {
		t.Fatal(code)
	}
	code, _ = f.chunk(t, m, 4, data[4:])
	if code != 409 {
		t.Fatal("paused upload accepted")
	}
	_, _ = f.request(t, f.first.Token, "POST", "/v1/jobs/"+m.ID+"/resume", nil, nil)
	code, b := f.chunk(t, m, 4, data[4:])
	if code != 200 {
		t.Fatal(code, string(b))
	}
	_, _ = f.request(t, f.first.Token, "POST", "/v1/jobs/"+m.ID+"/cancel", nil, nil)
	f.a.work(m.ID)
	j, _ := f.s.Job(m.ID)
	if j.Stage != "cancelled" {
		t.Fatal(j.Stage)
	}
	if _, err := os.Stat(f.s.jobPath(m.ID, "payload")); !os.IsNotExist(err) {
		t.Fatal("cancel did not clean temporary payload")
	}
	if _, err := os.Stat(filepath.Join(f.nas, m.Folder, m.Name)); !os.IsNotExist(err) {
		t.Fatal("cancel wrote to NAS")
	}
}
func TestNASFailureRetainsAndRetries(t *testing.T) {
	f := setup(t)
	data := []byte("retry data")
	m := f.manifest(data)
	f.accept(t, m, data)
	f.a.ResolveTarget = func(Target) (string, error) { return "", errors.New("offline") }
	f.a.work(m.ID)
	j, _ := f.s.Job(m.ID)
	if j.Stage != "retry_pending" {
		t.Fatal(j.Stage)
	}
	if _, err := os.Stat(f.s.jobPath(m.ID, "payload")); err != nil {
		t.Fatal("source lost")
	}
	f.a.ResolveTarget = func(Target) (string, error) { return f.nas, nil }
	f.a.work(m.ID)
	j, _ = f.s.Job(m.ID)
	if j.Stage != "completed" {
		t.Fatal(j)
	}
}
func TestConflictingArchiveNeverOverwritten(t *testing.T) {
	f := setup(t)
	data := []byte("new material")
	m := f.manifest(data)
	f.accept(t, m, data)
	p := filepath.Join(f.nas, m.Folder, m.Name)
	_ = os.MkdirAll(p, 0700)
	_ = os.WriteFile(filepath.Join(p, "existing.txt"), []byte("keep"), 0600)
	f.a.work(m.ID)
	j, _ := f.s.Job(m.ID)
	if j.Stage != "awaiting_duplicate" {
		t.Fatal(j)
	}
	code, body := f.request(t, f.first.Token, "POST", "/v1/jobs/"+m.ID+"/use-existing", nil, nil)
	if code != 200 {
		t.Fatalf("confirm %d %s", code, body)
	}
	f.a.work(m.ID)
	j, _ = f.s.Job(m.ID)
	if j.Stage != "conflict" {
		t.Fatal(j)
	}
	b, _ := os.ReadFile(filepath.Join(p, "existing.txt"))
	if string(b) != "keep" {
		t.Fatal("existing data changed")
	}
	if _, err := os.Stat(f.s.jobPath(m.ID, "payload")); err != nil {
		t.Fatal("conflicting source removed")
	}
}
func TestCLIClientsAndRevocationAreVisibleWithoutRestart(t *testing.T) {
	f := setup(t)
	other, err := Open(f.s.Root)
	if err != nil {
		t.Fatal(err)
	}
	newClient, err := other.AddClient("Created by CLI", "client")
	if err != nil {
		t.Fatal(err)
	}
	code, _ := f.request(t, newClient.Token, "GET", "/v1/info", nil, nil)
	if code != 200 {
		t.Fatal("new CLI token not live")
	}
	err = other.SaveConfig(func(c *Config) error {
		for i := range c.Clients {
			if c.Clients[i].ID == newClient.ClientID {
				c.Clients[i].Revoked = true
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	code, _ = f.request(t, newClient.Token, "GET", "/v1/info", nil, nil)
	if code != 401 {
		t.Fatal("revoked client still accepted")
	}
}
func TestTraversalAndSymlinkRejected(t *testing.T) {
	f := setup(t)
	m := f.manifest([]byte("x"))
	m.Entries[2].Path = "../outside"
	code, _ := f.request(t, f.first.Token, "POST", "/v1/jobs", m, nil)
	if code != 400 {
		t.Fatal("traversal accepted")
	}
	base := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(base, "escape")); err != nil {
		t.Fatal(err)
	}
	if _, err := ensureDirs(base, "escape/sub"); err == nil {
		t.Fatal("NAS symlink followed")
	}
}
func TestConcurrentDuplicateChunkIsNotDoubleCounted(t *testing.T) {
	f := setup(t)
	data := []byte("one chunk")
	m := f.manifest(data)
	f.create(t, m)
	var wg sync.WaitGroup
	codes := make(chan int, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); code, _ := f.chunk(t, m, 0, data); codes <- code }()
	}
	wg.Wait()
	close(codes)
	success := 0
	for c := range codes {
		if c == 200 {
			success++
		} else if c != 409 {
			t.Fatal(c)
		}
	}
	j, _ := f.s.Job(m.ID)
	if success != 1 || j.Done != int64(len(data)) {
		t.Fatal("chunk counted more than once", j.Done)
	}
}
func TestCorruptRelayPayloadNeverCleared(t *testing.T) {
	f := setup(t)
	data := []byte("original")
	m := f.manifest(data)
	f.accept(t, m, data)
	_ = os.WriteFile(f.s.jobPath(m.ID, "payload", m.Entries[2].Path), []byte("damaged!"), 0600)
	f.a.work(m.ID)
	j, _ := f.s.Job(m.ID)
	if j.Stage != "failed" {
		t.Fatal(j)
	}
	if _, err := os.Stat(f.s.jobPath(m.ID, "payload")); err != nil {
		t.Fatal("damaged source removed")
	}
}
func TestRestartPreservesPauseAndDurableOffsets(t *testing.T) {
	f := setup(t)
	data := []byte("restart upload")
	m := f.manifest(data)
	f.create(t, m)
	_, _ = f.chunk(t, m, 0, data[:3])
	_, _ = f.request(t, f.first.Token, "POST", "/v1/jobs/"+m.ID+"/pause", nil, nil)
	restored, err := Open(f.s.Root)
	if err != nil {
		t.Fatal(err)
	}
	j, _ := restored.Job(m.ID)
	if j.Stage != "paused" || j.Action != "paused" {
		t.Fatal(j)
	}
	offset, err := restored.normalizeUpload(m.ID, 2, m.Entries[2])
	if err != nil || offset != 3 {
		t.Fatal(offset, err)
	}
}

func TestCompletedCleanupSurvivesRestart(t *testing.T) {
	f := setup(t)
	data := []byte("keep verified archive")
	m := f.manifest(data)
	f.accept(t, m, data)
	f.a.work(m.ID)
	// Simulate a crash after completion was saved but before private payload cleanup.
	if err := os.MkdirAll(f.s.jobPath(m.ID, "payload"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(f.s.jobPath(m.ID, "payload", "remaining"), data, 0600); err != nil {
		t.Fatal(err)
	}
	_ = f.s.Update(m.ID, func(j *Job) error { j.RelayClean = false; j.NASClean = false; return nil })
	if err := f.a.cleanupFinished(m.ID, "", true); err != nil {
		t.Fatal(err)
	}
	j, _ := f.s.Job(m.ID)
	if j.Stage != "completed" || !j.RelayClean || !j.NASClean {
		t.Fatalf("cleanup state: %+v", j)
	}
	if _, err := os.Stat(f.s.jobPath(m.ID, "payload")); !os.IsNotExist(err) {
		t.Fatal("payload retained")
	}
	if got, err := os.ReadFile(filepath.Join(f.nas, m.Folder, m.Name, "camera.mov")); err != nil || !bytes.Equal(got, data) {
		t.Fatal("published file changed", err)
	}
}
func TestCleanupFailureKeepsCompletion(t *testing.T) {
	f := setup(t)
	data := []byte("archive")
	m := f.manifest(data)
	f.accept(t, m, data)
	// An unsafe staging cleanup path fails after final publication and receipt.
	parent := filepath.Join(f.nas, m.Folder, ".nas-relay-staging")
	f.a.work(m.ID)
	if err := os.Remove(parent); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(t.TempDir(), parent); err != nil {
		t.Fatal(err)
	}
	_ = f.s.Update(m.ID, func(j *Job) error { j.NASClean = false; return nil })
	if err := f.a.cleanupFinished(m.ID, "", true); err == nil {
		t.Fatal("unsafe path accepted")
	}
	j, _ := f.s.Job(m.ID)
	if j.Stage != "completed" {
		t.Fatal("lost completion")
	}
}
