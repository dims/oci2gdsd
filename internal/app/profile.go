package app

import (
	"fmt"
	"sort"
	"strings"

	digest "github.com/opencontainers/go-digest"
)

const (
	MediaTypeModelArtifact = "application/vnd.acme.model.v1"
	MediaTypeModelConfig   = "application/vnd.acme.model.config.v1+json"
	MediaTypeModelShard    = "application/vnd.acme.model.shard.v1+safetensors"
	MediaTypeTensorMap     = "application/vnd.acme.model.tensor-map.v1+json"

	// ManifestDigestPlaceholder avoids impossible self-referential manifest digest
	// pinning in config payloads. The resolved manifest digest is still known at
	// pull time and used as the immutable key.
	ManifestDigestPlaceholder = "resolved-manifest-digest"
)

type ModelProfile struct {
	SchemaVersion   int            `json:"schemaVersion" yaml:"schemaVersion"`
	ModelID         string         `json:"modelId" yaml:"modelId"`
	ModelRevision   string         `json:"modelRevision" yaml:"modelRevision"`
	Framework       string         `json:"framework" yaml:"framework"`
	Format          string         `json:"format" yaml:"format"`
	Shards          []ModelShard   `json:"shards" yaml:"shards"`
	Integrity       ModelIntegrity `json:"integrity" yaml:"integrity"`
	LoadPlan        *ModelLoadPlan `json:"loadPlan,omitempty" yaml:"loadPlan,omitempty"`
	TensorMapDigest string         `json:"tensorMapDigest,omitempty" yaml:"tensorMapDigest,omitempty"`
	IOHints         map[string]any `json:"ioHints,omitempty" yaml:"ioHints,omitempty"`
}

type ModelShard struct {
	Name      string `json:"name" yaml:"name"`
	Digest    string `json:"digest" yaml:"digest"`
	Size      int64  `json:"size" yaml:"size"`
	Ordinal   int    `json:"ordinal" yaml:"ordinal"`
	Kind      string `json:"kind,omitempty" yaml:"kind,omitempty"`
	Alignment int64  `json:"alignment,omitempty" yaml:"alignment,omitempty"`
}

type ModelIntegrity struct {
	ManifestDigest string `json:"manifestDigest" yaml:"manifestDigest"`
}

type ModelLoadPlan struct {
	RecommendedOrder []int `json:"recommendedOrder,omitempty" yaml:"recommendedOrder,omitempty"`
}

type ManifestLayer struct {
	MediaType   string
	Digest      string
	Size        int64
	Annotations map[string]string
}

type ProfileLintResult struct {
	Valid    bool     `json:"valid"`
	Errors   []string `json:"errors,omitempty"`
	Warnings []string `json:"warnings,omitempty"`
}

type ProfileSummary struct {
	ModelID        string `json:"model_id"`
	ModelRevision  string `json:"model_revision"`
	Framework      string `json:"framework"`
	Format         string `json:"format"`
	ShardCount     int    `json:"shard_count"`
	TotalShardSize int64  `json:"total_shard_size"`
	ManifestDigest string `json:"manifest_digest"`
}

