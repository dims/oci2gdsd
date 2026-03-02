package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	configpkg "github.com/dims/oci2gdsd/internal/config"
	storepkg "github.com/dims/oci2gdsd/internal/store"
	digest "github.com/opencontainers/go-digest"
	"gopkg.in/yaml.v3"
)

type Service struct {
	cfg       configpkg.Config
	store     *storepkg.StateStore
	locks     *LockManager
	fetcher   ModelFetcher
	gpuLoader GPULoader
}

func (s *Service) MinFreeBytesDefault() int64 {
	return s.cfg.Retention.MinFreeBytes
}

type EnsureRequest struct {
	Ref              string
	ModelID          string
	LeaseHolder      string
	StrictIntegrity  bool
	StrictDirectPath bool
	Wait             bool
	Timeout          time.Duration
}

type EnsureResult struct {
	Status          string     `json:"status"`
	ModelID         string     `json:"model_id"`
	ManifestDigest  string     `json:"manifest_digest"`
	ModelRootPath   string     `json:"model_root_path"`
	BytesDownloaded int64      `json:"bytes_downloaded"`
	BytesReused     int64      `json:"bytes_reused"`
	DurationMS      int64      `json:"duration_ms"`
	ReasonCode      ReasonCode `json:"reason_code"`
	Message         string     `json:"message,omitempty"`
}

type StatusResult struct {
	ModelID        string           `json:"model_id"`
	ManifestDigest string           `json:"manifest_digest"`
	Status         string           `json:"status"`
	Path           string           `json:"path"`
	ActiveLeases   []storepkg.Lease `json:"active_leases"`
	LastError      ReasonCode       `json:"last_error"`
	ReasonCode     ReasonCode       `json:"reason_code"`
	Message        string           `json:"message,omitempty"`
	Bytes          int64            `json:"bytes"`
}

type ReleaseResult struct {
	ModelID         string     `json:"model_id"`
	ManifestDigest  string     `json:"manifest_digest"`
	Status          string     `json:"status"`
	RemainingLeases int        `json:"remaining_leases"`
	ReasonCode      ReasonCode `json:"reason_code"`
	Message         string     `json:"message,omitempty"`
}

type GCResult struct {
	Policy          string   `json:"policy"`
	DeletedModels   []string `json:"deleted_models"`
	BytesFreed      int64    `json:"bytes_freed"`
	RemainingModels int      `json:"remaining_models"`
}

type VerifyResult struct {
	Status         string     `json:"status"`
	ModelID        string     `json:"model_id,omitempty"`
	ManifestDigest string     `json:"manifest_digest,omitempty"`
	Path           string     `json:"path"`
	ReasonCode     ReasonCode `json:"reason_code"`
	Message        string     `json:"message,omitempty"`
}

type localMetadata struct {
	SchemaVersion  int          `json:"schemaVersion"`
	ModelID        string       `json:"modelId"`
	ManifestDigest string       `json:"manifestDigest"`
	Reference      string       `json:"reference"`
	ArtifactType   string       `json:"artifactType"`
	PublishedAt    time.Time    `json:"publishedAt"`
	Bytes          int64        `json:"bytes"`
	Profile        ModelProfile `json:"profile"`
}

