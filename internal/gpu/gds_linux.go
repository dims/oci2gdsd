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
#include <stdio.h>

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_driver_open = 0;
static CUcontext g_device_ctxs[128];
static int g_device_ids[128];
static int g_device_ctx_count = 0;

static int gds_find_ctx_locked(int device) {
	for (int i = 0; i < g_device_ctx_count; i++) {
		if (g_device_ids[i] == device) {
			return i;
		}
	}
	return -1;
}

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
	for (int i = 0; i < g_device_ctx_count; i++) {
		if (g_device_ctxs[i] == NULL) {
			continue;
		}
		CUdevice dev;
		CUresult cu = cuDeviceGet(&dev, g_device_ids[i]);
		if (cu == CUDA_SUCCESS) {
			(void)cuDevicePrimaryCtxRelease(dev);
		}
		g_device_ctxs[i] = NULL;
		g_device_ids[i] = -1;
	}
	g_device_ctx_count = 0;
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
	CUresult cui = cuInit(0);
	if (cui != CUDA_SUCCESS) return 1000 + (int)cui;
	CUresult cu = cuDeviceGetCount(count);
	if (cu != CUDA_SUCCESS) return 1000 + (int)cu;
	return 0;
}

static int gds_device_uuid(int device, char* out, int out_len) {
	CUresult cui = cuInit(0);
	if (cui != CUDA_SUCCESS) return 1000 + (int)cui;
	CUdevice dev;
	CUuuid uuid;
	CUresult cu = cuDeviceGet(&dev, device);
	if (cu != CUDA_SUCCESS) return 1000 + (int)cu;
#if defined(CUDA_VERSION) && CUDA_VERSION >= 11000
	cu = cuDeviceGetUuid_v2(&uuid, dev);
#else
	cu = cuDeviceGetUuid(&uuid, dev);
#endif
	if (cu != CUDA_SUCCESS) return 1000 + (int)cu;
	if (out == NULL || out_len < 40) return 3010;
	int n = snprintf(
		out,
		(size_t)out_len,
		"GPU-%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
		(unsigned int)(unsigned char)uuid.bytes[0], (unsigned int)(unsigned char)uuid.bytes[1],
		(unsigned int)(unsigned char)uuid.bytes[2], (unsigned int)(unsigned char)uuid.bytes[3],
		(unsigned int)(unsigned char)uuid.bytes[4], (unsigned int)(unsigned char)uuid.bytes[5],
		(unsigned int)(unsigned char)uuid.bytes[6], (unsigned int)(unsigned char)uuid.bytes[7],
		(unsigned int)(unsigned char)uuid.bytes[8], (unsigned int)(unsigned char)uuid.bytes[9],
		(unsigned int)(unsigned char)uuid.bytes[10], (unsigned int)(unsigned char)uuid.bytes[11],
		(unsigned int)(unsigned char)uuid.bytes[12], (unsigned int)(unsigned char)uuid.bytes[13],
		(unsigned int)(unsigned char)uuid.bytes[14], (unsigned int)(unsigned char)uuid.bytes[15]
	);
	if (n <= 0 || n >= out_len) return 3010;
	return 0;
}

static int gds_device_name(int device, char* out, int out_len) {
	CUresult cui = cuInit(0);
	if (cui != CUDA_SUCCESS) return 1000 + (int)cui;
	CUdevice dev;
	CUresult cu = cuDeviceGet(&dev, device);
	if (cu != CUDA_SUCCESS) return 1000 + (int)cu;
	if (out == NULL || out_len <= 1) return 3010;
	cu = cuDeviceGetName(out, out_len, dev);
	if (cu != CUDA_SUCCESS) return 1000 + (int)cu;
	return 0;
}

