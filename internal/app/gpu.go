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
	DeviceUUID  string `json:"device_uuid"`
	DeviceIndex int    `json:"device_index"`
	DeviceCount int    `json:"device_count"`
	GDSDriver   bool   `json:"gds_driver"`
	Message     string `json:"message,omitempty"`
}

type GPUDeviceInfo struct {
	UUID  string `json:"uuid"`
	Index int    `json:"index"`
	Name  string `json:"name,omitempty"`
}

type GPULoadFileRequest struct {
	Path       string
	Device     int
	ChunkBytes int64
	Strict     bool
	ClientID   string
}

type GPULoadFileResult struct {
	Path       string `json:"-"`
	Bytes      int64  `json:"bytes"`
	DurationMS int64  `json:"duration_ms"`
	Direct     bool   `json:"direct"`
	Loaded     bool   `json:"loaded"`
	RefCount   int    `json:"ref_count,omitempty"`
	DevicePtr  string `json:"device_ptr,omitempty"`
	IPCHandle  string `json:"ipc_handle,omitempty"`
	Message    string `json:"message,omitempty"`
}

type GPUAllocateRequest struct {
	Ref                         string `json:"ref"`
	ModelID                     string `json:"model_id"`
	Digest                      string `json:"digest"`
	LeaseHolder                 string `json:"lease_holder"`
	DeviceUUID                  string `json:"device_uuid"`
	ChunkBytes                  int64  `json:"chunk_bytes"`
	MaxShards                   int    `json:"max_shards"`
	Strict                      bool   `json:"strict"`
	RuntimeBundleIncludeWeights bool   `json:"runtime_bundle_include_weights"`
}

type GPUAllocateResult struct {
	Status                    string     `json:"status"`
	AllocationID              string     `json:"allocation_id,omitempty"`
	ModelID                   string     `json:"model_id,omitempty"`
	ManifestDigest            string     `json:"manifest_digest,omitempty"`
	LeaseHolder               string     `json:"lease_holder,omitempty"`
	DeviceUUID                string     `json:"device_uuid,omitempty"`
	DeviceIndex               int        `json:"device_index,omitempty"`
	Loader                    string     `json:"loader,omitempty"`
	Files                     int        `json:"files,omitempty"`
	DirectFiles               int        `json:"direct_files,omitempty"`
	TotalBytes                int64      `json:"total_bytes,omitempty"`
	RuntimeBundleToken        string     `json:"runtime_bundle_token,omitempty"`
	RuntimeBundleTokenExpires string     `json:"runtime_bundle_token_expires_at,omitempty"`
	DurationMS                int64      `json:"duration_ms"`
	ReasonCode                ReasonCode `json:"reason_code"`
	Message                   string     `json:"message,omitempty"`
}

type GPULoadRequest struct {
	AllocationID string `json:"allocation_id"`
	ChunkBytes   int64  `json:"chunk_bytes"`
	MaxShards    int    `json:"max_shards"`
	Strict       bool   `json:"strict"`
	Mode         string `json:"mode"`
}

type GPUStandaloneBenchmarkRequest struct {
	ModelID    string
	Digest     string
	Path       string
	DeviceUUID string
	ChunkBytes int64
	MaxShards  int
	Strict     bool
}

type GPULoadResult struct {
	Status         string              `json:"status"`
	AllocationID   string              `json:"allocation_id,omitempty"`
	ModelID        string              `json:"model_id,omitempty"`
	ManifestDigest string              `json:"manifest_digest,omitempty"`
	LeaseHolder    string              `json:"lease_holder,omitempty"`
	DeviceUUID     string              `json:"device_uuid"`
	DeviceIndex    int                 `json:"device_index"`
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
	AllocationID string `json:"allocation_id"`
}

type GPUUnloadResult struct {
	Status          string              `json:"status"`
	AllocationID    string              `json:"allocation_id,omitempty"`
	ModelID         string              `json:"model_id,omitempty"`
	ManifestDigest  string              `json:"manifest_digest,omitempty"`
	LeaseHolder     string              `json:"lease_holder,omitempty"`
	DeviceUUID      string              `json:"device_uuid"`
	DeviceIndex     int                 `json:"device_index"`
	Loader          string              `json:"loader"`
	Files           []GPULoadFileResult `json:"files"`
	ReleasedBytes   int64               `json:"released_bytes"`
	RemainingLeases int                 `json:"remaining_leases"`
	DurationMS      int64               `json:"duration_ms"`
	ReasonCode      ReasonCode          `json:"reason_code"`
	Message         string              `json:"message,omitempty"`
}

type GPUExportRequest struct {
	AllocationID string `json:"allocation_id"`
	MaxShards    int    `json:"max_shards"`
}

type GPUExportResult struct {
	Status         string              `json:"status"`
	AllocationID   string              `json:"allocation_id,omitempty"`
	ModelID        string              `json:"model_id,omitempty"`
	ManifestDigest string              `json:"manifest_digest,omitempty"`
	DeviceUUID     string              `json:"device_uuid"`
	DeviceIndex    int                 `json:"device_index"`
	Loader         string              `json:"loader"`
	Files          []GPULoadFileResult `json:"files"`
	TotalBytes     int64               `json:"total_bytes"`
	DurationMS     int64               `json:"duration_ms"`
	ReasonCode     ReasonCode          `json:"reason_code"`
	Message        string              `json:"message,omitempty"`
}

