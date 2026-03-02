package app

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	storepkg "github.com/dims/oci2gdsd/internal/store"
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
	Loaded     bool   `json:"loaded"`
	RefCount   int    `json:"ref_count,omitempty"`
	DevicePtr  string `json:"device_ptr,omitempty"`
	IPCHandle  string `json:"ipc_handle,omitempty"`
	Message    string `json:"message,omitempty"`
}

type GPULoadRequest struct {
	ModelID     string `json:"model_id"`
	Digest      string `json:"digest"`
	Path        string `json:"path"`
	LeaseHolder string `json:"lease_holder"`
	Device      int    `json:"device"`
	ChunkBytes  int64  `json:"chunk_bytes"`
	MaxShards   int    `json:"max_shards"`
	Strict      bool   `json:"strict"`
	Mode        string `json:"mode"`
}

type GPULoadResult struct {
	Status         string              `json:"status"`
	ModelID        string              `json:"model_id,omitempty"`
	ManifestDigest string              `json:"manifest_digest,omitempty"`
	LeaseHolder    string              `json:"lease_holder,omitempty"`
	Path           string              `json:"path"`
	Device         int                 `json:"device"`
	Loader         string              `json:"loader"`
	Mode           string              `json:"mode"`
	Persistent     bool                `json:"persistent"`
	Files          []GPULoadFileResult `json:"files"`
	TotalBytes     int64               `json:"total_bytes"`
	DurationMS     int64               `json:"duration_ms"`
	ReasonCode     ReasonCode          `json:"reason_code"`
	Message        string              `json:"message,omitempty"`
}

type GPUUnloadRequest struct {
	ModelID     string `json:"model_id"`
	Digest      string `json:"digest"`
	Path        string `json:"path"`
	LeaseHolder string `json:"lease_holder"`
	Device      int    `json:"device"`
}

type GPUUnloadResult struct {
	Status          string              `json:"status"`
	ModelID         string              `json:"model_id,omitempty"`
	ManifestDigest  string              `json:"manifest_digest,omitempty"`
	LeaseHolder     string              `json:"lease_holder,omitempty"`
	Path            string              `json:"path"`
	Device          int                 `json:"device"`
	Loader          string              `json:"loader"`
	Files           []GPULoadFileResult `json:"files"`
	ReleasedBytes   int64               `json:"released_bytes"`
	RemainingLeases int                 `json:"remaining_leases"`
	DurationMS      int64               `json:"duration_ms"`
	ReasonCode      ReasonCode          `json:"reason_code"`
	Message         string              `json:"message,omitempty"`
}

type GPUExportRequest struct {
	ModelID   string `json:"model_id"`
	Digest    string `json:"digest"`
	Path      string `json:"path"`
	Device    int    `json:"device"`
	MaxShards int    `json:"max_shards"`
}

type GPUExportResult struct {
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
	LoadPersistent(ctx context.Context, req GPULoadFileRequest) (GPULoadFileResult, error)
	ExportPersistent(ctx context.Context, req GPULoadFileRequest) (GPULoadFileResult, error)
	UnloadPersistent(ctx context.Context, req GPULoadFileRequest) (GPULoadFileResult, error)
	ListPersistent(ctx context.Context, device int) ([]GPULoadFileResult, error)
}

