//go:build linux && cgo && gds

package gpu

/*
#define _GNU_SOURCE
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
#include <pthread.h>

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_driver_open = 0;
static CUcontext g_primary_ctx = NULL;
static int g_primary_device = -1;

static int gds_init() {
	CUresult cu = cuInit(0);
	if (cu != CUDA_SUCCESS) return 1000 + (int)cu;
	pthread_mutex_lock(&g_mu);
	if (!g_driver_open) {
		CUfileError_t st = cuFileDriverOpen();
		if (st.err != CU_FILE_SUCCESS) {
			pthread_mutex_unlock(&g_mu);
			return 2000 + (int)st.err;
		}
		g_driver_open = 1;
	}
	pthread_mutex_unlock(&g_mu);
	return 0;
}

static int gds_shutdown() {
	pthread_mutex_lock(&g_mu);
	if (g_primary_ctx != NULL && g_primary_device >= 0) {
		CUdevice old_dev;
		CUresult cu = cuDeviceGet(&old_dev, g_primary_device);
		if (cu == CUDA_SUCCESS) {
			(void)cuDevicePrimaryCtxRelease(old_dev);
		}
		g_primary_ctx = NULL;
		g_primary_device = -1;
	}
	if (g_driver_open) {
		CUfileError_t st = cuFileDriverClose();
		if (st.err != CU_FILE_SUCCESS) {
			pthread_mutex_unlock(&g_mu);
			return 2000 + (int)st.err;
		}
		g_driver_open = 0;
	}
	pthread_mutex_unlock(&g_mu);
	return 0;
}

static int gds_device_count(int* count) {
	CUresult cu = cuDeviceGetCount(count);
	if (cu != CUDA_SUCCESS) return 1000 + (int)cu;
	return 0;
}

static int gds_activate_device(int device) {
	CUresult cu;
	CUdevice dev;
	pthread_mutex_lock(&g_mu);
	if (!g_driver_open) {
		pthread_mutex_unlock(&g_mu);
		return 2001;
	}
	if (g_primary_ctx != NULL && g_primary_device == device) {
		pthread_mutex_unlock(&g_mu);
		return 0;
	}
	if (g_primary_ctx != NULL && g_primary_device >= 0) {
		CUdevice old_dev;
		cu = cuDeviceGet(&old_dev, g_primary_device);
		if (cu == CUDA_SUCCESS) {
			(void)cuDevicePrimaryCtxRelease(old_dev);
		}
		g_primary_ctx = NULL;
		g_primary_device = -1;
	}
	cu = cuDeviceGet(&dev, device);
	if (cu != CUDA_SUCCESS) {
		pthread_mutex_unlock(&g_mu);
		return 1000 + (int)cu;
	}
	cu = cuDevicePrimaryCtxRetain(&g_primary_ctx, dev);
	if (cu != CUDA_SUCCESS) {
		g_primary_ctx = NULL;
		pthread_mutex_unlock(&g_mu);
		return 1000 + (int)cu;
	}
	g_primary_device = device;
	pthread_mutex_unlock(&g_mu);
	return 0;
}

static int gds_read_file(const char* path, int device, long long chunk_bytes, int strict, long long* total_bytes, long long* elapsed_us) {
	CUresult cu;
	CUcontext prev_ctx = NULL;
	struct stat st;
	int rc = 0;
	int fd = -1;
	CUfileHandle_t cfh;
	CUdeviceptr dptr = 0;
	int handle_registered = 0;
	int buf_registered = 0;
	int ctx_pushed = 0;
	size_t chunk = (size_t)chunk_bytes;
	off_t file_size = 0;
	off_t file_off = 0;
	struct timespec t0;
	struct timespec t1;

	memset(&cfh, 0, sizeof(cfh));

	if (chunk < 4096) chunk = 4096;
	chunk = (chunk / 4096) * 4096;
	if (chunk == 0) chunk = 4096;

	rc = gds_activate_device(device);
	if (rc != 0) {
		return rc;
	}
	cu = cuCtxPushCurrent(g_primary_ctx);
	if (cu != CUDA_SUCCESS) return 1000 + (int)cu;
	ctx_pushed = 1;

	fd = open(path, O_RDONLY | O_DIRECT);
	if (fd < 0) {
		rc = 3001;
		goto cleanup;
	}

	if (fstat(fd, &st) != 0) {
		rc = 3002;
		goto cleanup;
	}
	file_size = st.st_size;
	if ((file_size % 4096) != 0) {
		rc = 3005;
		goto cleanup;
	}

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
		if ((n % 4096) != 0 && ((file_off + (off_t)n) < file_size)) {
			rc = 4005;
			goto cleanup;
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
	if (ctx_pushed) {
		(void)cuCtxPopCurrent(&prev_ctx);
	}
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
	return rc;
}

static int gds_load_persistent(const char* path, int device, long long chunk_bytes, int strict, CUdeviceptr* out_dptr, long long* total_bytes, long long* elapsed_us, int* out_direct) {
	CUresult cu;
	CUcontext prev_ctx = NULL;
	struct stat st;
	int rc = 0;
	int fd = -1;
	CUfileHandle_t cfh;
	CUdeviceptr dptr = 0;
	int handle_registered = 0;
	int buf_registered = 0;
	int ctx_pushed = 0;
	void* host_buf = NULL;
	size_t chunk = (size_t)chunk_bytes;
	off_t file_size = 0;
	off_t direct_size = 0;
	off_t file_off = 0;
	int direct_only = 1;
	struct timespec t0;
	struct timespec t1;

	if (out_dptr == NULL || total_bytes == NULL || elapsed_us == NULL || out_direct == NULL) {
		return 3009;
	}
	*out_dptr = 0;
	*total_bytes = 0;
	*elapsed_us = 0;
	*out_direct = 0;
	memset(&cfh, 0, sizeof(cfh));

	if (chunk < 4096) chunk = 4096;
	chunk = (chunk / 4096) * 4096;
	if (chunk == 0) chunk = 4096;

	rc = gds_activate_device(device);
	if (rc != 0) {
		return rc;
	}
	cu = cuCtxPushCurrent(g_primary_ctx);
	if (cu != CUDA_SUCCESS) return 1000 + (int)cu;
	ctx_pushed = 1;

	if (clock_gettime(CLOCK_MONOTONIC, &t0) != 0) {
		rc = 3003;
		goto cleanup;
	}

	fd = open(path, O_RDONLY | O_DIRECT);
	if (fd < 0) {
		if (strict) {
			rc = 3001;
			goto cleanup;
		}
		direct_only = 0;
		fd = open(path, O_RDONLY);
		if (fd < 0) {
			rc = 3001;
			goto cleanup;
		}
	}

	if (fstat(fd, &st) != 0) {
		rc = 3002;
		goto cleanup;
	}
	file_size = st.st_size;
	if (file_size <= 0) {
		rc = 3006;
		goto cleanup;
	}

	cu = cuMemAlloc(&dptr, (size_t)file_size);
	if (cu != CUDA_SUCCESS) {
		rc = 1000 + (int)cu;
		goto cleanup;
	}

	direct_size = (off_t)((file_size / 4096) * 4096);
	if (direct_only && direct_size > 0) {
		CUfileDescr_t desc;
		memset(&desc, 0, sizeof(desc));
		desc.handle.fd = fd;
		desc.type = CU_FILE_HANDLE_TYPE_OPAQUE_FD;

		CUfileError_t ferr = cuFileHandleRegister(&cfh, &desc);
		if (ferr.err != CU_FILE_SUCCESS) {
			if (strict) {
				rc = 2000 + (int)ferr.err;
				goto cleanup;
			}
			direct_only = 0;
		} else {
			handle_registered = 1;
			ferr = cuFileBufRegister((void*)(uintptr_t)dptr, (size_t)direct_size, 0);
			if (ferr.err == CU_FILE_SUCCESS) {
				buf_registered = 1;
			} else if (strict) {
				rc = 2000 + (int)ferr.err;
				goto cleanup;
			} else {
				direct_only = 0;
			}
		}

		if (!direct_only) {
			if (buf_registered) {
				(void)cuFileBufDeregister((void*)(uintptr_t)dptr);
				buf_registered = 0;
			}
			if (handle_registered) {
				(void)cuFileHandleDeregister(cfh);
				handle_registered = 0;
			}
			if (fd >= 0) {
				(void)close(fd);
				fd = -1;
			}
			fd = open(path, O_RDONLY);
			if (fd < 0) {
				rc = 3001;
				goto cleanup;
			}
		}
	} else if (direct_only && direct_size == 0) {
		if (strict) {
			rc = 3005;
			goto cleanup;
		}
		direct_only = 0;
		if (fd >= 0) {
			(void)close(fd);
			fd = -1;
		}
		fd = open(path, O_RDONLY);
		if (fd < 0) {
			rc = 3001;
			goto cleanup;
		}
	}

	if (direct_only) {
		file_off = 0;
		while (file_off < direct_size) {
			size_t to_read = chunk;
			if ((off_t)to_read > (direct_size - file_off)) {
				to_read = (size_t)(direct_size - file_off);
			}
			ssize_t n = cuFileRead(cfh, (void*)(uintptr_t)(dptr + (CUdeviceptr)file_off), to_read, file_off, 0);
			if (n < 0) {
				if (strict) {
					rc = 4000 + (int)(-n);
					goto cleanup;
				}
				direct_only = 0;
				break;
			}
			if (n == 0) {
				break;
			}
			if ((n % 4096) != 0 && ((file_off + (off_t)n) < direct_size)) {
				if (strict) {
					rc = 4005;
					goto cleanup;
				}
				direct_only = 0;
				break;
			}
			file_off += (off_t)n;
		}
		if (!strict && !direct_only) {
			if (buf_registered) {
				(void)cuFileBufDeregister((void*)(uintptr_t)dptr);
				buf_registered = 0;
			}
			if (handle_registered) {
				(void)cuFileHandleDeregister(cfh);
				handle_registered = 0;
			}
			if (fd >= 0) {
				(void)close(fd);
				fd = -1;
			}
			fd = open(path, O_RDONLY);
			if (fd < 0) {
				rc = 3001;
				goto cleanup;
			}
			file_off = 0;
		}
	}

	if (!direct_only) {
		host_buf = malloc(chunk);
		if (host_buf == NULL) {
			rc = 3007;
			goto cleanup;
		}
		file_off = 0;
		while (file_off < file_size) {
			size_t to_read = chunk;
			if ((off_t)to_read > (file_size - file_off)) {
				to_read = (size_t)(file_size - file_off);
			}
			ssize_t n = pread(fd, host_buf, to_read, file_off);
			if (n < 0) {
				rc = 3008;
				goto cleanup;
			}
			if (n == 0) {
				break;
			}
			cu = cuMemcpyHtoD(dptr + (CUdeviceptr)file_off, host_buf, (size_t)n);
			if (cu != CUDA_SUCCESS) {
				rc = 1000 + (int)cu;
				goto cleanup;
			}
			file_off += (off_t)n;
		}
	} else if (direct_size < file_size) {
		if (strict) {
			rc = 3005;
			goto cleanup;
		}
		/*
		 * Tail bytes are not 4KiB-aligned; switch to a non-O_DIRECT fd for
		 * host-buffer copy to avoid pread(EINVAL) on O_DIRECT descriptors.
		 */
		if (buf_registered) {
			(void)cuFileBufDeregister((void*)(uintptr_t)dptr);
			buf_registered = 0;
		}
		if (handle_registered) {
			(void)cuFileHandleDeregister(cfh);
			handle_registered = 0;
		}
		if (fd >= 0) {
			(void)close(fd);
			fd = -1;
		}
		fd = open(path, O_RDONLY);
		if (fd < 0) {
			rc = 3001;
			goto cleanup;
		}
		host_buf = malloc(chunk);
		if (host_buf == NULL) {
			rc = 3007;
			goto cleanup;
		}
		file_off = direct_size;
		while (file_off < file_size) {
			size_t to_read = chunk;
			if ((off_t)to_read > (file_size - file_off)) {
				to_read = (size_t)(file_size - file_off);
			}
			ssize_t n = pread(fd, host_buf, to_read, file_off);
			if (n < 0) {
				rc = 3008;
				goto cleanup;
			}
			if (n == 0) {
				break;
			}
			cu = cuMemcpyHtoD(dptr + (CUdeviceptr)file_off, host_buf, (size_t)n);
			if (cu != CUDA_SUCCESS) {
				rc = 1000 + (int)cu;
				goto cleanup;
			}
			file_off += (off_t)n;
		}
		direct_only = 0;
	}

	if (clock_gettime(CLOCK_MONOTONIC, &t1) != 0) {
		rc = 3004;
		goto cleanup;
	}

	if (buf_registered) {
		(void)cuFileBufDeregister((void*)(uintptr_t)dptr);
		buf_registered = 0;
	}
	if (handle_registered) {
		(void)cuFileHandleDeregister(cfh);
		handle_registered = 0;
	}

	*out_dptr = dptr;
	dptr = 0;
	*total_bytes = (long long)file_off;
	*elapsed_us = (long long)((t1.tv_sec - t0.tv_sec) * 1000000LL + (t1.tv_nsec - t0.tv_nsec) / 1000LL);
	*out_direct = direct_only ? 1 : 0;