func NewService(cfg configpkg.Config, fetcher ModelFetcher, gpuLoader GPULoader) (*Service, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	if err := cfg.EnsureDirectories(); err != nil {
		return nil, err
	}
	store := storepkg.NewStateStore(cfg.StateDB)
	if err := store.Init(); err != nil {
		return nil, err
	}
	if fetcher == nil {
		return nil, NewAppError(ExitValidation, ReasonValidationFailed, "fetcher must not be nil", nil)
	}
	if gpuLoader == nil {
		return nil, NewAppError(ExitValidation, ReasonValidationFailed, "gpu loader must not be nil", nil)
	}
	s := &Service{
		cfg:       cfg,
		store:     store,
		locks:     NewLockManager(cfg.LocksRoot),
		fetcher:   fetcher,
		gpuLoader: gpuLoader,
	}
	if err := s.Recover(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Service) Recover() error {
	// Remove old stale temp paths from previous crashes. Keep young paths to
	// avoid interfering with currently running ensure operations.
	if fileExists(s.cfg.TmpRoot) {
		_ = filepath.WalkDir(s.cfg.TmpRoot, func(path string, d os.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if path == s.cfg.TmpRoot {
				return nil
			}
			if !d.IsDir() {
				return nil
			}
			info, statErr := d.Info()
			if statErr != nil {
				return nil
			}
			if time.Since(info.ModTime()) > 24*time.Hour {
				_ = os.RemoveAll(path)
				return filepath.SkipDir
			}
			return nil
		})
	}
	records, err := s.store.List()
	if err != nil {
		return err
	}
	for _, rec := range records {
		if rec.Path != "" {
			if err := ensurePathWithinRoot(s.cfg.ModelRoot, rec.Path); err != nil {
				rec.Status = StateFailed
				rec.LastError = ReasonStateDBCorrupt
				rec.LastErrorMessage = "recovery found model path outside configured model_root"
				if putErr := s.store.Put(&rec); putErr != nil {
					return putErr
				}
				_ = NewJournal(s.cfg.JournalDir, rec.ModelID, rec.ManifestDigest).Delete()
				continue
			}
		}
		journal := NewJournal(s.cfg.JournalDir, rec.ModelID, rec.ManifestDigest)
		markers, markerErr := journal.Markers()
		if markerErr != nil {
			return markerErr
		}
		if len(markers) > 0 {
			if markers[JournalCommitted] {
				_ = journal.Delete()
			} else if markers[JournalReadyWritten] {
				ready, _, verifyErr := s.verifyPublishedPathQuick(rec.Path)
				if verifyErr == nil && ready {
					rec.Status = StateReady
					rec.LastError = ReasonNone
					rec.LastErrorMessage = ""
					if putErr := s.store.Put(&rec); putErr != nil {
						return putErr
					}
					_ = journal.Append(JournalCommitted)
					_ = journal.Delete()
					continue
				}
				rec.Status = StateFailed
				rec.LastError = ReasonStateDBCorrupt
				rec.LastErrorMessage = "recovery found incomplete ensure transaction after READY write"
				if putErr := s.store.Put(&rec); putErr != nil {
					return putErr
				}
				_ = journal.Delete()
				continue
			} else {
				rec.Status = StateFailed
				rec.LastError = ReasonStateDBCorrupt
				rec.LastErrorMessage = "recovery found incomplete ensure transaction"
				if putErr := s.store.Put(&rec); putErr != nil {
					return putErr
				}
				_ = journal.Delete()
				continue
			}
		}
		if rec.Status != StateReady {
			continue
		}
		ready, _, verifyErr := s.verifyPublishedPathQuick(rec.Path)
		if verifyErr != nil || !ready {
			rec.Status = StateFailed
			rec.LastError = ReasonStateDBCorrupt
			rec.LastErrorMessage = "recovery found inconsistent READY state"
			if putErr := s.store.Put(&rec); putErr != nil {
				return putErr
			}
		}
	}
	return nil
}

func (s *Service) Ensure(ctx context.Context, req EnsureRequest) (EnsureResult, error) {
	start := time.Now()
	repository, manifestDigest, err := ParseDigestPinnedRef(req.Ref)
	if err != nil {
		return EnsureResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "ensure requires digest-pinned --ref", err)
	}
	_ = repository
	if strings.TrimSpace(req.ModelID) == "" {
		return EnsureResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "--model-id is required", nil)
	}
	if err := ValidateModelID(req.ModelID); err != nil {
		return EnsureResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "invalid --model-id", err)
	}
	if req.StrictDirectPath {
		// Standalone mode keeps this guard explicit to prevent silent downgrades.
		if strings.HasPrefix(s.cfg.ModelRoot, "/dev/shm") || strings.Contains(s.cfg.ModelRoot, "tmpfs") {
			return EnsureResult{}, NewAppError(ExitPolicy, ReasonDirectPathIneligible, "strict direct path requested but model_root appears transient", nil)
		}
	}

	timeout := s.cfg.TimeoutOrDefault(req.Timeout)
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}

	key := modelKey(req.ModelID, manifestDigest)
	unlock, pending, err := s.locks.Acquire(ctx, key, req.Wait)
	if err != nil {
		return EnsureResult{}, err
	}
	if pending {
		return EnsureResult{
			Status:         "PENDING",
			ModelID:        req.ModelID,
			ManifestDigest: manifestDigest,
			ReasonCode:     ReasonNone,
			DurationMS:     time.Since(start).Milliseconds(),
		}, nil
	}
	defer unlock()

	existing, ok, err := s.store.Get(key)
	if err != nil {
		return EnsureResult{}, err
	}
	if ok && existing.Path != "" {
		if err := ensurePathWithinRoot(s.cfg.ModelRoot, existing.Path); err != nil {
			return EnsureResult{}, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "existing model path escapes configured model_root", err)
		}
	}
	if ok && existing.Status == StateReady {
		if ready, _, verifyErr := s.verifyPublishedPath(existing.Path); verifyErr == nil && ready {
			existing.AcquireLease(req.LeaseHolder)
			existing.LastError = ReasonNone
			existing.LastErrorMessage = ""
			if putErr := s.store.Put(existing); putErr != nil {
				return EnsureResult{}, putErr
			}
			return EnsureResult{
				Status:          "READY",
				ModelID:         existing.ModelID,
				ManifestDigest:  existing.ManifestDigest,
				ModelRootPath:   existing.Path,
				BytesDownloaded: 0,
				BytesReused:     existing.Bytes,
				DurationMS:      time.Since(start).Milliseconds(),
				ReasonCode:      ReasonNone,
			}, nil
		}
	}

	finalPath := modelRootPath(s.cfg.ModelRoot, req.ModelID, manifestDigest)
	if err := ensurePathWithinRoot(s.cfg.ModelRoot, finalPath); err != nil {
		return EnsureResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "computed model path escapes configured model_root", err)
	}

	record := &storepkg.ModelRecord{
		Key:            key,
		ModelID:        req.ModelID,
		ManifestDigest: manifestDigest,
		Status:         StateResolving,
		Path:           finalPath,
		CreatedAt:      time.Now().UTC(),
		UpdatedAt:      time.Now().UTC(),
		LastAccessedAt: time.Now().UTC(),
	}
	if existing != nil {
		record.Leases = append([]storepkg.Lease(nil), existing.Leases...)
		if existing.Status == StateFailed {
			if err := transitionState(existing.Status, StateResolving); err != nil {
				return EnsureResult{}, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, err.Error(), err)
			}
		}
	}
	record.AcquireLease(req.LeaseHolder)
	if err := s.store.Put(record); err != nil {
		return EnsureResult{}, err
	}

	journal := NewJournal(s.cfg.JournalDir, req.ModelID, manifestDigest)
	if err := journal.Append(JournalTxnStarted); err != nil {
		return EnsureResult{}, err
	}

	fail := func(reason ReasonCode, message string, cause error) (EnsureResult, error) {
		record.Status = StateFailed
		record.LastError = reason
		record.LastErrorMessage = message
		_ = s.store.Put(record)
		appErr := NewAppError(mapReasonToExitCode(reason), reason, message, cause)
		return EnsureResult{
			Status:          "FAILED",
			ModelID:         req.ModelID,
			ManifestDigest:  manifestDigest,
			ModelRootPath:   "",
			BytesDownloaded: 0,
			BytesReused:     0,
			DurationMS:      time.Since(start).Milliseconds(),
			ReasonCode:      reason,
			Message:         appErr.Error(),
		}, appErr
	}

	fetched, err := s.fetcher.Fetch(ctx, req.Ref)
	if err != nil {
		appErr := AsAppError(err)
		return fail(appErr.Reason, "failed to fetch from registry", appErr)
	}
	lint := LintProfile(fetched.Profile, manifestDigest, fetched.Layers)
	if !lint.Valid {
		return fail(ReasonProfileLintFailed, strings.Join(lint.Errors, "; "), nil)
	}
	if req.StrictIntegrity && fetched.ArtifactType != "" && fetched.ArtifactType != MediaTypeModelArtifact {
		return fail(ReasonProfileLintFailed, fmt.Sprintf("artifactType %q does not match %q", fetched.ArtifactType, MediaTypeModelArtifact), nil)
	}
	if fetched.Profile.ModelID != "" && fetched.Profile.ModelID != req.ModelID {
		return fail(ReasonProfileLintFailed, fmt.Sprintf("profile modelId %q does not match --model-id %q", fetched.Profile.ModelID, req.ModelID), nil)
	}

	totalExpected, err := sumShardSizes(fetched.Profile.Shards)
	if err != nil {
		return fail(ReasonProfileLintFailed, "invalid aggregate shard size", err)
	}
	freeBytes, err := diskFreeBytes(s.cfg.ModelRoot)
	if err != nil {
		return fail(ReasonFilesystemError, "failed to measure free disk space", err)
	}
	if s.cfg.Retention.MinFreeBytes > math.MaxInt64-totalExpected {
		return fail(ReasonDiskSpaceInsufficient, "requested min_free_bytes plus shard sizes exceeds int64 range", nil)
	}
	requiredFloor := s.cfg.Retention.MinFreeBytes + totalExpected
	if freeBytes < requiredFloor {
		return fail(ReasonDiskSpaceInsufficient, "insufficient free space for ensure transaction", nil)
	}

	if err := transitionState(record.Status, StateDownloading); err != nil {
		return fail(ReasonStateDBCorrupt, err.Error(), err)
	}
	record.Status = StateDownloading
	if err := s.store.Put(record); err != nil {
		return EnsureResult{}, err
	}

	txnPath := tmpTxnPath(s.cfg.TmpRoot, req.ModelID, manifestDigest)
	if err := ensurePathWithinRoot(s.cfg.TmpRoot, txnPath); err != nil {
		return fail(ReasonValidationFailed, "computed transaction path escapes configured tmp_root", err)
	}
	stagingRoot := filepath.Join(txnPath, "publish")
	metadataDir := filepath.Join(stagingRoot, "metadata")
	shardsDir := filepath.Join(stagingRoot, "shards")
	if err := os.MkdirAll(metadataDir, 0o755); err != nil {
		return fail(ReasonFilesystemError, "failed to create metadata staging directory", err)
	}
	if err := os.MkdirAll(shardsDir, 0o755); err != nil {
		return fail(ReasonFilesystemError, "failed to create shard staging directory", err)
	}

	var bytesDownloaded int64
	buffer := make([]byte, s.cfg.Transfer.StreamBufferBytes)
	for _, blob := range fetched.Blobs {
		if err := ValidateShardName(blob.Name); err != nil {
			_ = os.RemoveAll(txnPath)
			return fail(ReasonProfileLintFailed, fmt.Sprintf("invalid shard name %q: %v", blob.Name, err), nil)
		}
		target := filepath.Join(shardsDir, blob.Name)
		if err := s.downloadBlob(ctx, blob, target, buffer); err != nil {
			appErr := AsAppError(err)
			_ = os.RemoveAll(txnPath)
			return fail(appErr.Reason, "blob download failed", appErr)
		}
		bytesDownloaded += blob.Size
	}
	if err := journal.Append(JournalBlobsWritten); err != nil {
		_ = os.RemoveAll(txnPath)
		return EnsureResult{}, err
	}
	if err := journal.Append(JournalBlobsVerified); err != nil {
		_ = os.RemoveAll(txnPath)
		return EnsureResult{}, err
	}

	if err := transitionState(record.Status, StateVerifying); err != nil {
		return fail(ReasonStateDBCorrupt, err.Error(), err)
	}
	record.Status = StateVerifying
	if err := s.store.Put(record); err != nil {
		return EnsureResult{}, err
	}
	if err := transitionState(record.Status, StatePublishing); err != nil {
		return fail(ReasonStateDBCorrupt, err.Error(), err)
	}
	record.Status = StatePublishing
	if err := s.store.Put(record); err != nil {
		return EnsureResult{}, err
	}

	meta := localMetadata{
		SchemaVersion:  1,
		ModelID:        req.ModelID,
		ManifestDigest: manifestDigest,
		Reference:      fetched.Reference,
		ArtifactType:   fetched.ArtifactType,
		PublishedAt:    time.Now().UTC(),
		Bytes:          totalExpected,
		Profile:        *fetched.Profile,
	}
	metaBytes, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		_ = os.RemoveAll(txnPath)
		return fail(ReasonFilesystemError, "failed to marshal metadata", err)
	}
	if err := writeAtomicFile(filepath.Join(metadataDir, "model.json"), metaBytes, 0o444, s.cfg.Publish.FsyncFiles); err != nil {
		_ = os.RemoveAll(txnPath)
		return fail(ReasonFilesystemError, "failed to write metadata", err)
	}
	if err := journal.Append(JournalMetadataWritten); err != nil {
		_ = os.RemoveAll(txnPath)
		return EnsureResult{}, err
	}

	readyBody := []byte(time.Now().UTC().Format(time.RFC3339) + "\n")
	if err := writeAtomicFile(filepath.Join(stagingRoot, "READY"), readyBody, 0o444, s.cfg.Publish.FsyncFiles); err != nil {
		_ = os.RemoveAll(txnPath)
		return fail(ReasonFilesystemError, "failed to write READY marker", err)
	}
	if err := journal.Append(JournalReadyWritten); err != nil {
		_ = os.RemoveAll(txnPath)
		return EnsureResult{}, err
	}

	finalPath = record.Path
	if fileExists(finalPath) {
		ok, reason, verifyErr := s.verifyPublishedPath(finalPath)
		if verifyErr != nil || !ok {
			_ = os.RemoveAll(txnPath)
			return fail(reason, "final path already exists but is not valid READY content", verifyErr)
		}
		_ = os.RemoveAll(txnPath)
	} else {
		if err := os.MkdirAll(filepath.Dir(finalPath), 0o755); err != nil {
			_ = os.RemoveAll(txnPath)
			return fail(ReasonFilesystemError, "failed to create final model parent directory", err)
		}
		if err := os.Rename(stagingRoot, finalPath); err != nil {
			_ = os.RemoveAll(txnPath)
			return fail(ReasonPublishRenameFailed, "atomic publish rename failed", err)
		}
		if s.cfg.Publish.FsyncDirectory {
			if err := fsyncDir(filepath.Dir(finalPath)); err != nil {
				return fail(ReasonFilesystemError, "failed to fsync final model parent directory", err)
			}
		}
		_ = os.RemoveAll(txnPath)
	}

	if err := journal.Append(JournalCommitted); err != nil {
		return EnsureResult{}, err
	}

	record.Status = StateReady
	record.Path = finalPath
	record.Bytes = totalExpected
	record.LastError = ReasonNone
	record.LastErrorMessage = ""
	record.Releasable = false
	record.ReleasableAt = nil
	record.LastAccessedAt = time.Now().UTC()
	if err := s.store.Put(record); err != nil {
		return EnsureResult{}, err
	}
	_ = journal.Delete()

	return EnsureResult{
		Status:          "READY",
		ModelID:         req.ModelID,
		ManifestDigest:  manifestDigest,
		ModelRootPath:   finalPath,
		BytesDownloaded: bytesDownloaded,
		BytesReused:     0,
		DurationMS:      time.Since(start).Milliseconds(),
		ReasonCode:      ReasonNone,
	}, nil
}

