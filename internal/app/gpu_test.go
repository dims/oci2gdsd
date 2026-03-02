package app

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	storepkg "github.com/dims/oci2gdsd/internal/store"
	digest "github.com/opencontainers/go-digest"
)

type fakePersistentLoader struct {
	mu    sync.Mutex
	files map[string]*fakePersistentAlloc
}

type fakePersistentAlloc struct {
	bytes int64
	refs  int
}

func newFakePersistentLoader() *fakePersistentLoader {
	return &fakePersistentLoader{files: map[string]*fakePersistentAlloc{}}
}

func (l *fakePersistentLoader) Name() string {
	return "fake-gpu"
}

func (l *fakePersistentLoader) Probe(_ context.Context, device int) (GPUProbeResult, error) {
	return GPUProbeResult{
		Available:   true,
		Loader:      l.Name(),
		Device:      device,
		DeviceCount: 1,
		GDSDriver:   true,
	}, nil
}

func (l *fakePersistentLoader) LoadFile(_ context.Context, req GPULoadFileRequest) (GPULoadFileResult, error) {
	fi, err := os.Stat(req.Path)
	if err != nil {
		return GPULoadFileResult{}, err
	}
	return GPULoadFileResult{Path: req.Path, Bytes: fi.Size(), Direct: true}, nil
}

func (l *fakePersistentLoader) LoadPersistent(_ context.Context, req GPULoadFileRequest) (GPULoadFileResult, error) {
	fi, err := os.Stat(req.Path)
	if err != nil {
		return GPULoadFileResult{}, err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if alloc, ok := l.files[req.Path]; ok {
		alloc.refs++
		return GPULoadFileResult{
			Path:      req.Path,
			Bytes:     alloc.bytes,
			Direct:    true,
			Loaded:    false,
			RefCount:  alloc.refs,
			DevicePtr: fmt.Sprintf("0x%x", len(req.Path)),
		}, nil
	}
	l.files[req.Path] = &fakePersistentAlloc{bytes: fi.Size(), refs: 1}
	return GPULoadFileResult{
		Path:      req.Path,
		Bytes:     fi.Size(),
		Direct:    true,
		Loaded:    true,
		RefCount:  1,
		DevicePtr: fmt.Sprintf("0x%x", len(req.Path)),
	}, nil
}

func (l *fakePersistentLoader) ExportPersistent(_ context.Context, req GPULoadFileRequest) (GPULoadFileResult, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	alloc, ok := l.files[req.Path]
	if !ok {
		return GPULoadFileResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "persistent allocation not found", nil)
	}
	return GPULoadFileResult{
		Path:      req.Path,
		Bytes:     alloc.bytes,
		Direct:    true,
		Loaded:    true,
		RefCount:  alloc.refs,
		DevicePtr: fmt.Sprintf("0x%x", len(req.Path)),
		IPCHandle: "ZmFrZS1pcGMtaGFuZGxl",
	}, nil
}

func (l *fakePersistentLoader) UnloadPersistent(_ context.Context, req GPULoadFileRequest) (GPULoadFileResult, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	alloc, ok := l.files[req.Path]
	if !ok {
		return GPULoadFileResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "persistent allocation not found", nil)
	}
	alloc.refs--
	if alloc.refs > 0 {
		return GPULoadFileResult{
			Path:      req.Path,
			Bytes:     0,
			Direct:    true,
			Loaded:    false,
			RefCount:  alloc.refs,
			DevicePtr: fmt.Sprintf("0x%x", len(req.Path)),
		}, nil
	}
	delete(l.files, req.Path)
	return GPULoadFileResult{
		Path:      req.Path,
		Bytes:     alloc.bytes,
		Direct:    true,
		Loaded:    false,
		RefCount:  0,
		DevicePtr: fmt.Sprintf("0x%x", len(req.Path)),
	}, nil
}

func (l *fakePersistentLoader) ListPersistent(_ context.Context, _ int) ([]GPULoadFileResult, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([]GPULoadFileResult, 0, len(l.files))
	for p, alloc := range l.files {
		out = append(out, GPULoadFileResult{
			Path:      p,
			Bytes:     alloc.bytes,
			Direct:    true,
			Loaded:    true,
			RefCount:  alloc.refs,
			DevicePtr: fmt.Sprintf("0x%x", len(p)),
		})
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].Path < out[j].Path
	})
	return out, nil
}

