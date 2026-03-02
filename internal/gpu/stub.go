//go:build !linux || !cgo || !gds

package gpu

import (
	"context"

	"github.com/dims/oci2gdsd/internal/app"
)

type unsupportedGPULoader struct{}

func NewDefaultGPULoader() app.GPULoader {
	return &unsupportedGPULoader{}
}

func (l *unsupportedGPULoader) Name() string {
	return "unsupported"
}

func (l *unsupportedGPULoader) Probe(_ context.Context, device int) (app.GPUProbeResult, error) {
	return app.GPUProbeResult{
		Available:   false,
		Loader:      l.Name(),
		Device:      device,
		DeviceCount: 0,
		GDSDriver:   false,
		Message:     "GPU direct loader unavailable: build on Linux with CGO and -tags gds",
	}, nil
}

func (l *unsupportedGPULoader) LoadFile(_ context.Context, req app.GPULoadFileRequest) (app.GPULoadFileResult, error) {
	return app.GPULoadFileResult{}, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, "GPU direct loader unavailable in this build", nil)
}

func (l *unsupportedGPULoader) LoadPersistent(_ context.Context, req app.GPULoadFileRequest) (app.GPULoadFileResult, error) {
	return app.GPULoadFileResult{}, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, "GPU direct loader unavailable in this build", nil)
}

func (l *unsupportedGPULoader) UnloadPersistent(_ context.Context, req app.GPULoadFileRequest) (app.GPULoadFileResult, error) {
	return app.GPULoadFileResult{}, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, "GPU direct loader unavailable in this build", nil)
}

func (l *unsupportedGPULoader) ListPersistent(_ context.Context, _ int) ([]app.GPULoadFileResult, error) {
	return nil, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, "GPU direct loader unavailable in this build", nil)
}

func (l *unsupportedGPULoader) BeginSession(_ context.Context, _ int) (func(), error) {
	return func() {}, nil
}
