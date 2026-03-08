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
	target, err := s.resolveAllocationTarget(ctx, req.AllocationID)
	if err != nil {
		return GPUTensorMapResult{}, err
	}
	if req.MaxShards <= 0 {
		req.MaxShards = 0
	}
	if req.MaxTensors <= 0 {
		req.MaxTensors = 0
	}

	format := strings.ToLower(strings.TrimSpace(target.Metadata.Profile.Format))
	if format != "" && format != "safetensors" {
		return GPUTensorMapResult{}, NewAppError(ExitValidation, ReasonValidationFailed, fmt.Sprintf("gpu tensor-map only supports safetensors format; got %q", target.Metadata.Profile.Format), nil)
	}

	snapshot, err := s.getOrBuildTensorMapSnapshot(target.ModelKey, target.ModelID, target.ManifestDigest, target.ModelPath, target.Metadata)
	if err != nil {
		return GPUTensorMapResult{}, err
	}

	tensors := cloneTensorDescriptors(snapshot.Tensors)
	if req.MaxShards > 0 {
		allowedShards := map[string]struct{}{}
		shards, shardErr := gpuWeightShards(target.Metadata.Profile)
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
			shardPath := filepath.Join(target.ModelPath, "shards", shardName)
			res, exportErr := s.gpuLoader.ExportPersistent(ctx, GPULoadFileRequest{
				Path:   shardPath,
				Device: target.DeviceIndex,
			})
			if exportErr != nil {
				appErr := AsAppError(exportErr)
				return GPUTensorMapResult{
					Status:         "FAILED",
					AllocationID:   target.AllocationID,
					ModelID:        target.ModelID,
					ManifestDigest: target.ManifestDigest,
					DeviceUUID:     target.DeviceUUID,
					DeviceIndex:    target.DeviceIndex,
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
		AllocationID:     target.AllocationID,
		ModelID:          target.ModelID,
		ManifestDigest:   target.ManifestDigest,
		DeviceUUID:       target.DeviceUUID,
		DeviceIndex:      target.DeviceIndex,
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
		s.addTensorMapHit()
		return &cp, nil
	}
	s.tensorMapMu.RUnlock()
	s.addTensorMapMiss()

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
		s.addTensorMapHit()
		return &cp, nil
	}
	evicted := s.evictTensorMapCacheLocked(1)
	s.tensorMapCache[key] = snap
	s.tensorMapMu.Unlock()
	s.addTensorMapEvictions(evicted)

	cp := *snap
	cp.Tensors = cloneTensorDescriptors(snap.Tensors)
	return &cp, nil
}

func (s *Service) evictTensorMapCacheLocked(extraEntries int) int {
	limit := s.tensorMapCacheLimit()
	if limit <= 0 {
		return 0
	}
	current := len(s.tensorMapCache)
	if current+extraEntries <= limit {
		return 0
	}
	type candidate struct {
		key     string
		builtAt time.Time
	}
	candidates := make([]candidate, 0, len(s.tensorMapCache))
	for key, snap := range s.tensorMapCache {
		if snap == nil {
			candidates = append(candidates, candidate{key: key})
			continue
		}
		candidates = append(candidates, candidate{
			key:     key,
			builtAt: snap.BuiltAt,
		})
	}
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].builtAt.Equal(candidates[j].builtAt) {
			return candidates[i].key < candidates[j].key
		}
		return candidates[i].builtAt.Before(candidates[j].builtAt)
	})
	toEvict := current + extraEntries - limit
	evicted := 0
	for i := 0; i < len(candidates) && evicted < toEvict; i++ {
		delete(s.tensorMapCache, candidates[i].key)
		evicted++
	}
	return evicted
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
