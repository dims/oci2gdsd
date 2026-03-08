package store

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
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

func TestAllocationLifecycle(t *testing.T) {
	statePath := filepath.Join(t.TempDir(), "state.db")
	s := NewStateStore(statePath)
	if err := s.Init(); err != nil {
		t.Fatalf("init state store: %v", err)
	}

	now := time.Now().UTC()
	first := &AllocationRecord{
		AllocationID:   "alloc-b",
		ModelKey:       "demo@sha256:" + strings.Repeat("b", 64),
		ModelID:        "demo",
		ManifestDigest: "sha256:" + strings.Repeat("b", 64),
		Path:           "/var/lib/oci2gdsd/models/demo/sha256-b",
		LeaseHolder:    "holder-b",
		DeviceUUID:     "GPU-11111111-2222-3333-4444-555555555555",
		DeviceIndex:    0,
		Status:         "READY",
		CreatedAt:      now,
	}
	second := &AllocationRecord{
		AllocationID:   "alloc-a",
		ModelKey:       "demo@sha256:" + strings.Repeat("a", 64),
		ModelID:        "demo",
		ManifestDigest: "sha256:" + strings.Repeat("a", 64),
		Path:           "/var/lib/oci2gdsd/models/demo/sha256-a",
		LeaseHolder:    "holder-a",
		DeviceUUID:     "GPU-11111111-2222-3333-4444-555555555555",
		DeviceIndex:    0,
		Status:         "READY",
		CreatedAt:      now,
	}
	if err := s.PutAllocation(first); err != nil {
		t.Fatalf("put first allocation: %v", err)
	}
	if err := s.PutAllocation(second); err != nil {
		t.Fatalf("put second allocation: %v", err)
	}

	got, ok, err := s.GetAllocation(first.AllocationID)
	if err != nil {
		t.Fatalf("get allocation: %v", err)
	}
	if !ok {
		t.Fatalf("expected allocation to exist")
	}
	if got.AllocationID != first.AllocationID || got.ModelKey != first.ModelKey {
		t.Fatalf("unexpected allocation record: %+v", got)
	}

	allocs, err := s.ListAllocations()
	if err != nil {
		t.Fatalf("list allocations: %v", err)
	}
	if len(allocs) != 2 {
		t.Fatalf("expected 2 allocations, got %d", len(allocs))
	}
	if allocs[0].AllocationID != "alloc-a" || allocs[1].AllocationID != "alloc-b" {
		t.Fatalf("expected allocations sorted by allocation_id: %+v", allocs)
	}

	if err := s.DeleteAllocation("alloc-a"); err != nil {
		t.Fatalf("delete allocation: %v", err)
	}
	if _, ok, err := s.GetAllocation("alloc-a"); err != nil || ok {
		t.Fatalf("expected alloc-a to be deleted; ok=%v err=%v", ok, err)
	}

	if err := s.ClearAllocations(); err != nil {
		t.Fatalf("clear allocations: %v", err)
	}
	allocs, err = s.ListAllocations()
	if err != nil {
		t.Fatalf("list allocations after clear: %v", err)
	}
	if len(allocs) != 0 {
		t.Fatalf("expected no allocations after clear, got %+v", allocs)
	}
}

func TestStateDBMigrationUpgradesVersionAndAllocationsMap(t *testing.T) {
	statePath := filepath.Join(t.TempDir(), "state.db")
	legacy := []byte(`{
  "version": 1,
  "models": {
    "demo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": {
      "key": "demo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "model_id": "demo",
      "manifest_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "status": "READY",
      "path": "/var/lib/oci2gdsd/models/demo/sha256-a",
      "bytes": 1,
      "leases": []
    }
  }
}`)
	if err := os.MkdirAll(filepath.Dir(statePath), 0o755); err != nil {
		t.Fatalf("mkdir state db dir: %v", err)
	}
	if err := os.WriteFile(statePath, legacy, 0o644); err != nil {
		t.Fatalf("seed legacy state db: %v", err)
	}

	s := NewStateStore(statePath)
	if err := s.Init(); err != nil {
		t.Fatalf("init state store: %v", err)
	}
	if err := s.PutAllocation(&AllocationRecord{
		AllocationID:   "alloc-upgrade",
		ModelKey:       "demo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		ModelID:        "demo",
		ManifestDigest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		Path:           "/var/lib/oci2gdsd/models/demo/sha256-a",
		LeaseHolder:    "holder-upgrade",
		DeviceUUID:     "GPU-11111111-2222-3333-4444-555555555555",
		DeviceIndex:    0,
		Status:         "READY",
	}); err != nil {
		t.Fatalf("put allocation post-migration: %v", err)
	}

	raw, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatalf("read persisted state db: %v", err)
	}
	var db map[string]any
	if err := json.Unmarshal(raw, &db); err != nil {
		t.Fatalf("unmarshal persisted db: %v", err)
	}
	if got := int(db["version"].(float64)); got != 2 {
		t.Fatalf("expected migrated version=2, got %d", got)
	}
	allocations, ok := db["allocations"].(map[string]any)
	if !ok {
		t.Fatalf("expected allocations map after migration, got %T", db["allocations"])
	}
	if _, found := allocations["alloc-upgrade"]; !found {
		t.Fatalf("expected migrated db to persist alloc-upgrade, got %+v", allocations)
	}
}
