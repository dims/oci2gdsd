package app

import (
	"bytes"
	"context"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	configpkg "github.com/dims/oci2gdsd/internal/config"
	storepkg "github.com/dims/oci2gdsd/internal/store"
	digest "github.com/opencontainers/go-digest"
)

type ensureBlob struct {
	name    string
	data    []byte
	ordinal int
	kind    string
}

type fakeEnsureFetcher struct {
	mu      sync.Mutex
	calls   int
	fetchFn func(ref string) (*FetchedModel, error)
}

func (f *fakeEnsureFetcher) Fetch(_ context.Context, ref string) (*FetchedModel, error) {
	f.mu.Lock()
	f.calls++
	f.mu.Unlock()
	return f.fetchFn(ref)
}

func (f *fakeEnsureFetcher) CallCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

func buildFetchedModelForEnsure(ref, modelID, manifestDigest string, blobs []ensureBlob) *FetchedModel {
	profileShards := make([]ModelShard, 0, len(blobs))
	layers := make([]ManifestLayer, 0, len(blobs))
	remoteBlobs := make([]RemoteBlob, 0, len(blobs))
	for _, b := range blobs {
		data := append([]byte(nil), b.data...)
		d := digest.FromBytes(data).String()
		sz := int64(len(data))
		profileShards = append(profileShards, ModelShard{
			Name:    b.name,
			Digest:  d,
			Size:    sz,
			Ordinal: b.ordinal,
			Kind:    b.kind,
		})
		layers = append(layers, ManifestLayer{
			MediaType: MediaTypeModelShard,
			Digest:    d,
			Size:      sz,
		})
		remoteBlobs = append(remoteBlobs, RemoteBlob{
			Name:      b.name,
			Digest:    d,
			Size:      sz,
			MediaType: MediaTypeModelShard,
			Open: func(_ context.Context) (io.ReadCloser, error) {
				return io.NopCloser(bytes.NewReader(data)), nil
			},
		})
	}
	return &FetchedModel{
		Reference:      ref,
		Repository:     "registry.example.com/models/demo",
		ManifestDigest: manifestDigest,
		ArtifactType:   MediaTypeModelArtifact,
		Profile: &ModelProfile{
			SchemaVersion: 1,
			ModelID:       modelID,
			ModelRevision: "r1",
			Framework:     "pytorch",
			Format:        "safetensors",
			Shards:        profileShards,
			Integrity: ModelIntegrity{
				ManifestDigest: manifestDigest,
			},
		},
		Layers: layers,
		Blobs:  remoteBlobs,
	}
}

func newEnsureTestService(t *testing.T, fetcher ModelFetcher) *Service {
	t.Helper()
	root := t.TempDir()
	cfg := configpkg.DefaultConfig()
	cfg.Root = root
	cfg.ModelRoot = filepath.Join(root, "models")
	cfg.TmpRoot = filepath.Join(root, "tmp")
	cfg.LocksRoot = filepath.Join(root, "locks")
	cfg.JournalDir = filepath.Join(root, "journal")
	cfg.StateDB = filepath.Join(root, "state.db")
	cfg.Retention.MinFreeBytes = 0
	if err := cfg.EnsureDirectories(); err != nil {
		t.Fatalf("ensure directories: %v", err)
	}
	store := storepkg.NewStateStore(cfg.StateDB)
	if err := store.Init(); err != nil {
		t.Fatalf("state init: %v", err)
	}
	return &Service{
		cfg:       cfg,
		store:     store,
		locks:     NewLockManager(cfg.LocksRoot),
		fetcher:   fetcher,
		gpuLoader: newFakePersistentLoader(),
	}
}

func TestEnsureHappyPathAndIdempotentReuse(t *testing.T) {
	manifest := "sha256:" + strings.Repeat("1", 64)
	ref := "registry.example.com/models/demo@" + manifest
	blobData := bytes.Repeat([]byte{0xAB}, 4096)
	fetcher := &fakeEnsureFetcher{
		fetchFn: func(_ string) (*FetchedModel, error) {
			return buildFetchedModelForEnsure(ref, "demo", manifest, []ensureBlob{
				{name: "weights-00001.safetensors", data: blobData, ordinal: 1, kind: "weight"},
				{name: "config.json", data: []byte("{}\n"), ordinal: 2, kind: "runtime"},
			}), nil
		},
	}
	svc := newEnsureTestService(t, fetcher)

	first, err := svc.Ensure(context.Background(), EnsureRequest{
		Ref:         ref,
		ModelID:     "demo",
		LeaseHolder: "holder-a",
		Wait:        true,
	})
	if err != nil {
		t.Fatalf("first ensure failed: %v", err)
	}
	if first.Status != "READY" {
		t.Fatalf("unexpected first status: %+v", first)
	}
	if first.BytesDownloaded <= 0 {
		t.Fatalf("expected downloaded bytes, got %+v", first)
	}
	if fetcher.CallCount() != 1 {
		t.Fatalf("expected one fetch call, got %d", fetcher.CallCount())
	}

	second, err := svc.Ensure(context.Background(), EnsureRequest{
		Ref:         ref,
		ModelID:     "demo",
		LeaseHolder: "holder-b",
		Wait:        true,
	})
	if err != nil {
		t.Fatalf("second ensure failed: %v", err)
	}
	if second.Status != "READY" {
		t.Fatalf("unexpected second status: %+v", second)
	}
	if second.BytesDownloaded != 0 || second.BytesReused == 0 {
		t.Fatalf("expected reuse on second ensure, got %+v", second)
	}
	if fetcher.CallCount() != 1 {
		t.Fatalf("expected cached reuse with one fetch call, got %d", fetcher.CallCount())
	}

	journalPath := NewJournal(svc.cfg.JournalDir, "demo", manifest).Path()
	if fileExists(journalPath) {
		t.Fatalf("expected journal cleanup after committed ensure, found %s", journalPath)
	}
}

