package app

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	digest "github.com/opencontainers/go-digest"
)

func TestVerifyPublishedPathSuccess(t *testing.T) {
	tmp := t.TempDir()
	modelPath := filepath.Join(tmp, "models", "demo", "sha256-deadbeef")
	if err := os.MkdirAll(filepath.Join(modelPath, "metadata"), 0o755); err != nil {
		t.Fatalf("mkdir metadata: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(modelPath, "shards"), 0o755); err != nil {
		t.Fatalf("mkdir shards: %v", err)
	}
	content := []byte("hello-model")
	sum := digest.FromBytes(content).String()
	shardName := "model-00001-of-00001.safetensors"
	if err := os.WriteFile(filepath.Join(modelPath, "shards", shardName), content, 0o444); err != nil {
		t.Fatalf("write shard: %v", err)
	}
	md := localMetadata{
		SchemaVersion:  1,
		ModelID:        "demo",
		ManifestDigest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		Profile: ModelProfile{
			SchemaVersion: 1,
			ModelID:       "demo",
			ModelRevision: "r1",
			Framework:     "pytorch",
			Format:        "safetensors",
			Shards: []ModelShard{
				{
					Name:    shardName,
					Digest:  sum,
					Size:    int64(len(content)),
					Ordinal: 1,
				},
			},
			Integrity: ModelIntegrity{
				ManifestDigest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
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
	svc := &Service{}
	ok, reason, err := svc.verifyPublishedPath(modelPath)
	if err != nil {
		t.Fatalf("verifyPublishedPath error: %v", err)
	}
	if !ok {
		t.Fatalf("expected verify success, reason=%s", reason)
	}
}

func TestVerifyPublishedPathMissingReady(t *testing.T) {
	tmp := t.TempDir()
	modelPath := filepath.Join(tmp, "models", "demo")
	if err := os.MkdirAll(modelPath, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	svc := &Service{}
	ok, reason, err := svc.verifyPublishedPath(modelPath)
	if err == nil {
		t.Fatalf("expected verify error")
	}
	if ok {
		t.Fatalf("expected verify false")
	}
	if reason == ReasonNone {
		t.Fatalf("expected non-empty reason")
	}
}

func TestVerifyPublishedPathRejectsTraversalShardName(t *testing.T) {
	tmp := t.TempDir()
	modelPath := filepath.Join(tmp, "models", "demo", "sha256-deadbeef")
	if err := os.MkdirAll(filepath.Join(modelPath, "metadata"), 0o755); err != nil {
		t.Fatalf("mkdir metadata: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(modelPath, "shards"), 0o755); err != nil {
		t.Fatalf("mkdir shards: %v", err)
	}
	content := []byte("hello-model")
	if err := os.WriteFile(filepath.Join(modelPath, "shards", "safe-file.safetensors"), content, 0o444); err != nil {
		t.Fatalf("write shard: %v", err)
	}
	md := localMetadata{
		SchemaVersion:  1,
		ModelID:        "demo",
		ManifestDigest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		Profile: ModelProfile{
			SchemaVersion: 1,
			ModelID:       "demo",
			ModelRevision: "r1",
			Framework:     "pytorch",
			Format:        "safetensors",
			Shards: []ModelShard{
				{
					Name:    "../escape",
					Digest:  digest.FromBytes(content).String(),
					Size:    int64(len(content)),
					Ordinal: 1,
				},
			},
			Integrity: ModelIntegrity{
				ManifestDigest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
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
	svc := &Service{}
	ok, reason, err := svc.verifyPublishedPath(modelPath)
	if err == nil || ok {
		t.Fatalf("expected verification failure for traversal shard name")
	}
	if reason != ReasonValidationFailed {
		t.Fatalf("expected reason %s, got %s", ReasonValidationFailed, reason)
	}
}
