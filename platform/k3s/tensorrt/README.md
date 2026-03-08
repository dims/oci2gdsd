# TensorRT-LLM Workloads

Runtime-specific assets for TensorRT-LLM paths in k3s daemonset mode.

## Files

- `tensorrt-daemon-client-job.yaml.tpl`: daemon client workload job.
- `tensorrt_daemon_client.py`: engine build + `ModelRunnerCpp` flow with GDS checks.
- Reuses `platform/k3s/pytorch/native/oci2gds_torch_native.cpp` for CUDA IPC import utilities.

## Typical run

- `make verify-k3s-tensor`

## Parity mode

- `RUNTIME_PARITY_MODE=full` is required (path-backed modes removed).
- `make verify-k3s-tensor` always runs with `RUNTIME_PARITY_MODE=full`.
- TensorRT flow validates daemon `/v2/gpu/tensor-map` coverage before inference and emits:
  - `TENSORRT_IPC_TENSOR_MAP_OK`
  - `TENSORRT_IPC_BIND_OK`
  - `TENSORRT_IPC_IMPORT_OK`
- In `full` mode, runtime shards are materialized from daemon-exported IPC handles (`source=ipc_materialized`) and fallback reads are rejected (`fallback_reads=0`).

## Startup modes

- `TENSORRT_STARTUP_MODE=parity` (default): always rebuilds checkpoint+engine in the workload run.
- `TENSORRT_STARTUP_MODE=fast`: reuses a persistent engine cache when present and skips conversion/build on cache hit.
- Cache location is host-mounted at `TENSORRT_ENGINE_CACHE_HOST_PATH` (default `/mnt/nvme/oci2gdsd-tensorrt-cache`) and exposed in-container as `/var/cache/oci2gdsd/tensorrt`.

Example fast-mode runs (second run should hit cache):

```bash
TENSORRT_STARTUP_MODE=fast make verify-k3s-tensor
TENSORRT_STARTUP_MODE=fast make verify-k3s-tensor
```

Fast-mode cache behavior marker:

- `TENSORRT_ENGINE_FASTPATH_OK cache_hit=true built=false ...`
