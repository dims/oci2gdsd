package daemon

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	apppkg "github.com/dims/oci2gdsd/internal/app"
	configpkg "github.com/dims/oci2gdsd/internal/config"
	digest "github.com/opencontainers/go-digest"
)

const daemonTestDeviceUUID = "GPU-11111111-2222-3333-4444-555555555555"

type daemonTestFetcher struct {
	model *apppkg.FetchedModel
	err   error
}

func (f *daemonTestFetcher) Fetch(_ context.Context, _ string) (*apppkg.FetchedModel, error) {
	if f.err != nil {
		return nil, f.err
	}
	return f.model, nil
}

type daemonTestLoader struct {
	mu    sync.Mutex
	files map[string]int
}

func newDaemonTestLoader() *daemonTestLoader {
	return &daemonTestLoader{files: map[string]int{}}
}

func (l *daemonTestLoader) Name() string {
	return "daemon-test-gpu"
}

func (l *daemonTestLoader) ListDevices(_ context.Context) ([]apppkg.GPUDeviceInfo, error) {
	return []apppkg.GPUDeviceInfo{{UUID: daemonTestDeviceUUID, Index: 0, Name: "daemon-test-gpu-0"}}, nil
}

func (l *daemonTestLoader) ResolveDevice(_ context.Context, deviceUUID string) (apppkg.GPUDeviceInfo, error) {
	if strings.TrimSpace(deviceUUID) != daemonTestDeviceUUID {
		return apppkg.GPUDeviceInfo{}, apppkg.NewAppError(apppkg.ExitValidation, apppkg.ReasonValidationFailed, "unknown test device", nil)
	}
	return apppkg.GPUDeviceInfo{UUID: daemonTestDeviceUUID, Index: 0, Name: "daemon-test-gpu-0"}, nil
}

func (l *daemonTestLoader) Probe(_ context.Context, device int) (apppkg.GPUProbeResult, error) {
	return apppkg.GPUProbeResult{
		Available:   true,
		Loader:      l.Name(),
		DeviceUUID:  daemonTestDeviceUUID,
		DeviceIndex: device,
		DeviceCount: 1,
		GDSDriver:   true,
	}, nil
}

func (l *daemonTestLoader) LoadFile(_ context.Context, req apppkg.GPULoadFileRequest) (apppkg.GPULoadFileResult, error) {
	st, err := ioStat(req.Path)
	if err != nil {
		return apppkg.GPULoadFileResult{}, err
	}
	return apppkg.GPULoadFileResult{Path: req.Path, Bytes: st, Direct: true, Loaded: true, RefCount: 1}, nil
}

