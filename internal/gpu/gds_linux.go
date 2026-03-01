//go:build linux && cgo && gds

package gpu

/*
#cgo LDFLAGS: -lcuda -lcufile
#include <cuda.h>
#include <cufile.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

static int gds_init() {
	CUresult cu = cuInit(0);
	if (cu != CUDA_SUCCESS) return 1000 + (int)cu;
	CUfileError_t st = cuFileDriverOpen();
	if (st.err != CU_FILE_SUCCESS) return 2000 + (int)st.err;
	return 0;
}

static int gds_shutdown() {
	CUfileError_t st = cuFileDriverClose();
	if (st.err != CU_FILE_SUCCESS) return 2000 + (int)st.err;
	return 0;
}

static int gds_device_count(int* count) {
	CUresult cu = cuDeviceGetCount(count);
	if (cu != CUDA_SUCCESS) return 1000 + (int)cu;
	return 0;
}

static int gds_read_file(const char* path, int device, long long chunk_bytes, int strict, long long* total_bytes, long long* elapsed_us) {
	CUresult cu;
	CUdevice dev;
	CUcontext ctx;
	struct stat st;
	int rc = 0;
	int fd = -1;
	CUfileHandle_t cfh;
	CUdeviceptr dptr = 0;
	int handle_registered = 0;
	int buf_registered = 0;
	size_t chunk = (size_t)chunk_bytes;
	off_t file_size = 0;
	off_t file_off = 0;
	struct timespec t0;
	struct timespec t1;

	memset(&cfh, 0, sizeof(cfh));

	if (chunk < 4096) chunk = 4096;

	cu = cuDeviceGet(&dev, device);
	if (cu != CUDA_SUCCESS) return 1000 + (int)cu;

	cu = cuCtxCreate(&ctx, 0, dev);
	if (cu != CUDA_SUCCESS) return 1000 + (int)cu;

	fd = open(path, O_RDONLY);
	if (fd < 0) {
		rc = 3001;
		goto cleanup;
	}

	if (fstat(fd, &st) != 0) {
		rc = 3002;
		goto cleanup;
	}
	file_size = st.st_size;

	CUfileDescr_t desc;
	memset(&desc, 0, sizeof(desc));
	desc.handle.fd = fd;
	desc.type = CU_FILE_HANDLE_TYPE_OPAQUE_FD;

	CUfileError_t ferr = cuFileHandleRegister(&cfh, &desc);
	if (ferr.err != CU_FILE_SUCCESS) {
		rc = 2000 + (int)ferr.err;
		goto cleanup;
	}
	handle_registered = 1;

	cu = cuMemAlloc(&dptr, chunk);
	if (cu != CUDA_SUCCESS) {
		rc = 1000 + (int)cu;
		goto cleanup;
	}

	ferr = cuFileBufRegister((void*)(uintptr_t)dptr, chunk, 0);
	if (ferr.err == CU_FILE_SUCCESS) {
		buf_registered = 1;
	} else if (strict) {
		rc = 2000 + (int)ferr.err;
		goto cleanup;
	}

	if (clock_gettime(CLOCK_MONOTONIC, &t0) != 0) {
		rc = 3003;
		goto cleanup;
	}

	while (file_off < file_size) {
		size_t to_read = chunk;
		if ((off_t)to_read > (file_size - file_off)) {
			to_read = (size_t)(file_size - file_off);
		}
		ssize_t n = cuFileRead(cfh, (void*)(uintptr_t)dptr, to_read, file_off, 0);
		if (n < 0) {
			rc = 4000 + (int)(-n);
			goto cleanup;
		}
		if (n == 0) {
			break;
		}
		file_off += (off_t)n;
	}

	if (clock_gettime(CLOCK_MONOTONIC, &t1) != 0) {
		rc = 3004;
		goto cleanup;
	}

	*total_bytes = (long long)file_off;
	*elapsed_us = (long long)((t1.tv_sec - t0.tv_sec) * 1000000LL + (t1.tv_nsec - t0.tv_nsec) / 1000LL);

cleanup:
	if (buf_registered) {
		(void)cuFileBufDeregister((void*)(uintptr_t)dptr);
	}
	if (dptr != 0) {
		(void)cuMemFree(dptr);
	}
	if (handle_registered) {
		(void)cuFileHandleDeregister(cfh);
	}
	if (fd >= 0) {
		(void)close(fd);
	}
	(void)cuCtxDestroy(ctx);
	return rc;
}
*/
import "C"

import (
	"context"
	"fmt"
	"io"
	"os"
	"time"
	"unsafe"

	"github.com/dims/oci2gdsd/internal/app"
)