cleanup:
	if (ctx_pushed) {
		(void)cuCtxPopCurrent(&prev_ctx);
	}
	if (host_buf != NULL) {
		free(host_buf);
	}
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
	return rc;
}

static int gds_free_persistent(int device, CUdeviceptr dptr) {
	CUresult cu;
	CUcontext prev_ctx = NULL;
	int rc = 0;
	int ctx_pushed = 0;

	if (dptr == 0) {
		return 0;
	}
	rc = gds_activate_device(device);
	if (rc != 0) {
		return rc;
	}
	cu = cuCtxPushCurrent(g_primary_ctx);
	if (cu != CUDA_SUCCESS) return 1000 + (int)cu;
	ctx_pushed = 1;

	cu = cuMemFree(dptr);
	if (cu != CUDA_SUCCESS) {
		rc = 1000 + (int)cu;
	}
	if (ctx_pushed) {
		(void)cuCtxPopCurrent(&prev_ctx);
	}
	return rc;
}

static int gds_export_ipc_handle(int device, CUdeviceptr dptr, unsigned char* out_handle, int out_handle_len) {
	CUresult cu;
	CUcontext prev_ctx = NULL;
	int rc = 0;
	int ctx_pushed = 0;
	CUipcMemHandle handle;

	if (dptr == 0 || out_handle == NULL) {
		return 3009;
	}
	if (out_handle_len < (int)sizeof(CUipcMemHandle)) {
		return 3010;
	}

	rc = gds_activate_device(device);
	if (rc != 0) {
		return rc;
	}
	cu = cuCtxPushCurrent(g_primary_ctx);
	if (cu != CUDA_SUCCESS) return 1000 + (int)cu;
	ctx_pushed = 1;

	cu = cuIpcGetMemHandle(&handle, dptr);
	if (cu != CUDA_SUCCESS) {
		rc = 1000 + (int)cu;
		goto cleanup;
	}
	memcpy(out_handle, &handle, sizeof(CUipcMemHandle));

cleanup:
	if (ctx_pushed) {
		(void)cuCtxPopCurrent(&prev_ctx);
	}
	return rc;
}
*/
import "C"

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"sort"
	"sync"
	"time"
	"unsafe"

	"github.com/dims/oci2gdsd/internal/app"
)