func LintProfile(profile *ModelProfile, manifestDigest string, layers []ManifestLayer) ProfileLintResult {
	errs := make([]string, 0)
	warnings := make([]string, 0)
	if profile == nil {
		return ProfileLintResult{
			Valid:  false,
			Errors: []string{"profile is nil"},
		}
	}
	if profile.SchemaVersion != 1 {
		errs = append(errs, "schemaVersion must be 1")
	}
	if strings.TrimSpace(profile.ModelID) == "" {
		errs = append(errs, "modelId is required")
	}
	if strings.TrimSpace(profile.ModelRevision) == "" {
		errs = append(errs, "modelRevision is required")
	}
	if strings.TrimSpace(profile.Framework) == "" {
		errs = append(errs, "framework is required")
	}
	format := strings.ToLower(strings.TrimSpace(profile.Format))
	if format == "" {
		errs = append(errs, "format is required")
	} else if format != "safetensors" && format != "gguf" {
		warnings = append(warnings, fmt.Sprintf("non-standard format %q", profile.Format))
	}
	if len(profile.Shards) == 0 {
		errs = append(errs, "at least one shard is required")
	}
	if profile.Integrity.ManifestDigest == "" {
		errs = append(errs, "integrity.manifestDigest is required")
	} else if profile.Integrity.ManifestDigest == ManifestDigestPlaceholder {
		warnings = append(warnings, "integrity.manifestDigest uses placeholder; resolved digest will be authoritative at pull time")
	} else if _, err := digest.Parse(profile.Integrity.ManifestDigest); err != nil {
		errs = append(errs, "integrity.manifestDigest is malformed")
	} else if manifestDigest != "" && profile.Integrity.ManifestDigest != manifestDigest {
		errs = append(errs, "integrity.manifestDigest must match resolved manifest digest")
	}

	ordinals := map[int]bool{}
	digests := map[string]ModelShard{}
	var total int64
	for i, shard := range profile.Shards {
		if strings.TrimSpace(shard.Name) == "" {
			errs = append(errs, fmt.Sprintf("shards[%d].name is required", i))
		} else if err := ValidateShardName(shard.Name); err != nil {
			errs = append(errs, fmt.Sprintf("shards[%d].name is invalid: %v", i, err))
		}
		if _, err := digest.Parse(shard.Digest); err != nil {
			errs = append(errs, fmt.Sprintf("shards[%d].digest is malformed", i))
		}
		if shard.Size <= 0 {
			errs = append(errs, fmt.Sprintf("shards[%d].size must be > 0", i))
		}
		if shard.Ordinal <= 0 {
			errs = append(errs, fmt.Sprintf("shards[%d].ordinal must be > 0", i))
		}
		if kind := strings.ToLower(strings.TrimSpace(shard.Kind)); kind != "" && kind != "weight" && kind != "runtime" {
			errs = append(errs, fmt.Sprintf("shards[%d].kind must be one of: weight,runtime", i))
		}
		if ordinals[shard.Ordinal] {
			errs = append(errs, fmt.Sprintf("duplicate shard ordinal %d", shard.Ordinal))
		}
		ordinals[shard.Ordinal] = true
		digests[shard.Digest] = shard
		total += shard.Size
	}

	if len(ordinals) != len(profile.Shards) {
		errs = append(errs, "missing or duplicated shard ordinals")
	}

	if len(layers) > 0 {
		layerDigests := make(map[string]bool, len(layers))
		for _, layer := range layers {
			layerDigests[layer.Digest] = true
			if !strings.Contains(layer.MediaType, "model.shard") {
				warnings = append(warnings, fmt.Sprintf("layer %s has non-shard mediaType %s", layer.Digest, layer.MediaType))
				continue
			}
			shard, ok := digests[layer.Digest]
			if !ok {
				errs = append(errs, fmt.Sprintf("manifest layer %s not present in profile shards", layer.Digest))
				continue
			}
			if shard.Size != layer.Size {
				errs = append(errs, fmt.Sprintf("size mismatch for shard %s: profile=%d manifest=%d", shard.Name, shard.Size, layer.Size))
			}
		}
		for _, shard := range profile.Shards {
			if !layerDigests[shard.Digest] {
				errs = append(errs, fmt.Sprintf("profile shard %s (%s) missing in manifest layers", shard.Name, shard.Digest))
			}
		}
	}

	return ProfileLintResult{
		Valid:    len(errs) == 0,
		Errors:   errs,
		Warnings: warnings,
	}
}

func BuildProfileSummary(profile *ModelProfile) ProfileSummary {
	if profile == nil {
		return ProfileSummary{}
	}
	var total int64
	for _, shard := range profile.Shards {
		total += shard.Size
	}
	return ProfileSummary{
		ModelID:        profile.ModelID,
		ModelRevision:  profile.ModelRevision,
		Framework:      profile.Framework,
		Format:         profile.Format,
		ShardCount:     len(profile.Shards),
		TotalShardSize: total,
		ManifestDigest: profile.Integrity.ManifestDigest,
	}
}

func SortShardsByOrdinal(shards []ModelShard) []ModelShard {
	cp := append([]ModelShard(nil), shards...)
	sort.Slice(cp, func(i, j int) bool {
		return cp[i].Ordinal < cp[j].Ordinal
	})
	return cp
}

func ShardIsWeight(shard ModelShard) bool {
	kind := strings.ToLower(strings.TrimSpace(shard.Kind))
	return kind == "" || kind == "weight"
}

func FilterWeightShards(shards []ModelShard) []ModelShard {
	out := make([]ModelShard, 0, len(shards))
	for _, shard := range shards {
		if ShardIsWeight(shard) {
			out = append(out, shard)
		}
	}
	return out
}
