package app

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const maxSafeTensorsHeaderBytes = int64(128 << 20) // 128 MiB

type safeTensorsHeaderTensor struct {
	DType       string  `json:"dtype"`
	Shape       []int64 `json:"shape"`
	DataOffsets []int64 `json:"data_offsets"`
}

func (s *Service) GPUTensorMap(ctx context.Context, req GPUTensorMapRequest) (GPUTensorMapResult, error) {
	start := time.Now()
	allocationID := strings.TrimSpace(req.AllocationID)
	if allocationID == "" {
		return GPUTensorMapResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "allocation_id is required", nil)
	}
	alloc, err := s.getAllocation(allocationID)
	if err != nil {
		return GPUTensorMapResult{}, err
	}
	device, err := s.resolveRequestedDevice(ctx, alloc.DeviceUUID)
	if err != nil {
		return GPUTensorMapResult{}, err
	}
	req.DeviceUUID = device.UUID
	req.Device = device.Index
	if req.MaxShards <= 0 {
		req.MaxShards = 0
	}
	if req.MaxTensors <= 0 {
		req.MaxTensors = 0
	}

	modelPath, modelID, manifestDigest, md, key, err := s.resolveGPUModelTarget("", alloc.ModelID, alloc.ManifestDigest)
	if err != nil {
		return GPUTensorMapResult{}, err
	}
	format := strings.ToLower(strings.TrimSpace(md.Profile.Format))
	if format != "" && format != "safetensors" {
		return GPUTensorMapResult{}, NewAppError(ExitValidation, ReasonValidationFailed, fmt.Sprintf("gpu tensor-map only supports safetensors format; got %q", md.Profile.Format), nil)
	}

	snapshot, err := s.getOrBuildTensorMapSnapshot(key, modelID, manifestDigest, modelPath, md)
	if err != nil {
		return GPUTensorMapResult{}, err
	}

	tensors := cloneTensorDescriptors(snapshot.Tensors)
	if req.MaxShards > 0 {
		allowedShards := map[string]struct{}{}
		shards, shardErr := gpuWeightShards(md.Profile)
		if shardErr != nil {
			return GPUTensorMapResult{}, shardErr
		}
		for i := 0; i < len(shards) && i < req.MaxShards; i++ {
			allowedShards[shards[i].Name] = struct{}{}
		}
		filtered := make([]GPUTensorDescriptor, 0, len(tensors))
		for _, entry := range tensors {
			if _, ok := allowedShards[entry.ShardName]; ok {
				filtered = append(filtered, entry)
			}
		}
		tensors = filtered
	}

	if req.MaxTensors > 0 && req.MaxTensors < len(tensors) {
		tensors = tensors[:req.MaxTensors]
	}

	handleByShard := map[string]string{}
	if req.IncludeHandles {
		seenShard := map[string]struct{}{}
		shardOrder := make([]string, 0, len(tensors))
		for _, entry := range tensors {
			if _, ok := seenShard[entry.ShardName]; ok {
				continue
			}
			seenShard[entry.ShardName] = struct{}{}
			shardOrder = append(shardOrder, entry.ShardName)
		}
		for _, shardName := range shardOrder {
			if err := ValidateShardName(shardName); err != nil {
				return GPUTensorMapResult{}, NewAppError(ExitValidation, ReasonValidationFailed, fmt.Sprintf("invalid shard name %q: %v", shardName, err), nil)
			}
			shardPath := filepath.Join(modelPath, "shards", shardName)
			res, exportErr := s.gpuLoader.ExportPersistent(ctx, GPULoadFileRequest{
				Path:   shardPath,
				Device: req.Device,
			})
			if exportErr != nil {
				appErr := AsAppError(exportErr)
				return GPUTensorMapResult{
					Status:         "FAILED",
					AllocationID:   allocationID,
					ModelID:        modelID,
					ManifestDigest: manifestDigest,
					Path:           modelPath,
					DeviceUUID:     req.DeviceUUID,
					DeviceIndex:    req.Device,
					Loader:         s.gpuLoader.Name(),
					Format:         "safetensors",
					ReasonCode:     appErr.Reason,
					DurationMS:     time.Since(start).Milliseconds(),
					Message:        fmt.Sprintf("failed exporting shard %s: %v", shardName, appErr.Error()),
				}, appErr
			}
			ipcHandle := strings.TrimSpace(res.IPCHandle)
			if ipcHandle == "" {
				return GPUTensorMapResult{}, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, fmt.Sprintf("gpu export returned empty IPC handle for shard %s", shardName), nil)
			}
			handleByShard[shardName] = ipcHandle
		}
	}
	var totalTensorBytes int64
	if req.IncludeHandles {
		for i := range tensors {
			tensors[i].IPCHandle = handleByShard[tensors[i].ShardName]
			totalTensorBytes += tensors[i].ByteLength
		}
	} else {
		for _, entry := range tensors {
			totalTensorBytes += entry.ByteLength
		}
	}

	return GPUTensorMapResult{
		Status:           "READY",
		AllocationID:     allocationID,
		ModelID:          modelID,
		ManifestDigest:   manifestDigest,
		Path:             modelPath,
		DeviceUUID:       req.DeviceUUID,
		DeviceIndex:      req.Device,
		Loader:           s.gpuLoader.Name(),
		Format:           "safetensors",
		Tensors:          tensors,
		TensorCount:      len(tensors),
		TotalTensorBytes: totalTensorBytes,
		DurationMS:       time.Since(start).Milliseconds(),
		ReasonCode:       ReasonNone,
		Message:          "tensor map generated from cached safetensors headers",
	}, nil
}