type GPULoaderSession interface {
	BeginSession(ctx context.Context, device int) (end func(), err error)
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
	mode := strings.ToLower(strings.TrimSpace(req.Mode))
	if mode == "" {
		mode = "benchmark"
	}
	switch mode {
	case "benchmark":
	case "persistent":
	default:
		return GPULoadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "gpu load --mode must be one of: benchmark,persistent", nil)
	}

	modelPath := strings.TrimSpace(req.Path)
	modelID := strings.TrimSpace(req.ModelID)
	manifestDigest := strings.TrimSpace(req.Digest)
	if modelPath == "" {
		if modelID == "" || manifestDigest == "" {
			return GPULoadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "either --path or (--model-id and --digest) is required", nil)
		}
		if err := s.validateModelID(modelID); err != nil {
			return GPULoadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "invalid --model-id", err)
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
			Mode:           mode,
			Persistent:     false,
			ReasonCode:     ReasonDirectPathIneligible,
			DurationMS:     time.Since(start).Milliseconds(),
			Message:        probe.Message,
		}, NewAppError(ExitPolicy, ReasonDirectPathIneligible, probe.Message, nil)
	}

	switch mode {
	case "benchmark":
		return s.gpuBenchmarkLoad(ctx, start, req, modelPath, modelID, manifestDigest, md)
	case "persistent":
		return s.gpuPersistentLoad(ctx, start, req, modelPath, modelID, manifestDigest, md)
	default:
		return GPULoadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "gpu load --mode must be one of: benchmark,persistent", nil)
	}
}

func gpuWeightShards(profile ModelProfile) ([]ModelShard, error) {
	weights := SortShardsByOrdinal(FilterWeightShards(profile.Shards))
	if len(weights) == 0 {
		return nil, NewAppError(ExitValidation, ReasonValidationFailed, "profile has no weight shards for GPU load", nil)
	}
	return weights, nil
}

func (s *Service) gpuBenchmarkLoad(ctx context.Context, start time.Time, req GPULoadRequest, modelPath, modelID, manifestDigest string, md *localMetadata) (GPULoadResult, error) {
	if sessionLoader, ok := s.gpuLoader.(GPULoaderSession); ok {
		end, err := sessionLoader.BeginSession(ctx, req.Device)
		if err != nil {
			appErr := AsAppError(err)
			return GPULoadResult{
				Status:         "FAILED",
				ModelID:        modelID,
				ManifestDigest: manifestDigest,
				LeaseHolder:    strings.TrimSpace(req.LeaseHolder),
				Path:           modelPath,
				Device:         req.Device,
				Loader:         s.gpuLoader.Name(),
				Mode:           "benchmark",
				Persistent:     false,
				ReasonCode:     appErr.Reason,
				DurationMS:     time.Since(start).Milliseconds(),
				Message:        appErr.Error(),
			}, appErr
		}
		defer end()
	}

	shards, err := gpuWeightShards(md.Profile)
	if err != nil {
		return GPULoadResult{}, err
	}
	files := make([]GPULoadFileResult, 0, len(shards))
	var total int64
	for i, shard := range shards {
		if req.MaxShards > 0 && i >= req.MaxShards {
			break
		}
		if err := ValidateShardName(shard.Name); err != nil {
			return GPULoadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, fmt.Sprintf("invalid shard name %q: %v", shard.Name, err), nil)
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
				Mode:           "benchmark",
				Persistent:     false,
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
		LeaseHolder:    strings.TrimSpace(req.LeaseHolder),
		Path:           modelPath,
		Device:         req.Device,
		Loader:         s.gpuLoader.Name(),
		Mode:           "benchmark",
		Persistent:     false,
		Files:          files,
		TotalBytes:     total,
		DurationMS:     time.Since(start).Milliseconds(),
		ReasonCode:     ReasonNone,
		Message:        "benchmark mode completed; data is not retained in GPU memory after command exit",
	}, nil
}

