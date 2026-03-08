package app

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	configpkg "github.com/dims/oci2gdsd/internal/config"
	storepkg "github.com/dims/oci2gdsd/internal/store"
	digest "github.com/opencontainers/go-digest"
)

func newRuntimeBundleTestService(t *testing.T) *Service {
	t.Helper()
	root := t.TempDir()
	cfg := configpkg.DefaultConfig()
	cfg.Root = root
	cfg.ModelRoot = filepath.Join(root, "models")
	cfg.TmpRoot = filepath.Join(root, "tmp")
	cfg.LocksRoot = filepath.Join(root, "locks")
	cfg.JournalDir = filepath.Join(root, "journal")
	cfg.StateDB = filepath.Join(root, "state.db")
	cfg.Retention.MinFreeBytes = 0
	if err := cfg.EnsureDirectories(); err != nil {
		t.Fatalf("ensure directories: %v", err)
	}
	store := storepkg.NewStateStore(cfg.StateDB)
	if err := store.Init(); err != nil {
		t.Fatalf("state init: %v", err)
	}
	return &Service{
		cfg:       cfg,
		store:     store,
		locks:     NewLockManager(cfg.LocksRoot),
		gpuLoader: newFakePersistentLoader(),
	}
}

func writeReadyModelForRuntimeBundle(t *testing.T, svc *Service, modelID, manifest string) string {
	t.Helper()
	modelPath := filepath.Join(svc.cfg.ModelRoot, modelID, strings.ReplaceAll(manifest, ":", "-"))
	if err := os.MkdirAll(filepath.Join(modelPath, "metadata"), 0o755); err != nil {
		t.Fatalf("mkdir metadata: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(modelPath, "shards"), 0o755); err != nil {
		t.Fatalf("mkdir shards: %v", err)
	}

	weight := []byte("weights-blob")
	config := []byte("{}\n")
	tokenizer := []byte("{\"version\":1}\n")
	if err := os.WriteFile(filepath.Join(modelPath, "shards", "weights-00001.safetensors"), weight, 0o444); err != nil {
		t.Fatalf("write weight shard: %v", err)
	}
	if err := os.WriteFile(filepath.Join(modelPath, "shards", "config.json"), config, 0o444); err != nil {
		t.Fatalf("write config shard: %v", err)
	}
	if err := os.WriteFile(filepath.Join(modelPath, "shards", "tokenizer.json"), tokenizer, 0o444); err != nil {
		t.Fatalf("write tokenizer shard: %v", err)
	}
	if err := os.WriteFile(filepath.Join(modelPath, "metadata", "generation_config.json"), []byte("{}\n"), 0o444); err != nil {
		t.Fatalf("write generation config: %v", err)
	}

	md := localMetadata{
		SchemaVersion:  1,
		ModelID:        modelID,
		ManifestDigest: manifest,
		Reference:      "registry.example.invalid/models/demo@" + manifest,
		PublishedAt:    time.Now().UTC(),
		Bytes:          int64(len(weight) + len(config) + len(tokenizer)),
		Profile: ModelProfile{
			SchemaVersion: 1,
			ModelID:       modelID,
			ModelRevision: "r1",
			Framework:     "pytorch",
			Format:        "safetensors",
			Shards: []ModelShard{
				{
					Name:    "weights-00001.safetensors",
					Digest:  digest.FromBytes(weight).String(),
					Size:    int64(len(weight)),
					Ordinal: 1,
					Kind:    "weight",
				},
				{
					Name:    "config.json",
					Digest:  digest.FromBytes(config).String(),
					Size:    int64(len(config)),
					Ordinal: 2,
					Kind:    "runtime",
				},
				{
					Name:    "tokenizer.json",
					Digest:  digest.FromBytes(tokenizer).String(),
					Size:    int64(len(tokenizer)),
					Ordinal: 3,
					Kind:    "runtime",
				},
			},
			Integrity: ModelIntegrity{ManifestDigest: manifest},
		},
	}
	b, err := json.Marshal(md)
	if err != nil {
		t.Fatalf("marshal metadata: %v", err)
	}
	if err := os.WriteFile(filepath.Join(modelPath, "metadata", "model.json"), b, 0o444); err != nil {
		t.Fatalf("write model metadata: %v", err)
	}
	if err := os.WriteFile(filepath.Join(modelPath, "READY"), []byte("ok\n"), 0o444); err != nil {
		t.Fatalf("write READY marker: %v", err)
	}

	rec := &storepkg.ModelRecord{
		Key:            modelKey(modelID, manifest),
		ModelID:        modelID,
		ManifestDigest: manifest,
		Status:         StateReady,
		Path:           modelPath,
		CreatedAt:      time.Now().UTC(),
		UpdatedAt:      time.Now().UTC(),
		LastAccessedAt: time.Now().UTC(),
	}
	if err := svc.store.Put(rec); err != nil {
		t.Fatalf("store put: %v", err)
	}
	return modelPath
}

func writeAllocationForRuntimeBundle(t *testing.T, svc *Service, allocationID, modelID, manifest, modelPath string) {
	t.Helper()
	rec := &storepkg.AllocationRecord{
		AllocationID:   allocationID,
		ModelKey:       modelKey(modelID, manifest),
		ModelID:        modelID,
		ManifestDigest: manifest,
		Path:           modelPath,
		LeaseHolder:    "runtime-bundle-test",
		DeviceUUID:     "GPU-00000000-0000-0000-0000-000000000000",
		DeviceIndex:    0,
		Status:         "READY",
		CreatedAt:      time.Now().UTC(),
		UpdatedAt:      time.Now().UTC(),
	}
	if err := svc.store.PutAllocation(rec); err != nil {
		t.Fatalf("allocation put: %v", err)
	}
}

func TestRuntimeBundleExcludesWeightShardsByDefault(t *testing.T) {
	svc := newRuntimeBundleTestService(t)
	manifest := "sha256:" + strings.Repeat("a", 64)
	modelPath := writeReadyModelForRuntimeBundle(t, svc, "demo", manifest)
	const allocationID = "alloc-runtime-bundle-default"
	writeAllocationForRuntimeBundle(t, svc, allocationID, "demo", manifest, modelPath)

	res, err := svc.RuntimeBundle(context.Background(), RuntimeBundleRequest{
		AllocationID: allocationID,
	})
	if err != nil {
		t.Fatalf("runtime bundle failed: %v", err)
	}
	if res.Status != "READY" {
		t.Fatalf("expected READY status, got %+v", res)
	}
	if res.FileCount == 0 {
		t.Fatalf("expected non-empty runtime bundle")
	}
	archivePaths := map[string]bool{}
	for _, f := range res.Files {
		archivePaths[f.ArchivePath] = true
	}
	if archivePaths["shards/weights-00001.safetensors"] {
		t.Fatalf("weight shard should not be present when include_weights=false")
	}
	if !archivePaths["shards/config.json"] {
		t.Fatalf("missing runtime config shard in runtime bundle")
	}
	if !archivePaths["shards/tokenizer.json"] {
		t.Fatalf("missing runtime tokenizer shard in runtime bundle")
	}
	if !archivePaths["metadata/model.json"] {
		t.Fatalf("missing metadata/model.json in runtime bundle")
	}
}

func TestRuntimeBundleIncludesWeightsWhenRequested(t *testing.T) {
	svc := newRuntimeBundleTestService(t)
	manifest := "sha256:" + strings.Repeat("b", 64)
	modelPath := writeReadyModelForRuntimeBundle(t, svc, "demo", manifest)
	const allocationID = "alloc-runtime-bundle-weights"
	writeAllocationForRuntimeBundle(t, svc, allocationID, "demo", manifest, modelPath)

	res, err := svc.RuntimeBundle(context.Background(), RuntimeBundleRequest{
		AllocationID:   allocationID,
		IncludeWeights: true,
	})
	if err != nil {
		t.Fatalf("runtime bundle failed: %v", err)
	}
	archivePaths := map[string]bool{}
	for _, f := range res.Files {
		archivePaths[f.ArchivePath] = true
	}
	if !archivePaths["shards/weights-00001.safetensors"] {
		t.Fatalf("expected weight shard when include_weights=true")
	}
}

func TestRuntimeBundleTokenExpires(t *testing.T) {
	svc := newRuntimeBundleTestService(t)
	svc.bundleTTL = 5 * time.Millisecond

	manifest := "sha256:" + strings.Repeat("c", 64)
	modelPath := writeReadyModelForRuntimeBundle(t, svc, "demo", manifest)
	const allocationID = "alloc-runtime-bundle-token-expiry"
	writeAllocationForRuntimeBundle(t, svc, allocationID, "demo", manifest, modelPath)

	token, _ := svc.issueRuntimeBundleToken(allocationID, false)
	if strings.TrimSpace(token) == "" {
		t.Fatalf("expected non-empty token")
	}
	if _, _, err := svc.resolveRuntimeBundleToken(token); err != nil {
		t.Fatalf("expected token to resolve before expiry: %v", err)
	}

	time.Sleep(20 * time.Millisecond)
	_, _, err := svc.resolveRuntimeBundleToken(token)
	if err == nil {
		t.Fatalf("expected token resolution to fail after expiry")
	}
	appErr := AsAppError(err)
	if appErr.Reason != ReasonValidationFailed {
		t.Fatalf("expected reason %s, got %s", ReasonValidationFailed, appErr.Reason)
	}
	if !strings.Contains(strings.ToLower(appErr.Error()), "token") {
		t.Fatalf("expected token-related error, got %v", appErr)
	}
}

func TestRuntimeBundleTokenRevokedByAllocation(t *testing.T) {
	svc := newRuntimeBundleTestService(t)
	svc.bundleTTL = 5 * time.Minute

	manifest := "sha256:" + strings.Repeat("d", 64)
	modelPath := writeReadyModelForRuntimeBundle(t, svc, "demo", manifest)
	const allocationID = "alloc-runtime-bundle-token-revoke"
	writeAllocationForRuntimeBundle(t, svc, allocationID, "demo", manifest, modelPath)

	tokenA, _ := svc.issueRuntimeBundleToken(allocationID, false)
	tokenB, _ := svc.issueRuntimeBundleToken(allocationID, true)
	if _, _, err := svc.resolveRuntimeBundleToken(tokenA); err != nil {
		t.Fatalf("expected tokenA to resolve: %v", err)
	}
	if _, _, err := svc.resolveRuntimeBundleToken(tokenB); err != nil {
		t.Fatalf("expected tokenB to resolve: %v", err)
	}

	svc.revokeRuntimeBundleTokensForAllocation(allocationID)

	if _, _, err := svc.resolveRuntimeBundleToken(tokenA); err == nil {
		t.Fatalf("expected tokenA resolution to fail after revoke")
	}
	if _, _, err := svc.resolveRuntimeBundleToken(tokenB); err == nil {
		t.Fatalf("expected tokenB resolution to fail after revoke")
	}
}

func TestRuntimeBundleTokenCacheEvictionAndMetrics(t *testing.T) {
	svc := newRuntimeBundleTestService(t)
	svc.bundleTTL = 10 * time.Minute
	svc.cfg.Runtime.MaxRuntimeBundleTokens = 2

	manifest := "sha256:" + strings.Repeat("e", 64)
	modelPath := writeReadyModelForRuntimeBundle(t, svc, "demo", manifest)
	const allocationID = "alloc-runtime-bundle-token-evict"
	writeAllocationForRuntimeBundle(t, svc, allocationID, "demo", manifest, modelPath)

	tokenA, _ := svc.issueRuntimeBundleToken(allocationID, false)
	tokenB, _ := svc.issueRuntimeBundleToken(allocationID, false)
	tokenC, _ := svc.issueRuntimeBundleToken(allocationID, false)

	if _, _, err := svc.resolveRuntimeBundleToken(tokenA); err == nil {
		t.Fatalf("expected oldest token to be evicted after limit enforcement")
	}
	if _, _, err := svc.resolveRuntimeBundleToken(tokenB); err != nil {
		t.Fatalf("expected tokenB to remain valid: %v", err)
	}
	if _, _, err := svc.resolveRuntimeBundleToken(tokenC); err != nil {
		t.Fatalf("expected tokenC to remain valid: %v", err)
	}

	metrics := svc.CacheMetricsSnapshot()
	if metrics.RuntimeBundleEvictions == 0 {
		t.Fatalf("expected runtime bundle eviction metric > 0, got %+v", metrics)
	}
	if metrics.RuntimeBundleHits < 2 {
		t.Fatalf("expected at least two runtime bundle hits, got %+v", metrics)
	}
	if metrics.RuntimeBundleMisses == 0 {
		t.Fatalf("expected at least one runtime bundle miss, got %+v", metrics)
	}
}