type gdsLoader struct{}

func NewDefaultGPULoader() app.GPULoader {
	return &gdsLoader{}
}

func (l *gdsLoader) Name() string {
	return "cufile"
}

func (l *gdsLoader) Probe(_ context.Context, device int) (app.GPUProbeResult, error) {
	code := int(C.gds_init())
	if code != 0 {
		return app.GPUProbeResult{
			Available: false,
			Loader:    l.Name(),
			Device:    device,
			GDSDriver: false,
			Message:   fmt.Sprintf("failed to initialize CUDA/GDS driver: code=%d", code),
		}, nil
	}
	defer C.gds_shutdown()

	var cnt C.int
	code = int(C.gds_device_count(&cnt))
	if code != 0 {
		return app.GPUProbeResult{
			Available: false,
			Loader:    l.Name(),
			Device:    device,
			GDSDriver: true,
			Message:   fmt.Sprintf("failed to read CUDA device count: code=%d", code),
		}, nil
	}
	if int(cnt) <= device {
		return app.GPUProbeResult{
			Available:   false,
			Loader:      l.Name(),
			Device:      device,
			DeviceCount: int(cnt),
			GDSDriver:   true,
			Message:     fmt.Sprintf("device index %d out of range (device_count=%d)", device, int(cnt)),
		}, nil
	}
	return app.GPUProbeResult{
		Available:   true,
		Loader:      l.Name(),
		Device:      device,
		DeviceCount: int(cnt),
		GDSDriver:   true,
	}, nil
}

func (l *gdsLoader) LoadFile(ctx context.Context, req app.GPULoadFileRequest) (app.GPULoadFileResult, error) {
	select {
	case <-ctx.Done():
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitRegistry, app.ReasonRegistryTimeout, "context canceled before GDS read", ctx.Err())
	default:
	}
	if req.ChunkBytes <= 0 {
		req.ChunkBytes = 16 * 1024 * 1024
	}
	fi, err := os.Stat(req.Path)
	if err != nil {
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitFilesystem, app.ReasonFilesystemError, "failed to stat shard path", err)
	}

	code := int(C.gds_init())
	if code != 0 {
		if req.Strict {
			return app.GPULoadFileResult{}, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, fmt.Sprintf("failed to initialize CUDA/GDS driver: code=%d", code), nil)
		}
		return hostReadFallback(req.Path, req.ChunkBytes)
	}
	defer C.gds_shutdown()

	cPath := C.CString(req.Path)
	defer C.free(unsafe.Pointer(cPath))
	var total C.longlong
	var elapsed C.longlong
	code = int(C.gds_read_file(
		cPath,
		C.int(req.Device),
		C.longlong(req.ChunkBytes),
		C.int(boolToInt(req.Strict)),
		&total,
		&elapsed,
	))
	if code != 0 {
		if req.Strict {
			return app.GPULoadFileResult{}, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, fmt.Sprintf("cuFile read failed: code=%d", code), nil)
		}
		res, fallbackErr := hostReadFallback(req.Path, req.ChunkBytes)
		if fallbackErr != nil {
			return app.GPULoadFileResult{}, fallbackErr
		}
		res.Message = fmt.Sprintf("direct GDS read failed (code=%d), used host fallback", code)
		return res, nil
	}
	if int64(total) != fi.Size() {
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitIntegrity, app.ReasonBlobSizeMismatch, fmt.Sprintf("GDS read size mismatch: expected=%d got=%d", fi.Size(), int64(total)), nil)
	}
	return app.GPULoadFileResult{
		Path:       req.Path,
		Bytes:      int64(total),
		DurationMS: int64(elapsed) / 1000,
		Direct:     true,
	}, nil
}

func hostReadFallback(path string, chunkBytes int64) (app.GPULoadFileResult, error) {
	start := time.Now()
	f, err := os.Open(path)
	if err != nil {
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitFilesystem, app.ReasonFilesystemError, "host fallback failed to open shard file", err)
	}
	defer f.Close()
	if chunkBytes <= 0 {
		chunkBytes = 4 * 1024 * 1024
	}
	buf := make([]byte, chunkBytes)
	n, err := io.CopyBuffer(io.Discard, f, buf)
	if err != nil {
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitFilesystem, app.ReasonFilesystemError, "host fallback failed to read shard file", err)
	}
	return app.GPULoadFileResult{
		Path:       path,
		Bytes:      n,
		DurationMS: time.Since(start).Milliseconds(),
		Direct:     false,
	}, nil
}

func boolToInt(v bool) int {
	if v {
		return 1
	}
	return 0
}