type persistentAllocation struct {
	ptr    C.CUdeviceptr
	bytes  int64
	refs   int
	direct bool
}

type gdsLoader struct {
	mu          sync.Mutex
	refs        int
	device      int
	ready       bool
	allocations map[string]*persistentAllocation
}

func NewDefaultGPULoader() app.GPULoader {
	return &gdsLoader{
		allocations: map[string]*persistentAllocation{},
	}
}

func (l *gdsLoader) Name() string {
	return "cufile"
}

func (l *gdsLoader) Probe(_ context.Context, device int) (app.GPUProbeResult, error) {
	l.mu.Lock()
	defer l.mu.Unlock()

	code := int(C.gds_init())
	if code != 0 {
		return app.GPUProbeResult{
			Available: false,
			Loader:    l.Name(),
			Device:    device,
			GDSDriver: false,
			Message:   fmt.Sprintf("failed to initialize CUDA/GDS driver: %s", describeGDSCode(code)),
		}, nil
	}
	if !l.ready {
		defer C.gds_shutdown()
	}

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

func (l *gdsLoader) BeginSession(_ context.Context, device int) (func(), error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.ready {
		if l.device != device {
			return nil, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, fmt.Sprintf("loader session already active on device %d", l.device), nil)
		}
		l.refs++
		return l.releaseFn(), nil
	}
	code := int(C.gds_init())
	if code != 0 {
		return nil, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, fmt.Sprintf("failed to initialize CUDA/GDS driver: %s", describeGDSCode(code)), nil)
	}
	code = int(C.gds_activate_device(C.int(device)))
	if code != 0 {
		_ = C.gds_shutdown()
		return nil, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, fmt.Sprintf("failed to activate CUDA primary context: %s", describeGDSCode(code)), nil)
	}
	l.refs = 1
	l.device = device
	l.ready = true
	return l.releaseFn(), nil
}