func (s *Service) downloadBlob(ctx context.Context, blob RemoteBlob, dst string, buffer []byte) error {
	rc, err := blob.Open(ctx)
	if err != nil {
		return err
	}
	defer rc.Close()

	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to create shard target directory", err)
	}
	f, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o444)
	if err != nil {
		return NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to create shard file", err)
	}
	defer f.Close()

	digester := digest.Canonical.Digester()
	writer := io.MultiWriter(f, digester.Hash())
	written, err := io.CopyBuffer(writer, rc, buffer)
	if err != nil {
		return NewAppError(ExitRegistry, ReasonRegistryDownloadFailure, fmt.Sprintf("failed writing shard %s", blob.Name), err)
	}
	if written != blob.Size {
		return NewAppError(ExitIntegrity, ReasonBlobSizeMismatch, fmt.Sprintf("size mismatch for shard %s: expected %d got %d", blob.Name, blob.Size, written), nil)
	}
	actual := digester.Digest().String()
	if actual != blob.Digest {
		return NewAppError(ExitIntegrity, ReasonBlobDigestMismatch, fmt.Sprintf("digest mismatch for shard %s: expected %s got %s", blob.Name, blob.Digest, actual), nil)
	}
	if s.cfg.Publish.FsyncFiles {
		if err := f.Sync(); err != nil {
			return NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to fsync shard file", err)
		}
	}
	return nil
}

