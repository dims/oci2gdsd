package app

import (
	"strings"
	"testing"
)

func TestLintProfileValid(t *testing.T) {
	profile := &ModelProfile{
		SchemaVersion: 1,
		ModelID:       "demo-model",
		ModelRevision: "r1",
		Framework:     "pytorch",
		Format:        "safetensors",
		Shards: []ModelShard{
			{
				Name:    "model-00001-of-00001.safetensors",
				Digest:  "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
				Size:    1024,
				Ordinal: 1,
			},
		},
		Integrity: ModelIntegrity{
			ManifestDigest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		},
	}
	layers := []ManifestLayer{
		{
			MediaType: MediaTypeModelShard,
			Digest:    "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			Size:      1024,
		},
	}

	got := LintProfile(profile, "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", layers)
	if !got.Valid {
		t.Fatalf("expected valid profile, got errors: %+v", got.Errors)
	}
}

func TestLintProfileInvalid(t *testing.T) {
	profile := &ModelProfile{
		SchemaVersion: 2,
		ModelID:       "",
		ModelRevision: "",
		Framework:     "",
		Format:        "",
		Shards: []ModelShard{
			{
				Name:    "",
				Digest:  "bad-digest",
				Size:    0,
				Ordinal: 1,
			},
			{
				Name:    "dup",
				Digest:  "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
				Size:    10,
				Ordinal: 1,
			},
		},
		Integrity: ModelIntegrity{
			ManifestDigest: "also-bad",
		},
	}
	got := LintProfile(profile, "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", nil)
	if got.Valid {
		t.Fatalf("expected invalid profile")
	}
	if len(got.Errors) == 0 {
		t.Fatalf("expected lint errors")
	}
}

func TestLintProfileMissingLayerForShard(t *testing.T) {
	profile := &ModelProfile{
		SchemaVersion: 1,
		ModelID:       "demo-model",
		ModelRevision: "r1",
		Framework:     "pytorch",
		Format:        "safetensors",
		Shards: []ModelShard{
			{
				Name:    "model-00001-of-00001.safetensors",
				Digest:  "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
				Size:    1024,
				Ordinal: 1,
			},
		},
		Integrity: ModelIntegrity{
			ManifestDigest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		},
	}
	layers := []ManifestLayer{
		{
			MediaType: MediaTypeModelShard,
			Digest:    "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
			Size:      1024,
		},
	}

	got := LintProfile(profile, "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", layers)
	if got.Valid {
		t.Fatalf("expected invalid profile when profile shard is missing in manifest")
	}
	found := false
	for _, err := range got.Errors {
		if strings.Contains(err, "missing in manifest layers") {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected missing shard-in-manifest error, got: %+v", got.Errors)
	}
}

func TestLintProfileRejectsTraversalShardName(t *testing.T) {
	profile := &ModelProfile{
		SchemaVersion: 1,
		ModelID:       "demo-model",
		ModelRevision: "r1",
		Framework:     "pytorch",
		Format:        "safetensors",
		Shards: []ModelShard{
			{
				Name:    "../escape",
				Digest:  "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
				Size:    1024,
				Ordinal: 1,
			},
		},
		Integrity: ModelIntegrity{
			ManifestDigest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		},
	}

	got := LintProfile(profile, "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", nil)
	if got.Valid {
		t.Fatalf("expected invalid profile")
	}
	found := false
	for _, err := range got.Errors {
		if strings.Contains(err, "shards[0].name is invalid") {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected invalid shard name lint error, got: %+v", got.Errors)
	}
}

func TestLintProfileRejectsUnknownShardKind(t *testing.T) {
	profile := &ModelProfile{
		SchemaVersion: 1,
		ModelID:       "demo-model",
		ModelRevision: "r1",
		Framework:     "pytorch",
		Format:        "safetensors",
		Shards: []ModelShard{
			{
				Name:    "model-00001-of-00001.safetensors",
				Digest:  "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
				Size:    1024,
				Ordinal: 1,
				Kind:    "unknown",
			},
		},
		Integrity: ModelIntegrity{
			ManifestDigest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		},
	}

	got := LintProfile(profile, "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", nil)
	if got.Valid {
		t.Fatalf("expected invalid profile for unknown shard kind")
	}
	found := false
	for _, err := range got.Errors {
		if strings.Contains(err, "kind must be one of") {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected shard kind lint error, got: %+v", got.Errors)
	}
}