func (s *Service) gpuPersistentLoad(ctx context.Context, start time.Time, req GPULoadRequest, modelPath, modelID, manifestDigest string, md *localMetadata) (GPULoadResult, error) {
	leaseHolder := strings.TrimSpace(req.LeaseHolder)
	if leaseHolder == "" {
		return GPULoadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "--lease-holder is required for gpu load --mode persistent", nil)
	}
	key := modelKey(modelID, manifestDigest)
	unlock, _, err := s.locks.Acquire(ctx, key, true)
	if err != nil {
		return GPULoadResult{}, err
	}
	defer unlock()

	rec, ok, err := s.store.Get(key)
	if err != nil {
		return GPULoadResult{}, err
	}
	if !ok || rec.Status != StateReady {
		return GPULoadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "model must exist in READY state before persistent gpu load", nil)
	}

	hadLease := hasLeaseHolder(rec.Leases, leaseHolder)
	rec.AcquireLease(leaseHolder)
	rec.Releasable = false
	rec.ReleasableAt = nil
	rec.LastError = ReasonNone
	rec.LastErrorMessage = ""
	if err := s.store.Put(rec); err != nil {
		return GPULoadResult{}, err
	}
	rollbackLease := !hadLease

	shards, err := gpuWeightShards(md.Profile)
	if err != nil {
		if rollbackLease {
			_, _ = s.releaseLeaseOnlyLocked(rec, leaseHolder)
		}
		return GPULoadResult{}, err
	}
	files := make([]GPULoadFileResult, 0, len(shards))
	var total int64
	for i, shard := range shards {
		if req.MaxShards > 0 && i >= req.MaxShards {
			break
		}
		if err := ValidateShardName(shard.Name); err != nil {
			if rollbackLease {
				_, _ = s.releaseLeaseOnlyLocked(rec, leaseHolder)
			}
			return GPULoadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, fmt.Sprintf("invalid shard name %q: %v", shard.Name, err), nil)
		}
		path := filepath.Join(modelPath, "shards", shard.Name)
		res, err := s.gpuLoader.LoadPersistent(ctx, GPULoadFileRequest{
			Path:       path,
			Device:     req.Device,
			ChunkBytes: req.ChunkBytes,
			Strict:     req.Strict,
		})
		if err != nil {
			if rollbackLease {
				_, _ = s.releaseLeaseOnlyLocked(rec, leaseHolder)
			}
			appErr := AsAppError(err)
			return GPULoadResult{
				Status:         "FAILED",
				ModelID:        modelID,
				ManifestDigest: manifestDigest,
				LeaseHolder:    leaseHolder,
				Path:           modelPath,
				Device:         req.Device,
				Loader:         s.gpuLoader.Name(),
				Mode:           "persistent",
				Persistent:     true,
				Files:          files,
				TotalBytes:     total,
				DurationMS:     time.Since(start).Milliseconds(),
				ReasonCode:     appErr.Reason,
				Message:        fmt.Sprintf("failed persistent-loading shard %s: %v", shard.Name, appErr.Error()),
			}, appErr
		}
		files = append(files, res)
		total += res.Bytes
	}

	return GPULoadResult{
		Status:         "READY",
		ModelID:        modelID,
		ManifestDigest: manifestDigest,
		LeaseHolder:    leaseHolder,
		Path:           modelPath,
		Device:         req.Device,
		Loader:         s.gpuLoader.Name(),
		Mode:           "persistent",
		Persistent:     true,
		Files:          files,
		TotalBytes:     total,
		DurationMS:     time.Since(start).Milliseconds(),
		ReasonCode:     ReasonNone,
		Message:        "persistent mode loaded weight shards into GPU memory for the current oci2gdsd process lifetime and attached a lease; unload via gpu unload",
	}, nil
}