func (s *Service) Status(modelID, manifestDigest string) (StatusResult, error) {
	if strings.TrimSpace(modelID) == "" || strings.TrimSpace(manifestDigest) == "" {
		return StatusResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "--model-id and --digest are required", nil)
	}
	if err := ValidateModelID(modelID); err != nil {
		return StatusResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "invalid --model-id", err)
	}
	key := modelKey(modelID, manifestDigest)
	rec, ok, err := s.store.Get(key)
	if err != nil {
		return StatusResult{}, err
	}
	if !ok {
		return StatusResult{
			ModelID:        modelID,
			ManifestDigest: manifestDigest,
			Status:         "RELEASED",
			ReasonCode:     ReasonNone,
		}, nil
	}
	return StatusResult{
		ModelID:        rec.ModelID,
		ManifestDigest: rec.ManifestDigest,
		Status:         rec.Status.ExternalStatus(),
		Path:           rec.Path,
		ActiveLeases:   rec.Leases,
		LastError:      rec.LastError,
		ReasonCode:     rec.LastError,
		Message:        rec.LastErrorMessage,
		Bytes:          rec.Bytes,
	}, nil
}

func (s *Service) List() ([]StatusResult, error) {
	records, err := s.store.List()
	if err != nil {
		return nil, err
	}
	results := make([]StatusResult, 0, len(records))
	for _, rec := range records {
		results = append(results, StatusResult{
			ModelID:        rec.ModelID,
			ManifestDigest: rec.ManifestDigest,
			Status:         rec.Status.ExternalStatus(),
			Path:           rec.Path,
			ActiveLeases:   rec.Leases,
			LastError:      rec.LastError,
			ReasonCode:     rec.LastError,
			Message:        rec.LastErrorMessage,
			Bytes:          rec.Bytes,
		})
	}
	sort.Slice(results, func(i, j int) bool {
		if results[i].ModelID == results[j].ModelID {
			return results[i].ManifestDigest < results[j].ManifestDigest
		}
		return results[i].ModelID < results[j].ModelID
	})
	return results, nil
}

