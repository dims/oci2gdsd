#ifndef OCI2GDSD_GDS_LINUX_BRIDGE_H
#define OCI2GDSD_GDS_LINUX_BRIDGE_H

#include <cuda.h>
#include <cuda_runtime_api.h>
#include <cufile.h>

int gds_init(void);
int gds_shutdown(void);
int gds_device_count(int* count);
int gds_device_uuid(int device, char* out, int out_len);
int gds_device_name(int device, char* out, int out_len);
int gds_activate_device(int device, CUcontext* out_ctx);
int gds_read_file(const char* path, int device, long long chunk_bytes, int strict, long long* total_bytes, long long* elapsed_us);
int gds_load_persistent(const char* path, int device, long long chunk_bytes, int strict, CUdeviceptr* out_dptr, long long* total_bytes, long long* elapsed_us, int* out_direct);
int gds_free_persistent(int device, CUdeviceptr dptr);
int gds_export_ipc_handle(int device, CUdeviceptr dptr, unsigned char* out_handle, int out_handle_len);

#endif
