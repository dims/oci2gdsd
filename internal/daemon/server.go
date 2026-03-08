package daemon

import (
	"archive/tar"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/dims/oci2gdsd/internal/app"
)

type ServerConfig struct {
	UnixSocket      string
	SocketFileMode  os.FileMode
	RemoveStaleSock bool
	ShutdownTimeout time.Duration
}

func Serve(ctx context.Context, svc *app.Service, cfg ServerConfig) error {
	socketPath := strings.TrimSpace(cfg.UnixSocket)
	if socketPath == "" {
		return app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "--unix-socket is required", nil)
	}
	if cfg.SocketFileMode == 0 {
		cfg.SocketFileMode = 0o600
	}
	if cfg.ShutdownTimeout <= 0 {
		cfg.ShutdownTimeout = 5 * time.Second
	}

	if err := os.MkdirAll(filepath.Dir(socketPath), 0o755); err != nil {
		return app.NewAppError(app.ExitFilesystem, app.ReasonFilesystemError, "failed to create unix socket parent directory", err)
	}
	if cfg.RemoveStaleSock {
		if err := os.Remove(socketPath); err != nil && !errors.Is(err, os.ErrNotExist) {
			return app.NewAppError(app.ExitFilesystem, app.ReasonFilesystemError, "failed to remove stale unix socket path", err)
		}
	}

	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		return app.NewAppError(app.ExitFilesystem, app.ReasonFilesystemError, "failed to listen on unix socket", err)
	}
	defer func() {
		_ = ln.Close()
		_ = os.Remove(socketPath)
	}()

	if err := os.Chmod(socketPath, cfg.SocketFileMode); err != nil {
		return app.NewAppError(app.ExitFilesystem, app.ReasonFilesystemError, "failed to set unix socket permissions", err)
	}

	h := &handler{svc: svc}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", h.handleHealthz)
	mux.HandleFunc("/v2/model/ensure", h.handleModelEnsure)
	mux.HandleFunc("/v2/model/verify", h.handleModelVerify)
	mux.HandleFunc("/v2/runtime-bundles/", h.handleRuntimeBundleToken)
	mux.HandleFunc("/v2/gpu/allocate", h.handleGPUAllocate)
	mux.HandleFunc("/v2/gpu/load", h.handleGPULoad)
	mux.HandleFunc("/v2/gpu/unload", h.handleGPUUnload)
	mux.HandleFunc("/v2/gpu/status", h.handleGPUStatus)
	mux.HandleFunc("/v2/gpu/devices", h.handleGPUDevices)
	mux.HandleFunc("/v2/gpu/export", h.handleGPUExport)
	mux.HandleFunc("/v2/gpu/tensor-map", h.handleGPUTensorMap)
	mux.HandleFunc("/v2/gpu/attach", h.handleGPUAttach)
	mux.HandleFunc("/v2/gpu/detach", h.handleGPUDetach)
	mux.HandleFunc("/v2/gpu/heartbeat", h.handleGPUHeartbeat)

	srv := &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		errCh <- srv.Serve(ln)
	}()

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
		err = <-errCh
		if err == nil || errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return app.NewAppError(app.ExitStateCorrupt, app.ReasonStateDBCorrupt, "daemon server exited with error", err)
	case err = <-errCh:
		if err == nil || errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return app.NewAppError(app.ExitStateCorrupt, app.ReasonStateDBCorrupt, "daemon server exited with error", err)
	}
}

type handler struct {
	svc *app.Service
}

func (h *handler) handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeMethodNotAllowed(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status": "ok",
	})
}