func (s *Service) Release(ctx context.Context, modelID, manifestDigest, leaseHolder string, cleanup bool) (ReleaseResult, error) {
	if strings.TrimSpace(modelID) == "" || strings.TrimSpace(manifestDigest) == "" {
		return ReleaseResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "--model-id and --digest are required", nil)
	}
	if err := ValidateModelID(modelID); err != nil {
		return ReleaseResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "invalid --model-id", err)
	}
	if strings.TrimSpace(leaseHolder) == "" {
		return ReleaseResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "--lease-holder is required", nil)
	}
	key := modelKey(modelID, manifestDigest)
	unlock, _, err := s.locks.Acquire(ctx, key, true)
	if err != nil {
		return ReleaseResult{}, err
	}
	defer unlock()

	rec, ok, err := s.store.Get(key)
	if err != nil {
		return ReleaseResult{}, err
	}
	if !ok {
		return ReleaseResult{
			ModelID:         modelID,
			ManifestDigest:  manifestDigest,
			Status:          "RELEASED",
			RemainingLeases: 0,
			ReasonCode:      ReasonNone,
		}, nil
	}
	if rec.Path != "" {
		if err := ensurePathWithinRoot(s.cfg.ModelRoot, rec.Path); err != nil {
			return ReleaseResult{}, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "refusing release cleanup for path outside configured model_root", err)
		}
	}
	rec.Status = StateReleasing
	remaining := rec.ReleaseLease(leaseHolder)
	now := time.Now().UTC()
	if remaining > 0 {
		rec.Status = StateReady
		rec.Releasable = false
		rec.ReleasableAt = nil
	} else {
		rec.Releasable = true
		rec.ReleasableAt = &now
		if cleanup {
			if rec.Path != "" && fileExists(rec.Path) {
				if err := os.RemoveAll(rec.Path); err != nil {
					return ReleaseResult{}, NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to cleanup model path", err)
				}
			}
			rec.Status = StateReleased
			rec.Path = ""
			rec.Bytes = 0
		} else {
			rec.Status = StateReady
		}
	}
	if err := s.store.Put(rec); err != nil {
		return ReleaseResult{}, err
	}
	return ReleaseResult{
		ModelID:         modelID,
		ManifestDigest:  manifestDigest,
		Status:          rec.Status.ExternalStatus(),
		RemainingLeases: remaining,
		ReasonCode:      ReasonNone,
	}, nil
}

