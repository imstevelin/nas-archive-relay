package relay

import (
	"crypto/x509"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCertificateRenewalPreservesIdentityAndTokens(t *testing.T) {
	f := setup(t)
	before := f.s.Snapshot()
	old, _ := os.ReadFile(filepath.Join(f.s.Root, "server.crt"))
	if err := f.s.RenewCertificate(); err != nil {
		t.Fatal(err)
	}
	current, err := os.ReadFile(filepath.Join(f.s.Root, "server.crt"))
	if err != nil {
		t.Fatal(err)
	}
	if string(old) == string(current) {
		t.Fatal("certificate not renewed")
	}
	block, _ := pem.Decode(current)
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	if cert.NotAfter.Sub(cert.NotBefore) > 367*24*time.Hour {
		t.Fatal("certificate exceeds macOS validity limit")
	}
	if err = cert.VerifyHostname("127.0.0.1"); err != nil {
		t.Fatal(err)
	}
	if before.ID != f.s.Snapshot().ID {
		t.Fatal("identity changed")
	}
	if _, ok := f.s.Authenticate(f.first.Token); !ok {
		t.Fatal("existing token revoked")
	}
}
func TestFailedTargetEditRestoresSMBCredentials(t *testing.T) {
	f := setup(t)
	target := Target{ID: NewID(), Name: "SMB", Protocol: "smb", Host: "127.0.0.1", Share: "archive", Username: "editor", Enabled: true}
	if _, err := f.s.SaveTarget(TargetInput{Target: target, Password: "original-secret"}); err != nil {
		t.Fatal(err)
	}
	credential := filepath.Join(f.s.Root, "credentials", target.ID)
	original, err := os.ReadFile(credential)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(f.s.Root, "config.json"), []byte("invalid"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = f.s.SaveTarget(TargetInput{Target: target, Password: "new-secret"}); err == nil {
		t.Fatal("expected configuration failure")
	}
	after, err := os.ReadFile(credential)
	if err != nil || string(after) != string(original) {
		t.Fatal("credentials not restored", err)
	}
}

func TestCustomDataRootPointer(t *testing.T) {
	pointer := filepath.Join(t.TempDir(), "data-path")
	value := filepath.Join(t.TempDir(), "我的 暫存 ")
	if err := os.WriteFile(pointer, []byte(value+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if got := defaultDataRootFromFile(pointer); got != value {
		t.Fatalf("got %q", got)
	}
	_ = os.WriteFile(pointer, []byte("/\n"), 0600)
	if got := defaultDataRootFromFile(pointer); got != "/var/lib/nas-archive-relay" {
		t.Fatal(got)
	}
}