static int gds_activate_device(int device, CUcontext* out_ctx) {
	CUresult cu;
	CUdevice dev;
	pthread_mutex_lock(&g_mu);
	if (!g_driver_open) {
		pthread_mutex_unlock(&g_mu);
		return 2001;
	}
	if (out_ctx == NULL) {
		pthread_mutex_unlock(&g_mu);
		return 3009;
	}
	int idx = gds_find_ctx_locked(device);
	if (idx >= 0) {
		*out_ctx = g_device_ctxs[idx];
		pthread_mutex_unlock(&g_mu);
		return 0;
	}
	if (g_device_ctx_count >= (int)(sizeof(g_device_ctxs) / sizeof(g_device_ctxs[0]))) {
		pthread_mutex_unlock(&g_mu);
		return 3011;
	}
	cu = cuDeviceGet(&dev, device);
	if (cu != CUDA_SUCCESS) {
		pthread_mutex_unlock(&g_mu);
		return 1000 + (int)cu;
	}
	CUcontext ctx = NULL;
	cu = cuDevicePrimaryCtxRetain(&ctx, dev);
	if (cu != CUDA_SUCCESS) {
		pthread_mutex_unlock(&g_mu);
		return 1000 + (int)cu;
	}
	g_device_ids[g_device_ctx_count] = device;
	g_device_ctxs[g_device_ctx_count] = ctx;
	g_device_ctx_count++;
	*out_ctx = ctx;
	pthread_mutex_unlock(&g_mu);
	return 0;
}

