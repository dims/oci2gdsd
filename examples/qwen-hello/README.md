# qwen-hello

`qwen-hello` is a Kubernetes example that shows:

1. Packaging `Qwen/Qwen3-0.6B` as an OCI artifact with `OCI-ModelProfile-v1`.
2. Preloading model files with `oci2gdsd ensure` in an init container.
3. Running `oci2gdsd serve` inside the GPU application container, so daemon GPU-load/export paths can use the same allocated device.
4. Running a FastAPI app that loads the model from local preloaded files using PyTorch + Transformers (offline mode).
5. Exercising `torch.ops.oci2gds.read_into_tensor`, `torch.ops.oci2gds.load_profile`, and a daemon IPC handoff probe at startup.

## What This Example Demonstrates

- Registry -> node-local OCI preload workflow.
- Deterministic runtime startup from local files (no Hugging Face network fetch at app start).
- Pod-local daemon API (`/v1/gpu/load`, `/v1/gpu/export`) for persistent allocation orchestration (running in-process with the app container).
- A runtime `oci2gds` probe path with:
  - optional native cuFile backend (JIT C++ extension build),
  - automatic Python fallback when native prerequisites are missing.
- A CUDA IPC probe path (daemon export + PyTorch-side import-copy) for cross-process VRAM handoff verification.
- A simple `/chat` endpoint returning generated text.

## Current Limit

This example now includes a daemon-mediated IPC probe, but still does not remap the full transformer weight graph to daemon-owned VRAM pointers.
Model execution still uses framework-managed parameter loading from local files.

## k3s Runtime Note

For host-native `k3s` clusters, the pod should run with `runtimeClassName: nvidia` so the NVIDIA container runtime injects CUDA driver libraries and devices correctly.
The e2e harness `host-direct` profile (default for `k3s`) uses hostPath root `/mnt/nvme/oci2gdsd` and enables strict oci2gds probe flags to test direct-path behavior.

If CUDA appears unavailable in pods (`torch.cuda.is_available() == False` while `/dev/nvidia*` exists), verify:

- `/etc/nvidia-container-runtime/config.toml` has `accept-nvidia-visible-devices-envvar-when-unprivileged=true`
- `k3s` is restarted after that change
- no manual hostPath mounts are forcing `libcuda.so.1` into the container (these can conflict with NVIDIA runtime hooks)

## Files

- `oci-model-registry.yaml`: In-cluster Docker registry deployment/service.
- `qwen-nvkind-hello-deployment.yaml.tpl`: Deployment template with:
  - `preload-model` init container (`oci2gdsd ensure`)
  - `pytorch-api` container (runs `oci2gdsd serve` + FastAPI + PyTorch runtime)
- `app/qwen_server.py`: FastAPI + PyTorch + `torch.ops.oci2gds` startup/runtime logic.
- `app/deps_bootstrap.py`: runtime dependency bootstrap script used by the pod command.
- `native/oci2gds_torch_native.cpp`: shared native extension source used by both qwen app and host probe.
- `Dockerfile.vllm-runtime-gds`: Optional qwen runtime image with `oci2gdsd` + `libcufile` for native probe experiments.
- `qwen-packager-hello-world.md`: Local packager walkthrough.
- `qwen-packager-nvkind-hello-world.md`: End-to-end nvkind walkthrough.

## Quick Start (Automated)

From repo root, run the nvkind harness:

```bash
make nvkind-e2e
```

To run qwen-hello validation specifically (enabled by default):

```bash
VALIDATE_QWEN_HELLO=true make nvkind-e2e
```

Harness docs: [`testharness/nvkind-e2e/README.md`](../../testharness/nvkind-e2e/README.md)

## Manual Walkthrough

Use:

- [`qwen-packager-nvkind-hello-world.md`](./qwen-packager-nvkind-hello-world.md)

It covers:

- creating `nvkind` cluster
- starting in-cluster registry
- packaging + pushing Qwen artifact
- rendering and applying the deployment template
- calling `/healthz` and `/chat`