func (s *Service) GPUUnload(ctx context.Context, req GPUUnloadRequest) (GPUUnloadResult, error) {
	start := time.Now()
	if req.Device < 0 {
		return GPUUnloadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "--device must be >= 0", nil)
	}
	leaseHolder := strings.TrimSpace(req.LeaseHolder)
	if leaseHolder == "" {
		return GPUUnloadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "--lease-holder is required for gpu unload", nil)
	}

	modelPath := strings.TrimSpace(req.Path)
	modelID := strings.TrimSpace(req.ModelID)
	manifestDigest := strings.TrimSpace(req.Digest)
	if modelPath == "" {
		if modelID == "" || manifestDigest == "" {
			return GPUUnloadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "either --path or (--model-id and --digest) is required", nil)
		}
		if err := s.validateModelID(modelID); err != nil {
			return GPUUnloadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "invalid --model-id", err)
		}
		rec, ok, err := s.store.Get(modelKey(modelID, manifestDigest))
		if err != nil {
			return GPUUnloadResult{}, err
		}
		if !ok {
			return GPUUnloadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "model not found in local state", nil)
		}
		modelPath = rec.Path
	}

	valid, reason, err := s.verifyPublishedPath(modelPath)
	if err != nil || !valid {
		if reason == ReasonNone {
			reason = ReasonStateDBCorrupt
		}
		return GPUUnloadResult{}, NewAppError(mapReasonToExitCode(reason), reason, "path failed READY verification before gpu unload", err)
	}

	md, err := loadLocalMetadata(modelPath)
	if err != nil {
		return GPUUnloadResult{}, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "failed to load local model metadata", err)
	}
	if modelID == "" {
		modelID = md.ModelID
	}
	if manifestDigest == "" {
		manifestDigest = md.ManifestDigest
	}

	key := modelKey(modelID, manifestDigest)
	unlock, _, err := s.locks.Acquire(ctx, key, true)
	if err != nil {
		return GPUUnloadResult{}, err
	}
	defer unlock()

	rec, ok, err := s.store.Get(key)
	if err != nil {
		return GPUUnloadResult{}, err
	}
	if !ok {
		return GPUUnloadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "model not found in local state", nil)
	}
	if !hasLeaseHolder(rec.Leases, leaseHolder) {
		return GPUUnloadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, fmt.Sprintf("lease holder %q not found on model", leaseHolder), nil)
	}

	shards, err := gpuWeightShards(md.Profile)
	if err != nil {
		return GPUUnloadResult{}, err
	}
	files := make([]GPULoadFileResult, 0, len(shards))
	var total int64
	for _, shard := range shards {
		if err := ValidateShardName(shard.Name); err != nil {
			return GPUUnloadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, fmt.Sprintf("invalid shard name %q: %v", shard.Name, err), nil)
		}
		path := filepath.Join(modelPath, "shards", shard.Name)
		res, err := s.gpuLoader.UnloadPersistent(ctx, GPULoadFileRequest{
			Path:   path,
			Device: req.Device,
		})
		if err != nil {
			appErr := AsAppError(err)
			return GPUUnloadResult{
				Status:         "FAILED",
				ModelID:        modelID,
				ManifestDigest: manifestDigest,
				LeaseHolder:    leaseHolder,
				Path:           modelPath,
				Device:         req.Device,
				Loader:         s.gpuLoader.Name(),
				Files:          files,
				ReleasedBytes:  total,
				DurationMS:     time.Since(start).Milliseconds(),
				ReasonCode:     appErr.Reason,
				Message:        fmt.Sprintf("failed persistent-unloading shard %s: %v", shard.Name, appErr.Error()),
			}, appErr
		}
		files = append(files, res)
		total += res.Bytes
	}

	remaining, err := s.releaseLeaseOnlyLocked(rec, leaseHolder)
	if err != nil {
		return GPUUnloadResult{}, err
	}

	return GPUUnloadResult{
		Status:          rec.Status.ExternalStatus(),
		ModelID:         modelID,
		ManifestDigest:  manifestDigest,
		LeaseHolder:     leaseHolder,
		Path:            modelPath,
		Device:          req.Device,
		Loader:          s.gpuLoader.Name(),
		Files:           files,
		ReleasedBytes:   total,
		RemainingLeases: remaining,
		DurationMS:      time.Since(start).Milliseconds(),
		ReasonCode:      ReasonNone,
		Message:         "persistent GPU allocations released and lease updated",
	}, nil
}

