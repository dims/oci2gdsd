# TensorRT-LLM Workloads

Runtime-specific assets for TensorRT-LLM paths in k3s daemonset mode.

## Files

- `tensorrt-daemon-client-job.yaml.tpl`: daemon client workload job.
- `tensorrt_daemon_client.py`: engine build + `ModelRunnerCpp` flow with GDS checks.
- Reuses `platform/k3s/pytorch/native/oci2gds_torch_native.cpp` for CUDA IPC import utilities.

## Typical run

- `make verify-k3s-tensor-e2e-daemonset`

## Parity mode

- `RUNTIME_PARITY_MODE=probe|partial|full`
- `make verify-k3s-tensor-e2e-daemonset-parity` runs with `RUNTIME_PARITY_MODE=full`.
- TensorRT flow validates daemon `/v1/gpu/tensor-map` coverage before inference and emits:
  - `TENSORRT_IPC_TENSOR_MAP_OK`
  - `TENSORRT_IPC_BIND_OK`
  - `TENSORRT_IPC_IMPORT_OK`
- In `full` mode, runtime shards are materialized from daemon-exported IPC handles (`source=ipc_materialized`) and fallback reads are rejected (`fallback_reads=0`).
