//go:build !linux || !cgo || !gds

package app

import (
	"context"
)

type unsupportedGPULoader struct{}

func newDefaultGPULoader() GPULoader {
	return &unsupportedGPULoader{}
}

func (l *unsupportedGPULoader) Name() string {
	return "unsupported"
}

func (l *unsupportedGPULoader) Probe(_ context.Context, device int) (GPUProbeResult, error) {
	return GPUProbeResult{
		Available:   false,
		Loader:      l.Name(),
		Device:      device,
		DeviceCount: 0,
		GDSDriver:   false,
		Message:     "GPU direct loader unavailable: build on Linux with CGO and -tags gds",
	}, nil
}

func (l *unsupportedGPULoader) LoadFile(_ context.Context, req GPULoadFileRequest) (GPULoadFileResult, error) {
	return GPULoadFileResult{}, NewAppError(ExitPolicy, ReasonDirectPathIneligible, "GPU direct loader unavailable in this build", nil)
}
