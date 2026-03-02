# qwen-hello

`qwen-hello` is a Kubernetes example that shows:

1. Packaging `Qwen/Qwen3-0.6B` as an OCI artifact with `OCI-ModelProfile-v1`.
2. Preloading model files with `oci2gdsd ensure` in an init container.
3. Running an `oci2gdsd serve` sidecar to keep persistent GPU allocations alive for the pod lifetime.
4. Running a FastAPI app that loads the model from local preloaded files using PyTorch + Transformers (offline mode).
5. Exercising `torch.ops.oci2gds.read_into_tensor`, `torch.ops.oci2gds.load_profile`, and a daemon IPC handoff probe at startup.

## What This Example Demonstrates

- Registry -> node-local OCI preload workflow.
- Deterministic runtime startup from local files (no Hugging Face network fetch at app start).
- Pod-local daemon API (`/v1/gpu/load`, `/v1/gpu/export`) for persistent allocation orchestration.
- A runtime `oci2gds` probe path with:
  - optional native cuFile backend (JIT C++ extension build),
  - automatic Python fallback when native prerequisites are missing.
- A CUDA IPC probe path (daemon export + PyTorch-side import-copy) for cross-process VRAM handoff verification.
- A simple `/chat` endpoint returning generated text.

## Current Limit

This example now includes a daemon-mediated IPC probe, but still does not remap the full transformer weight graph to daemon-owned VRAM pointers.
Model execution still uses framework-managed parameter loading from local files.

## Files

- `oci-model-registry.yaml`: In-cluster Docker registry deployment/service.
- `qwen-nvkind-hello-deployment.yaml.tpl`: Deployment template with:
  - `preload-model` init container (`oci2gdsd ensure`)
  - `pytorch-api` container (FastAPI + PyTorch runtime)
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