func TestGPULoadInvalidModeRejected(t *testing.T) {
	svc := &Service{}
	_, err := svc.GPULoad(context.Background(), GPULoadRequest{
		Device: 0,
		Mode:   "unknown",
	})
	if err == nil {
		t.Fatalf("expected error for invalid mode")
	}
	appErr := AsAppError(err)
	if appErr.Reason != ReasonValidationFailed {
		t.Fatalf("expected reason %s, got %s", ReasonValidationFailed, appErr.Reason)
	}
}

func TestGPULoadPersistentLeaseLifecycle(t *testing.T) {
	svc := newStateOnlyService(t)
	loader := newFakePersistentLoader()
	svc.gpuLoader = loader

	modelID := "demo"
	manifest := "sha256:" + strings.Repeat("d", 64)
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

	first, err := svc.GPULoad(context.Background(), GPULoadRequest{
		ModelID:     modelID,
		Digest:      manifest,
		LeaseHolder: "holder-a",
		Device:      0,
		ChunkBytes:  4 * 1024,
		Mode:        "persistent",
		Strict:      true,
	})
	if err != nil {
		t.Fatalf("first gpu load: %v", err)
	}
	if !first.Persistent || first.Mode != "persistent" {
		t.Fatalf("unexpected first load mode: %+v", first)
	}
	if len(first.Files) != 1 || !first.Files[0].Loaded || first.Files[0].RefCount != 1 {
		t.Fatalf("unexpected first file result: %+v", first.Files)
	}

	second, err := svc.GPULoad(context.Background(), GPULoadRequest{
		ModelID:     modelID,
		Digest:      manifest,
		LeaseHolder: "holder-b",
		Device:      0,
		ChunkBytes:  4 * 1024,
		Mode:        "persistent",
		Strict:      true,
	})
	if err != nil {
		t.Fatalf("second gpu load: %v", err)
	}
	if len(second.Files) != 1 || second.Files[0].Loaded || second.Files[0].RefCount != 2 {
		t.Fatalf("unexpected second file result: %+v", second.Files)
	}

	status, err := svc.GPUListPersistent(context.Background(), 0)
	if err != nil {
		t.Fatalf("gpu status: %v", err)
	}
	if len(status) != 1 || status[0].RefCount != 2 {
		t.Fatalf("unexpected gpu status: %+v", status)
	}

	firstUnload, err := svc.GPUUnload(context.Background(), GPUUnloadRequest{
		ModelID:     modelID,
		Digest:      manifest,
		LeaseHolder: "holder-a",
		Device:      0,
	})
	if err != nil {
		t.Fatalf("first unload: %v", err)
	}
	if firstUnload.RemainingLeases != 1 {
		t.Fatalf("expected remaining leases=1, got %d", firstUnload.RemainingLeases)
	}
	if firstUnload.ReleasedBytes != 0 {
		t.Fatalf("expected no bytes released while refs remain, got %d", firstUnload.ReleasedBytes)
	}

	secondUnload, err := svc.GPUUnload(context.Background(), GPUUnloadRequest{
		ModelID:     modelID,
		Digest:      manifest,
		LeaseHolder: "holder-b",
		Device:      0,
	})
	if err != nil {
		t.Fatalf("second unload: %v", err)
	}
	if secondUnload.RemainingLeases != 0 {
		t.Fatalf("expected remaining leases=0, got %d", secondUnload.RemainingLeases)
	}
	if secondUnload.ReleasedBytes != shardSize {
		t.Fatalf("expected released bytes=%d, got %d", shardSize, secondUnload.ReleasedBytes)
	}

	status, err = svc.GPUListPersistent(context.Background(), 0)
	if err != nil {
		t.Fatalf("gpu status after unload: %v", err)
	}
	if len(status) != 0 {
		t.Fatalf("expected no persistent allocations after unload, got %+v", status)
	}

	stored, ok, err := svc.store.Get(modelKey(modelID, manifest))
	if err != nil {
		t.Fatalf("store get: %v", err)
	}
	if !ok {
		t.Fatalf("expected model record")
	}
	if len(stored.Leases) != 0 {
		t.Fatalf("expected no active leases, got %+v", stored.Leases)
	}
	if !stored.Releasable || stored.ReleasableAt == nil {
		t.Fatalf("expected model to become releasable after final unload")
	}
}

