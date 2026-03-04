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
	ClientID   string
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

type GPUAttachRequest struct {
	ModelID    string `json:"model_id"`
	Digest     string `json:"digest"`
	Path       string `json:"path"`
	Device     int    `json:"device"`
	ClientID   string `json:"client_id"`
	MaxShards  int    `json:"max_shards"`
	TTLSeconds int    `json:"ttl_seconds"`
}

type GPUAttachResult struct {
	Status         string              `json:"status"`
	ModelID        string              `json:"model_id,omitempty"`
	ManifestDigest string              `json:"manifest_digest,omitempty"`
	Path           string              `json:"path"`
	Device         int                 `json:"device"`
	ClientID       string              `json:"client_id"`
	ExpiresAt      string              `json:"expires_at,omitempty"`
	Loader         string              `json:"loader"`
	Files          []GPULoadFileResult `json:"files"`
	AttachedFiles  int                 `json:"attached_files"`
	DurationMS     int64               `json:"duration_ms"`
	ReasonCode     ReasonCode          `json:"reason_code"`
	Message        string              `json:"message,omitempty"`
}

type GPUDetachRequest struct {
	ModelID  string `json:"model_id"`
	Digest   string `json:"digest"`
	Path     string `json:"path"`
	Device   int    `json:"device"`
	ClientID string `json:"client_id"`
}

type GPUDetachResult struct {
	Status         string              `json:"status"`
	ModelID        string              `json:"model_id,omitempty"`
	ManifestDigest string              `json:"manifest_digest,omitempty"`
	Path           string              `json:"path"`
	Device         int                 `json:"device"`
	ClientID       string              `json:"client_id"`
	Loader         string              `json:"loader"`
	Files          []GPULoadFileResult `json:"files"`
	DetachedFiles  int                 `json:"detached_files"`
	DurationMS     int64               `json:"duration_ms"`
	ReasonCode     ReasonCode          `json:"reason_code"`
	Message        string              `json:"message,omitempty"`
}

type GPUHeartbeatRequest struct {
	ModelID    string `json:"model_id"`
	Digest     string `json:"digest"`
	Path       string `json:"path"`
	Device     int    `json:"device"`
	ClientID   string `json:"client_id"`
	TTLSeconds int    `json:"ttl_seconds"`
}

type GPUHeartbeatResult struct {
	Status         string     `json:"status"`
	ModelID        string     `json:"model_id,omitempty"`
	ManifestDigest string     `json:"manifest_digest,omitempty"`
	Path           string     `json:"path"`
	Device         int        `json:"device"`
	ClientID       string     `json:"client_id"`
	ExpiresAt      string     `json:"expires_at,omitempty"`
	DurationMS     int64      `json:"duration_ms"`
	ReasonCode     ReasonCode `json:"reason_code"`
	Message        string     `json:"message,omitempty"`
}