func (s *Service) GPUListPersistent(ctx context.Context, device int) ([]GPULoadFileResult, error) {
	if device < 0 {
		return nil, NewAppError(ExitValidation, ReasonValidationFailed, "--device must be >= 0", nil)
	}
	return s.gpuLoader.ListPersistent(ctx, device)
}

func (s *Service) GPUExport(ctx context.Context, req GPUExportRequest) (GPUExportResult, error) {
	start := time.Now()
	if req.Device < 0 {
		return GPUExportResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "--device must be >= 0", nil)
	}
	if req.MaxShards <= 0 {
		req.MaxShards = 0
	}

	modelPath := strings.TrimSpace(req.Path)
	modelID := strings.TrimSpace(req.ModelID)
	manifestDigest := strings.TrimSpace(req.Digest)
	if modelPath == "" {
		if modelID == "" || manifestDigest == "" {
			return GPUExportResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "either --path or (--model-id and --digest) is required", nil)
		}
		if err := s.validateModelID(modelID); err != nil {
			return GPUExportResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "invalid --model-id", err)
		}
		rec, ok, err := s.store.Get(modelKey(modelID, manifestDigest))
		if err != nil {
			return GPUExportResult{}, err
		}
		if !ok {
			return GPUExportResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "model not found in local state", nil)
		}
		modelPath = rec.Path
	}

	valid, reason, err := s.verifyPublishedPath(modelPath)
	if err != nil || !valid {
		if reason == ReasonNone {
			reason = ReasonStateDBCorrupt
		}
		return GPUExportResult{}, NewAppError(mapReasonToExitCode(reason), reason, "path failed READY verification before gpu export", err)
	}

	md, err := loadLocalMetadata(modelPath)
	if err != nil {
		return GPUExportResult{}, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "failed to load local model metadata", err)
	}
	if modelID == "" {
		modelID = md.ModelID
	}
	if manifestDigest == "" {
		manifestDigest = md.ManifestDigest
	}

	shards, err := gpuWeightShards(md.Profile)
	if err != nil {
		return GPUExportResult{}, err
	}
	files := make([]GPULoadFileResult, 0, len(shards))
	var total int64
	for i, shard := range shards {
		if req.MaxShards > 0 && i >= req.MaxShards {
			break
		}
		if err := ValidateShardName(shard.Name); err != nil {
			return GPUExportResult{}, NewAppError(ExitValidation, ReasonValidationFailed, fmt.Sprintf("invalid shard name %q: %v", shard.Name, err), nil)
		}
		path := filepath.Join(modelPath, "shards", shard.Name)
		res, err := s.gpuLoader.ExportPersistent(ctx, GPULoadFileRequest{
			Path:   path,
			Device: req.Device,
		})
		if err != nil {
			appErr := AsAppError(err)
			return GPUExportResult{
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
				Message:        fmt.Sprintf("failed exporting shard %s: %v", shard.Name, appErr.Error()),
			}, appErr
		}
		files = append(files, res)
		total += res.Bytes
	}

	return GPUExportResult{
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
		Message:        "exported CUDA IPC handles for persistent allocations",
	}, nil
}

func (s *Service) releaseLeaseOnlyLocked(rec *storepkg.ModelRecord, leaseHolder string) (int, error) {
	if rec == nil {
		return 0, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "nil model record", nil)
	}
	rec.Status = StateReleasing
	remaining := rec.ReleaseLease(leaseHolder)
	now := time.Now().UTC()
	if remaining > 0 {
		rec.Status = StateReady
		rec.Releasable = false
		rec.ReleasableAt = nil
	} else {
		rec.Status = StateReady
		rec.Releasable = true
		rec.ReleasableAt = &now
	}
	if err := s.store.Put(rec); err != nil {
		return 0, err
	}
	return remaining, nil
}

func hasLeaseHolder(leases []storepkg.Lease, holder string) bool {
	for _, l := range leases {
		if l.Holder == holder {
			return true
		}
	}
	return false
}
