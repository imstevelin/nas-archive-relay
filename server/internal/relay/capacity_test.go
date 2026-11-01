package relay

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCapacityUsesUploadJournalDuringVerificationAndPause(t *testing.T) {
	f := setup(t)
	m := f.manifest([]byte("0123456789"))
	f.create(t, m)
	if err := atomicJSON(f.s.jobPath(m.ID, "upload.json"), map[string]int64{"2": 7}); err != nil {
		t.Fatal(err)
	}
	_ = f.s.Update(m.ID, func(j *Job) error { j.Stage = "verifying_receive"; j.Done = 0; return nil })
	f.s.mu.Lock()
	c, err := f.s.capacityLocked()
	f.s.mu.Unlock()
	if err != nil || c.ReservedUploads != 3 {
		t.Fatalf("%+v %v", c, err)
	}
	_ = f.s.Update(m.ID, func(j *Job) error { j.Stage = "paused"; j.Action = "paused"; j.Done = 9; return nil })
	code, b := f.request(t, f.first.Token, "GET", "/v1/info", nil, nil)
	var decoded Capacity
	if err = json.Unmarshal(b, &decoded); err != nil {
		t.Fatal(err)
	}
	if code != 200 || decoded.ReservedUploads != 3 || decoded.AvailableUploads != max(int64(0), decoded.FreeBytes-decoded.ReserveBytes-3) || decoded.TotalBytes < decoded.FreeBytes {
		t.Fatalf("%d %s", code, b)
	}
}

func TestSpaceRejectionIncludesAdmissionNumbers(t *testing.T) {
	f := setup(t)
	_ = f.s.SaveConfig(func(c *Config) error { c.ReserveBytes = 1 << 60; return nil })
	code, b := f.request(t, f.first.Token, "POST", "/v1/jobs", f.manifest([]byte("a")), nil)
	var result struct {
		Required  int64 `json:"required_bytes"`
		Available int64 `json:"available_upload_bytes"`
	}
	if err := json.Unmarshal(b, &result); err != nil {
		t.Fatal(err)
	}
	if code != 507 || result.Required != 1 || result.Available != 0 {
		t.Fatalf("%d %s", code, b)
	}
}

func TestReceiptReleasesRelayBeforeNASFailure(t *testing.T) {
	f := setup(t)
	data := []byte("verified archive")
	m := f.manifest(data)
	f.accept(t, m, data)
	f.a.work(m.ID)
	payload := f.s.jobPath(m.ID, "payload")
	if err := os.MkdirAll(payload, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(payload, "leftover"), data, 0600); err != nil {
		t.Fatal(err)
	}
	_ = f.s.Update(m.ID, func(j *Job) error { j.RelayClean = false; j.NASClean = false; return nil })
	f.a.ResolveTarget = func(Target) (string, error) { return "", errors.New("NAS offline") }
	if err := f.a.cleanupFinished(m.ID, "", true); err == nil {
		t.Fatal("expected NAS cleanup failure")
	}
	j, _ := f.s.Job(m.ID)
	if !j.RelayClean || j.NASClean {
		t.Fatalf("%+v", j)
	}
	if _, err := os.Stat(payload); !os.IsNotExist(err) {
		t.Fatal("payload retained despite durable completion receipt")
	}
}

func TestMissingOrMismatchedReceiptRetainsRelay(t *testing.T) {
	f := setup(t)
	data := []byte("keep")
	m := f.manifest(data)
	f.accept(t, m, data)
	_ = f.s.Update(m.ID, func(j *Job) error { j.Stage = "completed"; return nil })
	for _, sha := range []string{"", Hash([]byte("wrong manifest"))} {
		if sha != "" {
			_ = atomicJSON(filepath.Join(f.s.Root, "receipts", m.ID+".json"), map[string]any{"id": m.ID, "owner": f.first.ClientID, "manifest_sha256": sha, "verified_at": time.Now().UTC()})
		}
		if err := f.a.cleanupRelayFinished(m.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(f.s.jobPath(m.ID, "payload")); err != nil {
			t.Fatal("unverified payload removed", err)
		}
	}
}

func TestLocalCleanupIsIndependentOfOccupiedNASCleanupSlot(t *testing.T) {
	f := setup(t)
	data := []byte("archive")
	m := f.manifest(data)
	f.accept(t, m, data)
	f.a.work(m.ID)
	_ = os.MkdirAll(f.s.jobPath(m.ID, "payload"), 0700)
	_ = f.s.Update(m.ID, func(j *Job) error { j.RelayClean = false; j.NASClean = false; return nil })
	f.a.cleanup <- struct{}{} // A different task is stuck cleaning NAS state.
	defer func() { <-f.a.cleanup }()
	f.a.dispatch()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		j, _ := f.s.Job(m.ID)
		if j.RelayClean {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("local cleanup queued behind NAS cleanup")
}