func (s *Service) GC(policy string, minFreeBytes int64, dryRun bool) (GCResult, error) {
	if policy == "" {
		policy = s.cfg.Retention.Policy
	}
	if policy == "" {
		policy = "lru_no_lease"
	}
	if policy != "lru_no_lease" {
		return GCResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "unsupported gc policy", nil)
	}

	records, err := s.store.List()
	if err != nil {
		return GCResult{}, err
	}
	type candidate struct {
		rec storepkg.ModelRecord
	}
	candidates := make([]candidate, 0)
	for _, rec := range records {
		if len(rec.Leases) > 0 {
			continue
		}
		if rec.Path == "" {
			continue
		}
		if err := ensurePathWithinRoot(s.cfg.ModelRoot, rec.Path); err != nil {
			return GCResult{}, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "gc found model path outside configured model_root", err)
		}
		if rec.Status != StateReady && rec.Status != StateReleased && rec.Status != StateFailed {
			continue
		}
		if rec.Status != StateFailed && !fileExists(readyMarkerPath(rec.Path)) {
			continue
		}
		candidates = append(candidates, candidate{rec: rec})
	}
	sort.Slice(candidates, func(i, j int) bool {
		recI := candidates[i].rec
		recJ := candidates[j].rec
		nilI := recI.ReleasableAt == nil
		nilJ := recJ.ReleasableAt == nil
		if nilI != nilJ {
			// Prefer explicit releasable timestamps over nil timestamps.
			return !nilI
		}
		if !nilI && !nilJ {
			ttlI := *recI.ReleasableAt
			ttlJ := *recJ.ReleasableAt
			if !ttlI.Equal(ttlJ) {
				return ttlI.Before(ttlJ)
			}
		}
		if recI.UpdatedAt.Equal(recJ.UpdatedAt) {
			return recI.Bytes > recJ.Bytes
		}
		return recI.UpdatedAt.Before(recJ.UpdatedAt)
	})

	target := minFreeBytes
	if target <= 0 {
		target = s.cfg.Retention.MinFreeBytes
	}
	free, err := diskFreeBytes(s.cfg.ModelRoot)
	if err != nil {
		return GCResult{}, NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to get free disk for gc", err)
	}
	result := GCResult{
		Policy:        policy,
		DeletedModels: []string{},
	}
	for _, c := range candidates {
		if free >= target {
			break
		}
		key := modelKey(c.rec.ModelID, c.rec.ManifestDigest)
		unlock, pending, lockErr := s.locks.Acquire(context.Background(), key, false)
		if lockErr != nil {
			return result, lockErr
		}
		if pending {
			continue
		}

		rec, ok, getErr := s.store.Get(key)
		if getErr != nil {
			unlock()
			return result, getErr
		}
		if !ok {
			unlock()
			continue
		}
		if err := ensurePathWithinRoot(s.cfg.ModelRoot, rec.Path); err != nil {
			unlock()
			return result, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "gc refused path outside configured model_root", err)
		}
		if len(rec.Leases) > 0 || rec.Path == "" || (rec.Status != StateReady && rec.Status != StateReleased && rec.Status != StateFailed) || (rec.Status != StateFailed && !fileExists(readyMarkerPath(rec.Path))) {
			unlock()
			continue
		}
		freedBytes := rec.Bytes
		if !dryRun {
			if err := os.RemoveAll(rec.Path); err != nil {
				unlock()
				return result, NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to delete model during gc", err)
			}
			rec.Status = StateReleased
			rec.Path = ""
			rec.Bytes = 0
			rec.Releasable = true
			now := time.Now().UTC()
			rec.ReleasableAt = &now
			if err := s.store.Put(rec); err != nil {
				unlock()
				return result, err
			}
			_ = NewJournal(s.cfg.JournalDir, rec.ModelID, rec.ManifestDigest).Delete()
		}
		unlock()
		result.DeletedModels = append(result.DeletedModels, key)
		result.BytesFreed += freedBytes
		free += freedBytes
	}
	updated, err := s.store.List()
	if err != nil {
		return result, err
	}
	result.RemainingModels = len(updated)
	return result, nil
}