func (h *handler) handleModelEnsure(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w)
		return
	}
	var wireReq struct {
		Ref              string `json:"ref"`
		ModelID          string `json:"model_id"`
		LeaseHolder      string `json:"lease_holder"`
		StrictIntegrity  *bool  `json:"strict_integrity"`
		StrictDirectPath *bool  `json:"strict_direct_path"`
		Wait             *bool  `json:"wait"`
		TimeoutSeconds   int    `json:"timeout_seconds"`
	}
	if err := decodeJSONBody(r, &wireReq); err != nil {
		writeAppError(w, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid model ensure request body", err))
		return
	}
	req := app.EnsureRequest{
		Ref:              wireReq.Ref,
		ModelID:          wireReq.ModelID,
		LeaseHolder:      wireReq.LeaseHolder,
		StrictIntegrity:  true,
		StrictDirectPath: false,
		Wait:             true,
	}
	if wireReq.StrictIntegrity != nil {
		req.StrictIntegrity = *wireReq.StrictIntegrity
	}
	if wireReq.StrictDirectPath != nil {
		req.StrictDirectPath = *wireReq.StrictDirectPath
	}
	if wireReq.Wait != nil {
		req.Wait = *wireReq.Wait
	}
	if wireReq.TimeoutSeconds > 0 {
		req.Timeout = time.Duration(wireReq.TimeoutSeconds) * time.Second
	}
	res, err := h.svc.Ensure(r.Context(), req)
	if err != nil {
		writeAppErrorWithResult(w, err, res)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (h *handler) handleModelVerify(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w)
		return
	}
	var req struct {
		Path   string `json:"path"`
		Model  string `json:"model_id"`
		Digest string `json:"digest"`
	}
	if err := decodeJSONBody(r, &req); err != nil {
		writeAppError(w, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid model verify request body", err))
		return
	}
	res, err := h.svc.Verify(req.Path, req.Model, req.Digest)
	if err != nil {
		writeAppErrorWithResult(w, err, res)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (h *handler) handleRuntimeBundleToken(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeMethodNotAllowed(w)
		return
	}
	token := strings.TrimPrefix(r.URL.Path, "/v2/runtime-bundles/")
	token = strings.TrimSpace(token)
	if token == "" || strings.Contains(token, "/") {
		writeAppError(w, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "runtime bundle token path segment is required", nil))
		return
	}
	unescapedToken, err := url.PathUnescape(token)
	if err != nil {
		writeAppError(w, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid runtime bundle token encoding", err))
		return
	}
	res, err := h.svc.RuntimeBundleByToken(r.Context(), unescapedToken)
	if err != nil {
		writeAppErrorWithResult(w, err, res)
		return
	}

	w.Header().Set("Content-Type", "application/x-tar")
	w.Header().Set("X-Oci2gdsd-Model-Id", res.ModelID)
	w.Header().Set("X-Oci2gdsd-Manifest-Digest", res.ManifestDigest)
	if strings.TrimSpace(res.AllocationID) != "" {
		w.Header().Set("X-Oci2gdsd-Allocation-Id", res.AllocationID)
	}
	w.WriteHeader(http.StatusOK)
	tw := tar.NewWriter(w)
	for _, f := range res.Files {
		src, openErr := os.Open(f.SourcePath)
		if openErr != nil {
			_ = tw.Close()
			_, _ = fmt.Fprintf(os.Stderr, "daemon open runtime bundle source failed: %v\n", openErr)
			return
		}
		hdr := &tar.Header{
			Name:    f.ArchivePath,
			Mode:    int64(f.Mode.Perm()),
			Size:    f.Size,
			ModTime: time.Now().UTC(),
		}
		if err := tw.WriteHeader(hdr); err != nil {
			_ = src.Close()
			_ = tw.Close()
			_, _ = fmt.Fprintf(os.Stderr, "daemon write runtime bundle header failed: %v\n", err)
			return
		}
		if _, err := io.Copy(tw, src); err != nil {
			_ = src.Close()
			_ = tw.Close()
			_, _ = fmt.Fprintf(os.Stderr, "daemon stream runtime bundle payload failed: %v\n", err)
			return
		}
		_ = src.Close()
	}

	manifestPayload, err := json.Marshal(map[string]any{
		"allocation_id":   res.AllocationID,
		"model_id":        res.ModelID,
		"manifest_digest": res.ManifestDigest,
		"file_count":      res.FileCount,
		"total_bytes":     res.TotalBytes,
	})
	if err == nil {
		hdr := &tar.Header{
			Name:    "_oci2gds_runtime_bundle.json",
			Mode:    int64(0o444),
			Size:    int64(len(manifestPayload)),
			ModTime: time.Now().UTC(),
		}
		if writeErr := tw.WriteHeader(hdr); writeErr == nil {
			_, _ = tw.Write(manifestPayload)
		}
	}
	if err := tw.Close(); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "daemon close runtime bundle writer failed: %v\n", err)
	}
}

