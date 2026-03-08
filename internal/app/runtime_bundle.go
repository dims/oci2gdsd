package app

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type RuntimeBundleRequest struct {
	AllocationID   string `json:"allocation_id"`
	IncludeWeights bool   `json:"include_weights"`
}

type RuntimeBundleFile struct {
	ArchivePath string      `json:"archive_path"`
	SourcePath  string      `json:"-"`
	Size        int64       `json:"size"`
	Mode        os.FileMode `json:"mode"`
}

type RuntimeBundleResult struct {
	Status         string              `json:"status"`
	AllocationID   string              `json:"allocation_id,omitempty"`
	ModelID        string              `json:"model_id,omitempty"`
	ManifestDigest string              `json:"manifest_digest,omitempty"`
	Files          []RuntimeBundleFile `json:"files"`
	FileCount      int                 `json:"file_count"`
	TotalBytes     int64               `json:"total_bytes"`
	ReasonCode     ReasonCode          `json:"reason_code"`
	Message        string              `json:"message,omitempty"`
}

func (s *Service) RuntimeBundle(ctx context.Context, req RuntimeBundleRequest) (RuntimeBundleResult, error) {
	select {
	case <-ctx.Done():
		return RuntimeBundleResult{}, NewAppError(ExitRegistry, ReasonRegistryTimeout, "context canceled before runtime bundle resolution", ctx.Err())
	default:
	}

	allocationID := strings.TrimSpace(req.AllocationID)
	alloc, err := s.getAllocation(allocationID)
	if err != nil {
		return RuntimeBundleResult{}, err
	}
	modelPath, modelID, manifestDigest, md, _, err := s.resolveGPUModelTarget("", alloc.ModelID, alloc.ManifestDigest)
	if err != nil {
		return RuntimeBundleResult{}, err
	}

	seen := map[string]struct{}{}
	files := make([]RuntimeBundleFile, 0, len(md.Profile.Shards)+8)
	var total int64
	addFile := func(archivePath, sourcePath string) error {
		archivePath = filepath.ToSlash(strings.TrimSpace(archivePath))
		if archivePath == "" {
			return NewAppError(ExitValidation, ReasonValidationFailed, "runtime bundle archive path is empty", nil)
		}
		if strings.HasPrefix(archivePath, "/") || strings.Contains(archivePath, "..") {
			return NewAppError(ExitValidation, ReasonValidationFailed, "runtime bundle archive path is invalid", nil)
		}
		if _, dup := seen[archivePath]; dup {
			return NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "runtime bundle path collision", nil)
		}
		st, statErr := os.Stat(sourcePath)
		if statErr != nil {
			return NewAppError(ExitFilesystem, ReasonFilesystemError, "runtime bundle source file is missing", statErr)
		}
		if !st.Mode().IsRegular() {
			return NewAppError(ExitFilesystem, ReasonFilesystemError, "runtime bundle source is not a regular file", nil)
		}
		seen[archivePath] = struct{}{}
		total += st.Size()
		files = append(files, RuntimeBundleFile{
			ArchivePath: archivePath,
			SourcePath:  sourcePath,
			Size:        st.Size(),
			Mode:        st.Mode(),
		})
		return nil
	}

	for _, shard := range SortShardsByOrdinal(md.Profile.Shards) {
		if !req.IncludeWeights && ShardIsWeight(shard) {
			continue
		}
		if err := ValidateShardName(shard.Name); err != nil {
			return RuntimeBundleResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "invalid shard name in runtime bundle", err)
		}
		sourcePath := filepath.Join(modelPath, "shards", shard.Name)
		if err := addFile(filepath.Join("shards", shard.Name), sourcePath); err != nil {
			return RuntimeBundleResult{}, err
		}
	}

	metadataDir := filepath.Join(modelPath, "metadata")
	metadataEntries, err := os.ReadDir(metadataDir)
	if err != nil {
		return RuntimeBundleResult{}, NewAppError(ExitFilesystem, ReasonFilesystemError, "failed reading metadata directory for runtime bundle", err)
	}
	for _, entry := range metadataEntries {
		if entry.IsDir() {
			continue
		}
		name := strings.TrimSpace(entry.Name())
		if name == "" {
			continue
		}
		sourcePath := filepath.Join(metadataDir, name)
		if err := addFile(filepath.Join("metadata", name), sourcePath); err != nil {
			return RuntimeBundleResult{}, err
		}
	}

	sort.Slice(files, func(i, j int) bool {
		return files[i].ArchivePath < files[j].ArchivePath
	})

	return RuntimeBundleResult{
		Status:         "READY",
		AllocationID:   allocationID,
		ModelID:        modelID,
		ManifestDigest: manifestDigest,
		Files:          files,
		FileCount:      len(files),
		TotalBytes:     total,
		ReasonCode:     ReasonNone,
		Message:        "runtime bundle prepared",
	}, nil
}

func (s *Service) RuntimeBundleByToken(ctx context.Context, token string) (RuntimeBundleResult, error) {
	allocationID, includeWeights, err := s.resolveRuntimeBundleToken(token)
	if err != nil {
		return RuntimeBundleResult{}, err
	}
	return s.RuntimeBundle(ctx, RuntimeBundleRequest{
		AllocationID:   allocationID,
		IncludeWeights: includeWeights,
	})
}