type GPULoader interface {
	Name() string
	Probe(ctx context.Context, device int) (GPUProbeResult, error)
	LoadFile(ctx context.Context, req GPULoadFileRequest) (GPULoadFileResult, error)
	LoadPersistent(ctx context.Context, req GPULoadFileRequest) (GPULoadFileResult, error)
	ExportPersistent(ctx context.Context, req GPULoadFileRequest) (GPULoadFileResult, error)
	AttachPersistent(ctx context.Context, req GPULoadFileRequest) (GPULoadFileResult, error)
	DetachPersistent(ctx context.Context, req GPULoadFileRequest) (GPULoadFileResult, error)
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
	rollbackPersistent := func() error {
		var rollbackErr error
		for i := len(files) - 1; i >= 0; i-- {
			path := strings.TrimSpace(files[i].Path)
			if path == "" {
				continue
			}
			if _, unloadErr := s.gpuLoader.UnloadPersistent(context.Background(), GPULoadFileRequest{
				Path:   path,
				Device: req.Device,
			}); unloadErr != nil && rollbackErr == nil {
				rollbackErr = unloadErr
			}
		}
		if rollbackLease {
			if _, leaseErr := s.releaseLeaseOnlyLocked(rec, leaseHolder); leaseErr != nil && rollbackErr == nil {
				rollbackErr = leaseErr
			}
		}
		return rollbackErr
	}
	for i, shard := range shards {
		if req.MaxShards > 0 && i >= req.MaxShards {
			break
		}
		if err := ValidateShardName(shard.Name); err != nil {
			appErr := NewAppError(ExitValidation, ReasonValidationFailed, fmt.Sprintf("invalid shard name %q: %v", shard.Name, err), nil)
			if rollbackErr := rollbackPersistent(); rollbackErr != nil {
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
					ReasonCode:     ReasonStateDBCorrupt,
					Message:        fmt.Sprintf("%s (rollback failed: %v)", appErr.Error(), rollbackErr),
				}, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "persistent load rollback failed", fmt.Errorf("original_error=%v rollback_error=%w", appErr, rollbackErr))
			}
			return GPULoadResult{}, appErr
		}
		path := filepath.Join(modelPath, "shards", shard.Name)
		res, err := s.gpuLoader.LoadPersistent(ctx, GPULoadFileRequest{
			Path:       path,
			Device:     req.Device,
			ChunkBytes: req.ChunkBytes,
			Strict:     req.Strict,
		})
		if err != nil {
			appErr := AsAppError(err)
			if rollbackErr := rollbackPersistent(); rollbackErr != nil {
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
					ReasonCode:     ReasonStateDBCorrupt,
					Message:        fmt.Sprintf("failed persistent-loading shard %s: %v (rollback failed: %v)", shard.Name, appErr.Error(), rollbackErr),
				}, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "persistent load rollback failed", fmt.Errorf("load_error=%v rollback_error=%w", appErr, rollbackErr))
			}
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
	if err := s.pruneExpiredAttachments(context.Background()); err != nil {
		return GPUUnloadResult{}, err
	}
	if active := s.countActiveAttachmentsForModel(key, req.Device); active > 0 {
		return GPUUnloadResult{
			Status:         "FAILED",
			ModelID:        modelID,
			ManifestDigest: manifestDigest,
			LeaseHolder:    leaseHolder,
			Path:           modelPath,
			Device:         req.Device,
			Loader:         s.gpuLoader.Name(),
			DurationMS:     time.Since(start).Milliseconds(),
			ReasonCode:     ReasonLeaseConflict,
			Message:        fmt.Sprintf("cannot unload while %d attachment client(s) are active; detach clients first or wait for heartbeat TTL expiry", active),
		}, NewAppError(ExitPolicy, ReasonLeaseConflict, "active GPU attachment clients prevent unload", nil)
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

const (
	minAttachTTL = 15 * time.Second
	maxAttachTTL = time.Hour
)

func (s *Service) GPUAttach(ctx context.Context, req GPUAttachRequest) (GPUAttachResult, error) {
	start := time.Now()
	if req.Device < 0 {
		return GPUAttachResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "--device must be >= 0", nil)
	}
	clientID := strings.TrimSpace(req.ClientID)
	if clientID == "" {
		return GPUAttachResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "--client-id is required", nil)
	}
	if req.MaxShards <= 0 {
		req.MaxShards = 0
	}
	ttl := s.normalizeAttachTTL(req.TTLSeconds)

	modelPath, modelID, manifestDigest, md, key, err := s.resolveGPUModelTarget(req.Path, req.ModelID, req.Digest)
	if err != nil {
		return GPUAttachResult{}, err
	}
	if err := s.pruneExpiredAttachments(context.Background()); err != nil {
		return GPUAttachResult{}, err
	}

	shardPaths, err := resolveWeightShardPaths(md, modelPath, req.MaxShards)
	if err != nil {
		return GPUAttachResult{}, err
	}
	files := make([]GPULoadFileResult, 0, len(shardPaths))
	rollback := func() {
		for i := len(files) - 1; i >= 0; i-- {
			_, _ = s.gpuLoader.DetachPersistent(context.Background(), GPULoadFileRequest{
				Path:     files[i].Path,
				Device:   req.Device,
				ClientID: clientID,
			})
		}
	}
	for _, shardPath := range shardPaths {
		res, attachErr := s.gpuLoader.AttachPersistent(ctx, GPULoadFileRequest{
			Path:     shardPath,
			Device:   req.Device,
			ClientID: clientID,
		})
		if attachErr != nil {
			rollback()
			appErr := AsAppError(attachErr)
			return GPUAttachResult{
				Status:         "FAILED",
				ModelID:        modelID,
				ManifestDigest: manifestDigest,
				Path:           modelPath,
				Device:         req.Device,
				ClientID:       clientID,
				Loader:         s.gpuLoader.Name(),
				Files:          files,
				AttachedFiles:  len(files),
				DurationMS:     time.Since(start).Milliseconds(),
				ReasonCode:     appErr.Reason,
				Message:        fmt.Sprintf("failed attaching shard %s: %v", filepath.Base(shardPath), appErr.Error()),
			}, appErr
		}
		files = append(files, res)
	}

	expiresAt := time.Now().UTC().Add(ttl)
	s.attachMu.Lock()
	if s.attachMap == nil {
		s.attachMap = map[string]*gpuClientAttachment{}
	}
	s.attachMap[gpuAttachKey(key, req.Device, clientID)] = &gpuClientAttachment{
		ModelKey:        key,
		ModelID:         modelID,
		ManifestDigest:  manifestDigest,
		Path:            modelPath,
		Device:          req.Device,
		ClientID:        clientID,
		ShardPaths:      append([]string(nil), shardPaths...),
		ExpiresAt:       expiresAt,
		LastHeartbeatAt: time.Now().UTC(),
	}
	s.attachMu.Unlock()

	return GPUAttachResult{
		Status:         "READY",
		ModelID:        modelID,
		ManifestDigest: manifestDigest,
		Path:           modelPath,
		Device:         req.Device,
		ClientID:       clientID,
		ExpiresAt:      expiresAt.Format(time.RFC3339Nano),
		Loader:         s.gpuLoader.Name(),
		Files:          files,
		AttachedFiles:  len(files),
		DurationMS:     time.Since(start).Milliseconds(),
		ReasonCode:     ReasonNone,
		Message:        "client attached to persistent GPU allocations",
	}, nil
}

