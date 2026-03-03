package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
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
	mux.HandleFunc("/v1/gpu/load", h.handleGPULoad)
	mux.HandleFunc("/v1/gpu/unload", h.handleGPUUnload)
	mux.HandleFunc("/v1/gpu/status", h.handleGPUStatus)
	mux.HandleFunc("/v1/gpu/export", h.handleGPUExport)

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

func (h *handler) handleGPULoad(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w)
		return
	}
	var wireReq struct {
		ModelID     string `json:"model_id"`
		Digest      string `json:"digest"`
		Path        string `json:"path"`
		LeaseHolder string `json:"lease_holder"`
		Device      int    `json:"device"`
		ChunkBytes  int64  `json:"chunk_bytes"`
		MaxShards   int    `json:"max_shards"`
		Strict      *bool  `json:"strict"`
		Mode        string `json:"mode"`
	}
	if err := decodeJSONBody(r, &wireReq); err != nil {
		writeAppError(w, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid gpu load request body", err))
		return
	}
	req := app.GPULoadRequest{
		ModelID:     wireReq.ModelID,
		Digest:      wireReq.Digest,
		Path:        wireReq.Path,
		LeaseHolder: wireReq.LeaseHolder,
		Device:      wireReq.Device,
		ChunkBytes:  wireReq.ChunkBytes,
		MaxShards:   wireReq.MaxShards,
		Mode:        wireReq.Mode,
		Strict:      true,
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
	device := 0
	if q := strings.TrimSpace(r.URL.Query().Get("device")); q != "" {
		d, err := strconv.Atoi(q)
		if err != nil {
			writeAppError(w, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid device query parameter", err))
			return
		}
		device = d
	}
	res, err := h.svc.GPUListPersistent(r.Context(), device)
	if err != nil {
		writeAppError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status": "READY",
		"device": device,
		"files":  res,
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