static int gds_release_device_if_unused(int device) {
	pthread_mutex_lock(&g_mu);
	int idx = gds_find_ctx_locked(device);
	if (idx < 0) {
		pthread_mutex_unlock(&g_mu);
		return 0;
	}
	CUcontext ctx = g_device_ctxs[idx];
	if (ctx != NULL) {
		CUdevice dev;
		CUresult cu = cuDeviceGet(&dev, device);
		if (cu == CUDA_SUCCESS) {
			(void)cuDevicePrimaryCtxRelease(dev);
		}
	}
	for (int i = idx; i + 1 < g_device_ctx_count; i++) {
		g_device_ids[i] = g_device_ids[i+1];
		g_device_ctxs[i] = g_device_ctxs[i+1];
	}
	g_device_ctx_count--;
	if (g_device_ctx_count >= 0) {
		g_device_ids[g_device_ctx_count] = -1;
		g_device_ctxs[g_device_ctx_count] = NULL;
	}
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
	CUcontext active_ctx = NULL;
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

	rc = gds_activate_device(device, &active_ctx);
	if (rc != 0) {
		return rc;
	}
	cu = cuCtxPushCurrent(active_ctx);
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
		off_t remaining = file_size - file_off;
		size_t to_read = chunk;
		if ((off_t)to_read > remaining) {
			if (remaining < 4096) {
				to_read = 4096;
			} else {
				size_t rem = (size_t)remaining;
				to_read = (rem / 4096) * 4096;
				if (to_read == 0) {
					to_read = 4096;
				}
			}
		}
		ssize_t n = cuFileRead(cfh, (void*)(uintptr_t)dptr, to_read, file_off, 0);
		if (n < 0) {
			rc = 4000 + (int)(-n);
			goto cleanup;
		}
		if (n == 0) {
			rc = 4005;
			goto cleanup;
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
	CUcontext active_ctx = NULL;
	int handle_registered = 0;
	int buf_registered = 0;
	int tail_buf_registered = 0;
	int ctx_pushed = 0;
	void* host_buf = NULL;
	size_t chunk = (size_t)chunk_bytes;
	off_t file_size = 0;
	off_t direct_size = 0;
	off_t file_off = 0;
	int direct_only = 1;
	CUdeviceptr tail_dptr = 0;
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

	rc = gds_activate_device(device, &active_ctx);
	if (rc != 0) {
		return rc;
	}
	cu = cuCtxPushCurrent(active_ctx);
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
	if (direct_only) {
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
		}
		if (direct_only && direct_size > 0) {
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

	if (direct_only && file_off < file_size) {
		off_t tail_remaining = file_size - file_off;
		CUfileError_t ferr;
		ssize_t n;
		size_t copy_len;

		cu = cuMemAlloc(&tail_dptr, 4096);
		if (cu != CUDA_SUCCESS) {
			if (strict) {
				rc = 1000 + (int)cu;
				goto cleanup;
			}
			direct_only = 0;
		}
		if (direct_only) {
			ferr = cuFileBufRegister((void*)(uintptr_t)tail_dptr, 4096, 0);
			if (ferr.err != CU_FILE_SUCCESS) {
				if (strict) {
					rc = 2000 + (int)ferr.err;
					goto cleanup;
				}
				direct_only = 0;
			} else {
				tail_buf_registered = 1;
			}
		}
		if (direct_only) {
			n = cuFileRead(cfh, (void*)(uintptr_t)tail_dptr, 4096, file_off, 0);
			if (n < 0) {
				if (strict) {
					rc = 4000 + (int)(-n);
					goto cleanup;
				}
				direct_only = 0;
			} else if (n <= 0) {
				if (strict) {
					rc = 4005;
					goto cleanup;
				}
				direct_only = 0;
			} else {
				copy_len = (size_t)n;
				if ((off_t)copy_len > tail_remaining) {
					copy_len = (size_t)tail_remaining;
				}
				cu = cuMemcpyDtoD(dptr + (CUdeviceptr)file_off, tail_dptr, copy_len);
				if (cu != CUDA_SUCCESS) {
					rc = 1000 + (int)cu;
					goto cleanup;
				}
				file_off += (off_t)copy_len;
				if (file_off < file_size) {
					if (strict) {
						rc = 4005;
						goto cleanup;
					}
					direct_only = 0;
				}
			}
		}
		if (tail_buf_registered) {
			(void)cuFileBufDeregister((void*)(uintptr_t)tail_dptr);
			tail_buf_registered = 0;
		}
		if (tail_dptr != 0) {
			(void)cuMemFree(tail_dptr);
			tail_dptr = 0;
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
	if (tail_buf_registered) {
		(void)cuFileBufDeregister((void*)(uintptr_t)tail_dptr);
	}
	if (tail_dptr != 0) {
		(void)cuMemFree(tail_dptr);
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
	CUcontext active_ctx = NULL;
	int rc = 0;
	int ctx_pushed = 0;

	if (dptr == 0) {
		return 0;
	}
	rc = gds_activate_device(device, &active_ctx);
	if (rc != 0) {
		return rc;
	}
	cu = cuCtxPushCurrent(active_ctx);
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
	CUcontext active_ctx = NULL;
	int rc = 0;
	int ctx_pushed = 0;
	CUipcMemHandle handle;

	if (dptr == 0 || out_handle == NULL) {
		return 3009;
	}
	if (out_handle_len < (int)sizeof(CUipcMemHandle)) {
		return 3010;
	}

	rc = gds_activate_device(device, &active_ctx);
	if (rc != 0) {
		return rc;
	}
	cu = cuCtxPushCurrent(active_ctx);
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
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/dims/oci2gdsd/internal/app"
)

type persistentAllocation struct {
	device       int
	ptr          C.CUdeviceptr
	bytes        int64
	loadRefs     int
	importerRefs int
	importers    map[string]int
	direct       bool
}

type gdsLoader struct {
	mu          sync.Mutex
	refs        map[int]int
	active      map[int]bool
	allocations map[string]*persistentAllocation
}

func NewDefaultGPULoader() app.GPULoader {
	return &gdsLoader{
		refs:        map[int]int{},
		active:      map[int]bool{},
		allocations: map[string]*persistentAllocation{},
	}
}

func (l *gdsLoader) Name() string {
	return "cufile"
}

func normalizeGPUUUID(uuid string) string {
	s := strings.TrimSpace(strings.ToLower(uuid))
	s = strings.TrimPrefix(s, "gpu-")
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '-' {
			continue
		}
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') {
			out = append(out, c)
		}
	}
	return string(out)
}

func (l *gdsLoader) ListDevices(_ context.Context) ([]app.GPUDeviceInfo, error) {
	code := int(C.gds_init())
	if code != 0 {
		return nil, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, fmt.Sprintf("failed to initialize CUDA/GDS driver: %s", describeGDSCode(code)), nil)
	}
	var cnt C.int
	code = int(C.gds_device_count(&cnt))
	if code != 0 {
		return nil, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, fmt.Sprintf("failed to read CUDA device count: %s", describeGDSCode(code)), nil)
	}
	if int(cnt) <= 0 {
		return []app.GPUDeviceInfo{}, nil
	}
	out := make([]app.GPUDeviceInfo, 0, int(cnt))
	for i := 0; i < int(cnt); i++ {
		uuidBuf := make([]C.char, 64)
		code = int(C.gds_device_uuid(C.int(i), &uuidBuf[0], C.int(len(uuidBuf))))
		if code != 0 {
			return nil, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, fmt.Sprintf("failed to read CUDA device UUID for index %d: %s", i, describeGDSCode(code)), nil)
		}
		nameBuf := make([]C.char, 256)
		nameCode := int(C.gds_device_name(C.int(i), &nameBuf[0], C.int(len(nameBuf))))
		name := ""
		if nameCode == 0 {
			name = C.GoString(&nameBuf[0])
		}
		out = append(out, app.GPUDeviceInfo{
			UUID:  C.GoString(&uuidBuf[0]),
			Index: i,
			Name:  strings.TrimSpace(name),
		})
	}
	return out, nil
}

