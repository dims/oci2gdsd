package app

import (
	"bytes"
	"context"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	configpkg "github.com/dims/oci2gdsd/internal/config"
	storepkg "github.com/dims/oci2gdsd/internal/store"
	digest "github.com/opencontainers/go-digest"
)

func TestRecoverQuickDoesNotHashShardDigest(t *testing.T) {
	svc := newStateOnlyService(t)
	modelPath := filepath.Join(svc.cfg.ModelRoot, "demo", "sha256-deadbeef")
	if err := os.MkdirAll(filepath.Join(modelPath, "metadata"), 0o755); err != nil {
		t.Fatalf("mkdir metadata: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(modelPath, "shards"), 0o755); err != nil {
		t.Fatalf("mkdir shards: %v", err)
	}

	content := []byte("hello-model")
	shardName := "model-00001-of-00001.safetensors"
	if err := os.WriteFile(filepath.Join(modelPath, "shards", shardName), content, 0o444); err != nil {
		t.Fatalf("write shard: %v", err)
	}
	wrongDigest := digest.FromBytes([]byte("HELLO-model")).String()
	manifest := "sha256:" + strings.Repeat("b", 64)
	md := localMetadata{
		SchemaVersion:  1,
		ModelID:        "demo",
		ManifestDigest: manifest,
		Profile: ModelProfile{
			SchemaVersion: 1,
			ModelID:       "demo",
			ModelRevision: "r1",
			Framework:     "pytorch",
			Format:        "safetensors",
			Shards: []ModelShard{
				{
					Name:    shardName,
					Digest:  wrongDigest,
					Size:    int64(len(content)),
					Ordinal: 1,
				},
			},
			Integrity: ModelIntegrity{
				ManifestDigest: manifest,
			},
		},
	}
	mb, err := json.Marshal(md)
	if err != nil {
		t.Fatalf("marshal metadata: %v", err)
	}
	if err := os.WriteFile(filepath.Join(modelPath, "metadata", "model.json"), mb, 0o444); err != nil {
		t.Fatalf("write model.json: %v", err)
	}
	if err := os.WriteFile(filepath.Join(modelPath, "READY"), []byte("ok\n"), 0o444); err != nil {
		t.Fatalf("write READY: %v", err)
	}

	key := modelKey("demo", manifest)
	record := &storepkg.ModelRecord{
		Key:            key,
		ModelID:        "demo",
		ManifestDigest: manifest,
		Status:         StateReady,
		Path:           modelPath,
		Bytes:          int64(len(content)),
		CreatedAt:      time.Now().UTC(),
		UpdatedAt:      time.Now().UTC(),
		LastAccessedAt: time.Now().UTC(),
	}
	if err := svc.store.Put(record); err != nil {
		t.Fatalf("store put: %v", err)
	}

	if err := svc.Recover(); err != nil {
		t.Fatalf("recover: %v", err)
	}

	rec, ok, err := svc.store.Get(key)
	if err != nil {
		t.Fatalf("store get: %v", err)
	}
	if !ok {
		t.Fatalf("expected record after recover")
	}
	if rec.Status != StateReady {
		t.Fatalf("expected READY after quick recover check, got %s", rec.Status)
	}

	ready, reason, verifyErr := svc.verifyPublishedPath(modelPath)
	if verifyErr == nil || ready {
		t.Fatalf("expected full verify failure for digest mismatch")
	}
	if reason != ReasonBlobDigestMismatch {
		t.Fatalf("expected reason %s, got %s", ReasonBlobDigestMismatch, reason)
	}
}

func TestGCOrderingPrefersExplicitReleasableAtOverNil(t *testing.T) {
	svc := newStateOnlyService(t)
	now := time.Now().UTC()
	old := now.Add(-2 * time.Hour)
	manifestA := "sha256:" + strings.Repeat("a", 64)
	manifestB := "sha256:" + strings.Repeat("c", 64)
	pathA := filepath.Join(svc.cfg.ModelRoot, "model-a", "sha256-a")
	pathB := filepath.Join(svc.cfg.ModelRoot, "model-b", "sha256-b")
	mustWriteReadyOnly(t, pathA)
	mustWriteReadyOnly(t, pathB)

	recA := &storepkg.ModelRecord{
		Key:            modelKey("model-a", manifestA),
		ModelID:        "model-a",
		ManifestDigest: manifestA,
		Status:         StateReady,
		Path:           pathA,
		Bytes:          64 * 1024 * 1024,
		Releasable:     true,
		ReleasableAt:   &old,
		CreatedAt:      now,
		UpdatedAt:      now,
		LastAccessedAt: now,
	}
	recB := &storepkg.ModelRecord{
		Key:            modelKey("model-b", manifestB),
		ModelID:        "model-b",
		ManifestDigest: manifestB,
		Status:         StateReady,
		Path:           pathB,
		Bytes:          64 * 1024 * 1024,
		Releasable:     true,
		ReleasableAt:   nil,
		CreatedAt:      now,
		UpdatedAt:      now,
		LastAccessedAt: now,
	}
	if err := svc.store.Put(recA); err != nil {
		t.Fatalf("put recA: %v", err)
	}
	if err := svc.store.Put(recB); err != nil {
		t.Fatalf("put recB: %v", err)
	}

	free, err := diskFreeBytes(svc.cfg.ModelRoot)
	if err != nil {
		t.Fatalf("disk free: %v", err)
	}
	res, err := svc.GC("lru_no_lease", free+(32*1024*1024), true)
	if err != nil {
		t.Fatalf("gc: %v", err)
	}
	if len(res.DeletedModels) != 1 {
		t.Fatalf("expected one GC candidate in dry-run, got %d (%v)", len(res.DeletedModels), res.DeletedModels)
	}
	if res.DeletedModels[0] != recA.Key {
		t.Fatalf("expected explicit releasable_at candidate first, got %s", res.DeletedModels[0])
	}
}

func TestGCSkipsBusyModelLock(t *testing.T) {
	svc := newStateOnlyService(t)
	now := time.Now().UTC()
	manifest := "sha256:" + strings.Repeat("f", 64)
	modelPath := filepath.Join(svc.cfg.ModelRoot, "model-lock", "sha256-lock")
	mustWriteReadyOnly(t, modelPath)
	rec := &storepkg.ModelRecord{
		Key:            modelKey("model-lock", manifest),
		ModelID:        "model-lock",
		ManifestDigest: manifest,
		Status:         StateReady,
		Path:           modelPath,
		Bytes:          64 * 1024 * 1024,
		Releasable:     true,
		ReleasableAt:   &now,
		CreatedAt:      now,
		UpdatedAt:      now,
		LastAccessedAt: now,
	}
	if err := svc.store.Put(rec); err != nil {
		t.Fatalf("put rec: %v", err)
	}

	unlock, pending, err := svc.locks.Acquire(context.Background(), rec.Key, false)
	if err != nil {
		t.Fatalf("acquire lock: %v", err)
	}
	if pending {
		t.Fatalf("expected lock acquisition to succeed")
	}
	defer unlock()

	free, err := diskFreeBytes(svc.cfg.ModelRoot)
	if err != nil {
		t.Fatalf("disk free: %v", err)
	}
	res, err := svc.GC("lru_no_lease", free+(32*1024*1024), false)
	if err != nil {
		t.Fatalf("gc: %v", err)
	}
	if len(res.DeletedModels) != 0 {
		t.Fatalf("expected locked model to be skipped, got deleted models: %+v", res.DeletedModels)
	}
	if !fileExists(modelPath) {
		t.Fatalf("expected model path to remain while lock is held")
	}
}

func TestRecoverReplaysReadyWrittenJournal(t *testing.T) {
	svc := newStateOnlyService(t)
	content := []byte("recover-ready")
	manifest := "sha256:" + strings.Repeat("9", 64)
	modelPath := filepath.Join(svc.cfg.ModelRoot, "demo", "sha256-"+strings.Repeat("9", 64))
	if err := os.MkdirAll(filepath.Join(modelPath, "metadata"), 0o755); err != nil {
		t.Fatalf("mkdir metadata: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(modelPath, "shards"), 0o755); err != nil {
		t.Fatalf("mkdir shards: %v", err)
	}
	shardName := "weights-00001.safetensors"
	if err := os.WriteFile(filepath.Join(modelPath, "shards", shardName), content, 0o444); err != nil {
		t.Fatalf("write shard: %v", err)
	}
	md := localMetadata{
		SchemaVersion:  1,
		ModelID:        "demo",
		ManifestDigest: manifest,
		Profile: ModelProfile{
			SchemaVersion: 1,
			ModelID:       "demo",
			ModelRevision: "r1",
			Framework:     "pytorch",
			Format:        "safetensors",
			Shards: []ModelShard{{
				Name:    shardName,
				Digest:  digest.FromBytes(content).String(),
				Size:    int64(len(content)),
				Ordinal: 1,
				Kind:    "weight",
			}},
			Integrity: ModelIntegrity{ManifestDigest: manifest},
		},
	}
	mb, err := json.Marshal(md)
	if err != nil {
		t.Fatalf("marshal metadata: %v", err)
	}
	if err := os.WriteFile(filepath.Join(modelPath, "metadata", "model.json"), mb, 0o444); err != nil {
		t.Fatalf("write metadata: %v", err)
	}
	if err := os.WriteFile(filepath.Join(modelPath, "READY"), []byte("ok\n"), 0o444); err != nil {
		t.Fatalf("write READY: %v", err)
	}

	key := modelKey("demo", manifest)
	rec := &storepkg.ModelRecord{
		Key:            key,
		ModelID:        "demo",
		ManifestDigest: manifest,
		Status:         StatePublishing,
		Path:           modelPath,
		Bytes:          int64(len(content)),
		CreatedAt:      time.Now().UTC(),
		UpdatedAt:      time.Now().UTC(),
		LastAccessedAt: time.Now().UTC(),
	}
	if err := svc.store.Put(rec); err != nil {
		t.Fatalf("put record: %v", err)
	}

	j := NewJournal(svc.cfg.JournalDir, "demo", manifest)
	if err := j.Append(JournalTxnStarted); err != nil {
		t.Fatalf("append txn started: %v", err)
	}
	if err := j.Append(JournalReadyWritten); err != nil {
		t.Fatalf("append ready written: %v", err)
	}

	if err := svc.Recover(); err != nil {
		t.Fatalf("recover: %v", err)
	}

	stored, ok, err := svc.store.Get(key)
	if err != nil {
		t.Fatalf("store get: %v", err)
	}
	if !ok {
		t.Fatalf("expected record")
	}
	if stored.Status != StateReady {
		t.Fatalf("expected READY after recover replay, got %s", stored.Status)
	}
	if fileExists(j.Path()) {
		t.Fatalf("expected replayed journal to be cleaned up")
	}
}

func TestGCCollectsFailedRecordWithoutReadyMarker(t *testing.T) {
	svc := newStateOnlyService(t)
	now := time.Now().UTC()
	manifest := "sha256:" + strings.Repeat("e", 64)
	modelPath := filepath.Join(svc.cfg.ModelRoot, "failed-model", "sha256-failed")
	if err := os.MkdirAll(modelPath, 0o755); err != nil {
		t.Fatalf("mkdir failed path: %v", err)
	}
	blob := bytes.Repeat([]byte{0x1}, 1024)
	if err := os.WriteFile(filepath.Join(modelPath, "partial.bin"), blob, 0o644); err != nil {
		t.Fatalf("write partial file: %v", err)
	}
	rec := &storepkg.ModelRecord{
		Key:            modelKey("failed-model", manifest),
		ModelID:        "failed-model",
		ManifestDigest: manifest,
		Status:         StateFailed,
		Path:           modelPath,
		Bytes:          int64(len(blob)),
		Releasable:     true,
		ReleasableAt:   &now,
		CreatedAt:      now,
		UpdatedAt:      now,
		LastAccessedAt: now,
	}
	if err := svc.store.Put(rec); err != nil {
		t.Fatalf("put failed record: %v", err)
	}

	res, err := svc.GC("lru_no_lease", math.MaxInt64/4, false)
	if err != nil {
		t.Fatalf("gc failed: %v", err)
	}
	if len(res.DeletedModels) != 1 || res.DeletedModels[0] != rec.Key {
		t.Fatalf("expected failed record to be gc candidate, got %+v", res.DeletedModels)
	}
	if fileExists(modelPath) {
		t.Fatalf("expected failed path to be deleted by gc")
	}
}

func TestRecoverClearsEphemeralRuntimeState(t *testing.T) {
	svc := newStateOnlyService(t)
	svc.gpuLoader = newFakePersistentLoader()

	modelID := "demo"
	manifest := "sha256:" + strings.Repeat("4", 64)
	modelPath, shardSize := writeReadyModelForGPUTest(t, svc.cfg.ModelRoot, modelID, manifest)
	now := time.Now().UTC()
	rec := &storepkg.ModelRecord{
		Key:            modelKey(modelID, manifest),
		ModelID:        modelID,
		ManifestDigest: manifest,
		Status:         StateReady,
		Path:           modelPath,
		Bytes:          shardSize,
		CreatedAt:      now,
		UpdatedAt:      now,
		LastAccessedAt: now,
	}
	if err := svc.store.Put(rec); err != nil {
		t.Fatalf("put model record: %v", err)
	}

	const allocationID = "alloc-recover-ephemeral"
	if err := svc.putAllocation(&gpuAllocation{
		AllocationID:   allocationID,
		ModelKey:       rec.Key,
		ModelID:        modelID,
		ManifestDigest: manifest,
		Path:           modelPath,
		LeaseHolder:    "holder-recover",
		DeviceUUID:     fakeDeviceUUID0,
		DeviceIndex:    0,
		CreatedAt:      now,
	}); err != nil {
		t.Fatalf("put allocation: %v", err)
	}
	token, _ := svc.issueRuntimeBundleToken(allocationID, false)
	if strings.TrimSpace(token) == "" {
		t.Fatalf("expected runtime bundle token")
	}

	svc.attachMu.Lock()
	svc.attachMap = map[string]*gpuClientAttachment{
		gpuAttachKey(rec.Key, fakeDeviceUUID0, "client-recover"): {
			ModelKey:       rec.Key,
			ModelID:        modelID,
			ManifestDigest: manifest,
			Path:           modelPath,
			DeviceUUID:     fakeDeviceUUID0,
			DeviceIndex:    0,
			ClientID:       "client-recover",
			ShardPaths:     []string{filepath.Join(modelPath, "shards", "model-00001-of-00001.safetensors")},
			ExpiresAt:      now.Add(30 * time.Second),
		},
	}
	svc.attachMu.Unlock()

	svc.tensorMapMu.Lock()
	svc.tensorMapCache = map[string]*tensorMapSnapshot{
		rec.Key: {
			Key:    rec.Key,
			Format: "safetensors",
			Tensors: []GPUTensorDescriptor{
				{
					Name:       "weight",
					ShardName:  "model-00001-of-00001.safetensors",
					ByteLength: 8,
				},
			},
			BuiltAt: now,
			ModelID: modelID,
			Digest:  manifest,
		},
	}
	svc.tensorMapMu.Unlock()

	if err := svc.Recover(); err != nil {
		t.Fatalf("recover: %v", err)
	}

	allocations, err := svc.store.ListAllocations()
	if err != nil {
		t.Fatalf("list allocations: %v", err)
	}
	if len(allocations) != 0 {
		t.Fatalf("expected recover to clear allocations, got %+v", allocations)
	}

	if _, _, err := svc.resolveRuntimeBundleToken(token); err == nil {
		t.Fatalf("expected token resolution to fail after recover reset")
	}

	svc.attachMu.Lock()
	attachCount := len(svc.attachMap)
	svc.attachMu.Unlock()
	if attachCount != 0 {
		t.Fatalf("expected recover to clear attachment state, got %d", attachCount)
	}

	svc.tensorMapMu.RLock()
	cacheEntries := len(svc.tensorMapCache)
	svc.tensorMapMu.RUnlock()
	if cacheEntries != 0 {
		t.Fatalf("expected recover to clear tensor-map cache, got %d", cacheEntries)
	}
}

func newStateOnlyService(t *testing.T) *Service {
	t.Helper()
	root := t.TempDir()
	cfg := configpkg.DefaultConfig()
	cfg.Root = root
	cfg.ModelRoot = filepath.Join(root, "models")
	cfg.TmpRoot = filepath.Join(root, "tmp")
	cfg.LocksRoot = filepath.Join(root, "locks")
	cfg.JournalDir = filepath.Join(root, "journal")
	cfg.StateDB = filepath.Join(root, "state.db")
	if err := cfg.EnsureDirectories(); err != nil {
		t.Fatalf("ensure directories: %v", err)
	}
	store := storepkg.NewStateStore(cfg.StateDB)
	if err := store.Init(); err != nil {
		t.Fatalf("state init: %v", err)
	}
	return &Service{
		cfg:   cfg,
		store: store,
		locks: NewLockManager(cfg.LocksRoot),
	}
}

func mustWriteReadyOnly(t *testing.T, modelPath string) {
	t.Helper()
	if err := os.MkdirAll(modelPath, 0o755); err != nil {
		t.Fatalf("mkdir model path: %v", err)
	}
	if err := os.WriteFile(filepath.Join(modelPath, "READY"), []byte("ok\n"), 0o444); err != nil {
		t.Fatalf("write READY: %v", err)
	}
}
