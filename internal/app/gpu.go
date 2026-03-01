package app

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"time"
)

type GPUProbeResult struct {
	Available   bool   `json:"available"`
	Loader      string `json:"loader"`
	Device      int    `json:"device"`
	DeviceCount int    `json:"device_count"`
	GDSDriver   bool   `json:"gds_driver"`
	Message     string `json:"message,omitempty"`
}

type GPULoadFileRequest struct {
	Path       string
	Device     int
	ChunkBytes int64
	Strict     bool
}

type GPULoadFileResult struct {
	Path       string `json:"path"`
	Bytes      int64  `json:"bytes"`
	DurationMS int64  `json:"duration_ms"`
	Direct     bool   `json:"direct"`
	Message    string `json:"message,omitempty"`
}

type GPULoadRequest struct {
	ModelID    string
	Digest     string
	Path       string
	Device     int
	ChunkBytes int64
	MaxShards  int
	Strict     bool
}

type GPULoadResult struct {
	Status         string              `json:"status"`
	ModelID        string              `json:"model_id,omitempty"`
	ManifestDigest string              `json:"manifest_digest,omitempty"`
	Path           string              `json:"path"`
	Device         int                 `json:"device"`
	Loader         string              `json:"loader"`
	Files          []GPULoadFileResult `json:"files"`
	TotalBytes     int64               `json:"total_bytes"`
	DurationMS     int64               `json:"duration_ms"`
	ReasonCode     ReasonCode          `json:"reason_code"`
	Message        string              `json:"message,omitempty"`
}

type GPULoader interface {
	Name() string
	Probe(ctx context.Context, device int) (GPUProbeResult, error)
	LoadFile(ctx context.Context, req GPULoadFileRequest) (GPULoadFileResult, error)
}

func (s *Service) GPUProbe(ctx context.Context, device int) (GPUProbeResult, error) {
	return s.gpuLoader.Probe(ctx, device)
}

func (s *Service) GPULoad(ctx context.Context, req GPULoadRequest) (GPULoadResult, error) {
	start := time.Now()
	if req.Device < 0 {
		return GPULoadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "--device must be >= 0", nil)
	}
	if req.ChunkBytes <= 0 {
		req.ChunkBytes = 16 * 1024 * 1024
	}
	if req.MaxShards <= 0 {
		req.MaxShards = 0
	}

	modelPath := strings.TrimSpace(req.Path)
	modelID := strings.TrimSpace(req.ModelID)
	manifestDigest := strings.TrimSpace(req.Digest)
	if modelPath == "" {
		if modelID == "" || manifestDigest == "" {
			return GPULoadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "either --path or (--model-id and --digest) is required", nil)
		}
		rec, ok, err := s.store.Get(modelKey(modelID, manifestDigest))
		if err != nil {
			return GPULoadResult{}, err
		}
		if !ok {
			return GPULoadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "model not found in local state", nil)
		}
		modelPath = rec.Path
	}

	valid, reason, err := s.verifyPublishedPath(modelPath)
	if err != nil || !valid {
		if reason == ReasonNone {
			reason = ReasonStateDBCorrupt
		}
		return GPULoadResult{}, NewAppError(mapReasonToExitCode(reason), reason, "path failed READY verification before GPU load", err)
	}

	md, err := loadLocalMetadata(modelPath)
	if err != nil {
		return GPULoadResult{}, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "failed to load local model metadata", err)
	}
	if modelID == "" {
		modelID = md.ModelID
	}
	if manifestDigest == "" {
		manifestDigest = md.ManifestDigest
	}

	probe, err := s.gpuLoader.Probe(ctx, req.Device)
	if err != nil {
		return GPULoadResult{}, AsAppError(err)
	}
	if !probe.Available {
		return GPULoadResult{
			Status:         "FAILED",
			ModelID:        modelID,
			ManifestDigest: manifestDigest,
			Path:           modelPath,
			Device:         req.Device,
			Loader:         s.gpuLoader.Name(),
			ReasonCode:     ReasonDirectPathIneligible,
			DurationMS:     time.Since(start).Milliseconds(),
			Message:        probe.Message,
		}, NewAppError(ExitPolicy, ReasonDirectPathIneligible, probe.Message, nil)
	}

	shards := SortShardsByOrdinal(md.Profile.Shards)
	files := make([]GPULoadFileResult, 0, len(shards))
	var total int64
	for i, shard := range shards {
		if req.MaxShards > 0 && i >= req.MaxShards {
			break
		}
		path := filepath.Join(modelPath, "shards", shard.Name)
		res, err := s.gpuLoader.LoadFile(ctx, GPULoadFileRequest{
			Path:       path,
			Device:     req.Device,
			ChunkBytes: req.ChunkBytes,
			Strict:     req.Strict,
		})
		if err != nil {
			appErr := AsAppError(err)
			return GPULoadResult{
				Status:         "FAILED",
				ModelID:        modelID,
				ManifestDigest: manifestDigest,
				Path:           modelPath,
				Device:         req.Device,
				Loader:         s.gpuLoader.Name(),
				Files:          files,
				TotalBytes:     total,
				DurationMS:     time.Since(start).Milliseconds(),
				ReasonCode:     appErr.Reason,
				Message:        fmt.Sprintf("failed loading shard %s: %v", shard.Name, appErr.Error()),
			}, appErr
		}
		files = append(files, res)
		total += res.Bytes
	}

	return GPULoadResult{
		Status:         "READY",
		ModelID:        modelID,
		ManifestDigest: manifestDigest,
		Path:           modelPath,
		Device:         req.Device,
		Loader:         s.gpuLoader.Name(),
		Files:          files,
		TotalBytes:     total,
		DurationMS:     time.Since(start).Milliseconds(),
		ReasonCode:     ReasonNone,
	}, nil
}