func (l *gdsLoader) releaseFn() func() {
	released := false
	return func() {
		l.mu.Lock()
		defer l.mu.Unlock()
		if released {
			return
		}
		released = true
		if l.refs > 0 {
			l.refs--
		}
		if l.refs == 0 && l.ready && len(l.allocations) == 0 {
			_ = C.gds_shutdown()
			l.ready = false
			l.device = 0
		}
	}
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

	l.mu.Lock()
	sessionReady := l.ready && l.refs > 0 && l.device == req.Device
	l.mu.Unlock()
	var endSession func()
	if !sessionReady {
		var err error
		endSession, err = l.BeginSession(ctx, req.Device)
		if err != nil {
			if req.Strict {
				return app.GPULoadFileResult{}, err
			}
			return hostReadFallback(req.Path, req.ChunkBytes)
		}
		defer endSession()
	}

	cPath := C.CString(req.Path)
	defer C.free(unsafe.Pointer(cPath))
	var total C.longlong
	var elapsed C.longlong
	code := int(C.gds_read_file(
		cPath,
		C.int(req.Device),
		C.longlong(req.ChunkBytes),
		C.int(boolToInt(req.Strict)),
		&total,
		&elapsed,
	))
	if code != 0 {
		if req.Strict {
			return app.GPULoadFileResult{}, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, fmt.Sprintf("cuFile read failed: %s", describeGDSCode(code)), nil)
		}
		res, fallbackErr := hostReadFallback(req.Path, req.ChunkBytes)
		if fallbackErr != nil {
			return app.GPULoadFileResult{}, fallbackErr
		}
		res.Message = fmt.Sprintf("direct GDS read failed (%s), used host fallback", describeGDSCode(code))
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

func (l *gdsLoader) LoadPersistent(ctx context.Context, req app.GPULoadFileRequest) (app.GPULoadFileResult, error) {
	select {
	case <-ctx.Done():
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitRegistry, app.ReasonRegistryTimeout, "context canceled before persistent GDS load", ctx.Err())
	default:
	}
	if req.ChunkBytes <= 0 {
		req.ChunkBytes = 16 * 1024 * 1024
	}
	fi, err := os.Stat(req.Path)
	if err != nil {
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitFilesystem, app.ReasonFilesystemError, "failed to stat shard path", err)
	}

	l.mu.Lock()
	if l.allocations == nil {
		l.allocations = map[string]*persistentAllocation{}
	}
	if alloc, ok := l.allocations[req.Path]; ok {
		if !l.ready || l.device != req.Device {
			l.mu.Unlock()
			return app.GPULoadFileResult{}, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, "persistent allocation exists on different device/session state", nil)
		}
		alloc.refs++
		res := app.GPULoadFileResult{
			Path:      req.Path,
			Bytes:     alloc.bytes,
			Direct:    alloc.direct,
			Loaded:    false,
			RefCount:  alloc.refs,
			DevicePtr: devicePtrString(alloc.ptr),
			Message:   "already resident in GPU memory",
		}
		l.mu.Unlock()
		return res, nil
	}
	l.mu.Unlock()

	endSession, err := l.BeginSession(ctx, req.Device)
	if err != nil {
		return app.GPULoadFileResult{}, err
	}
	defer endSession()

	cPath := C.CString(req.Path)
	defer C.free(unsafe.Pointer(cPath))
	var ptr C.CUdeviceptr
	var total C.longlong
	var elapsed C.longlong
	var direct C.int
	code := int(C.gds_load_persistent(
		cPath,
		C.int(req.Device),
		C.longlong(req.ChunkBytes),
		C.int(boolToInt(req.Strict)),
		&ptr,
		&total,
		&elapsed,
		&direct,
	))
	if code != 0 {
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, fmt.Sprintf("persistent cuFile load failed: %s", describeGDSCode(code)), nil)
	}
	if int64(total) != fi.Size() {
		_ = C.gds_free_persistent(C.int(req.Device), ptr)
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitIntegrity, app.ReasonBlobSizeMismatch, fmt.Sprintf("persistent GDS read size mismatch: expected=%d got=%d", fi.Size(), int64(total)), nil)
	}

	var duplicate *persistentAllocation
	l.mu.Lock()
	if l.allocations == nil {
		l.allocations = map[string]*persistentAllocation{}
	}
	if alloc, ok := l.allocations[req.Path]; ok {
		alloc.refs++
		duplicate = alloc
	} else {
		l.allocations[req.Path] = &persistentAllocation{
			ptr:    ptr,
			bytes:  int64(total),
			refs:   1,
			direct: direct == 1,
		}
	}
	l.mu.Unlock()
	if duplicate != nil {
		_ = C.gds_free_persistent(C.int(req.Device), ptr)
		return app.GPULoadFileResult{
			Path:      req.Path,
			Bytes:     duplicate.bytes,
			Direct:    duplicate.direct,
			Loaded:    false,
			RefCount:  duplicate.refs,
			DevicePtr: devicePtrString(duplicate.ptr),
			Message:   "already resident in GPU memory",
		}, nil
	}

	return app.GPULoadFileResult{
		Path:       req.Path,
		Bytes:      int64(total),
		DurationMS: int64(elapsed) / 1000,
		Direct:     direct == 1,
		Loaded:     true,
		RefCount:   1,
		DevicePtr:  devicePtrString(ptr),
	}, nil
}

