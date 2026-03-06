# DaemonSet Manifest Guide

This guide describes the raw-manifest deployment path for running `oci2gdsd serve`
as a node-level daemon and validating GPU load/export lifecycle from a workload pod.

Architecture overview: [architecture-diagram.md](architecture-diagram.md)
Runtime contract matrix: [runtime-contract-matrix.md](runtime-contract-matrix.md)

## Files

- `platform/k3s/shared/oci2gdsd-daemonset.yaml.tpl`
- `platform/k3s/pytorch/pytorch-daemon-client-job.yaml.tpl`
- `platform/k3s/pytorch/pytorch_daemon_client.py`
- `platform/k3s/tensorrt/tensorrt-daemon-client-job.yaml.tpl`
- `platform/k3s/tensorrt/tensorrt_daemon_client.py`
- `platform/k3s/vllm/vllm-daemon-client-job.yaml.tpl`
- `platform/k3s/vllm/vllm_daemon_client.py`

## What this mode does

1. Deploys a privileged `oci2gdsd` DaemonSet on GPU nodes.
   - Daemon pod uses `runtimeClassName: nvidia` and sets `NVIDIA_VISIBLE_DEVICES=all`.
2. Shares hostPath cache root and UNIX socket with workload pods.
3. Uses an init container (`ensure/status/verify`) to pull OCI model shards.
4. Runs a PyTorch workload that calls daemon APIs:
   - `POST /v1/gpu/load` (`mode=persistent`)
   - `POST /v1/gpu/export`
   - `POST /v1/gpu/tensor-map`
   - `POST /v1/gpu/attach`
   - `POST /v1/gpu/heartbeat`
   - `POST /v1/gpu/detach`
   - `GET /v1/gpu/status`
   - `POST /v1/gpu/unload`
5. Rebinds model parameter storage to daemon-exported CUDA IPC tensor views before generation.

For TensorRT-LLM daemon-client mode, the workload:

- In `probe`/`partial` mode, builds a TensorRT engine from ensured local model files.
- In `full` parity mode, materializes runtime shard files from daemon-exported CUDA IPC handles before conversion/build (`source=ipc_materialized`).
- Runs `ModelRunnerCpp.from_dir(..., use_gpu_direct_storage=True)`.
- Verifies daemon `gpu/tensor-map` IPC handle coverage for safetensors shards.
- Verifies native IPC import coverage and zero fallback in `full` mode.
- Verifies daemon `gpu/load` + `gpu/status` + `gpu/attach` + `gpu/heartbeat` + `gpu/detach` + `gpu/unload` lifecycle.
- Mounts host `/run/udev` and `/etc/cufile.json` so cuFile device registration
  can succeed for strict direct-GDS engine loading.

For vLLM daemon-client mode, the workload:

- Registers out-of-tree `load_format=oci2gds`.
- Uses daemon `gpu/tensor-map` output to drive IPC-sourced weight loading checks.
- In `full` parity mode, imports tensor-map entries via CUDA IPC and copies them into vLLM-owned parameter storage (including fused `qkv_proj` and `gate_up_proj` coverage).
- Supports parity modes (`RUNTIME_PARITY_MODE=off|probe|partial|full`) to gate how strict runtime coupling must be.

## Harness entrypoint (recommended)

```bash
make verify-k3s-daemonset
```

Contract-only validation (fast static gate):

```bash
make verify-k3s-runtime-contract
make verify-k3s-runtime-contract-all
```

TensorRT-LLM daemon-client run:

```bash
make verify-k3s-tensor-e2e-daemonset
```

vLLM daemon-client run (out-of-tree loader plugin):

```bash
make verify-k3s-vllm-e2e-daemonset
```

Parity-focused runtime checks:

```bash
make verify-k3s-tensor-e2e-daemonset-parity
make verify-k3s-vllm-e2e-daemonset-parity
make verify-k3s-daemonset-parity-all
```

Equivalent explicit mode toggle:

```bash
E2E_DEPLOY_MODE=daemonset-manifest make verify-k3s
```

## Key environment variables