type GPUTensorMapRequest struct {
	AllocationID   string `json:"allocation_id"`
	MaxShards      int    `json:"max_shards"`
	MaxTensors     int    `json:"max_tensors"`
	IncludeHandles bool   `json:"include_handles"`
}

type GPUTensorDescriptor struct {
	Name         string  `json:"name"`
	DType        string  `json:"dtype"`
	Shape        []int64 `json:"shape"`
	ByteOffset   int64   `json:"byte_offset"`
	ByteLength   int64   `json:"byte_length"`
	ShardName    string  `json:"shard_name"`
	ShardDigest  string  `json:"shard_digest,omitempty"`
	ShardSize    int64   `json:"shard_size"`
	ShardOrdinal int     `json:"shard_ordinal"`
	IPCHandle    string  `json:"ipc_handle,omitempty"`
}

type GPUTensorMapResult struct {
	Status           string                `json:"status"`
	AllocationID     string                `json:"allocation_id,omitempty"`
	ModelID          string                `json:"model_id,omitempty"`
	ManifestDigest   string                `json:"manifest_digest,omitempty"`
	DeviceUUID       string                `json:"device_uuid"`
	DeviceIndex      int                   `json:"device_index"`
	Loader           string                `json:"loader"`
	Format           string                `json:"format,omitempty"`
	Tensors          []GPUTensorDescriptor `json:"tensors"`
	TensorCount      int                   `json:"tensor_count"`
	TotalTensorBytes int64                 `json:"total_tensor_bytes"`
	DurationMS       int64                 `json:"duration_ms"`
	ReasonCode       ReasonCode            `json:"reason_code"`
	Message          string                `json:"message,omitempty"`
}

type GPUAttachRequest struct {
	AllocationID string `json:"allocation_id"`
	ClientID     string `json:"client_id"`
	MaxShards    int    `json:"max_shards"`
	TTLSeconds   int    `json:"ttl_seconds"`
}

type GPUAttachResult struct {
	Status         string              `json:"status"`
	AllocationID   string              `json:"allocation_id,omitempty"`
	ModelID        string              `json:"model_id,omitempty"`
	ManifestDigest string              `json:"manifest_digest,omitempty"`
	DeviceUUID     string              `json:"device_uuid"`
	DeviceIndex    int                 `json:"device_index"`
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
	AllocationID string `json:"allocation_id"`
	ClientID     string `json:"client_id"`
}

type GPUDetachResult struct {
	Status         string              `json:"status"`
	AllocationID   string              `json:"allocation_id,omitempty"`
	ModelID        string              `json:"model_id,omitempty"`
	ManifestDigest string              `json:"manifest_digest,omitempty"`
	DeviceUUID     string              `json:"device_uuid"`
	DeviceIndex    int                 `json:"device_index"`
	ClientID       string              `json:"client_id"`
	Loader         string              `json:"loader"`
	Files          []GPULoadFileResult `json:"files"`
	DetachedFiles  int                 `json:"detached_files"`
	DurationMS     int64               `json:"duration_ms"`
	ReasonCode     ReasonCode          `json:"reason_code"`
	Message        string              `json:"message,omitempty"`
}

type GPUHeartbeatRequest struct {
	AllocationID string `json:"allocation_id"`
	ClientID     string `json:"client_id"`
	TTLSeconds   int    `json:"ttl_seconds"`
}

type GPUHeartbeatResult struct {
	Status         string     `json:"status"`
	AllocationID   string     `json:"allocation_id,omitempty"`
	ModelID        string     `json:"model_id,omitempty"`
	ManifestDigest string     `json:"manifest_digest,omitempty"`
	DeviceUUID     string     `json:"device_uuid"`
	DeviceIndex    int        `json:"device_index"`
	ClientID       string     `json:"client_id"`
	ExpiresAt      string     `json:"expires_at,omitempty"`
	DurationMS     int64      `json:"duration_ms"`
	ReasonCode     ReasonCode `json:"reason_code"`
	Message        string     `json:"message,omitempty"`
}