func (h *handler) handleGPUAllocate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w)
		return
	}
	var wireReq struct {
		Ref                         string `json:"ref"`
		ModelID                     string `json:"model_id"`
		Digest                      string `json:"digest"`
		LeaseHolder                 string `json:"lease_holder"`
		DeviceUUID                  string `json:"device_uuid"`
		ChunkBytes                  int64  `json:"chunk_bytes"`
		MaxShards                   int    `json:"max_shards"`
		Strict                      *bool  `json:"strict"`
		RuntimeBundleIncludeWeights *bool  `json:"runtime_bundle_include_weights"`
	}
	if err := decodeJSONBody(r, &wireReq); err != nil {
		writeAppError(w, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid gpu allocate request body", err))
		return
	}
	req := app.GPUAllocateRequest{
		Ref:                         wireReq.Ref,
		ModelID:                     wireReq.ModelID,
		Digest:                      wireReq.Digest,
		LeaseHolder:                 wireReq.LeaseHolder,
		DeviceUUID:                  wireReq.DeviceUUID,
		ChunkBytes:                  wireReq.ChunkBytes,
		MaxShards:                   wireReq.MaxShards,
		Strict:                      true,
		RuntimeBundleIncludeWeights: false,
	}
	if wireReq.Strict != nil {
		req.Strict = *wireReq.Strict
	}
	if wireReq.RuntimeBundleIncludeWeights != nil {
		req.RuntimeBundleIncludeWeights = *wireReq.RuntimeBundleIncludeWeights
	}
	res, err := h.svc.GPUAllocate(r.Context(), req)
	if err != nil {
		writeAppErrorWithResult(w, err, res)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (h *handler) handleGPULoad(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w)
		return
	}
	var wireReq struct {
		AllocationID string `json:"allocation_id"`
		ChunkBytes   int64  `json:"chunk_bytes"`
		MaxShards    int    `json:"max_shards"`
		Strict       *bool  `json:"strict"`
		Mode         string `json:"mode"`
	}
	if err := decodeJSONBody(r, &wireReq); err != nil {
		writeAppError(w, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid gpu load request body", err))
		return
	}
	req := app.GPULoadRequest{
		AllocationID: wireReq.AllocationID,
		ChunkBytes:   wireReq.ChunkBytes,
		MaxShards:    wireReq.MaxShards,
		Mode:         wireReq.Mode,
		Strict:       true,
	}
	if wireReq.Strict != nil {
		req.Strict = *wireReq.Strict
	}
	if strings.TrimSpace(req.Mode) == "" {
		req.Mode = "persistent"
	}
	res, err := h.svc.GPULoad(r.Context(), req)
	if err != nil {
		writeAppErrorWithResult(w, err, res)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (h *handler) handleGPUUnload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w)
		return
	}
	var req app.GPUUnloadRequest
	if err := decodeJSONBody(r, &req); err != nil {
		writeAppError(w, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid gpu unload request body", err))
		return
	}
	res, err := h.svc.GPUUnload(r.Context(), req)
	if err != nil {
		writeAppErrorWithResult(w, err, res)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (h *handler) handleGPUStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeMethodNotAllowed(w)
		return
	}
	deviceUUID := strings.TrimSpace(r.URL.Query().Get("device_uuid"))
	if deviceUUID == "" {
		writeAppError(w, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "device_uuid query parameter is required", nil))
		return
	}
	res, err := h.svc.GPUListPersistent(r.Context(), deviceUUID)
	if err != nil {
		writeAppError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status":      "READY",
		"device_uuid": deviceUUID,
		"files":       res,
	})
}

func (h *handler) handleGPUDevices(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeMethodNotAllowed(w)
		return
	}
	devices, err := h.svc.GPUDevices(r.Context())
	if err != nil {
		writeAppError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status":  "READY",
		"devices": devices,
	})
}