func TestGPUExportReturnsPersistentIPCHandle(t *testing.T) {
	svc := newStateOnlyService(t)
	loader := newFakePersistentLoader()
	svc.gpuLoader = loader

	modelID := "demo"
	manifest := "sha256:" + strings.Repeat("e", 64)
	modelPath, _ := writeReadyModelForGPUTest(t, svc.cfg.ModelRoot, modelID, manifest)

	now := time.Now().UTC()
	rec := &storepkg.ModelRecord{
		Key:            modelKey(modelID, manifest),
		ModelID:        modelID,
		ManifestDigest: manifest,
		Status:         StateReady,
		Path:           modelPath,
		Bytes:          1,
		CreatedAt:      now,
		UpdatedAt:      now,
		LastAccessedAt: now,
	}
	if err := svc.store.Put(rec); err != nil {
		t.Fatalf("put model record: %v", err)
	}

	_, err := svc.GPULoad(context.Background(), GPULoadRequest{
		ModelID:     modelID,
		Digest:      manifest,
		LeaseHolder: "holder-export",
		Device:      0,
		ChunkBytes:  4 * 1024,
		Mode:        "persistent",
		Strict:      true,
	})
	if err != nil {
		t.Fatalf("gpu persistent load: %v", err)
	}

	res, err := svc.GPUExport(context.Background(), GPUExportRequest{
		ModelID: modelID,
		Digest:  manifest,
		Device:  0,
	})
	if err != nil {
		t.Fatalf("gpu export: %v", err)
	}
	if res.Status != "READY" {
		t.Fatalf("unexpected export status: %+v", res)
	}
	if len(res.Files) != 1 {
		t.Fatalf("expected 1 exported shard, got %d", len(res.Files))
	}
	if strings.TrimSpace(res.Files[0].IPCHandle) == "" {
		t.Fatalf("expected non-empty ipc handle: %+v", res.Files[0])
	}
}

func TestGPUWeightShardsFiltersRuntimeEntries(t *testing.T) {
	shards := []ModelShard{
		{Name: "weights-1.safetensors", Ordinal: 1, Kind: "weight"},
		{Name: "config.json", Ordinal: 2, Kind: "runtime"},
		{Name: "weights-2.safetensors", Ordinal: 3},
	}
	got, err := gpuWeightShards(ModelProfile{Shards: shards})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 weight shards, got %d", len(got))
	}
	if got[0].Name != "weights-1.safetensors" || got[1].Name != "weights-2.safetensors" {
		t.Fatalf("unexpected weight shard ordering/filter result: %+v", got)
	}
}

func writeReadyModelForGPUTest(t *testing.T, modelRoot, modelID, manifest string) (string, int64) {
	t.Helper()
	modelPath := filepath.Join(modelRoot, modelID, strings.ReplaceAll(manifest, ":", "-"))
	if err := os.MkdirAll(filepath.Join(modelPath, "metadata"), 0o755); err != nil {
		t.Fatalf("mkdir metadata: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(modelPath, "shards"), 0o755); err != nil {
		t.Fatalf("mkdir shards: %v", err)
	}
	content := []byte("gpu-test-shard-content")
	shardName := "model-00001-of-00001.safetensors"
	if err := os.WriteFile(filepath.Join(modelPath, "shards", shardName), content, 0o444); err != nil {
		t.Fatalf("write shard: %v", err)
	}
	md := localMetadata{
		SchemaVersion:  1,
		ModelID:        modelID,
		ManifestDigest: manifest,
		Profile: ModelProfile{
			SchemaVersion: 1,
			ModelID:       modelID,
			ModelRevision: "r1",
			Framework:     "pytorch",
			Format:        "safetensors",
			Shards: []ModelShard{{
				Name:    shardName,
				Digest:  digest.FromBytes(content).String(),
				Size:    int64(len(content)),
				Ordinal: 1,
			}},
			Integrity: ModelIntegrity{ManifestDigest: manifest},
		},
	}
	mb, err := json.Marshal(md)
	if err != nil {
		t.Fatalf("marshal metadata: %v", err)
	}
	if err := os.WriteFile(filepath.Join(modelPath, "metadata", "model.json"), mb, 0o444); err != nil {
		t.Fatalf("write model metadata: %v", err)
	}
	if err := os.WriteFile(filepath.Join(modelPath, "READY"), []byte("ok\n"), 0o444); err != nil {
		t.Fatalf("write READY marker: %v", err)
	}
	return modelPath, int64(len(content))
}
