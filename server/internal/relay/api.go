package relay

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type principalKey struct{}
type Server struct {
	Store         *Store
	ResolveTarget func(Target) (string, error)
	active        sync.Map
	ingest        chan struct{}
	archive       chan struct{}
	cleanup       chan struct{}
}

func NewServer(s *Store) *Server {
	workers := s.Snapshot().Workers
	if workers < 1 {
		workers = 1
	}
	return &Server{Store: s, ResolveTarget: s.EnsureMount, ingest: make(chan struct{}, 1), archive: make(chan struct{}, workers), cleanup: make(chan struct{}, 1)}
}
func write(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
func problem(w http.ResponseWriter, status int, err error) {
	write(w, status, map[string]string{"error": err.Error()})
}
func decode(w http.ResponseWriter, r *http.Request, v any) error {
	r.Body = http.MaxBytesReader(w, r.Body, 16<<20)
	d := json.NewDecoder(r.Body)
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		return err
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return errors.New("only one JSON document is allowed")
	}
	return nil
}
func principal(r *http.Request) Client { return r.Context().Value(principalKey{}).(Client) }
func admin(w http.ResponseWriter, r *http.Request) bool {
	if principal(r).Role != "admin" {
		problem(w, 403, errors.New("administrator permission required"))
		return false
	}
	return true
}
func (a *Server) Handler() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /v1/ping", func(w http.ResponseWriter, r *http.Request) {
		c := a.Store.Snapshot()
		p := principal(r)
		write(w, 200, map[string]any{"server_id": c.ID, "name": c.Name, "version": Version, "client_id": p.ID, "role": p.Role})
	})
	m.HandleFunc("GET /v1/info", a.info)
	m.HandleFunc("PUT /v1/settings", a.settings)
	m.HandleFunc("GET /v1/targets", func(w http.ResponseWriter, r *http.Request) { write(w, 200, a.Store.Snapshot().Targets) })
	m.HandleFunc("POST /v1/targets", a.saveTarget)
	m.HandleFunc("PUT /v1/targets/{id}", a.saveTarget)
	m.HandleFunc("DELETE /v1/targets/{id}", func(w http.ResponseWriter, r *http.Request) {
		if !admin(w, r) {
			return
		}
		if err := a.Store.DeleteTarget(r.PathValue("id")); err != nil {
			problem(w, 409, err)
			return
		}
		write(w, 200, map[string]bool{"ok": true})
	})
	m.HandleFunc("POST /v1/targets/{id}/test", func(w http.ResponseWriter, r *http.Request) {
		if !admin(w, r) {
			return
		}
		t, ok := a.Store.Target(r.PathValue("id"))
		if !ok {
			problem(w, 404, os.ErrNotExist)
			return
		}
		result, err := a.Store.TestTarget(t)
		if err != nil {
			problem(w, 422, err)
			return
		}
		write(w, 200, result)
	})
	m.HandleFunc("GET /v1/clients", func(w http.ResponseWriter, r *http.Request) {
		if !admin(w, r) {
			return
		}
		clients := a.Store.Snapshot().Clients
		for i := range clients {
			clients[i].TokenHash = ""
		}
		write(w, 200, clients)
	})
	m.HandleFunc("POST /v1/clients", func(w http.ResponseWriter, r *http.Request) {
		if !admin(w, r) {
			return
		}
		var body struct {
			Name string `json:"name"`
			Role string `json:"role"`
		}
		if err := decode(w, r, &body); err != nil {
			problem(w, 400, err)
			return
		}
		c, err := a.Store.AddClient(body.Name, body.Role)
		if err != nil {
			problem(w, 400, err)
			return
		}
		write(w, 201, map[string]any{"connection": c, "uri": ConnectionURI(c)})
	})
	m.HandleFunc("DELETE /v1/clients/{id}", func(w http.ResponseWriter, r *http.Request) {
		if !admin(w, r) {
			return
		}
		if r.PathValue("id") == principal(r).ID {
			problem(w, 409, errors.New("cannot revoke the current administrator connection"))
			return
		}
		err := a.Store.SaveConfig(func(c *Config) error {
			for i := range c.Clients {
				if c.Clients[i].ID == r.PathValue("id") {
					c.Clients[i].Revoked = true
					return nil
				}
			}
			return os.ErrNotExist
		})
		if err != nil {
			problem(w, 404, err)
			return
		}
		write(w, 200, map[string]bool{"ok": true})
	})
	m.HandleFunc("GET /v1/jobs", a.listJobs)
	m.HandleFunc("POST /v1/jobs", a.createJob)
	m.HandleFunc("GET /v1/jobs/{id}", func(w http.ResponseWriter, r *http.Request) {
		j, ok := a.authorizedJob(w, r)
		if ok {
			write(w, 200, j)
		}
	})
	m.HandleFunc("GET /v1/jobs/{id}/upload", a.uploadStatus)
	m.HandleFunc("PUT /v1/jobs/{id}/files/{index}", a.uploadChunk)
	m.HandleFunc("POST /v1/jobs/{id}/commit", a.commit)
	m.HandleFunc("POST /v1/jobs/{id}/{action}", a.control)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Strict-Transport-Security", "max-age=31536000")
		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, "Bearer ") || len(header) > 256 {
			problem(w, 401, errors.New("valid client token required"))
			return
		}
		c, ok := a.Store.Authenticate(strings.TrimPrefix(header, "Bearer "))
		if !ok {
			problem(w, 401, errors.New("invalid or revoked client token"))
			return
		}
		m.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), principalKey{}, c)))
	})
}
func (a *Server) info(w http.ResponseWriter, r *http.Request) {
	c := a.Store.Snapshot()
	free, _ := freeSpace(a.Store.Root)
	write(w, 200, map[string]any{"server_id": c.ID, "name": c.Name, "version": Version, "endpoints": c.Endpoints, "role": principal(r).Role, "client_id": principal(r).ID, "default_target": c.DefaultTarget, "default_folder": c.DefaultFolder, "free_bytes": free, "reserve_bytes": c.ReserveBytes, "chunk_size": ChunkSize})
}
func (a *Server) settings(w http.ResponseWriter, r *http.Request) {
	if !admin(w, r) {
		return
	}
	var b struct {
		DefaultTarget string `json:"default_target"`
		DefaultFolder string `json:"default_folder"`
	}
	if err := decode(w, r, &b); err != nil {
		problem(w, 400, err)
		return
	}
	if !safePath(b.DefaultFolder, true) {
		problem(w, 400, errors.New("invalid default folder"))
		return
	}
	if b.DefaultTarget != "" {
		if _, ok := a.Store.Target(b.DefaultTarget); !ok {
			problem(w, 400, errors.New("unknown default target"))
			return
		}
	}
	err := a.Store.SaveConfig(func(c *Config) error {
		c.DefaultTarget = b.DefaultTarget
		c.DefaultFolder = b.DefaultFolder
		return nil
	})
	if err != nil {
		problem(w, 500, err)
		return
	}
	write(w, 200, map[string]bool{"ok": true})
}
func (a *Server) saveTarget(w http.ResponseWriter, r *http.Request) {
	if !admin(w, r) {
		return
	}
	var b TargetInput
	if err := decode(w, r, &b); err != nil {
		problem(w, 400, err)
		return
	}
	if id := r.PathValue("id"); id != "" {
		b.ID = id
	}
	t, err := a.Store.SaveTarget(b)
	if err != nil {
		problem(w, 409, err)
		return
	}
	write(w, 200, t)
}
func (a *Server) authorizedJob(w http.ResponseWriter, r *http.Request) (Job, bool) {
	j, ok := a.Store.Job(r.PathValue("id"))
	p := principal(r)
	if !ok || (j.Owner != p.ID && p.Role != "admin") {
		problem(w, 404, os.ErrNotExist)
		return Job{}, false
	}
	return j, true
}
func (a *Server) listJobs(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	all := p.Role == "admin" && r.URL.Query().Get("all") == "true"
	a.Store.mu.Lock()
	jobs := []Job{}
	for _, j := range a.Store.Jobs {
		if all || j.Owner == p.ID {
			jobs = append(jobs, j)
		}
	}
	a.Store.mu.Unlock()
	sort.Slice(jobs, func(i, j int) bool { return jobs[i].Created > jobs[j].Created })
	write(w, 200, jobs)
}
func (a *Server) createJob(w http.ResponseWriter, r *http.Request) {
	a.Store.management.RLock()
	defer a.Store.management.RUnlock()
	var m Manifest
	if err := decode(w, r, &m); err != nil {
		problem(w, 400, err)
		return
	}
	if m.TargetID == "" {
		m.TargetID = a.Store.Snapshot().DefaultTarget
	}
	total, err := ValidateManifest(m)
	if err != nil {
		problem(w, 400, err)
		return
	}
	t, ok := a.Store.Target(m.TargetID)
	if !ok || !t.Enabled {
		problem(w, 400, errors.New("target is missing or disabled"))
		return
	}
	lock := a.Store.lock(m.ID)
	lock.Lock()
	defer lock.Unlock()
	b, _ := json.Marshal(m)
	digest := Hash(b)
	if old, ok := a.Store.Job(m.ID); ok {
		if old.Owner != principal(r).ID || old.ManifestSHA != digest {
			problem(w, 409, errors.New("job id already belongs to a different request"))
			return
		}
		write(w, 200, old)
		return
	}
	a.Store.mu.Lock()
	defer a.Store.mu.Unlock()
	free, err := freeSpace(a.Store.Root)
	if err != nil {
		problem(w, 500, err)
		return
	}
	reserved := int64(0)
	for _, j := range a.Store.Jobs {
		if !j.Accepted && j.Stage != "cancelled" && j.Stage != "failed" {
			remaining := j.Bytes - j.Done
			if remaining > 0 {
				reserved += remaining
			}
		}
	}
	if free-a.Store.Config.ReserveBytes-reserved < total {
		problem(w, 507, errors.New("insufficient relay space including reserved uploads"))
		return
	}
	root := a.Store.jobPath(m.ID, "payload")
	if err = os.MkdirAll(root, 0700); err != nil {
		problem(w, 500, err)
		return
	}
	for _, e := range m.Entries {
		dir := filepath.Dir(e.Path)
		if e.Type == "dir" {
			dir = e.Path
		}
		if _, err = ensureDirs(root, dir); err != nil {
			problem(w, 500, err)
			return
		}
	}
	j := Job{ID: m.ID, Owner: principal(r).ID, Name: m.Name, TargetID: m.TargetID, Folder: m.Folder, ManifestSHA: digest, Stage: "receiving", Action: "running", Bytes: total, Total: total, Created: time.Now().UnixMilli(), Updated: time.Now().UnixMilli()}
	if err = atomicJSON(a.Store.jobPath(m.ID, "manifest.json"), m); err == nil {
		err = atomicJSON(a.Store.jobPath(m.ID, "state.json"), j)
	}
	if err != nil {
		problem(w, 500, err)
		return
	}
	a.Store.Jobs[m.ID] = j
	write(w, 201, j)
}
func (a *Server) uploadStatus(w http.ResponseWriter, r *http.Request) {
	j, ok := a.authorizedJob(w, r)
	if !ok {
		return
	}
	lock := a.Store.lock(j.ID)
	lock.Lock()
	defer lock.Unlock()
	m, err := a.Store.Manifest(j.ID)
	if err != nil {
		problem(w, 500, err)
		return
	}
	offsets := []map[string]any{}
	for i, e := range m.Entries {
		if e.Type != "file" {
			continue
		}
		offset := e.Size
		if !j.Accepted {
			var err error
			offset, err = a.Store.normalizeUpload(j.ID, i, e)
			if err != nil {
				problem(w, 500, err)
				return
			}
		}
		offsets = append(offsets, map[string]any{"index": i, "offset": offset, "size": e.Size})
	}
	write(w, 200, map[string]any{"files": offsets, "job": j})
}
func (a *Server) uploadChunk(w http.ResponseWriter, r *http.Request) {
	j, ok := a.authorizedJob(w, r)
	if !ok {
		return
	}
	if j.Accepted || j.Stage != "receiving" || j.Action != "running" {
		problem(w, 409, errors.New("job is not accepting data"))
		return
	}
	index, err := strconv.Atoi(r.PathValue("index"))
	m, e := a.Store.Manifest(j.ID)
	if err != nil || e != nil || index < 0 || index >= len(m.Entries) || m.Entries[index].Type != "file" {
		problem(w, 400, errors.New("invalid file index"))
		return
	}
	entry := m.Entries[index]
	offset, err := strconv.ParseInt(r.Header.Get("Upload-Offset"), 10, 64)
	length := r.ContentLength
	chunkHash := r.Header.Get("X-Chunk-SHA256")
	if err != nil || offset < 0 || length <= 0 || length > ChunkSize || offset > entry.Size-length || !hashPattern.MatchString(chunkHash) {
		problem(w, 400, errors.New("invalid chunk bounds or digest"))
		return
	}
	lock := a.Store.lock(j.ID)
	lock.Lock()
	defer lock.Unlock()
	if err = a.Store.Check(j.ID); err != nil {
		problem(w, 409, err)
		return
	}
	fresh, _ := a.Store.Job(j.ID)
	if fresh.Accepted || fresh.Stage != "receiving" {
		problem(w, 409, errors.New("handoff already started"))
		return
	}
	p := a.Store.jobPath(j.ID, "payload", entry.Path)
	confirmed, err := a.Store.normalizeUpload(j.ID, index, entry)
	if err != nil {
		problem(w, 500, err)
		return
	}
	if confirmed != offset {
		problem(w, 409, errors.New("upload offset changed; refresh upload status"))
		return
	}
	f, err := os.OpenFile(p, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		problem(w, 500, err)
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || info.Size() != offset {
		problem(w, 409, errors.New("upload offset changed; refresh upload status"))
		return
	}
	if _, err = f.Seek(offset, io.SeekStart); err != nil {
		problem(w, 500, err)
		return
	}
	committed := false
	defer func() {
		if !committed {
			_ = f.Truncate(offset)
			_ = f.Sync()
		}
	}()
	r.Body = http.MaxBytesReader(w, r.Body, ChunkSize)
	_ = http.NewResponseController(w).SetReadDeadline(time.Now().Add(15 * time.Minute))
	start := time.Now()
	hash := sha256.New()
	buf := make([]byte, 128<<10)
	written := int64(0)
	for written < length {
		if err = a.Store.Check(j.ID); err != nil {
			problem(w, 409, err)
			return
		}
		select {
		case <-r.Context().Done():
			return
		default:
		}
		want := int64(len(buf))
		if left := length - written; left < want {
			want = left
		}
		n, e := r.Body.Read(buf[:want])
		if n > 0 {
			if _, err = f.Write(buf[:n]); err != nil {
				problem(w, 500, err)
				return
			}
			_, _ = hash.Write(buf[:n])
			written += int64(n)
		}
		if e != nil {
			if e == io.EOF && written == length {
				break
			}
			problem(w, 400, errors.New("incomplete upload chunk"))
			return
		}
	}
	if hex.EncodeToString(hash.Sum(nil)) != chunkHash {
		problem(w, 422, errors.New("chunk checksum mismatch"))
		return
	}
	if err = f.Sync(); err != nil {
		problem(w, 500, err)
		return
	}
	if err = a.Store.Check(j.ID); err != nil {
		problem(w, 409, err)
		return
	}
	offsets, err := a.Store.uploadOffsets(j.ID)
	if err != nil {
		problem(w, 500, err)
		return
	}
	offsets[strconv.Itoa(index)] = offset + written
	if err = atomicJSON(a.Store.jobPath(j.ID, "upload.json"), offsets); err != nil {
		problem(w, 500, err)
		return
	}
	// Once the journal is durable, a lost response must not roll this chunk back.
	committed = true
	elapsed := time.Since(start).Seconds()
	speed := float64(written) / elapsed
	err = a.Store.Update(j.ID, func(v *Job) error {
		if v.Action != "running" {
			return ErrPaused
		}
		v.Done += written
		v.Speed = speed
		remaining := float64(v.Bytes-v.Done) / speed
		v.ETA = &remaining
		return nil
	})
	if err != nil {
		problem(w, 409, err)
		return
	}
	committed = true
	write(w, 200, map[string]int64{"offset": offset + written})
}

func (s *Store) uploadOffsets(id string) (map[string]int64, error) {
	values := map[string]int64{}
	err := readJSON(s.jobPath(id, "upload.json"), &values)
	if os.IsNotExist(err) {
		return values, nil
	}
	return values, err
}
func (s *Store) normalizeUpload(id string, index int, e Entry) (int64, error) {
	values, err := s.uploadOffsets(id)
	if err != nil {
		return 0, err
	}
	offset := values[strconv.Itoa(index)]
	if offset < 0 || offset > e.Size {
		return 0, errors.New("invalid upload journal")
	}
	p := s.jobPath(id, "payload", e.Path)
	info, err := os.Lstat(p)
	if os.IsNotExist(err) {
		if offset != 0 {
			return 0, errors.New("committed relay data is missing")
		}
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	if !info.Mode().IsRegular() || info.Size() < offset {
		return 0, errors.New("committed relay data is damaged")
	}
	if info.Size() > offset {
		f, err := os.OpenFile(p, os.O_WRONLY, 0600)
		if err != nil {
			return 0, err
		}
		defer f.Close()
		if err = f.Truncate(offset); err != nil {
			return 0, err
		}
		if err = f.Sync(); err != nil {
			return 0, err
		}
	}
	return offset, nil
}
func (a *Server) commit(w http.ResponseWriter, r *http.Request) {
	j, ok := a.authorizedJob(w, r)
	if !ok {
		return
	}
	lock := a.Store.lock(j.ID)
	lock.Lock()
	defer lock.Unlock()
	j, _ = a.Store.Job(j.ID)
	if j.Accepted {
		write(w, 200, j)
		return
	}
	if j.Action != "running" || j.Stage != "receiving" {
		problem(w, 409, errors.New("job is not ready for handoff"))
		return
	}
	m, err := a.Store.Manifest(j.ID)
	if err != nil {
		problem(w, 500, err)
		return
	}
	for _, e := range m.Entries {
		if e.Type == "file" {
			p := a.Store.jobPath(j.ID, "payload", e.Path)
			if e.Size == 0 {
				f, e2 := os.OpenFile(p, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
				if e2 == nil {
					_ = f.Sync()
					_ = f.Close()
				}
			}
			info, e2 := os.Stat(p)
			if e2 != nil || info.Size() != e.Size {
				problem(w, 409, errors.New("upload is incomplete"))
				return
			}
		}
	}
	err = a.Store.Update(j.ID, func(v *Job) error { v.Stage = "verifying_receive"; v.Done = 0; v.Speed = 0; v.ETA = nil; return nil })
	if err != nil {
		problem(w, 500, err)
		return
	}
	j, _ = a.Store.Job(j.ID)
	write(w, 202, j)
}
func (a *Server) control(w http.ResponseWriter, r *http.Request) {
	j, ok := a.authorizedJob(w, r)
	if !ok {
		return
	}
	action := r.PathValue("action")
	if action != "pause" && action != "resume" && action != "cancel" && action != "retry" {
		problem(w, 404, os.ErrNotExist)
		return
	}
	err := a.Store.Update(j.ID, func(v *Job) error {
		if v.Stage == "completed" || v.Stage == "cancelled" {
			return nil
		}
		switch action {
		case "pause":
			v.Action = "paused"
			v.ResumeStage = v.Stage
			v.Speed = 0
			v.ETA = nil
			if v.Stage == "receiving" || v.Stage == "queued" || v.Stage == "conflict" || v.Stage == "failed" {
				v.Stage = "paused"
			} else {
				v.Stage = "pausing"
			}
		case "resume", "retry":
			v.Action = "running"
			v.Error = ""
			v.RetryAt = 0
			if v.Accepted {
				v.Stage = "queued"
			} else if v.ResumeStage == "verifying_receive" || v.Stage == "failed" {
				v.Stage = "verifying_receive"
			} else {
				v.Stage = "receiving"
			}
			v.Speed = 0
			v.ETA = nil
		case "cancel":
			v.Action = "cancelled"
			v.Stage = "cancelling"
			v.Speed = 0
			v.ETA = nil
		}
		return nil
	})
	if err != nil {
		problem(w, 500, err)
		return
	}
	j, _ = a.Store.Job(j.ID)
	write(w, 200, j)
}

func (s *Store) SetProgress(id, stage string, done, total int64, start time.Time) error {
	elapsed := time.Since(start).Seconds()
	speed := float64(done) / elapsed
	var eta *float64
	if speed > 0 && total > done {
		value := float64(total-done) / speed
		eta = &value
	}
	return s.Update(id, func(j *Job) error {
		if j.Action == "paused" {
			return ErrPaused
		}
		if j.Action == "cancelled" {
			return ErrCancelled
		}
		j.Stage = stage
		j.Done = done
		j.Total = total
		j.Speed = speed
		j.ETA = eta
		j.Error = ""
		return nil
	})
}
func fileDigestMatches(p string, e Entry, check func() error, progress func(int64), durable bool) error {
	info, err := os.Lstat(p)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() != e.Size {
		return fmt.Errorf("file size/type differs: %s", e.Path)
	}
	if durable {
		f, e2 := os.Open(p)
		if e2 != nil {
			return e2
		}
		e2 = f.Sync()
		if e2 == nil {
			invalidateCache(f)
		}
		_ = f.Close()
		if e2 != nil {
			return e2
		}
	}
	h, err := hashFile(p, check, progress)
	if err != nil {
		return err
	}
	if h != e.SHA256 {
		return fmt.Errorf("SHA-256 mismatch: %s", e.Path)
	}
	return nil
}
