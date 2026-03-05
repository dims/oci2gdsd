# DaemonSet Manifest Guide

This guide describes the raw-manifest deployment path for running `oci2gdsd serve`
as a node-level daemon and validating GPU load/export lifecycle from a workload pod.

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
   - `POST /v1/gpu/attach`
   - `POST /v1/gpu/heartbeat`
   - `POST /v1/gpu/detach`
   - `GET /v1/gpu/status`
   - `POST /v1/gpu/unload`
5. Rebinds model parameter storage to daemon-exported CUDA IPC tensor views before generation.

For TensorRT-LLM daemon-client mode, the workload:

- Builds a TensorRT engine from the ensured local model files.
- Runs `ModelRunnerCpp.from_dir(..., use_gpu_direct_storage=True)`.
- Verifies daemon `gpu/load` + `gpu/status` + `gpu/unload` lifecycle.
- Mounts host `/run/udev` and `/etc/cufile.json` so cuFile device registration
  can succeed for strict direct-GDS engine loading.

## Harness entrypoint (recommended)

```bash
make verify-k3s-qwen-e2e-daemonset
```

TensorRT-LLM daemon-client run:

```bash
make verify-k3s-tensor-e2e-daemonset
```

vLLM daemon-client run (out-of-tree loader plugin):

```bash
make verify-k3s-vllm-e2e-daemonset
```

Equivalent explicit mode toggle:

```bash
E2E_DEPLOY_MODE=daemonset-manifest make verify-k3s-qwen-e2e-inline
```

## Key environment variables

- `OCI2GDSD_DAEMON_NAMESPACE` (default `oci2gdsd-daemon`)
- `OCI2GDSD_SOCKET_HOST_PATH` (default `/var/run/oci2gdsd`)
- `OCI2GDSD_ROOT_PATH` (default `/mnt/nvme/oci2gdsd` in host-direct profile)
- `REQUIRE_DIRECT_GDS` (default `true`)
- `WORKLOAD_RUNTIME` (`pytorch`, `tensorrt`, or `vllm`; default `pytorch`)

## Success markers

The daemon-client workload log (`platform/k3s/work/results/pytorch-daemon-client.log`) must include:

- `DAEMON_GPU_LOAD_READY`
- `DAEMON_GPU_EXPORT_OK`
- `DAEMON_GPU_ATTACH_OK`
- `DAEMON_GPU_HEARTBEAT_OK`
- `DAEMON_GPU_STATUS_OK`
- `DAEMON_QWEN_IPC_BIND_OK`
- `DAEMON_GPU_DETACH_OK`
- `DAEMON_GPU_UNLOAD_OK`
- `PYTORCH_DAEMON_CLIENT_SUCCESS`

TensorRT daemon-client log (`platform/k3s/work/results/tensorrt-daemon-client.log`) must include:

- `DAEMON_GPU_LOAD_READY`
- `DAEMON_GPU_STATUS_OK`
- `TENSORRT_ENGINE_BUILD_OK`
- `TENSORRT_GDS_RUNNER_READY`
- `TENSORRT_QWEN_INFER_OK`
- `DAEMON_GPU_UNLOAD_OK`
- `TENSORRT_DAEMON_CLIENT_SUCCESS`

vLLM daemon-client log (`platform/k3s/work/results/vllm-daemon-client.log`) must include:

- `DAEMON_GPU_LOAD_READY`
- `DAEMON_GPU_STATUS_OK`
- `VLLM_LOADER_REGISTERED`
- `VLLM_OCI2GDS_LOAD_OK`
- `VLLM_QWEN_INFER_OK`
- `DAEMON_GPU_UNLOAD_OK`
- `VLLM_DAEMON_CLIENT_SUCCESS`

The harness also checks preload readiness (`"status": "READY"`) and runs release/gc validation.
