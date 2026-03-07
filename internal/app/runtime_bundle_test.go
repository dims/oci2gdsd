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

func TestRuntimeBundleExcludesWeightShardsByDefault(t *testing.T) {
	svc := newRuntimeBundleTestService(t)
	manifest := "sha256:" + strings.Repeat("a", 64)
	writeReadyModelForRuntimeBundle(t, svc, "demo", manifest)

	res, err := svc.RuntimeBundle(context.Background(), RuntimeBundleRequest{
		ModelID: "demo",
		Digest:  manifest,
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
	writeReadyModelForRuntimeBundle(t, svc, "demo", manifest)

	res, err := svc.RuntimeBundle(context.Background(), RuntimeBundleRequest{
		ModelID:        "demo",
		Digest:         manifest,
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
