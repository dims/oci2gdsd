# TensorRT-LLM Workloads

Runtime-specific assets for TensorRT-LLM paths in k3s daemonset mode.

## Files

- `tensorrt-daemon-client-job.yaml.tpl`: daemon client workload job.
- `tensorrt_daemon_client.py`: TensorRT-LLM daemon client with backend-selectable parity flow.
- Reuses `platform/k3s/pytorch/native/oci2gds_torch_native.cpp` for CUDA IPC import utilities.

## Typical run

- `make verify-k3s-tensor`

## Parity mode

- `RUNTIME_PARITY_MODE=full` is required (path-backed modes removed).
- `make verify-k3s-tensor` always runs with `RUNTIME_PARITY_MODE=full`.
- TensorRT-LLM PyTorch backend (`TENSORRTLLM_BACKEND=pytorch`, default) validates daemon `/v2/gpu/tensor-map` coverage before inference and emits:
  - `TENSORRT_IPC_TENSOR_MAP_OK`
  - `TENSORRT_IPC_BIND_OK`
  - `TENSORRT_IPC_IMPORT_OK`
  - `TENSORRTLLM_PYTORCH_RUNNER_READY`
  - `TENSORRT_PYTORCH_ALIAS_OK`
- In `full` mode for the PyTorch backend, TensorRT-LLM loads weights directly from daemon-exported tensor-map IPC views (`source=ipc_tensor_map`, `managed_weights_source=checkpoint_loader`) and rejects fallback reads (`fallback_reads=0`).
- The recommended PyTorch path uses a TensorRT-LLM release image built from `torch-alias-main-single` and points `TENSORRTLLM_RUNTIME_IMAGE` / `TENSORRTLLM_IMAGE` at that local tag.
- TensorRT backend (`TENSORRTLLM_BACKEND=tensorrt`) keeps the existing engine/materialization flow and emits `TENSORRT_MANAGED_WEIGHTS_ALIAS_OK`.

## Startup modes

- `TENSORRTLLM_BACKEND=pytorch` (default): `TENSORRT_STARTUP_MODE=parity` only. There is no engine-cache fast path in this mode.
  - Build the runtime image from the TensorRT-LLM `torch-alias-main-single` branch before running `make verify-k3s-tensor`.
- `TENSORRTLLM_BACKEND=tensorrt`: preserves the existing startup split.
  - `TENSORRT_STARTUP_MODE=parity`: always rebuilds checkpoint+engine in the workload run.
  - `TENSORRT_STARTUP_MODE=fast`: reuses a persistent engine cache when present and skips conversion/build on cache hit.
  - Cache location is host-mounted at `TENSORRT_ENGINE_CACHE_HOST_PATH` (default `/mnt/nvme/oci2gdsd-tensorrt-cache`) and exposed in-container as `/var/cache/oci2gdsd/tensorrt`.

Example PyTorch backend run:

```bash
cd /path/to/TensorRT-LLM
git checkout torch-alias-main-single
git lfs install
git lfs pull
make -C docker release_build IMAGE_TAG=torch-alias-main-single CUDA_ARCHS="80-real" GIT_COMMIT="$(git rev-parse --short HEAD)"

cd /path/to/oci2gdsd
TENSORRTLLM_BACKEND=pytorch \
TENSORRTLLM_RUNTIME_IMAGE=tensorrt_llm/release:torch-alias-main-single \
TENSORRTLLM_IMAGE=tensorrt_llm/release:torch-alias-main-single \
make verify-k3s-tensor
```

Example fast-mode runs (second run should hit cache):

```bash
TENSORRTLLM_BACKEND=tensorrt TENSORRT_STARTUP_MODE=fast make verify-k3s-tensor
TENSORRTLLM_BACKEND=tensorrt TENSORRT_STARTUP_MODE=fast make verify-k3s-tensor
```

Fast-mode cache behavior marker:

- `TENSORRT_ENGINE_FASTPATH_OK cache_hit=true built=false ...`
