//go:build linux && cgo && gds
// +build linux,cgo,gds

#define _GNU_SOURCE
#include "gds_linux_bridge.h"
#include <cuda.h>
#include <cuda_runtime_api.h>
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

int gds_init() {
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

int gds_shutdown() {
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

int gds_device_count(int* count) {
	CUresult cui = cuInit(0);
	if (cui != CUDA_SUCCESS) return 1000 + (int)cui;
	CUresult cu = cuDeviceGetCount(count);
	if (cu != CUDA_SUCCESS) return 1000 + (int)cu;
	return 0;
}

int gds_device_uuid(int device, char* out, int out_len) {
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

int gds_device_name(int device, char* out, int out_len) {
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

int gds_activate_device(int device, CUcontext* out_ctx) {
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

int gds_read_file(const char* path, int device, long long chunk_bytes, int strict, long long* total_bytes, long long* elapsed_us) {
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

int gds_load_persistent(const char* path, int device, long long chunk_bytes, int strict, CUdeviceptr* out_dptr, long long* total_bytes, long long* elapsed_us, int* out_direct) {
	CUresult cu;
	cudaError_t crt;
	CUcontext prev_ctx = NULL;
	struct stat st;
	int rc = 0;
	int fd = -1;
	CUfileHandle_t cfh;
	CUdeviceptr dptr = 0;
	void* dptr_raw = NULL;
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
	void* tail_raw = NULL;
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

	crt = cudaSetDevice(device);
	if (crt != cudaSuccess) {
		rc = 5000 + (int)crt;
		goto cleanup;
	}
	crt = cudaMalloc(&dptr_raw, (size_t)file_size);
	if (crt != cudaSuccess) {
		rc = 5000 + (int)crt;
		goto cleanup;
	}
	dptr = (CUdeviceptr)(uintptr_t)dptr_raw;

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

		crt = cudaMalloc(&tail_raw, 4096);
		if (crt != cudaSuccess) {
			if (strict) {
				rc = 5000 + (int)crt;
				goto cleanup;
			}
			direct_only = 0;
		}
		tail_dptr = (CUdeviceptr)(uintptr_t)tail_raw;
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
			(void)cudaFree((void*)(uintptr_t)tail_dptr);
			tail_dptr = 0;
			tail_raw = NULL;
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
		(void)cudaFree((void*)(uintptr_t)tail_dptr);
	}
	if (buf_registered) {
		(void)cuFileBufDeregister((void*)(uintptr_t)dptr);
	}
	if (dptr != 0) {
		(void)cudaFree((void*)(uintptr_t)dptr);
	}
	if (handle_registered) {
		(void)cuFileHandleDeregister(cfh);
	}
	if (fd >= 0) {
		(void)close(fd);
	}
	return rc;
}

int gds_free_persistent(int device, CUdeviceptr dptr) {
	CUresult cu;
	cudaError_t crt;
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

	crt = cudaSetDevice(device);
	if (crt != cudaSuccess) {
		rc = 5000 + (int)crt;
		goto cleanup;
	}
	crt = cudaFree((void*)(uintptr_t)dptr);
	if (crt != cudaSuccess) {
		rc = 5000 + (int)crt;
	}
cleanup:
	if (ctx_pushed) {
		(void)cuCtxPopCurrent(&prev_ctx);
	}
	return rc;
}

int gds_export_ipc_handle(int device, CUdeviceptr dptr, unsigned char* out_handle, int out_handle_len) {
	CUresult cu;
	cudaError_t crt;
	CUcontext prev_ctx = NULL;
	CUcontext active_ctx = NULL;
	int rc = 0;
	int ctx_pushed = 0;
	cudaIpcMemHandle_t handle;

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

	crt = cudaSetDevice(device);
	if (crt != cudaSuccess) {
		rc = 5000 + (int)crt;
		goto cleanup;
	}
	crt = cudaIpcGetMemHandle(&handle, (void*)(uintptr_t)dptr);
	if (crt != cudaSuccess) {
		rc = 5000 + (int)crt;
		goto cleanup;
	}
	memcpy(out_handle, &handle, sizeof(cudaIpcMemHandle_t));

cleanup:
	if (ctx_pushed) {
		(void)cuCtxPopCurrent(&prev_ctx);
	}
	return rc;
}