func (l *gdsLoader) ExportPersistent(ctx context.Context, req app.GPULoadFileRequest) (app.GPULoadFileResult, error) {
	select {
	case <-ctx.Done():
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitRegistry, app.ReasonRegistryTimeout, "context canceled before persistent GPU export", ctx.Err())
	default:
	}

	l.mu.Lock()
	defer l.mu.Unlock()
	if l.allocations == nil {
		l.allocations = map[string]*persistentAllocation{}
	}
	alloc, ok := l.allocations[req.Path]
	if !ok {
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "persistent allocation not found for shard path", nil)
	}
	if !l.ready || l.device != req.Device {
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, "persistent allocation exists on a different device/session state", nil)
	}

	handle := make([]byte, 64)
	code := int(C.gds_export_ipc_handle(
		C.int(req.Device),
		alloc.ptr,
		(*C.uchar)(unsafe.Pointer(&handle[0])),
		C.int(len(handle)),
	))
	if code != 0 {
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, fmt.Sprintf("failed exporting CUDA IPC handle: %s", describeGDSCode(code)), nil)
	}

	return app.GPULoadFileResult{
		Path:      req.Path,
		Bytes:     alloc.bytes,
		Direct:    alloc.direct,
		Loaded:    true,
		RefCount:  alloc.refs,
		DevicePtr: devicePtrString(alloc.ptr),
		IPCHandle: base64.StdEncoding.EncodeToString(handle),
		Message:   "exported CUDA IPC handle for persistent allocation",
	}, nil
}