type GPULoader interface {
	Name() string
	ListDevices(ctx context.Context) ([]GPUDeviceInfo, error)
	ResolveDevice(ctx context.Context, deviceUUID string) (GPUDeviceInfo, error)
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

type gpuAllocationTarget struct {
	AllocationID   string
	ModelKey       string
	ModelID        string
	ManifestDigest string
	ModelPath      string
	LeaseHolder    string
	DeviceUUID     string
	DeviceIndex    int
	Metadata       *localMetadata
}

func (s *Service) resolveAllocationTarget(ctx context.Context, allocationID string) (*gpuAllocationTarget, error) {
	allocationID = strings.TrimSpace(allocationID)
	if allocationID == "" {
		return nil, NewAppError(ExitValidation, ReasonValidationFailed, "allocation_id is required", nil)
	}
	alloc, err := s.getAllocation(allocationID)
	if err != nil {
		return nil, err
	}
	modelID := strings.TrimSpace(alloc.ModelID)
	manifestDigest := strings.TrimSpace(alloc.ManifestDigest)
	leaseHolder := strings.TrimSpace(alloc.LeaseHolder)
	if modelID == "" || manifestDigest == "" || leaseHolder == "" {
		return nil, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "allocation record is incomplete", nil)
	}
	modelPath, resolvedModelID, resolvedDigest, md, key, err := s.resolveGPUModelTarget("", modelID, manifestDigest)
	if err != nil {
		return nil, err
	}
	device, err := s.resolveRequestedDevice(ctx, alloc.DeviceUUID)
	if err != nil {
		return nil, err
	}
	return &gpuAllocationTarget{
		AllocationID:   allocationID,
		ModelKey:       key,
		ModelID:        resolvedModelID,
		ManifestDigest: resolvedDigest,
		ModelPath:      modelPath,
		LeaseHolder:    leaseHolder,
		DeviceUUID:     device.UUID,
		DeviceIndex:    device.Index,
		Metadata:       md,
	}, nil
}

func (s *Service) GPUDevices(ctx context.Context) ([]GPUDeviceInfo, error) {
	return s.gpuLoader.ListDevices(ctx)
}

func (s *Service) GPUProbe(ctx context.Context, deviceUUID string) (GPUProbeResult, error) {
	device, err := s.resolveRequestedDevice(ctx, deviceUUID)
	if err != nil {
		return GPUProbeResult{}, err
	}
	probe, err := s.gpuLoader.Probe(ctx, device.Index)
	if err != nil {
		return GPUProbeResult{}, err
	}
	probe.DeviceUUID = device.UUID
	probe.DeviceIndex = device.Index
	return probe, nil
}

func (s *Service) GPUAllocate(ctx context.Context, req GPUAllocateRequest) (GPUAllocateResult, error) {
	start := time.Now()
	leaseHolder := strings.TrimSpace(req.LeaseHolder)
	if leaseHolder == "" {
		return GPUAllocateResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "lease_holder is required", nil)
	}
	modelID := strings.TrimSpace(req.ModelID)
	manifestDigest := strings.TrimSpace(req.Digest)
	if modelID == "" && strings.TrimSpace(req.Ref) == "" {
		return GPUAllocateResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "either ref or model_id is required", nil)
	}
	if req.ChunkBytes <= 0 {
		req.ChunkBytes = 4 * 1024 * 1024
	}
	if req.MaxShards < 0 {
		req.MaxShards = 0
	}
	device, err := s.resolveRequestedDevice(ctx, req.DeviceUUID)
	if err != nil {
		return GPUAllocateResult{}, err
	}
	req.DeviceUUID = device.UUID

	if strings.TrimSpace(req.Ref) != "" {
		ensureReq := EnsureRequest{
			Ref:             req.Ref,
			ModelID:         modelID,
			LeaseHolder:     leaseHolder,
			StrictIntegrity: true,
			Wait:            true,
		}
		ensureRes, ensureErr := s.Ensure(ctx, ensureReq)
		if ensureErr != nil {
			reason := ReasonStateDBCorrupt
			if appErr := AsAppError(ensureErr); appErr != nil {
				reason = appErr.Reason
			}
			return GPUAllocateResult{
				Status:         "FAILED",
				ModelID:        ensureRes.ModelID,
				ManifestDigest: ensureRes.ManifestDigest,
				LeaseHolder:    leaseHolder,
				DeviceUUID:     req.DeviceUUID,
				DeviceIndex:    device.Index,
				Loader:         s.gpuLoader.Name(),
				DurationMS:     time.Since(start).Milliseconds(),
				ReasonCode:     reason,
				Message:        ensureErr.Error(),
			}, ensureErr
		}
		modelID = ensureRes.ModelID
		manifestDigest = ensureRes.ManifestDigest
	}
	if modelID == "" || manifestDigest == "" {
		return GPUAllocateResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "allocation requires resolved model_id and digest", nil)
	}

	allocationID := s.nextAllocationID()
	modelPath, _, _, _, key, resolveErr := s.resolveGPUModelTarget("", modelID, manifestDigest)
	if resolveErr != nil {
		_, _ = s.Release(context.Background(), modelID, manifestDigest, leaseHolder, false)
		reason := ReasonStateDBCorrupt
		if appErr := AsAppError(resolveErr); appErr != nil {
			reason = appErr.Reason
		}
		return GPUAllocateResult{
			Status:         "FAILED",
			ModelID:        modelID,
			ManifestDigest: manifestDigest,
			LeaseHolder:    leaseHolder,
			DeviceUUID:     req.DeviceUUID,
			DeviceIndex:    device.Index,
			Loader:         s.gpuLoader.Name(),
			DurationMS:     time.Since(start).Milliseconds(),
			ReasonCode:     reason,
			Message:        resolveErr.Error(),
		}, resolveErr
	}
	if err := s.putAllocation(&gpuAllocation{
		AllocationID:   allocationID,
		ModelKey:       key,
		ModelID:        modelID,
		ManifestDigest: manifestDigest,
		Path:           modelPath,
		LeaseHolder:    leaseHolder,
		DeviceUUID:     req.DeviceUUID,
		DeviceIndex:    device.Index,
		CreatedAt:      time.Now().UTC(),
	}); err != nil {
		_, _ = s.Release(context.Background(), modelID, manifestDigest, leaseHolder, false)
		return GPUAllocateResult{}, err
	}
	loadRes, loadErr := s.GPULoad(ctx, GPULoadRequest{
		AllocationID: allocationID,
		ChunkBytes:   req.ChunkBytes,
		MaxShards:    req.MaxShards,
		Strict:       req.Strict,
		Mode:         "persistent",
	})
	if loadErr != nil {
		s.revokeRuntimeBundleTokensForAllocation(allocationID)
		_ = s.deleteAllocation(allocationID)
		_, _ = s.Release(context.Background(), modelID, manifestDigest, leaseHolder, false)
		reason := ReasonStateDBCorrupt
		if appErr := AsAppError(loadErr); appErr != nil {
			reason = appErr.Reason
		}
		return GPUAllocateResult{
			Status:         "FAILED",
			ModelID:        modelID,
			ManifestDigest: manifestDigest,
			LeaseHolder:    leaseHolder,
			DeviceUUID:     req.DeviceUUID,
			DeviceIndex:    device.Index,
			Loader:         s.gpuLoader.Name(),
			Files:          len(loadRes.Files),
			DirectFiles:    0,
			TotalBytes:     loadRes.TotalBytes,
			DurationMS:     time.Since(start).Milliseconds(),
			ReasonCode:     reason,
			Message:        loadErr.Error(),
		}, loadErr
	}
	directFiles := 0
	for _, file := range loadRes.Files {
		if file.Direct {
			directFiles++
		}
	}
	runtimeBundleToken, runtimeBundleTokenExpiresAt := s.issueRuntimeBundleToken(allocationID, req.RuntimeBundleIncludeWeights)
	return GPUAllocateResult{
		Status:                    "READY",
		AllocationID:              allocationID,
		ModelID:                   modelID,
		ManifestDigest:            manifestDigest,
		LeaseHolder:               leaseHolder,
		DeviceUUID:                req.DeviceUUID,
		DeviceIndex:               device.Index,
		Loader:                    s.gpuLoader.Name(),
		Files:                     len(loadRes.Files),
		DirectFiles:               directFiles,
		TotalBytes:                loadRes.TotalBytes,
		RuntimeBundleToken:        runtimeBundleToken,
		RuntimeBundleTokenExpires: runtimeBundleTokenExpiresAt.Format(time.RFC3339Nano),
		DurationMS:                time.Since(start).Milliseconds(),
		ReasonCode:                ReasonNone,
		Message:                   "gpu allocation created",
	}, nil
}

