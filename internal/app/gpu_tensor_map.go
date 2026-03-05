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
	device, err := s.resolveRequestedDevice(ctx, req.DeviceUUID)
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

	modelPath, modelID, manifestDigest, md, _, err := s.resolveGPUModelTarget(req.Path, req.ModelID, req.Digest)
	if err != nil {
		return GPUTensorMapResult{}, err
	}
	format := strings.ToLower(strings.TrimSpace(md.Profile.Format))
	if format != "" && format != "safetensors" {
		return GPUTensorMapResult{}, NewAppError(ExitValidation, ReasonValidationFailed, fmt.Sprintf("gpu tensor-map only supports safetensors format; got %q", md.Profile.Format), nil)
	}

	shards, err := gpuWeightShards(md.Profile)
	if err != nil {
		return GPUTensorMapResult{}, err
	}
	if req.MaxShards > 0 && req.MaxShards < len(shards) {
		shards = shards[:req.MaxShards]
	}

	handleByPath := map[string]string{}
	if req.IncludeHandles {
		for _, shard := range shards {
			if err := ValidateShardName(shard.Name); err != nil {
				return GPUTensorMapResult{}, NewAppError(ExitValidation, ReasonValidationFailed, fmt.Sprintf("invalid shard name %q: %v", shard.Name, err), nil)
			}
			shardPath := filepath.Join(modelPath, "shards", shard.Name)
			res, exportErr := s.gpuLoader.ExportPersistent(ctx, GPULoadFileRequest{
				Path:   shardPath,
				Device: req.Device,
			})
			if exportErr != nil {
				appErr := AsAppError(exportErr)
				return GPUTensorMapResult{
					Status:         "FAILED",
					ModelID:        modelID,
					ManifestDigest: manifestDigest,
					Path:           modelPath,
					DeviceUUID:     req.DeviceUUID,
					DeviceIndex:    req.Device,
					Loader:         s.gpuLoader.Name(),
					Format:         "safetensors",
					ReasonCode:     appErr.Reason,
					DurationMS:     time.Since(start).Milliseconds(),
					Message:        fmt.Sprintf("failed exporting shard %s: %v", shard.Name, appErr.Error()),
				}, appErr
			}
			ipcHandle := strings.TrimSpace(res.IPCHandle)
			if ipcHandle == "" {
				return GPUTensorMapResult{}, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, fmt.Sprintf("gpu export returned empty IPC handle for shard %s", shard.Name), nil)
			}
			handleByPath[shardPath] = ipcHandle
		}
	}

	tensors := make([]GPUTensorDescriptor, 0, 1024)
	var totalTensorBytes int64
	appendTensor := func(desc GPUTensorDescriptor) bool {
		tensors = append(tensors, desc)
		totalTensorBytes += desc.ByteLength
		return req.MaxTensors > 0 && len(tensors) >= req.MaxTensors
	}

	for _, shard := range shards {
		if err := ValidateShardName(shard.Name); err != nil {
			return GPUTensorMapResult{}, NewAppError(ExitValidation, ReasonValidationFailed, fmt.Sprintf("invalid shard name %q: %v", shard.Name, err), nil)
		}
		shardPath := filepath.Join(modelPath, "shards", shard.Name)
		entries, parseErr := parseSafeTensorsShard(shardPath, shard)
		if parseErr != nil {
			return GPUTensorMapResult{}, NewAppError(ExitIntegrity, ReasonProfileLintFailed, fmt.Sprintf("failed parsing safetensors header for shard %s", shard.Name), parseErr)
		}
		if req.IncludeHandles {
			ipcHandle := handleByPath[shardPath]
			for i := range entries {
				entries[i].IPCHandle = ipcHandle
			}
		}
		for _, entry := range entries {
			if appendTensor(entry) {
				return GPUTensorMapResult{
					Status:           "READY",
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
					Message:          "tensor map generated (max_tensors limit reached)",
				}, nil
			}
		}
	}

	return GPUTensorMapResult{
		Status:           "READY",
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
		Message:          "tensor map generated from safetensors headers",
	}, nil
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
			ShardPath:    shardPath,
			ShardDigest:  shard.Digest,
			ShardSize:    fileSize,
			ShardOrdinal: shard.Ordinal,
		}
		out = append(out, desc)
	}
	return out, nil
}