func sumShardSizes(shards []ModelShard) (int64, error) {
	var total int64
	for i, shard := range shards {
		if shard.Size < 0 {
			return 0, fmt.Errorf("shard[%d] has negative size %d", i, shard.Size)
		}
		if total > math.MaxInt64-shard.Size {
			return 0, fmt.Errorf("aggregate shard size overflow at shard[%d]", i)
		}
		total += shard.Size
	}
	return total, nil
}

func (s *Service) Verify(path string, modelID string, manifestDigest string) (VerifyResult, error) {
	if strings.TrimSpace(path) == "" {
		if modelID == "" || manifestDigest == "" {
			return VerifyResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "either --path or (--model-id and --digest) are required", nil)
		}
		if err := ValidateModelID(modelID); err != nil {
			return VerifyResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "invalid --model-id", err)
		}
		key := modelKey(modelID, manifestDigest)
		rec, ok, err := s.store.Get(key)
		if err != nil {
			return VerifyResult{}, err
		}
		if !ok {
			return VerifyResult{}, NewAppError(ExitValidation, ReasonValidationFailed, "model not found in local state", nil)
		}
		path = rec.Path
	}
	ok, reason, err := s.verifyPublishedPath(path)
	if err != nil {
		return VerifyResult{
			Status:     "FAILED",
			Path:       path,
			ReasonCode: reason,
			Message:    err.Error(),
		}, err
	}
	if !ok {
		return VerifyResult{
			Status:     "FAILED",
			Path:       path,
			ReasonCode: reason,
			Message:    "verify failed",
		}, NewAppError(mapReasonToExitCode(reason), reason, "verify failed", nil)
	}
	md, _ := loadLocalMetadata(path)
	return VerifyResult{
		Status:         "READY",
		Path:           path,
		ModelID:        md.ModelID,
		ManifestDigest: md.ManifestDigest,
		ReasonCode:     ReasonNone,
	}, nil
}

