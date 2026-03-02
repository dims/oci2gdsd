package store

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/dims/oci2gdsd/internal/model"
)

func TestGetAndListDoNotRewriteStateDB(t *testing.T) {
	statePath := filepath.Join(t.TempDir(), "state.db")
	s := NewStateStore(statePath)
	if err := s.Init(); err != nil {
		t.Fatalf("init state store: %v", err)
	}

	rec := &ModelRecord{
		Key:            "demo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		ModelID:        "demo",
		ManifestDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		Status:         model.StateReady,
		Path:           "/var/lib/oci2gdsd/models/demo/sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		Bytes:          4096,
	}
	if err := s.Put(rec); err != nil {
		t.Fatalf("put record: %v", err)
	}

	beforeBytes, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatalf("read state db before: %v", err)
	}
	beforeInfo, err := os.Stat(statePath)
	if err != nil {
		t.Fatalf("stat state db before: %v", err)
	}

	time.Sleep(20 * time.Millisecond)
	if _, _, err := s.Get(rec.Key); err != nil {
		t.Fatalf("get record: %v", err)
	}
	afterGetBytes, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatalf("read state db after get: %v", err)
	}
	afterGetInfo, err := os.Stat(statePath)
	if err != nil {
		t.Fatalf("stat state db after get: %v", err)
	}
	if !beforeInfo.ModTime().Equal(afterGetInfo.ModTime()) {
		t.Fatalf("expected Get to be read-only; modtime changed from %s to %s", beforeInfo.ModTime(), afterGetInfo.ModTime())
	}
	if !bytes.Equal(beforeBytes, afterGetBytes) {
		t.Fatalf("expected Get to be read-only; state file contents changed")
	}

	time.Sleep(20 * time.Millisecond)
	if _, err := s.List(); err != nil {
		t.Fatalf("list records: %v", err)
	}
	afterListBytes, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatalf("read state db after list: %v", err)
	}
	afterListInfo, err := os.Stat(statePath)
	if err != nil {
		t.Fatalf("stat state db after list: %v", err)
	}
	if !beforeInfo.ModTime().Equal(afterListInfo.ModTime()) {
		t.Fatalf("expected List to be read-only; modtime changed from %s to %s", beforeInfo.ModTime(), afterListInfo.ModTime())
	}
	if !bytes.Equal(beforeBytes, afterListBytes) {
		t.Fatalf("expected List to be read-only; state file contents changed")
	}
}