func TestEnsureFailsBlobDigestMismatch(t *testing.T) {
	manifest := "sha256:" + strings.Repeat("2", 64)
	ref := "registry.example.com/models/demo@" + manifest
	blobData := bytes.Repeat([]byte{0xCC}, 1024)
	fetcher := &fakeEnsureFetcher{
		fetchFn: func(_ string) (*FetchedModel, error) {
			m := buildFetchedModelForEnsure(ref, "demo", manifest, []ensureBlob{
				{name: "weights-00001.safetensors", data: blobData, ordinal: 1, kind: "weight"},
			})
			m.Blobs[0].Digest = digest.FromBytes([]byte("wrong")).String()
			return m, nil
		},
	}
	svc := newEnsureTestService(t, fetcher)

	_, err := svc.Ensure(context.Background(), EnsureRequest{
		Ref:         ref,
		ModelID:     "demo",
		LeaseHolder: "holder-a",
		Wait:        true,
	})
	if err == nil {
		t.Fatalf("expected ensure failure")
	}
	appErr := AsAppError(err)
	if appErr.Reason != ReasonBlobDigestMismatch {
		t.Fatalf("expected reason %s, got %s", ReasonBlobDigestMismatch, appErr.Reason)
	}
}

func TestEnsureFailsDiskSpaceInsufficient(t *testing.T) {
	manifest := "sha256:" + strings.Repeat("3", 64)
	ref := "registry.example.com/models/demo@" + manifest
	fetcher := &fakeEnsureFetcher{
		fetchFn: func(_ string) (*FetchedModel, error) {
			return buildFetchedModelForEnsure(ref, "demo", manifest, []ensureBlob{
				{name: "weights-00001.safetensors", data: bytes.Repeat([]byte{0x11}, 4096), ordinal: 1, kind: "weight"},
			}), nil
		},
	}
	svc := newEnsureTestService(t, fetcher)
	svc.cfg.Retention.MinFreeBytes = math.MaxInt64 / 2

	_, err := svc.Ensure(context.Background(), EnsureRequest{
		Ref:         ref,
		ModelID:     "demo",
		LeaseHolder: "holder-a",
		Wait:        true,
	})
	if err == nil {
		t.Fatalf("expected ensure failure")
	}
	appErr := AsAppError(err)
	if appErr.Reason != ReasonDiskSpaceInsufficient {
		t.Fatalf("expected reason %s, got %s", ReasonDiskSpaceInsufficient, appErr.Reason)
	}
}

func TestEnsureConcurrentWaitersReuseSingleDownload(t *testing.T) {
	manifest := "sha256:" + strings.Repeat("4", 64)
	ref := "registry.example.com/models/demo@" + manifest
	blobData := bytes.Repeat([]byte{0x42}, 4096)
	fetcher := &fakeEnsureFetcher{
		fetchFn: func(_ string) (*FetchedModel, error) {
			time.Sleep(75 * time.Millisecond)
			return buildFetchedModelForEnsure(ref, "demo", manifest, []ensureBlob{
				{name: "weights-00001.safetensors", data: blobData, ordinal: 1, kind: "weight"},
			}), nil
		},
	}
	svc := newEnsureTestService(t, fetcher)

	var wg sync.WaitGroup
	errs := make(chan error, 2)
	results := make(chan EnsureResult, 2)
	run := func(holder string) {
		defer wg.Done()
		res, err := svc.Ensure(context.Background(), EnsureRequest{
			Ref:         ref,
			ModelID:     "demo",
			LeaseHolder: holder,
			Wait:        true,
		})
		if err != nil {
			errs <- err
			return
		}
		results <- res
	}
	wg.Add(2)
	go run("holder-a")
	go run("holder-b")
	wg.Wait()
	close(errs)
	close(results)

	for err := range errs {
		t.Fatalf("unexpected ensure error: %v", err)
	}
	if len(results) != 2 {
		t.Fatalf("expected two ensure results, got %d", len(results))
	}
	if fetcher.CallCount() != 1 {
		t.Fatalf("expected one registry fetch across concurrent waiters, got %d", fetcher.CallCount())
	}
	rec, ok, err := svc.store.Get(modelKey("demo", manifest))
	if err != nil {
		t.Fatalf("store get failed: %v", err)
	}
	if !ok {
		t.Fatalf("expected model record")
	}
	if len(rec.Leases) != 2 {
		t.Fatalf("expected two lease holders after concurrent ensure, got %+v", rec.Leases)
	}
}

func TestProfileFromFileParsesYAML(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "model-config.yaml")
	body := `
schemaVersion: 1
modelId: demo
modelRevision: r1
framework: pytorch
format: safetensors
shards:
  - name: weights-00001.safetensors
    digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    size: 4096
    ordinal: 1
integrity:
  manifestDigest: sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write yaml: %v", err)
	}

	profile, err := (&Service{}).ProfileFromFile(path)
	if err != nil {
		t.Fatalf("expected YAML parse success, got %v", err)
	}
	if profile.ModelID != "demo" {
		t.Fatalf("unexpected model ID: %+v", profile)
	}
}