func (s *Service) GPUHeartbeat(ctx context.Context, req GPUHeartbeatRequest) (GPUHeartbeatResult, error) {
	start := time.Now()
	if req.Device < 0 {
		return GPUHeartbeatResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "--device must be >= 0", nil)
	}
	clientID := strings.TrimSpace(req.ClientID)
	if clientID == "" {
		return GPUHeartbeatResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "--client-id is required", nil)
	}

	modelPath, modelID, manifestDigest, _, key, err := s.resolveGPUModelTarget(req.Path, req.ModelID, req.Digest)
	if err != nil {
		return GPUHeartbeatResult{}, err
	}
	if err := s.pruneExpiredAttachments(context.Background()); err != nil {
		return GPUHeartbeatResult{}, err
	}
	ttl := s.normalizeAttachTTL(req.TTLSeconds)

	now := time.Now().UTC()
	attachKey := gpuAttachKey(key, req.Device, clientID)
	s.attachMu.Lock()
	session, ok := s.attachMap[attachKey]
	if !ok {
		s.attachMu.Unlock()
		return GPUHeartbeatResult{
			Status:         "FAILED",
			ModelID:        modelID,
			ManifestDigest: manifestDigest,
			Path:           modelPath,
			Device:         req.Device,
			ClientID:       clientID,
			DurationMS:     time.Since(start).Milliseconds(),
			ReasonCode:     ReasonValidationFailed,
			Message:        "attachment session not found; call gpu/attach first",
		}, NewAppError(ExitValidation, ReasonValidationFailed, "attachment session not found", nil)
	}
	session.LastHeartbeatAt = now
	session.ExpiresAt = now.Add(ttl)
	expiresAt := session.ExpiresAt
	s.attachMu.Unlock()

	select {
	case <-ctx.Done():
		return GPUHeartbeatResult{}, NewAppError(ExitRegistry, ReasonRegistryTimeout, "context canceled before attachment heartbeat update completed", ctx.Err())
	default:
	}

	return GPUHeartbeatResult{
		Status:         "READY",
		ModelID:        modelID,
		ManifestDigest: manifestDigest,
		Path:           modelPath,
		Device:         req.Device,
		ClientID:       clientID,
		ExpiresAt:      expiresAt.Format(time.RFC3339Nano),
		DurationMS:     time.Since(start).Milliseconds(),
		ReasonCode:     ReasonNone,
		Message:        "attachment heartbeat updated",
	}, nil
}