func (l *daemonTestLoader) LoadPersistent(_ context.Context, req apppkg.GPULoadFileRequest) (apppkg.GPULoadFileResult, error) {
	st, err := ioStat(req.Path)
	if err != nil {
		return apppkg.GPULoadFileResult{}, err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.files[req.Path]++
	return apppkg.GPULoadFileResult{Path: req.Path, Bytes: st, Direct: true, Loaded: true, RefCount: l.files[req.Path]}, nil
}

func (l *daemonTestLoader) ExportPersistent(_ context.Context, req apppkg.GPULoadFileRequest) (apppkg.GPULoadFileResult, error) {
	st, err := ioStat(req.Path)
	if err != nil {
		return apppkg.GPULoadFileResult{}, err
	}
	return apppkg.GPULoadFileResult{
		Path:      req.Path,
		Bytes:     st,
		Direct:    true,
		Loaded:    true,
		RefCount:  1,
		IPCHandle: "ZmFrZS1pcGMtaGFuZGxl",
	}, nil
}

func (l *daemonTestLoader) AttachPersistent(_ context.Context, req apppkg.GPULoadFileRequest) (apppkg.GPULoadFileResult, error) {
	st, err := ioStat(req.Path)
	if err != nil {
		return apppkg.GPULoadFileResult{}, err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.files[req.Path]++
	return apppkg.GPULoadFileResult{Path: req.Path, Bytes: st, Direct: true, Loaded: true, RefCount: l.files[req.Path]}, nil
}

func (l *daemonTestLoader) DetachPersistent(_ context.Context, req apppkg.GPULoadFileRequest) (apppkg.GPULoadFileResult, error) {
	st, err := ioStat(req.Path)
	if err != nil {
		return apppkg.GPULoadFileResult{}, err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if refs := l.files[req.Path]; refs > 0 {
		l.files[req.Path] = refs - 1
	}
	return apppkg.GPULoadFileResult{Path: req.Path, Bytes: st, Direct: true, Loaded: true, RefCount: l.files[req.Path]}, nil
}

func (l *daemonTestLoader) UnloadPersistent(_ context.Context, req apppkg.GPULoadFileRequest) (apppkg.GPULoadFileResult, error) {
	st, err := ioStat(req.Path)
	if err != nil {
		return apppkg.GPULoadFileResult{}, err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if refs := l.files[req.Path]; refs > 1 {
		l.files[req.Path] = refs - 1
		return apppkg.GPULoadFileResult{Path: req.Path, Bytes: 0, Direct: true, Loaded: false, RefCount: l.files[req.Path]}, nil
	}
	delete(l.files, req.Path)
	return apppkg.GPULoadFileResult{Path: req.Path, Bytes: st, Direct: true, Loaded: false, RefCount: 0}, nil
}

func (l *daemonTestLoader) ListPersistent(_ context.Context, _ int) ([]apppkg.GPULoadFileResult, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([]apppkg.GPULoadFileResult, 0, len(l.files))
	for path, refs := range l.files {
		st, err := ioStat(path)
		if err != nil {
			continue
		}
		out = append(out, apppkg.GPULoadFileResult{
			Path:     path,
			Bytes:    st,
			Direct:   true,
			Loaded:   true,
			RefCount: refs,
		})
	}
	return out, nil
}

func ioStat(path string) (int64, error) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, err
	}
	return info.Size(), nil
}

func newDaemonIntegrationService(t *testing.T) (*apppkg.Service, string, string) {
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
	manifest := "sha256:" + strings.Repeat("a", 64)
	ref := "registry.example.com/models/demo@" + manifest
	svc, err := apppkg.NewService(cfg, &daemonTestFetcher{
		model: buildDaemonFetchedModel(ref, "demo", manifest),
	}, newDaemonTestLoader())
	if err != nil {
		t.Fatalf("new service: %v", err)
	}
	return svc, ref, manifest
}

func buildDaemonFetchedModel(ref, modelID, manifest string) *apppkg.FetchedModel {
	type blobSpec struct {
		name    string
		kind    string
		ordinal int
		data    []byte
	}
	blobs := []blobSpec{
		{
			name:    "weights-00001.safetensors",
			kind:    "weight",
			ordinal: 1,
			data:    []byte("fake-weight-shard"),
		},
		{
			name:    "config.json",
			kind:    "runtime",
			ordinal: 2,
			data:    []byte("{}\n"),
		},
	}
	shards := make([]apppkg.ModelShard, 0, len(blobs))
	layers := make([]apppkg.ManifestLayer, 0, len(blobs))
	remote := make([]apppkg.RemoteBlob, 0, len(blobs))
	for _, spec := range blobs {
		data := append([]byte(nil), spec.data...)
		d := digest.FromBytes(data).String()
		shards = append(shards, apppkg.ModelShard{
			Name:    spec.name,
			Digest:  d,
			Size:    int64(len(data)),
			Ordinal: spec.ordinal,
			Kind:    spec.kind,
		})
		layers = append(layers, apppkg.ManifestLayer{
			MediaType: apppkg.MediaTypeModelShard,
			Digest:    d,
			Size:      int64(len(data)),
		})
		openData := append([]byte(nil), data...)
		remote = append(remote, apppkg.RemoteBlob{
			Name:      spec.name,
			Digest:    d,
			Size:      int64(len(data)),
			MediaType: apppkg.MediaTypeModelShard,
			Open: func(_ context.Context) (io.ReadCloser, error) {
				return io.NopCloser(bytes.NewReader(openData)), nil
			},
		})
	}

	return &apppkg.FetchedModel{
		Reference:      ref,
		Repository:     "registry.example.com/models/demo",
		ManifestDigest: manifest,
		ArtifactType:   apppkg.MediaTypeModelArtifact,
		Profile: &apppkg.ModelProfile{
			SchemaVersion: 1,
			ModelID:       modelID,
			ModelRevision: "r1",
			Framework:     "pytorch",
			Format:        "safetensors",
			Shards:        shards,
			Integrity: apppkg.ModelIntegrity{
				ManifestDigest: manifest,
			},
		},
		Layers: layers,
		Blobs:  remote,
	}
}

func TestV2PayloadValidationRejectsUnknownFields(t *testing.T) {
	cases := []struct {
		name string
		body string
		call func(h *handler, w http.ResponseWriter, r *http.Request)
	}{
		{
			name: "gpu_allocate",
			body: `{"ref":"registry.example.com/models/demo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","model_id":"demo","lease_holder":"holder","device_uuid":"` + daemonTestDeviceUUID + `","extra":"x"}`,
			call: (*handler).handleGPUAllocate,
		},
		{
			name: "gpu_load",
			body: `{"allocation_id":"alloc-test","mode":"persistent","extra":"x"}`,
			call: (*handler).handleGPULoad,
		},
		{
			name: "gpu_unload",
			body: `{"allocation_id":"alloc-test","extra":"x"}`,
			call: (*handler).handleGPUUnload,
		},
		{
			name: "gpu_tensor_map",
			body: `{"allocation_id":"alloc-test","include_handles":true,"extra":"x"}`,
			call: (*handler).handleGPUTensorMap,
		},
		{
			name: "gpu_attach",
			body: `{"allocation_id":"alloc-test","client_id":"client","extra":"x"}`,
			call: (*handler).handleGPUAttach,
		},
		{
			name: "gpu_detach",
			body: `{"allocation_id":"alloc-test","client_id":"client","extra":"x"}`,
			call: (*handler).handleGPUDetach,
		},
		{
			name: "gpu_heartbeat",
			body: `{"allocation_id":"alloc-test","client_id":"client","ttl_seconds":30,"extra":"x"}`,
			call: (*handler).handleGPUHeartbeat,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := &handler{}
			req := httptest.NewRequest(http.MethodPost, "/v2/test", strings.NewReader(tc.body))
			req.Header.Set("Content-Type", "application/json")
			rr := httptest.NewRecorder()
			tc.call(h, rr, req)
			if rr.Code != http.StatusBadRequest {
				t.Fatalf("expected status 400, got %d body=%s", rr.Code, rr.Body.String())
			}
			var payload map[string]any
			if err := json.Unmarshal(rr.Body.Bytes(), &payload); err != nil {
				t.Fatalf("decode response: %v", err)
			}
			if got := payload["reason_code"]; got != string(apppkg.ReasonValidationFailed) {
				t.Fatalf("expected reason_code=%s, got %v", apppkg.ReasonValidationFailed, got)
			}
		})
	}
}

func TestRuntimeBundleTokenStreamsTarball(t *testing.T) {
	svc, ref, manifest := newDaemonIntegrationService(t)
	_, err := svc.Ensure(context.Background(), apppkg.EnsureRequest{
		Ref:         ref,
		ModelID:     "demo",
		LeaseHolder: "daemon-stream-test",
		Wait:        true,
	})
	if err != nil {
		t.Fatalf("ensure: %v", err)
	}

	alloc, err := svc.GPUAllocate(context.Background(), apppkg.GPUAllocateRequest{
		ModelID:                     "demo",
		Digest:                      manifest,
		LeaseHolder:                 "daemon-stream-test",
		DeviceUUID:                  daemonTestDeviceUUID,
		Strict:                      true,
		RuntimeBundleIncludeWeights: true,
	})
	if err != nil {
		t.Fatalf("gpu allocate: %v", err)
	}
	if strings.TrimSpace(alloc.RuntimeBundleToken) == "" {
		t.Fatalf("expected runtime bundle token from allocation")
	}

	h := &handler{svc: svc}
	req := httptest.NewRequest(http.MethodGet, "/v2/runtime-bundles/"+alloc.RuntimeBundleToken, nil)
	rr := httptest.NewRecorder()
	h.handleRuntimeBundleToken(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d body=%s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("Content-Type"); got != "application/x-tar" {
		t.Fatalf("expected content-type application/x-tar, got %q", got)
	}
	if got := rr.Header().Get("X-Oci2gdsd-Allocation-Id"); got != alloc.AllocationID {
		t.Fatalf("unexpected allocation header: %q", got)
	}

	tr := tar.NewReader(bytes.NewReader(rr.Body.Bytes()))
	files := map[string][]byte{}
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("tar read: %v", err)
		}
		payload, readErr := io.ReadAll(tr)
		if readErr != nil {
			t.Fatalf("tar read body: %v", readErr)
		}
		files[hdr.Name] = payload
	}

	required := []string{
		"metadata/model.json",
		"shards/config.json",
		"shards/weights-00001.safetensors",
		"_oci2gds_runtime_bundle.json",
	}
	for _, name := range required {
		if _, ok := files[name]; !ok {
			t.Fatalf("expected runtime bundle tar to include %s; files=%v", name, mapKeys(files))
		}
	}

	var manifestPayload map[string]any
	if err := json.Unmarshal(files["_oci2gds_runtime_bundle.json"], &manifestPayload); err != nil {
		t.Fatalf("decode runtime bundle manifest payload: %v", err)
	}
	if got := manifestPayload["allocation_id"]; got != alloc.AllocationID {
		t.Fatalf("unexpected allocation_id in manifest payload: %v", got)
	}
	if got := manifestPayload["manifest_digest"]; got != manifest {
		t.Fatalf("unexpected manifest_digest in manifest payload: %v", got)
	}
}

func TestGPUCacheMetricsEndpoint(t *testing.T) {
	svc, _, _ := newDaemonIntegrationService(t)
	h := &handler{svc: svc}
	req := httptest.NewRequest(http.MethodGet, "/v2/gpu/cache-metrics", nil)
	rr := httptest.NewRecorder()

	h.handleGPUCacheMetrics(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d body=%s", rr.Code, rr.Body.String())
	}
	var payload struct {
		Status  string              `json:"status"`
		Metrics apppkg.CacheMetrics `json:"metrics"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if payload.Status != "READY" {
		t.Fatalf("expected READY status, got %+v", payload)
	}
}

func mapKeys(in map[string][]byte) []string {
	out := make([]string, 0, len(in))
	for k := range in {
		out = append(out, k)
	}
	return out
}