func (s *Service) GPUBenchmarkLoadStandalone(ctx context.Context, req GPUStandaloneBenchmarkRequest) (GPULoadResult, error) {
	if req.ChunkBytes <= 0 {
		req.ChunkBytes = 16 * 1024 * 1024
	}
	if req.MaxShards <= 0 {
		req.MaxShards = 0
	}
	device, err := s.resolveRequestedDevice(ctx, req.DeviceUUID)
	if err != nil {
		return GPULoadResult{}, err
	}
	modelPath, modelID, manifestDigest, md, _, err := s.resolveGPUModelTarget(req.Path, req.ModelID, req.Digest)
	if err != nil {
		return GPULoadResult{}, err
	}
	start := time.Now()
	probe, err := s.gpuLoader.Probe(ctx, device.Index)
	if err != nil {
		return GPULoadResult{}, AsAppError(err)
	}
	if !probe.Available {
		return GPULoadResult{
			Status:         "FAILED",
			ModelID:        modelID,
			ManifestDigest: manifestDigest,
			DeviceUUID:     device.UUID,
			DeviceIndex:    device.Index,
			Loader:         s.gpuLoader.Name(),
			Mode:           "benchmark",
			Persistent:     false,
			ReasonCode:     ReasonDirectPathIneligible,
			DurationMS:     time.Since(start).Milliseconds(),
			Message:        probe.Message,
		}, NewAppError(ExitPolicy, ReasonDirectPathIneligible, probe.Message, nil)
	}
	target := &gpuAllocationTarget{
		ModelID:        modelID,
		ManifestDigest: manifestDigest,
		ModelPath:      modelPath,
		DeviceUUID:     device.UUID,
		DeviceIndex:    device.Index,
		Metadata:       md,
	}
	return s.gpuBenchmarkLoad(ctx, start, GPULoadRequest{
		ChunkBytes: req.ChunkBytes,
		MaxShards:  req.MaxShards,
		Strict:     req.Strict,
		Mode:       "benchmark",
	}, target)
}