func cloneTensorDescriptors(in []GPUTensorDescriptor) []GPUTensorDescriptor {
	out := make([]GPUTensorDescriptor, len(in))
	for i := range in {
		out[i] = in[i]
		out[i].Shape = append([]int64(nil), in[i].Shape...)
	}
	return out
}

func (s *Service) getOrBuildTensorMapSnapshot(key, modelID, manifestDigest, modelPath string, md *localMetadata) (*tensorMapSnapshot, error) {
	s.tensorMapMu.RLock()
	if snap, ok := s.tensorMapCache[key]; ok && snap != nil {
		cp := *snap
		cp.Tensors = cloneTensorDescriptors(snap.Tensors)
		s.tensorMapMu.RUnlock()
		return &cp, nil
	}
	s.tensorMapMu.RUnlock()

	buildStart := time.Now()
	shards, err := gpuWeightShards(md.Profile)
	if err != nil {
		return nil, err
	}
	tensors := make([]GPUTensorDescriptor, 0, 1024)
	for _, shard := range shards {
		if err := ValidateShardName(shard.Name); err != nil {
			return nil, NewAppError(ExitValidation, ReasonValidationFailed, fmt.Sprintf("invalid shard name %q: %v", shard.Name, err), nil)
		}
		shardPath := filepath.Join(modelPath, "shards", shard.Name)
		entries, parseErr := parseSafeTensorsShard(shardPath, shard)
		if parseErr != nil {
			return nil, NewAppError(ExitIntegrity, ReasonProfileLintFailed, fmt.Sprintf("failed parsing safetensors header for shard %s", shard.Name), parseErr)
		}
		tensors = append(tensors, entries...)
	}

	snap := &tensorMapSnapshot{
		Key:     key,
		Format:  "safetensors",
		Tensors: cloneTensorDescriptors(tensors),
		BuildMS: time.Since(buildStart).Milliseconds(),
		BuiltAt: time.Now().UTC(),
		ModelID: modelID,
		Digest:  manifestDigest,
	}

	s.tensorMapMu.Lock()
	if s.tensorMapCache == nil {
		s.tensorMapCache = map[string]*tensorMapSnapshot{}
	}
	if existing, ok := s.tensorMapCache[key]; ok && existing != nil {
		cp := *existing
		cp.Tensors = cloneTensorDescriptors(existing.Tensors)
		s.tensorMapMu.Unlock()
		return &cp, nil
	}
	s.tensorMapCache[key] = snap
	s.tensorMapMu.Unlock()

	cp := *snap
	cp.Tensors = cloneTensorDescriptors(snap.Tensors)
	return &cp, nil
}

func parseSafeTensorsShard(shardPath string, shard ModelShard) ([]GPUTensorDescriptor, error) {
	f, err := os.Open(shardPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	fileSize := st.Size()
	if fileSize < 8 {
		return nil, fmt.Errorf("invalid safetensors file size (%d bytes)", fileSize)
	}

	lenBuf := make([]byte, 8)
	if _, err := io.ReadFull(f, lenBuf); err != nil {
		return nil, err
	}
	headerLen := int64(binary.LittleEndian.Uint64(lenBuf))
	if headerLen <= 0 {
		return nil, fmt.Errorf("invalid safetensors header length (%d)", headerLen)
	}
	if headerLen > maxSafeTensorsHeaderBytes {
		return nil, fmt.Errorf("safetensors header length exceeds limit (%d > %d)", headerLen, maxSafeTensorsHeaderBytes)
	}
	if headerLen > fileSize-8 {
		return nil, fmt.Errorf("safetensors header length exceeds file bounds (%d > %d)", headerLen, fileSize-8)
	}

	headerPayload := make([]byte, headerLen)
	if _, err := io.ReadFull(f, headerPayload); err != nil {
		return nil, err
	}

	raw := map[string]safeTensorsHeaderTensor{}
	if err := json.Unmarshal(headerPayload, &raw); err != nil {
		return nil, err
	}

	names := make([]string, 0, len(raw))
	for name := range raw {
		if name == "__metadata__" {
			continue
		}
		names = append(names, name)
	}
	sort.Strings(names)

	dataStart := int64(8) + headerLen
	out := make([]GPUTensorDescriptor, 0, len(names))
	for _, name := range names {
		spec := raw[name]
		if len(spec.DataOffsets) != 2 {
			return nil, fmt.Errorf("tensor %q has invalid data_offsets length (%d)", name, len(spec.DataOffsets))
		}
		start := spec.DataOffsets[0]
		end := spec.DataOffsets[1]
		if start < 0 || end < start {
			return nil, fmt.Errorf("tensor %q has invalid data_offsets [%d,%d]", name, start, end)
		}
		absStart := dataStart + start
		absEnd := dataStart + end
		if absStart < dataStart || absEnd < absStart {
			return nil, fmt.Errorf("tensor %q has invalid absolute offsets", name)
		}
		if absEnd > fileSize {
			return nil, fmt.Errorf("tensor %q exceeds shard file size (%d > %d)", name, absEnd, fileSize)
		}
		desc := GPUTensorDescriptor{
			Name:         name,
			DType:        strings.TrimSpace(spec.DType),
			Shape:        append([]int64(nil), spec.Shape...),
			ByteOffset:   absStart,
			ByteLength:   absEnd - absStart,
			ShardName:    shard.Name,
			ShardDigest:  shard.Digest,
			ShardSize:    fileSize,
			ShardOrdinal: shard.Ordinal,
		}
		out = append(out, desc)
	}
	return out, nil
}