func (h *handler) handleGPUExport(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w)
		return
	}
	var req app.GPUExportRequest
	if err := decodeJSONBody(r, &req); err != nil {
		writeAppError(w, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid gpu export request body", err))
		return
	}
	res, err := h.svc.GPUExport(r.Context(), req)
	if err != nil {
		writeAppErrorWithResult(w, err, res)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (h *handler) handleGPUTensorMap(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w)
		return
	}
	var wireReq struct {
		AllocationID   string `json:"allocation_id"`
		MaxShards      int    `json:"max_shards"`
		MaxTensors     int    `json:"max_tensors"`
		IncludeHandles *bool  `json:"include_handles"`
	}
	if err := decodeJSONBody(r, &wireReq); err != nil {
		writeAppError(w, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid gpu tensor-map request body", err))
		return
	}
	includeHandles := true
	if wireReq.IncludeHandles != nil {
		includeHandles = *wireReq.IncludeHandles
	}
	req := app.GPUTensorMapRequest{
		AllocationID:   wireReq.AllocationID,
		MaxShards:      wireReq.MaxShards,
		MaxTensors:     wireReq.MaxTensors,
		IncludeHandles: includeHandles,
	}
	res, err := h.svc.GPUTensorMap(r.Context(), req)
	if err != nil {
		writeAppErrorWithResult(w, err, res)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (h *handler) handleGPUAttach(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w)
		return
	}
	var req app.GPUAttachRequest
	if err := decodeJSONBody(r, &req); err != nil {
		writeAppError(w, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid gpu attach request body", err))
		return
	}
	res, err := h.svc.GPUAttach(r.Context(), req)
	if err != nil {
		writeAppErrorWithResult(w, err, res)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (h *handler) handleGPUDetach(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w)
		return
	}
	var req app.GPUDetachRequest
	if err := decodeJSONBody(r, &req); err != nil {
		writeAppError(w, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid gpu detach request body", err))
		return
	}
	res, err := h.svc.GPUDetach(r.Context(), req)
	if err != nil {
		writeAppErrorWithResult(w, err, res)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (h *handler) handleGPUHeartbeat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w)
		return
	}
	var req app.GPUHeartbeatRequest
	if err := decodeJSONBody(r, &req); err != nil {
		writeAppError(w, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid gpu heartbeat request body", err))
		return
	}
	res, err := h.svc.GPUHeartbeat(r.Context(), req)
	if err != nil {
		writeAppErrorWithResult(w, err, res)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func decodeJSONBody(r *http.Request, out any) error {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(out); err != nil {
		return err
	}
	return nil
}

func writeMethodNotAllowed(w http.ResponseWriter) {
	writeJSON(w, http.StatusMethodNotAllowed, map[string]any{
		"status": "FAILED",
		"error":  "method not allowed",
	})
}

func writeAppError(w http.ResponseWriter, err error) {
	writeAppErrorWithResult(w, err, nil)
}

func writeAppErrorWithResult(w http.ResponseWriter, err error, result any) {
	appErr := app.AsAppError(err)
	if appErr == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{
			"status":      "FAILED",
			"reason_code": app.ReasonStateDBCorrupt,
			"message":     err.Error(),
			"exit_code":   app.ExitStateCorrupt,
		})
		return
	}
	code := httpStatusFromExitCode(appErr.ExitCode)
	if result == nil {
		writeJSON(w, code, map[string]any{
			"status":      "FAILED",
			"reason_code": appErr.Reason,
			"message":     appErr.Error(),
			"exit_code":   appErr.ExitCode,
		})
		return
	}
	writeJSON(w, code, map[string]any{
		"status":      "FAILED",
		"reason_code": appErr.Reason,
		"message":     appErr.Error(),
		"exit_code":   appErr.ExitCode,
		"result":      result,
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		_, _ = fmt.Fprintf(os.Stderr, "daemon write json failed: %v\n", err)
	}
}

func httpStatusFromExitCode(exitCode int) int {
	switch exitCode {
	case app.ExitValidation:
		return http.StatusBadRequest
	case app.ExitAuth:
		return http.StatusUnauthorized
	case app.ExitRegistry:
		return http.StatusBadGateway
	case app.ExitIntegrity:
		return http.StatusUnprocessableEntity
	case app.ExitFilesystem:
		return http.StatusInternalServerError
	case app.ExitPolicy:
		return http.StatusConflict
	case app.ExitStateCorrupt:
		return http.StatusInternalServerError
	default:
		return http.StatusInternalServerError
	}
}