func (l *gdsLoader) UnloadPersistent(ctx context.Context, req app.GPULoadFileRequest) (app.GPULoadFileResult, error) {
	select {
	case <-ctx.Done():
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitRegistry, app.ReasonRegistryTimeout, "context canceled before persistent GPU unload", ctx.Err())
	default:
	}

	l.mu.Lock()
	defer l.mu.Unlock()
	if l.allocations == nil {
		l.allocations = map[string]*persistentAllocation{}
	}
	alloc, ok := l.allocations[req.Path]
	if !ok {
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "persistent allocation not found for shard path", nil)
	}
	if !l.ready || l.device != req.Device {
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, "persistent allocation exists on a different device", nil)
	}
	if alloc.refs > 1 {
		alloc.refs--
		return app.GPULoadFileResult{
			Path:      req.Path,
			Bytes:     0,
			Direct:    alloc.direct,
			Loaded:    false,
			RefCount:  alloc.refs,
			DevicePtr: devicePtrString(alloc.ptr),
			Message:   "persistent allocation retained; active references remain",
		}, nil
	}
	code := int(C.gds_free_persistent(C.int(req.Device), alloc.ptr))
	if code != 0 {
		alloc.refs = 1
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, fmt.Sprintf("persistent GPU free failed: %s", describeGDSCode(code)), nil)
	}
	res := app.GPULoadFileResult{
		Path:      req.Path,
		Bytes:     alloc.bytes,
		Direct:    alloc.direct,
		Loaded:    false,
		RefCount:  0,
		DevicePtr: devicePtrString(alloc.ptr),
		Message:   "persistent allocation released",
	}
	delete(l.allocations, req.Path)
	if l.refs == 0 && l.ready && len(l.allocations) == 0 {
		_ = C.gds_shutdown()
		l.ready = false
		l.device = 0
	}
	return res, nil
}