func (s *Service) GPUDetach(ctx context.Context, req GPUDetachRequest) (GPUDetachResult, error) {
	start := time.Now()
	if req.Device < 0 {
		return GPUDetachResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "--device must be >= 0", nil)
	}
	clientID := strings.TrimSpace(req.ClientID)
	if clientID == "" {
		return GPUDetachResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "--client-id is required", nil)
	}

	modelPath, modelID, manifestDigest, _, key, err := s.resolveGPUModelTarget(req.Path, req.ModelID, req.Digest)
	if err != nil {
		return GPUDetachResult{}, err
	}
	if err := s.pruneExpiredAttachments(context.Background()); err != nil {
		return GPUDetachResult{}, err
	}
	attachKey := gpuAttachKey(key, req.Device, clientID)

	s.attachMu.Lock()
	session, ok := s.attachMap[attachKey]
	if ok {
		delete(s.attachMap, attachKey)
	}
	s.attachMu.Unlock()

	if !ok {
		return GPUDetachResult{
			Status:         "READY",
			ModelID:        modelID,
			ManifestDigest: manifestDigest,
			Path:           modelPath,
			Device:         req.Device,
			ClientID:       clientID,
			Loader:         s.gpuLoader.Name(),
			Files:          []GPULoadFileResult{},
			DetachedFiles:  0,
			DurationMS:     time.Since(start).Milliseconds(),
			ReasonCode:     ReasonNone,
			Message:        "attachment session already absent",
		}, nil
	}

	files := make([]GPULoadFileResult, 0, len(session.ShardPaths))
	for _, shardPath := range session.ShardPaths {
		res, detachErr := s.gpuLoader.DetachPersistent(ctx, GPULoadFileRequest{
			Path:     shardPath,
			Device:   req.Device,
			ClientID: clientID,
		})
		if detachErr != nil {
			appErr := AsAppError(detachErr)
			return GPUDetachResult{
				Status:         "FAILED",
				ModelID:        modelID,
				ManifestDigest: manifestDigest,
				Path:           modelPath,
				Device:         req.Device,
				ClientID:       clientID,
				Loader:         s.gpuLoader.Name(),
				Files:          files,
				DetachedFiles:  len(files),
				DurationMS:     time.Since(start).Milliseconds(),
				ReasonCode:     appErr.Reason,
				Message:        fmt.Sprintf("failed detaching shard %s: %v", filepath.Base(shardPath), appErr.Error()),
			}, appErr
		}
		files = append(files, res)
	}

	return GPUDetachResult{
		Status:         "READY",
		ModelID:        modelID,
		ManifestDigest: manifestDigest,
		Path:           modelPath,
		Device:         req.Device,
		ClientID:       clientID,
		Loader:         s.gpuLoader.Name(),
		Files:          files,
		DetachedFiles:  len(files),
		DurationMS:     time.Since(start).Milliseconds(),
		ReasonCode:     ReasonNone,
		Message:        "client detached from persistent GPU allocations",
	}, nil
}

