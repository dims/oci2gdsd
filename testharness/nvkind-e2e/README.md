# nvkind local integration harness

This harness provisions a local `nvkind` Kubernetes cluster (works on Brev GPU instances), preloads an OCI model with `oci2gdsd` in an init container, runs a GPU-backed PyTorch smoke workload, and validates model lifecycle transitions (`READY` -> `RELEASED`).
It is designed to run directly by an operator on a machine and does not require GitHub Actions.

## What it validates

- GPU-enabled Kubernetes with NVIDIA GPU Operator.
- Local OCI registry in-cluster for repeatable artifact tests.
- `oci2gdsd ensure/status/verify` in an init container.
- PyTorch container reading preloaded model files and running CUDA compute.
- Validation of `examples/qwen-hello` FastAPI + vLLM deployment by issuing a real `/chat` request.
- `oci2gdsd release + gc + status` on the same node as workload pod.

## Run

From repo root:

```bash
make nvkind-e2e
```

## Common overrides

```bash
# Use a different model source
HF_REPO=Qwen/Qwen3-0.6B HF_REVISION=main make nvkind-e2e

# Override workload image (default uses the vLLM runtime image)
PYTORCH_IMAGE=pytorch/pytorch:2.4.1-cuda12.1-cudnn9-runtime make nvkind-e2e

# Reuse an already pushed model artifact and skip package/push
MODEL_REF_OVERRIDE=oci-model-registry.oci2gdsd-registry.svc.cluster.local:5000/models/qwen3-0.6b@sha256:... \
MODEL_DIGEST_OVERRIDE=sha256:... \
make nvkind-e2e

# Skip qwen-hello example validation (enabled by default)
VALIDATE_QWEN_HELLO=false make nvkind-e2e

# Optional: pre-load workload image(s) into kind nodes (default false)
PRELOAD_WORKLOAD_IMAGE=true make nvkind-e2e

# Optional: pre-load the large vLLM runtime image into kind nodes (default false)
PRELOAD_VLLM_RUNTIME_IMAGE=true make nvkind-e2e

# Force namespace/cluster names
CLUSTER_NAME=oci2gdsd-e2e E2E_NAMESPACE=oci2gdsd-e2e make nvkind-e2e
```

## Cleanup

```bash
make nvkind-e2e-clean
```

## Artifacts

Logs are written under:

- `testharness/nvkind-e2e/work/results/preload.log`
- `testharness/nvkind-e2e/work/results/pytorch.log`
- `testharness/nvkind-e2e/work/results/qwen-hello.log`
- `testharness/nvkind-e2e/work/results/release-gc.log`