func (l *gdsLoader) ListPersistent(_ context.Context, device int) ([]app.GPULoadFileResult, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.allocations == nil {
		l.allocations = map[string]*persistentAllocation{}
	}
	if len(l.allocations) == 0 {
		return []app.GPULoadFileResult{}, nil
	}
	if !l.ready || l.device != device {
		return nil, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, fmt.Sprintf("persistent allocations are loaded on device %d", l.device), nil)
	}
	out := make([]app.GPULoadFileResult, 0, len(l.allocations))
	for path, alloc := range l.allocations {
		out = append(out, app.GPULoadFileResult{
			Path:      path,
			Bytes:     alloc.bytes,
			Direct:    alloc.direct,
			Loaded:    true,
			RefCount:  alloc.refs,
			DevicePtr: devicePtrString(alloc.ptr),
		})
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].Path < out[j].Path
	})
	return out, nil
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

func devicePtrString(ptr C.CUdeviceptr) string {
	return fmt.Sprintf("0x%x", uint64(ptr))
}

func describeGDSCode(code int) string {
	switch {
	case code >= 1000 && code < 2000:
		return fmt.Sprintf("code=%d (CUDA driver error=%d)", code, code-1000)
	case code >= 2000 && code < 3000:
		return fmt.Sprintf("code=%d (cuFile error=%d)", code, code-2000)
	case code >= 4000 && code < 5000:
		return fmt.Sprintf("code=%d (cuFile read status=%d)", code, code-4000)
	}
	switch code {
	case 3001:
		return "code=3001 (failed to open shard path; O_DIRECT may be unsupported)"
	case 3002:
		return "code=3002 (failed to stat shard path)"
	case 3003:
		return "code=3003 (failed to read CLOCK_MONOTONIC start time)"
	case 3004:
		return "code=3004 (failed to read CLOCK_MONOTONIC end time)"
	case 3005:
		return "code=3005 (file size or read boundary is not 4KiB-aligned for direct path)"
	case 3006:
		return "code=3006 (file size must be > 0)"
	case 3007:
		return "code=3007 (failed to allocate host staging buffer)"
	case 3008:
		return "code=3008 (host pread failed in fallback path)"
	case 3009:
		return "code=3009 (invalid output pointer arguments)"
	case 3010:
		return "code=3010 (output buffer too small for CUDA IPC handle)"
	default:
		return fmt.Sprintf("code=%d", code)
	}
}
