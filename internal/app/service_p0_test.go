package app

import (
	"context"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	storepkg "github.com/dims/oci2gdsd/internal/store"
)

func TestSumShardSizesOverflow(t *testing.T) {
	_, err := sumShardSizes([]ModelShard{
		{Size: math.MaxInt64},
		{Size: 1},
	})
	if err == nil {
		t.Fatalf("expected overflow error")
	}
}

func TestSumShardSizesRejectsNegative(t *testing.T) {
	_, err := sumShardSizes([]ModelShard{
		{Size: -1},
	})
	if err == nil {
		t.Fatalf("expected negative size error")
	}
}

func TestEnsureRejectsInvalidModelID(t *testing.T) {
	manifest := "sha256:" + strings.Repeat("a", 64)
	ref := "registry.example.com/models/demo@" + manifest
	fetcher := &fakeEnsureFetcher{
		fetchFn: func(_ string) (*FetchedModel, error) {
			t.Fatalf("fetcher must not be called for invalid model id")
			return nil, nil
		},
	}
	svc := newEnsureTestService(t, fetcher)

	_, err := svc.Ensure(context.Background(), EnsureRequest{
		Ref:         ref,
		ModelID:     "../escape",
		LeaseHolder: "holder-a",
		Wait:        true,
	})
	if err == nil {
		t.Fatalf("expected invalid model-id failure")
	}
	appErr := AsAppError(err)
	if appErr.Reason != ReasonValidationFailed {
		t.Fatalf("expected reason %s, got %s", ReasonValidationFailed, appErr.Reason)
	}
	if fetcher.CallCount() != 0 {
		t.Fatalf("expected fetcher to not be called, got %d calls", fetcher.CallCount())
	}
}

func TestReleaseRejectsInvalidModelID(t *testing.T) {
	svc := newStateOnlyService(t)
	_, err := svc.Release(context.Background(), "../escape", "sha256:"+strings.Repeat("b", 64), "holder-a", false)
	if err == nil {
		t.Fatalf("expected invalid model-id failure")
	}
	appErr := AsAppError(err)
	if appErr.Reason != ReasonValidationFailed {
		t.Fatalf("expected reason %s, got %s", ReasonValidationFailed, appErr.Reason)
	}
}

func TestGCRejectsRecordPathOutsideModelRoot(t *testing.T) {
	svc := newStateOnlyService(t)
	manifest := "sha256:" + strings.Repeat("c", 64)
	outside := filepath.Join(t.TempDir(), "outside", "model")
	rec := &storepkg.ModelRecord{
		Key:            modelKey("demo", manifest),
		ModelID:        "demo",
		ManifestDigest: manifest,
		Status:         StateReady,
		Path:           outside,
		Bytes:          1024,
		CreatedAt:      time.Now().UTC(),
		UpdatedAt:      time.Now().UTC(),
		LastAccessedAt: time.Now().UTC(),
	}
	if err := svc.store.Put(rec); err != nil {
		t.Fatalf("put record: %v", err)
	}

	_, err := svc.GC("lru_no_lease", math.MaxInt64/4, false)
	if err == nil {
		t.Fatalf("expected gc failure for out-of-root path")
	}
	appErr := AsAppError(err)
	if appErr.Reason != ReasonStateDBCorrupt {
		t.Fatalf("expected reason %s, got %s", ReasonStateDBCorrupt, appErr.Reason)
	}
}

func TestEnsureRejectsModelIDOutsideAllowlist(t *testing.T) {
	manifest := "sha256:" + strings.Repeat("d", 64)
	ref := "registry.example.com/models/demo@" + manifest
	fetcher := &fakeEnsureFetcher{
		fetchFn: func(_ string) (*FetchedModel, error) {
			t.Fatalf("fetcher must not be called for disallowed model id")
			return nil, nil
		},
	}
	svc := newEnsureTestService(t, fetcher)
	svc.modelIDAllowlist = regexp.MustCompile(`^[a-z0-9-]+$`)

	_, err := svc.Ensure(context.Background(), EnsureRequest{
		Ref:         ref,
		ModelID:     "Demo-Upper",
		LeaseHolder: "holder-a",
		Wait:        true,
	})
	if err == nil {
		t.Fatalf("expected allowlist model-id failure")
	}
	appErr := AsAppError(err)
	if appErr.Reason != ReasonValidationFailed {
		t.Fatalf("expected reason %s, got %s", ReasonValidationFailed, appErr.Reason)
	}
	if fetcher.CallCount() != 0 {
		t.Fatalf("expected fetcher to not be called, got %d calls", fetcher.CallCount())
	}
}

func TestGCRejectsRecordPathViaSymlinkEscape(t *testing.T) {
	svc := newStateOnlyService(t)
	manifest := "sha256:" + strings.Repeat("e", 64)

	outside := filepath.Join(t.TempDir(), "outside")
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatalf("mkdir outside: %v", err)
	}
	link := filepath.Join(svc.cfg.ModelRoot, "linked")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}
	escaped := filepath.Join(link, "model")
	if err := os.MkdirAll(escaped, 0o755); err != nil {
		t.Fatalf("mkdir escaped: %v", err)
	}
	if err := os.WriteFile(filepath.Join(escaped, "READY"), []byte("ok\n"), 0o444); err != nil {
		t.Fatalf("write ready: %v", err)
	}

	rec := &storepkg.ModelRecord{
		Key:            modelKey("demo", manifest),
		ModelID:        "demo",
		ManifestDigest: manifest,
		Status:         StateReady,
		Path:           escaped,
		Bytes:          1024,
		CreatedAt:      time.Now().UTC(),
		UpdatedAt:      time.Now().UTC(),
		LastAccessedAt: time.Now().UTC(),
	}
	if err := svc.store.Put(rec); err != nil {
		t.Fatalf("put record: %v", err)
	}

	_, err := svc.GC("lru_no_lease", math.MaxInt64/4, false)
	if err == nil {
		t.Fatalf("expected gc failure for symlink-escaped path")
	}
	appErr := AsAppError(err)
	if appErr.Reason != ReasonStateDBCorrupt {
		t.Fatalf("expected reason %s, got %s", ReasonStateDBCorrupt, appErr.Reason)
	}
}