func (l *gdsLoader) ResolveDevice(ctx context.Context, deviceUUID string) (app.GPUDeviceInfo, error) {
	want := normalizeGPUUUID(deviceUUID)
	if len(want) != 32 {
		return app.GPUDeviceInfo{}, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "device UUID must be a canonical GPU UUID (GPU-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)", nil)
	}
	devices, err := l.ListDevices(ctx)
	if err != nil {
		return app.GPUDeviceInfo{}, err
	}
	for _, dev := range devices {
		if normalizeGPUUUID(dev.UUID) == want {
			return dev, nil
		}
	}
	return app.GPUDeviceInfo{}, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, fmt.Sprintf("device UUID %q is not visible to this process", deviceUUID), nil)
}

func (l *gdsLoader) Probe(_ context.Context, device int) (app.GPUProbeResult, error) {
	code := int(C.gds_init())
	if code != 0 {
		return app.GPUProbeResult{
			Available:   false,
			Loader:      l.Name(),
			DeviceIndex: device,
			GDSDriver:   false,
			Message:     fmt.Sprintf("failed to initialize CUDA/GDS driver: %s", describeGDSCode(code)),
		}, nil
	}

	var cnt C.int
	code = int(C.gds_device_count(&cnt))
	if code != 0 {
		return app.GPUProbeResult{
			Available:   false,
			Loader:      l.Name(),
			DeviceIndex: device,
			GDSDriver:   true,
			Message:     fmt.Sprintf("failed to read CUDA device count: code=%d", code),
		}, nil
	}
	if int(cnt) <= device {
		return app.GPUProbeResult{
			Available:   false,
			Loader:      l.Name(),
			DeviceIndex: device,
			DeviceCount: int(cnt),
			GDSDriver:   true,
			Message:     fmt.Sprintf("device index %d out of range (device_count=%d)", device, int(cnt)),
		}, nil
	}
	return app.GPUProbeResult{
		Available:   true,
		Loader:      l.Name(),
		DeviceIndex: device,
		DeviceCount: int(cnt),
		GDSDriver:   true,
	}, nil
}

func allocKey(device int, path string) string {
	return fmt.Sprintf("%d|%s", device, path)
}

func (l *gdsLoader) totalRefsLocked() int {
	total := 0
	for _, c := range l.refs {
		total += c
	}
	return total
}