func (s *Service) GPULoad(ctx context.Context, req GPULoadRequest) (GPULoadResult, error) {
	start := time.Now()
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
	target, err := s.resolveAllocationTarget(ctx, req.AllocationID)
	if err != nil {
		return GPULoadResult{}, err
	}
	probe, err := s.gpuLoader.Probe(ctx, target.DeviceIndex)
	if err != nil {
		return GPULoadResult{}, AsAppError(err)
	}
	if !probe.Available {
		return GPULoadResult{
			Status:         "FAILED",
			AllocationID:   target.AllocationID,
			ModelID:        target.ModelID,
			ManifestDigest: target.ManifestDigest,
			DeviceUUID:     target.DeviceUUID,
			DeviceIndex:    target.DeviceIndex,
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
		return s.gpuBenchmarkLoad(ctx, start, req, target)
	case "persistent":
		return s.gpuPersistentLoad(ctx, start, req, target)
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

func (s *Service) gpuBenchmarkLoad(ctx context.Context, start time.Time, req GPULoadRequest, target *gpuAllocationTarget) (GPULoadResult, error) {
	if target == nil || target.Metadata == nil {
		return GPULoadResult{}, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "gpu benchmark target is incomplete", nil)
	}
	deviceIndex := target.DeviceIndex
	if sessionLoader, ok := s.gpuLoader.(GPULoaderSession); ok {
		end, err := sessionLoader.BeginSession(ctx, deviceIndex)
		if err != nil {
			appErr := AsAppError(err)
			return GPULoadResult{
				Status:         "FAILED",
				AllocationID:   target.AllocationID,
				ModelID:        target.ModelID,
				ManifestDigest: target.ManifestDigest,
				LeaseHolder:    target.LeaseHolder,
				DeviceUUID:     target.DeviceUUID,
				DeviceIndex:    deviceIndex,
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

	shards, err := gpuWeightShards(target.Metadata.Profile)
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
		path := filepath.Join(target.ModelPath, "shards", shard.Name)
		res, err := s.gpuLoader.LoadFile(ctx, GPULoadFileRequest{
			Path:       path,
			Device:     deviceIndex,
			ChunkBytes: req.ChunkBytes,
			Strict:     req.Strict,
		})
		if err != nil {
			appErr := AsAppError(err)
			return GPULoadResult{
				Status:         "FAILED",
				AllocationID:   target.AllocationID,
				ModelID:        target.ModelID,
				ManifestDigest: target.ManifestDigest,
				DeviceUUID:     target.DeviceUUID,
				DeviceIndex:    deviceIndex,
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
		AllocationID:   target.AllocationID,
		ModelID:        target.ModelID,
		ManifestDigest: target.ManifestDigest,
		LeaseHolder:    target.LeaseHolder,
		DeviceUUID:     target.DeviceUUID,
		DeviceIndex:    deviceIndex,
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

func (s *Service) gpuPersistentLoad(ctx context.Context, start time.Time, req GPULoadRequest, target *gpuAllocationTarget) (GPULoadResult, error) {
	if target == nil || target.Metadata == nil {
		return GPULoadResult{}, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "gpu persistent target is incomplete", nil)
	}
	leaseHolder := strings.TrimSpace(target.LeaseHolder)
	if leaseHolder == "" {
		return GPULoadResult{}, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "allocation lease holder is required", nil)
	}
	modelPath := target.ModelPath
	modelID := target.ModelID
	manifestDigest := target.ManifestDigest
	allocationID := target.AllocationID
	key := target.ModelKey
	deviceIndex := target.DeviceIndex

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

	shards, err := gpuWeightShards(target.Metadata.Profile)
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
				Device: deviceIndex,
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
					AllocationID:   allocationID,
					ModelID:        modelID,
					ManifestDigest: manifestDigest,
					LeaseHolder:    leaseHolder,
					DeviceUUID:     target.DeviceUUID,
					DeviceIndex:    deviceIndex,
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
			Device:     deviceIndex,
			ChunkBytes: req.ChunkBytes,
			Strict:     req.Strict,
		})
		if err != nil {
			appErr := AsAppError(err)
			if rollbackErr := rollbackPersistent(); rollbackErr != nil {
				return GPULoadResult{
					Status:         "FAILED",
					AllocationID:   allocationID,
					ModelID:        modelID,
					ManifestDigest: manifestDigest,
					LeaseHolder:    leaseHolder,
					DeviceUUID:     target.DeviceUUID,
					DeviceIndex:    deviceIndex,
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
				AllocationID:   allocationID,
				ModelID:        modelID,
				ManifestDigest: manifestDigest,
				LeaseHolder:    leaseHolder,
				DeviceUUID:     target.DeviceUUID,
				DeviceIndex:    deviceIndex,
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
		AllocationID:   allocationID,
		ModelID:        modelID,
		ManifestDigest: manifestDigest,
		LeaseHolder:    leaseHolder,
		DeviceUUID:     target.DeviceUUID,
		DeviceIndex:    deviceIndex,
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
	target, err := s.resolveAllocationTarget(ctx, req.AllocationID)
	if err != nil {
		return GPUUnloadResult{}, err
	}
	unlock, _, err := s.locks.Acquire(ctx, target.ModelKey, true)
	if err != nil {
		return GPUUnloadResult{}, err
	}
	defer unlock()

	rec, ok, err := s.store.Get(target.ModelKey)
	if err != nil {
		return GPUUnloadResult{}, err
	}
	if !ok {
		return GPUUnloadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "model not found in local state", nil)
	}
	if !hasLeaseHolder(rec.Leases, target.LeaseHolder) {
		return GPUUnloadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, fmt.Sprintf("lease holder %q not found on model", target.LeaseHolder), nil)
	}
	if err := s.pruneExpiredAttachments(context.Background()); err != nil {
		return GPUUnloadResult{}, err
	}
	if active := s.countActiveAttachmentsForModel(target.ModelKey, target.DeviceUUID); active > 0 {
		return GPUUnloadResult{
			Status:         "FAILED",
			AllocationID:   target.AllocationID,
			ModelID:        target.ModelID,
			ManifestDigest: target.ManifestDigest,
			LeaseHolder:    target.LeaseHolder,
			DeviceUUID:     target.DeviceUUID,
			DeviceIndex:    target.DeviceIndex,
			Loader:         s.gpuLoader.Name(),
			DurationMS:     time.Since(start).Milliseconds(),
			ReasonCode:     ReasonLeaseConflict,
			Message:        fmt.Sprintf("cannot unload while %d attachment client(s) are active; detach clients first or wait for heartbeat TTL expiry", active),
		}, NewAppError(ExitPolicy, ReasonLeaseConflict, "active GPU attachment clients prevent unload", nil)
	}

	shards, err := gpuWeightShards(target.Metadata.Profile)
	if err != nil {
		return GPUUnloadResult{}, err
	}
	files := make([]GPULoadFileResult, 0, len(shards))
	var total int64
	for _, shard := range shards {
		if err := ValidateShardName(shard.Name); err != nil {
			return GPUUnloadResult{}, NewAppError(ExitValidation, ReasonValidationFailed, fmt.Sprintf("invalid shard name %q: %v", shard.Name, err), nil)
		}
		path := filepath.Join(target.ModelPath, "shards", shard.Name)
		res, err := s.gpuLoader.UnloadPersistent(ctx, GPULoadFileRequest{
			Path:   path,
			Device: target.DeviceIndex,
		})
		if err != nil {
			appErr := AsAppError(err)
			return GPUUnloadResult{
				Status:         "FAILED",
				AllocationID:   target.AllocationID,
				ModelID:        target.ModelID,
				ManifestDigest: target.ManifestDigest,
				LeaseHolder:    target.LeaseHolder,
				DeviceUUID:     target.DeviceUUID,
				DeviceIndex:    target.DeviceIndex,
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

	remaining, err := s.releaseLeaseOnlyLocked(rec, target.LeaseHolder)
	if err != nil {
		return GPUUnloadResult{}, err
	}

	s.revokeRuntimeBundleTokensForAllocation(target.AllocationID)
	if delErr := s.deleteAllocation(target.AllocationID); delErr != nil {
		return GPUUnloadResult{}, delErr
	}
	return GPUUnloadResult{
		Status:          rec.Status.ExternalStatus(),
		AllocationID:    target.AllocationID,
		ModelID:         target.ModelID,
		ManifestDigest:  target.ManifestDigest,
		LeaseHolder:     target.LeaseHolder,
		DeviceUUID:      target.DeviceUUID,
		DeviceIndex:     target.DeviceIndex,
		Loader:          s.gpuLoader.Name(),
		Files:           files,
		ReleasedBytes:   total,
		RemainingLeases: remaining,
		DurationMS:      time.Since(start).Milliseconds(),
		ReasonCode:      ReasonNone,
		Message:         "persistent GPU allocations released and lease updated",
	}, nil
}

func (s *Service) GPUListPersistent(ctx context.Context, deviceUUID string) ([]GPULoadFileResult, error) {
	device, err := s.resolveRequestedDevice(ctx, deviceUUID)
	if err != nil {
		return nil, err
	}
	return s.gpuLoader.ListPersistent(ctx, device.Index)
}

func (s *Service) GPUExport(ctx context.Context, req GPUExportRequest) (GPUExportResult, error) {
	start := time.Now()
	target, err := s.resolveAllocationTarget(ctx, req.AllocationID)
	if err != nil {
		return GPUExportResult{}, err
	}
	if req.MaxShards <= 0 {
		req.MaxShards = 0
	}

	shards, err := gpuWeightShards(target.Metadata.Profile)
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
		path := filepath.Join(target.ModelPath, "shards", shard.Name)
		res, err := s.gpuLoader.ExportPersistent(ctx, GPULoadFileRequest{
			Path:   path,
			Device: target.DeviceIndex,
		})
		if err != nil {
			appErr := AsAppError(err)
			return GPUExportResult{
				Status:         "FAILED",
				AllocationID:   target.AllocationID,
				ModelID:        target.ModelID,
				ManifestDigest: target.ManifestDigest,
				DeviceUUID:     target.DeviceUUID,
				DeviceIndex:    target.DeviceIndex,
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
		AllocationID:   target.AllocationID,
		ModelID:        target.ModelID,
		ManifestDigest: target.ManifestDigest,
		DeviceUUID:     target.DeviceUUID,
		DeviceIndex:    target.DeviceIndex,
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
	target, err := s.resolveAllocationTarget(ctx, req.AllocationID)
	if err != nil {
		return GPUAttachResult{}, err
	}
	clientID := strings.TrimSpace(req.ClientID)
	if clientID == "" {
		return GPUAttachResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "--client-id is required", nil)
	}
	if req.MaxShards <= 0 {
		req.MaxShards = 0
	}
	ttl := s.normalizeAttachTTL(req.TTLSeconds)

	if err := s.pruneExpiredAttachments(context.Background()); err != nil {
		return GPUAttachResult{}, err
	}

	shardPaths, err := resolveWeightShardPaths(target.Metadata, target.ModelPath, req.MaxShards)
	if err != nil {
		return GPUAttachResult{}, err
	}
	files := make([]GPULoadFileResult, 0, len(shardPaths))
	rollback := func() {
		for i := len(files) - 1; i >= 0; i-- {
			_, _ = s.gpuLoader.DetachPersistent(context.Background(), GPULoadFileRequest{
				Path:     files[i].Path,
				Device:   target.DeviceIndex,
				ClientID: clientID,
			})
		}
	}
	for _, shardPath := range shardPaths {
		res, attachErr := s.gpuLoader.AttachPersistent(ctx, GPULoadFileRequest{
			Path:     shardPath,
			Device:   target.DeviceIndex,
			ClientID: clientID,
		})
		if attachErr != nil {
			rollback()
			appErr := AsAppError(attachErr)
			return GPUAttachResult{
				Status:         "FAILED",
				AllocationID:   target.AllocationID,
				ModelID:        target.ModelID,
				ManifestDigest: target.ManifestDigest,
				DeviceUUID:     target.DeviceUUID,
				DeviceIndex:    target.DeviceIndex,
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
	s.attachMap[gpuAttachKey(target.ModelKey, target.DeviceUUID, clientID)] = &gpuClientAttachment{
		ModelKey:        target.ModelKey,
		ModelID:         target.ModelID,
		ManifestDigest:  target.ManifestDigest,
		Path:            target.ModelPath,
		DeviceUUID:      target.DeviceUUID,
		DeviceIndex:     target.DeviceIndex,
		ClientID:        clientID,
		ShardPaths:      append([]string(nil), shardPaths...),
		ExpiresAt:       expiresAt,
		LastHeartbeatAt: time.Now().UTC(),
	}
	s.attachMu.Unlock()

	return GPUAttachResult{
		Status:         "READY",
		AllocationID:   target.AllocationID,
		ModelID:        target.ModelID,
		ManifestDigest: target.ManifestDigest,
		DeviceUUID:     target.DeviceUUID,
		DeviceIndex:    target.DeviceIndex,
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
	target, err := s.resolveAllocationTarget(ctx, req.AllocationID)
	if err != nil {
		return GPUHeartbeatResult{}, err
	}
	clientID := strings.TrimSpace(req.ClientID)
	if clientID == "" {
		return GPUHeartbeatResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "--client-id is required", nil)
	}

	if err := s.pruneExpiredAttachments(context.Background()); err != nil {
		return GPUHeartbeatResult{}, err
	}
	ttl := s.normalizeAttachTTL(req.TTLSeconds)

	now := time.Now().UTC()
	attachKey := gpuAttachKey(target.ModelKey, target.DeviceUUID, clientID)
	s.attachMu.Lock()
	session, ok := s.attachMap[attachKey]
	if !ok {
		s.attachMu.Unlock()
		return GPUHeartbeatResult{
			Status:         "FAILED",
			AllocationID:   target.AllocationID,
			ModelID:        target.ModelID,
			ManifestDigest: target.ManifestDigest,
			DeviceUUID:     target.DeviceUUID,
			DeviceIndex:    target.DeviceIndex,
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
		AllocationID:   target.AllocationID,
		ModelID:        target.ModelID,
		ManifestDigest: target.ManifestDigest,
		DeviceUUID:     target.DeviceUUID,
		DeviceIndex:    target.DeviceIndex,
		ClientID:       clientID,
		ExpiresAt:      expiresAt.Format(time.RFC3339Nano),
		DurationMS:     time.Since(start).Milliseconds(),
		ReasonCode:     ReasonNone,
		Message:        "attachment heartbeat updated",
	}, nil
}

func (s *Service) GPUDetach(ctx context.Context, req GPUDetachRequest) (GPUDetachResult, error) {
	start := time.Now()
	target, err := s.resolveAllocationTarget(ctx, req.AllocationID)
	if err != nil {
		return GPUDetachResult{}, err
	}
	clientID := strings.TrimSpace(req.ClientID)
	if clientID == "" {
		return GPUDetachResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "--client-id is required", nil)
	}

	if err := s.pruneExpiredAttachments(context.Background()); err != nil {
		return GPUDetachResult{}, err
	}
	attachKey := gpuAttachKey(target.ModelKey, target.DeviceUUID, clientID)

	s.attachMu.Lock()
	session, ok := s.attachMap[attachKey]
	if ok {
		delete(s.attachMap, attachKey)
	}
	s.attachMu.Unlock()

	if !ok {
		return GPUDetachResult{
			Status:         "READY",
			AllocationID:   target.AllocationID,
			ModelID:        target.ModelID,
			ManifestDigest: target.ManifestDigest,
			DeviceUUID:     target.DeviceUUID,
			DeviceIndex:    target.DeviceIndex,
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
			Device:   target.DeviceIndex,
			ClientID: clientID,
		})
		if detachErr != nil {
			appErr := AsAppError(detachErr)
			return GPUDetachResult{
				Status:         "FAILED",
				AllocationID:   target.AllocationID,
				ModelID:        target.ModelID,
				ManifestDigest: target.ManifestDigest,
				DeviceUUID:     target.DeviceUUID,
				DeviceIndex:    target.DeviceIndex,
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
		AllocationID:   target.AllocationID,
		ModelID:        target.ModelID,
		ManifestDigest: target.ManifestDigest,
		DeviceUUID:     target.DeviceUUID,
		DeviceIndex:    target.DeviceIndex,
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
			device:     session.DeviceIndex,
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

func (s *Service) countActiveAttachmentsForModel(modelKey, deviceUUID string) int {
	s.attachMu.Lock()
	defer s.attachMu.Unlock()
	count := 0
	for _, session := range s.attachMap {
		if session == nil {
			continue
		}
		if session.ModelKey == modelKey && session.DeviceUUID == deviceUUID {
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

func gpuAttachKey(modelKey, deviceUUID, clientID string) string {
	return fmt.Sprintf("%s|%s|%s", modelKey, deviceUUID, clientID)
}

func (s *Service) nextAllocationID() string {
	s.allocMu.Lock()
	defer s.allocMu.Unlock()
	s.allocSeq++
	return fmt.Sprintf("alloc_%d_%d", time.Now().UTC().UnixNano(), s.allocSeq)
}

func (s *Service) putAllocation(rec *gpuAllocation) error {
	if rec == nil || strings.TrimSpace(rec.AllocationID) == "" {
		return NewAppError(ExitValidation, ReasonValidationFailed, "allocation record is required", nil)
	}
	storeRec := &storepkg.AllocationRecord{
		AllocationID:   strings.TrimSpace(rec.AllocationID),
		ModelKey:       strings.TrimSpace(rec.ModelKey),
		ModelID:        strings.TrimSpace(rec.ModelID),
		ManifestDigest: strings.TrimSpace(rec.ManifestDigest),
		Path:           strings.TrimSpace(rec.Path),
		LeaseHolder:    strings.TrimSpace(rec.LeaseHolder),
		DeviceUUID:     strings.TrimSpace(rec.DeviceUUID),
		DeviceIndex:    rec.DeviceIndex,
		Status:         "READY",
		CreatedAt:      rec.CreatedAt,
	}
	return s.store.PutAllocation(storeRec)
}

func (s *Service) deleteAllocation(allocationID string) error {
	allocationID = strings.TrimSpace(allocationID)
	if allocationID == "" {
		return nil
	}
	return s.store.DeleteAllocation(allocationID)
}

func (s *Service) getAllocation(allocationID string) (*gpuAllocation, error) {
	allocationID = strings.TrimSpace(allocationID)
	if allocationID == "" {
		return nil, NewAppError(ExitValidation, ReasonValidationFailed, "allocation_id is required", nil)
	}
	rec, ok, err := s.store.GetAllocation(allocationID)
	if err != nil {
		return nil, err
	}
	if !ok || rec == nil {
		return nil, NewAppError(ExitValidation, ReasonValidationFailed, "gpu allocation not found", nil)
	}
	return &gpuAllocation{
		AllocationID:   rec.AllocationID,
		ModelKey:       rec.ModelKey,
		ModelID:        rec.ModelID,
		ManifestDigest: rec.ManifestDigest,
		Path:           rec.Path,
		LeaseHolder:    rec.LeaseHolder,
		DeviceUUID:     rec.DeviceUUID,
		DeviceIndex:    rec.DeviceIndex,
		CreatedAt:      rec.CreatedAt,
	}, nil
}

func (s *Service) resolveRequestedDevice(ctx context.Context, deviceUUID string) (GPUDeviceInfo, error) {
	uuid := strings.TrimSpace(deviceUUID)
	if uuid == "" {
		return GPUDeviceInfo{}, NewAppError(ExitValidation, ReasonValidationFailed, "--device-uuid is required", nil)
	}
	device, err := s.gpuLoader.ResolveDevice(ctx, uuid)
	if err != nil {
		return GPUDeviceInfo{}, AsAppError(err)
	}
	if strings.TrimSpace(device.UUID) == "" {
		return GPUDeviceInfo{}, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "gpu loader returned empty device UUID", nil)
	}
	if device.Index < 0 {
		return GPUDeviceInfo{}, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "gpu loader returned invalid device index", nil)
	}
	return device, nil
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