func (s *Service) verifyPublishedPath(path string) (bool, ReasonCode, error) {
	if strings.TrimSpace(path) == "" {
		return false, ReasonValidationFailed, errors.New("path is empty")
	}
	if !fileExists(path) {
		return false, ReasonFilesystemError, fmt.Errorf("path does not exist: %s", path)
	}
	if !fileExists(readyMarkerPath(path)) {
		return false, ReasonStateDBCorrupt, errors.New("READY marker missing")
	}
	meta, err := loadLocalMetadata(path)
	if err != nil {
		return false, ReasonStateDBCorrupt, err
	}
	shardsDir := filepath.Join(path, "shards")
	info, err := os.Stat(shardsDir)
	if err != nil {
		return false, ReasonFilesystemError, err
	}
	if !info.IsDir() {
		return false, ReasonFilesystemError, errors.New("shards path is not a directory")
	}

	seen := 0
	for _, shard := range meta.Profile.Shards {
		if err := ValidateShardName(shard.Name); err != nil {
			return false, ReasonValidationFailed, fmt.Errorf("invalid shard name %q: %v", shard.Name, err)
		}
		sp := shardPath(path, shard.Name)
		st, err := os.Stat(sp)
		if err != nil {
			return false, ReasonFilesystemError, fmt.Errorf("missing shard %s", shard.Name)
		}
		if st.Size() != shard.Size {
			return false, ReasonBlobSizeMismatch, fmt.Errorf("size mismatch for shard %s", shard.Name)
		}
		f, err := os.Open(sp)
		if err != nil {
			return false, ReasonFilesystemError, err
		}
		digester := digest.Canonical.Digester()
		if _, err := io.Copy(digester.Hash(), f); err != nil {
			_ = f.Close()
			return false, ReasonFilesystemError, err
		}
		_ = f.Close()
		if digester.Digest().String() != shard.Digest {
			return false, ReasonBlobDigestMismatch, fmt.Errorf("digest mismatch for shard %s", shard.Name)
		}
		seen++
	}

	files, err := os.ReadDir(shardsDir)
	if err != nil {
		return false, ReasonFilesystemError, err
	}
	if len(files) != seen {
		return false, ReasonStateDBCorrupt, fmt.Errorf("shard cardinality mismatch: expected %d got %d", seen, len(files))
	}

	return true, ReasonNone, nil
}

func (s *Service) verifyPublishedPathQuick(path string) (bool, ReasonCode, error) {
	if strings.TrimSpace(path) == "" {
		return false, ReasonValidationFailed, errors.New("path is empty")
	}
	if !fileExists(path) {
		return false, ReasonFilesystemError, fmt.Errorf("path does not exist: %s", path)
	}
	if !fileExists(readyMarkerPath(path)) {
		return false, ReasonStateDBCorrupt, errors.New("READY marker missing")
	}
	meta, err := loadLocalMetadata(path)
	if err != nil {
		return false, ReasonStateDBCorrupt, err
	}
	shardsDir := filepath.Join(path, "shards")
	info, err := os.Stat(shardsDir)
	if err != nil {
		return false, ReasonFilesystemError, err
	}
	if !info.IsDir() {
		return false, ReasonFilesystemError, errors.New("shards path is not a directory")
	}
	seen := 0
	for _, shard := range meta.Profile.Shards {
		if err := ValidateShardName(shard.Name); err != nil {
			return false, ReasonValidationFailed, fmt.Errorf("invalid shard name %q: %v", shard.Name, err)
		}
		sp := shardPath(path, shard.Name)
		st, err := os.Stat(sp)
		if err != nil {
			return false, ReasonFilesystemError, fmt.Errorf("missing shard %s", shard.Name)
		}
		if st.Size() != shard.Size {
			return false, ReasonBlobSizeMismatch, fmt.Errorf("size mismatch for shard %s", shard.Name)
		}
		seen++
	}
	files, err := os.ReadDir(shardsDir)
	if err != nil {
		return false, ReasonFilesystemError, err
	}
	if len(files) != seen {
		return false, ReasonStateDBCorrupt, fmt.Errorf("shard cardinality mismatch: expected %d got %d", seen, len(files))
	}
	return true, ReasonNone, nil
}

func loadLocalMetadata(path string) (*localMetadata, error) {
	b, err := os.ReadFile(metadataPath(path))
	if err != nil {
		return nil, err
	}
	md := &localMetadata{}
	if err := json.Unmarshal(b, md); err != nil {
		return nil, err
	}
	return md, nil
}

func (s *Service) ProfileFromRef(ctx context.Context, ref string) (*ModelProfile, []ManifestLayer, string, error) {
	fetched, err := s.fetcher.Fetch(ctx, ref)
	if err != nil {
		return nil, nil, "", err
	}
	return fetched.Profile, fetched.Layers, fetched.ManifestDigest, nil
}

func (s *Service) ProfileFromFile(path string) (*ModelProfile, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, NewAppError(ExitValidation, ReasonValidationFailed, "failed to read profile config file", err)
	}
	profile := &ModelProfile{}
	ext := strings.ToLower(filepath.Ext(path))
	if ext == ".yaml" || ext == ".yml" {
		if err := yaml.Unmarshal(b, profile); err != nil {
			return nil, NewAppError(ExitValidation, ReasonValidationFailed, "failed to parse profile config YAML", err)
		}
		return profile, nil
	}
	if err := json.Unmarshal(b, profile); err != nil {
		return nil, NewAppError(ExitValidation, ReasonValidationFailed, "failed to parse profile config JSON", err)
	}
	return profile, nil
}