func (l *gdsLoader) BeginSession(_ context.Context, device int) (func(), error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.refs == nil {
		l.refs = map[int]int{}
	}
	if l.active == nil {
		l.active = map[int]bool{}
	}
	if count := l.refs[device]; count > 0 {
		l.refs[device] = count + 1
		return l.releaseFn(device), nil
	}
	code := int(C.gds_init())
	if code != 0 {
		return nil, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, fmt.Sprintf("failed to initialize CUDA/GDS driver: %s", describeGDSCode(code)), nil)
	}
	var ctx C.CUcontext
	code = int(C.gds_activate_device(C.int(device), &ctx))
	if code != 0 {
		if l.totalRefsLocked() == 0 && len(l.allocations) == 0 {
			_ = C.gds_shutdown()
		}
		return nil, app.NewAppError(app.ExitPolicy, app.ReasonDirectPathIneligible, fmt.Sprintf("failed to activate CUDA primary context: %s", describeGDSCode(code)), nil)
	}
	l.refs[device] = 1
	l.active[device] = true
	return l.releaseFn(device), nil
}

func (l *gdsLoader) releaseFn(device int) func() {
	released := false
	return func() {
		l.mu.Lock()
		defer l.mu.Unlock()
		if released {
			return
		}
		released = true
		if count := l.refs[device]; count > 1 {
			l.refs[device] = count - 1
		} else {
			delete(l.refs, device)
		}
		if l.totalRefsLocked() == 0 && len(l.allocations) == 0 {
			_ = C.gds_shutdown()
			l.active = map[int]bool{}
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
	sessionReady := l.refs[req.Device] > 0
	l.mu.Unlock()
	var endSession func()
	if !sessionReady {
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

	key := allocKey(req.Device, req.Path)
	l.mu.Lock()
	if l.allocations == nil {
		l.allocations = map[string]*persistentAllocation{}
	}
	if alloc, ok := l.allocations[key]; ok {
		alloc.loadRefs++
		res := app.GPULoadFileResult{
			Path:      req.Path,
			Bytes:     alloc.bytes,
			Direct:    alloc.direct,
			Loaded:    false,
			RefCount:  alloc.loadRefs + alloc.importerRefs,
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
	if alloc, ok := l.allocations[key]; ok {
		alloc.loadRefs++
		duplicate = alloc
	} else {
		l.allocations[key] = &persistentAllocation{
			device:    req.Device,
			ptr:       ptr,
			bytes:     int64(total),
			loadRefs:  1,
			importers: map[string]int{},
			direct:    direct == 1,
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
			RefCount:  duplicate.loadRefs + duplicate.importerRefs,
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
	key := allocKey(req.Device, req.Path)

	l.mu.Lock()
	defer l.mu.Unlock()
	if l.allocations == nil {
		l.allocations = map[string]*persistentAllocation{}
	}
	alloc, ok := l.allocations[key]
	if !ok {
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "persistent allocation not found for shard path", nil)
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
		RefCount:  alloc.loadRefs + alloc.importerRefs,
		DevicePtr: devicePtrString(alloc.ptr),
		IPCHandle: base64.StdEncoding.EncodeToString(handle),
		Message:   "exported CUDA IPC handle for persistent allocation",
	}, nil
}

func (l *gdsLoader) AttachPersistent(ctx context.Context, req app.GPULoadFileRequest) (app.GPULoadFileResult, error) {
	select {
	case <-ctx.Done():
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitRegistry, app.ReasonRegistryTimeout, "context canceled before persistent GPU attach", ctx.Err())
	default:
	}
	clientID := req.ClientID
	if clientID == "" {
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "client id is required for persistent attach", nil)
	}
	key := allocKey(req.Device, req.Path)

	l.mu.Lock()
	defer l.mu.Unlock()
	if l.allocations == nil {
		l.allocations = map[string]*persistentAllocation{}
	}
	alloc, ok := l.allocations[key]
	if !ok {
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "persistent allocation not found for shard path", nil)
	}
	if alloc.importers == nil {
		alloc.importers = map[string]int{}
	}
	alloc.importers[clientID]++
	alloc.importerRefs++

	return app.GPULoadFileResult{
		Path:      req.Path,
		Bytes:     alloc.bytes,
		Direct:    alloc.direct,
		Loaded:    true,
		RefCount:  alloc.loadRefs + alloc.importerRefs,
		DevicePtr: devicePtrString(alloc.ptr),
		Message:   "persistent allocation attached for client import",
	}, nil
}

func (l *gdsLoader) DetachPersistent(ctx context.Context, req app.GPULoadFileRequest) (app.GPULoadFileResult, error) {
	select {
	case <-ctx.Done():
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitRegistry, app.ReasonRegistryTimeout, "context canceled before persistent GPU detach", ctx.Err())
	default:
	}
	clientID := req.ClientID
	if clientID == "" {
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "client id is required for persistent detach", nil)
	}
	key := allocKey(req.Device, req.Path)

	l.mu.Lock()
	defer l.mu.Unlock()
	if l.allocations == nil {
		l.allocations = map[string]*persistentAllocation{}
	}
	alloc, ok := l.allocations[key]
	if !ok {
		return app.GPULoadFileResult{
			Path:     req.Path,
			Loaded:   false,
			RefCount: 0,
			Message:  "persistent allocation already absent",
		}, nil
	}
	if alloc.importers == nil {
		alloc.importers = map[string]int{}
	}
	if count := alloc.importers[clientID]; count > 1 {
		alloc.importers[clientID] = count - 1
		if alloc.importerRefs > 0 {
			alloc.importerRefs--
		}
	} else if count == 1 {
		delete(alloc.importers, clientID)
		if alloc.importerRefs > 0 {
			alloc.importerRefs--
		}
	}

	return app.GPULoadFileResult{
		Path:      req.Path,
		Bytes:     alloc.bytes,
		Direct:    alloc.direct,
		Loaded:    true,
		RefCount:  alloc.loadRefs + alloc.importerRefs,
		DevicePtr: devicePtrString(alloc.ptr),
		Message:   "persistent allocation detached for client import",
	}, nil
}

func (l *gdsLoader) UnloadPersistent(ctx context.Context, req app.GPULoadFileRequest) (app.GPULoadFileResult, error) {
	select {
	case <-ctx.Done():
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitRegistry, app.ReasonRegistryTimeout, "context canceled before persistent GPU unload", ctx.Err())
	default:
	}
	key := allocKey(req.Device, req.Path)

	l.mu.Lock()
	defer l.mu.Unlock()
	if l.allocations == nil {
		l.allocations = map[string]*persistentAllocation{}
	}
	alloc, ok := l.allocations[key]
	if !ok {
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "persistent allocation not found for shard path", nil)
	}
	if alloc.loadRefs > 1 {
		alloc.loadRefs--
		return app.GPULoadFileResult{
			Path:      req.Path,
			Bytes:     0,
			Direct:    alloc.direct,
			Loaded:    false,
			RefCount:  alloc.loadRefs + alloc.importerRefs,
			DevicePtr: devicePtrString(alloc.ptr),
			Message:   "persistent allocation retained; active references remain",
		}, nil
	}
	if alloc.importerRefs > 0 {
		return app.GPULoadFileResult{}, app.NewAppError(app.ExitPolicy, app.ReasonLeaseConflict, fmt.Sprintf("persistent allocation has %d active importer reference(s)", alloc.importerRefs), nil)
	}
	code := int(C.gds_free_persistent(C.int(req.Device), alloc.ptr))
	if code != 0 {
		alloc.loadRefs = 1
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
	delete(l.allocations, key)
	if l.totalRefsLocked() == 0 && len(l.allocations) == 0 {
		_ = C.gds_shutdown()
		l.active = map[int]bool{}
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
	out := make([]app.GPULoadFileResult, 0, len(l.allocations))
	for path, alloc := range l.allocations {
		if alloc.device != device {
			continue
		}
		out = append(out, app.GPULoadFileResult{
			Path:      strings.TrimPrefix(path, fmt.Sprintf("%d|", device)),
			Bytes:     alloc.bytes,
			Direct:    alloc.direct,
			Loaded:    true,
			RefCount:  alloc.loadRefs + alloc.importerRefs,
			DevicePtr: devicePtrString(alloc.ptr),
			Message:   fmt.Sprintf("load_refs=%d importer_refs=%d", alloc.loadRefs, alloc.importerRefs),
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
