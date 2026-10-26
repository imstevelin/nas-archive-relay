package relay

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestDuplicateRequiresDecisionAndCanSkipIdentical(t *testing.T) {
	f := setup(t)
	data := []byte("identical archive")
	first := f.manifest(data)
	f.accept(t, first, data)
	f.a.work(first.ID)
	second := f.manifest(data)
	f.accept(t, second, data)
	f.a.work(second.ID)
	j, _ := f.s.Job(second.ID)
	if j.Stage != "awaiting_duplicate" || j.Action != "paused" {
		t.Fatal(j)
	}
	reopened, err := Open(f.s.Root)
	if err != nil {
		t.Fatal(err)
	}
	j, _ = reopened.Job(second.ID)
	if j.Stage != "awaiting_duplicate" {
		t.Fatal("decision lost on restart", j)
	}
	code, b := f.request(t, f.first.Token, "POST", "/v1/jobs/"+second.ID+"/use-existing", nil, nil)
	if code != 200 {
		t.Fatalf("%d %s", code, b)
	}
	f.a.work(second.ID)
	j, _ = f.s.Job(second.ID)
	if j.Stage != "completed" || !j.NASClean || !j.RelayClean {
		t.Fatal(j)
	}
}
func TestKeepBothNeverChangesExistingArchive(t *testing.T) {
	f := setup(t)
	old := []byte("existing archive")
	first := f.manifest(old)
	f.accept(t, first, old)
	f.a.work(first.ID)
	data := []byte("different new footage")
	m := f.manifest(data)
	f.accept(t, m, data)
	f.a.work(m.ID)
	code, b := f.request(t, f.first.Token, "POST", "/v1/jobs/"+m.ID+"/keep-both", nil, nil)
	if code != 200 {
		t.Fatalf("%d %s", code, b)
	}
	f.a.work(m.ID)
	j, _ := f.s.Job(m.ID)
	if j.Stage != "completed" || j.ArchiveName == "" {
		t.Fatal(j)
	}
	for name, want := range map[string][]byte{m.Name: old, j.ArchiveName: data} {
		got, err := os.ReadFile(filepath.Join(f.nas, m.Folder, name, "camera.mov"))
		if err != nil || !bytes.Equal(got, want) {
			t.Fatal("archive changed", name, err)
		}
	}
}
func TestFailedNASUploadRemovesOwnedStatusFolder(t *testing.T) {
	f := setup(t)
	data := []byte("new footage")
	m := f.manifest(data)
	f.accept(t, m, data)
	workspace := filepath.Join(f.nas, m.Folder, workName(m.Name, m.ID, "上傳中"))
	if err := os.MkdirAll(filepath.Join(workspace, "empty"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := atomicJSON(filepath.Join(workspace, ".nas-relay-incomplete.json"), map[string]string{"id": m.ID}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspace, "camera.mov"), bytes.Repeat([]byte("x"), 100), 0600); err != nil {
		t.Fatal(err)
	}
	f.a.work(m.ID)
	j, _ := f.s.Job(m.ID)
	if j.Stage != "retry_pending" || !j.NASClean {
		t.Fatal(j)
	}
	if _, err := os.Stat(workspace); !os.IsNotExist(err) {
		t.Fatal("failed upload remains on NAS", err)
	}
	if _, err := os.Stat(f.s.jobPath(m.ID, "payload")); err != nil {
		t.Fatal("relay source lost", err)
	}
}
func TestCancelledLegacyPartialRemovedOnlyWithMatchingOwner(t *testing.T) {
	f := setup(t)
	m := f.manifest([]byte("source"))
	f.accept(t, m, []byte("source"))
	dir := filepath.Join(f.nas, m.Folder, m.Name)
	_ = os.MkdirAll(dir, 0700)
	_ = atomicJSON(filepath.Join(dir, ".nas-relay-incomplete.json"), map[string]string{"id": NewID()})
	_ = os.WriteFile(filepath.Join(dir, "camera.mov"), []byte("other job"), 0600)
	_ = f.s.Update(m.ID, func(j *Job) error { j.Stage = "cancelled"; j.Action = "cancelled"; return nil })
	if err := f.a.cleanupNASWork(m.ID, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "camera.mov")); err != nil {
		t.Fatal("foreign data removed")
	}
	_ = atomicJSON(filepath.Join(dir, ".nas-relay-incomplete.json"), map[string]string{"id": m.ID})
	if err := f.a.cleanupNASWork(m.ID, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatal("owned partial retained")
	}
}
func TestStatusFolderCannotDeleteUnownedDirectory(t *testing.T) {
	f := setup(t)
	m := f.manifest([]byte("source"))
	f.accept(t, m, []byte("source"))
	dir := filepath.Join(f.nas, m.Folder, workName(m.Name, m.ID, "校驗中"))
	_ = os.MkdirAll(dir, 0700)
	_ = os.WriteFile(filepath.Join(dir, "camera.mov"), []byte("unowned"), 0600)
	if err := f.a.cleanupNASWork(m.ID, ""); err == nil {
		t.Fatal("unowned cleanup allowed")
	}
	if _, err := os.Stat(filepath.Join(dir, "camera.mov")); err != nil {
		t.Fatal("foreign data removed")
	}
}

func TestPreflightDetectsDuplicateWithoutCreatingAJob(t *testing.T) {
	f := setup(t)
	m := f.manifest([]byte("data"))
	dir := filepath.Join(f.nas, m.Folder, m.Name)
	_ = os.MkdirAll(dir, 0700)
	code, b := f.request(t, f.first.Token, "POST", "/v1/preflight", map[string]string{"name": m.Name, "target_id": m.TargetID, "folder": m.Folder}, nil)
	if code != 200 || !bytes.Contains(b, []byte(`"exists":true`)) {
		t.Fatalf("%d %s", code, b)
	}
	if len(f.s.Jobs) != 0 {
		t.Fatal("preflight unexpectedly created a job")
	}
	code, b = f.request(t, f.first.Token, "POST", "/v1/preflight", map[string]string{"name": "new", "target_id": m.TargetID, "folder": "not-created/nested"}, nil)
	if code != 200 || !bytes.Contains(b, []byte(`"exists":false`)) {
		t.Fatalf("%d %s", code, b)
	}
	if _, err := os.Stat(filepath.Join(f.nas, "not-created")); !os.IsNotExist(err) {
		t.Fatal("preflight modified NAS")
	}
}
func TestConfirmedKeepBothIsSavedWithInitialManifest(t *testing.T) {
	f := setup(t)
	data := []byte("chosen copy")
	m := f.manifest(data)
	m.CollisionPolicy = "keep-both"
	f.accept(t, m, data)
	j, _ := f.s.Job(m.ID)
	if j.DuplicateChoice != "keep-both" || j.ArchiveName == "" {
		t.Fatal(j)
	}
	f.a.work(m.ID)
	j, _ = f.s.Job(m.ID)
	if j.Stage != "completed" {
		t.Fatal(j)
	}
	if _, err := os.Stat(filepath.Join(f.nas, m.Folder, j.ArchiveName, "camera.mov")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(f.nas, m.Folder, m.Name)); !os.IsNotExist(err) {
		t.Fatal("original name used despite keep both")
	}
}

func TestReservedMarkersCannotAliasOnSMB(t *testing.T) {
	for _, path := range []string{"Footage/.NAS-RELAY-INCOMPLETE.JSON", ".RELAY-PARTIAL"} {
		if safePath(path, false) {
			t.Fatal("reserved alias accepted", path)
		}
	}
}