- `OCI2GDSD_DAEMON_NAMESPACE` (default `oci2gdsd-daemon`)
- `OCI2GDSD_SOCKET_HOST_PATH` (default `/var/run/oci2gdsd`)
- `OCI2GDSD_ROOT_PATH` (default `/mnt/nvme/oci2gdsd` in host-direct profile)
- `REQUIRE_DIRECT_GDS` (default `true`)
- `WORKLOAD_RUNTIME` (`pytorch`, `tensorrt`, or `vllm`; default `pytorch`)
- `RUNTIME_PARITY_MODE` (`off`, `probe`, `partial`, `full`; default `probe`)
- `REQUIRE_FULL_IPC_BIND` (default `false`, currently used by vLLM parity flow)

## Contract enforcement

The harness validates runtime manifest contracts before deployment using:

- `platform/k3s/contracts/runtime-contract.v1.json`
- `platform/k3s/scripts/validate-runtime-contract.sh`

Checks run during both prereq (`make prereq-k3s`) and k3s e2e run paths.
Failures emit `platform/k3s/work/artifacts/results/runtime-contract-report.json`.

## Success markers

The daemon-client workload log (`platform/k3s/work/artifacts/results/pytorch-daemon-client.log`) must include:

- `DAEMON_GPU_LOAD_READY`
- `DAEMON_GPU_EXPORT_OK`
- `DAEMON_GPU_ATTACH_OK`
- `DAEMON_GPU_HEARTBEAT_OK`
- `DAEMON_GPU_STATUS_OK`
- `DAEMON_QWEN_IPC_BIND_OK`
- `DAEMON_GPU_DETACH_OK`
- `DAEMON_GPU_UNLOAD_OK`
- `PYTORCH_DAEMON_CLIENT_SUCCESS`

TensorRT daemon-client log (`platform/k3s/work/artifacts/results/tensorrt-daemon-client.log`) must include:

- `DAEMON_GPU_LOAD_READY`
- `DAEMON_GPU_STATUS_OK`
- `DAEMON_GPU_ATTACH_OK`
- `DAEMON_GPU_HEARTBEAT_OK`
- `TENSORRT_IPC_TENSOR_MAP_OK`
- `TENSORRT_IPC_BIND_OK`
- `TENSORRT_IPC_IMPORT_OK`
- `TENSORRT_ENGINE_BUILD_OK`
- `TENSORRT_GDS_RUNNER_READY`
- `TENSORRT_QWEN_INFER_OK`
- `DAEMON_GPU_DETACH_OK`
- `DAEMON_GPU_UNLOAD_OK`
- `TENSORRT_DAEMON_CLIENT_SUCCESS`

For `RUNTIME_PARITY_MODE=full`, harness also validates:

- `TENSORRT_IPC_BIND_OK status=ok`
- `TENSORRT_IPC_IMPORT_OK status=ok unresolved_shards=0`
- `TENSORRT_FULL_SOURCE_OK source=ipc_materialized fallback_reads=0`

vLLM daemon-client log (`platform/k3s/work/artifacts/results/vllm-daemon-client.log`) must include:

- `DAEMON_GPU_LOAD_READY`
- `DAEMON_GPU_STATUS_OK`
- `DAEMON_GPU_ATTACH_OK`
- `DAEMON_GPU_HEARTBEAT_OK`
- `VLLM_IPC_TENSOR_MAP_OK`
- `VLLM_IPC_BIND_OK`
- `VLLM_LOADER_REGISTERED`
- `VLLM_OCI2GDS_LOAD_OK`
- `VLLM_QWEN_INFER_OK`
- `DAEMON_GPU_DETACH_OK`
- `DAEMON_GPU_UNLOAD_OK`
- `VLLM_DAEMON_CLIENT_SUCCESS`

For `RUNTIME_PARITY_MODE=full`, harness also validates:

- `VLLM_IPC_BIND_OK status=ok`
- `VLLM_IPC_BIND_OK ... unresolved=0`
- `VLLM_IPC_BIND_OK ... rebound_params>0`

The harness also checks preload readiness (`"status": "READY"`) and runs release/gc validation.