func (s *Service) pruneExpiredAttachments(ctx context.Context) error {
	now := time.Now().UTC()
	type expiredSession struct {
		clientID   string
		device     int
		shardPaths []string
	}
	expired := []expiredSession{}

	s.attachMu.Lock()
	for key, session := range s.attachMap {
		if session == nil {
			delete(s.attachMap, key)
			continue
		}
		if session.ExpiresAt.IsZero() || session.ExpiresAt.After(now) {
			continue
		}
		expired = append(expired, expiredSession{
			clientID:   session.ClientID,
			device:     session.Device,
			shardPaths: append([]string(nil), session.ShardPaths...),
		})
		delete(s.attachMap, key)
	}
	s.attachMu.Unlock()
	for _, session := range expired {
		for _, shardPath := range session.shardPaths {
			_, _ = s.gpuLoader.DetachPersistent(ctx, GPULoadFileRequest{
				Path:     shardPath,
				Device:   session.device,
				ClientID: session.clientID,
			})
		}
	}
	return nil
}

func (s *Service) countActiveAttachmentsForModel(modelKey string, device int) int {
	s.attachMu.Lock()
	defer s.attachMu.Unlock()
	count := 0
	for _, session := range s.attachMap {
		if session == nil {
			continue
		}
		if session.ModelKey == modelKey && session.Device == device {
			count++
		}
	}
	return count
}

func (s *Service) normalizeAttachTTL(ttlSeconds int) time.Duration {
	if ttlSeconds <= 0 {
		return s.attachTTL
	}
	ttl := time.Duration(ttlSeconds) * time.Second
	if ttl < minAttachTTL {
		return minAttachTTL
	}
	if ttl > maxAttachTTL {
		return maxAttachTTL
	}
	return ttl
}

func gpuAttachKey(modelKey string, device int, clientID string) string {
	return fmt.Sprintf("%s|%d|%s", modelKey, device, clientID)
}

func resolveWeightShardPaths(md *localMetadata, modelPath string, maxShards int) ([]string, error) {
	shards, err := gpuWeightShards(md.Profile)
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(shards))
	for i, shard := range shards {
		if maxShards > 0 && i >= maxShards {
			break
		}
		if err := ValidateShardName(shard.Name); err != nil {
			return nil, NewAppError(ExitValidation, ReasonValidationFailed, fmt.Sprintf("invalid shard name %q: %v", shard.Name, err), nil)
		}
		out = append(out, filepath.Join(modelPath, "shards", shard.Name))
	}
	return out, nil
}

func (s *Service) resolveGPUModelTarget(path, modelID, digestValue string) (string, string, string, *localMetadata, string, error) {
	modelPath := strings.TrimSpace(path)
	resolvedModelID := strings.TrimSpace(modelID)
	resolvedDigest := strings.TrimSpace(digestValue)
	if modelPath == "" {
		if resolvedModelID == "" || resolvedDigest == "" {
			return "", "", "", nil, "", NewAppError(ExitValidation, ReasonValidationFailed, "either --path or (--model-id and --digest) is required", nil)
		}
		if err := s.validateModelID(resolvedModelID); err != nil {
			return "", "", "", nil, "", NewAppError(ExitValidation, ReasonValidationFailed, "invalid --model-id", err)
		}
		rec, ok, err := s.store.Get(modelKey(resolvedModelID, resolvedDigest))
		if err != nil {
			return "", "", "", nil, "", err
		}
		if !ok {
			return "", "", "", nil, "", NewAppError(ExitValidation, ReasonValidationFailed, "model not found in local state", nil)
		}
		modelPath = rec.Path
	}

	valid, reason, err := s.verifyPublishedPath(modelPath)
	if err != nil || !valid {
		if reason == ReasonNone {
			reason = ReasonStateDBCorrupt
		}
		return "", "", "", nil, "", NewAppError(mapReasonToExitCode(reason), reason, "path failed READY verification", err)
	}

	md, err := loadLocalMetadata(modelPath)
	if err != nil {
		return "", "", "", nil, "", NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "failed to load local model metadata", err)
	}
	if resolvedModelID == "" {
		resolvedModelID = md.ModelID
	}
	if resolvedDigest == "" {
		resolvedDigest = md.ManifestDigest
	}
	return modelPath, resolvedModelID, resolvedDigest, md, modelKey(resolvedModelID, resolvedDigest), nil
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
