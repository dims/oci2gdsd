# nvkind local integration harness

This harness provisions a local `nvkind` Kubernetes cluster (works on Brev GPU instances), preloads an OCI model with `oci2gdsd` in an init container, runs a GPU-backed PyTorch smoke workload, and validates model lifecycle transitions (`READY` -> `RELEASED`).
It is designed to run directly by an operator on a machine and does not require GitHub Actions.

## What it validates

- GPU-enabled Kubernetes with NVIDIA GPU Operator.
- Local OCI registry in-cluster for repeatable artifact tests.
- `oci2gdsd ensure/status/verify` in an init container.
- PyTorch container reading preloaded model files and running CUDA compute.
- Validation of `examples/qwen-hello` FastAPI + PyTorch deployment by issuing a real `/chat` request and verifying `/healthz` `oci2gds_profile` status fields.
- Optional strict gating on daemon IPC probe status (`REQUIRE_DAEMON_IPC_PROBE=true`).
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

# Override workload image (default uses the qwen-hello runtime image)
PYTORCH_IMAGE=pytorch/pytorch:2.4.1-cuda12.1-cudnn9-runtime make nvkind-e2e

# Reuse an already pushed model artifact and skip package/push
MODEL_REF_OVERRIDE=oci-model-registry.oci2gdsd-registry.svc.cluster.local:5000/models/qwen3-0.6b@sha256:... \
MODEL_DIGEST_OVERRIDE=sha256:... \
make nvkind-e2e

# Skip qwen-hello example validation (enabled by default)
VALIDATE_QWEN_HELLO=false make nvkind-e2e

# Skip local host GDS preflight (`gpu probe` + `gpu load --mode benchmark`)
VALIDATE_LOCAL_GDS=false make nvkind-e2e

# Optional: pre-load workload image(s) into kind nodes (default false)
PRELOAD_WORKLOAD_IMAGE=true make nvkind-e2e

# Optional: pre-load the qwen-hello PyTorch runtime image into kind nodes (default false)
PRELOAD_PYTORCH_RUNTIME_IMAGE=true make nvkind-e2e

# Optional: require daemon IPC probe to report status=ok (default false)
REQUIRE_DAEMON_IPC_PROBE=true make nvkind-e2e

# Build a GDS-capable oci2gdsd image for init/daemon containers
OCI2GDSD_ENABLE_GDS_IMAGE=true REQUIRE_DAEMON_IPC_PROBE=true make nvkind-e2e

# Or point to a custom Dockerfile for oci2gdsd image builds
OCI2GDSD_DOCKERFILE=testharness/nvkind-e2e/Dockerfile.oci2gdsd.gds make nvkind-e2e

# Force namespace/cluster names
CLUSTER_NAME=oci2gdsd-e2e E2E_NAMESPACE=oci2gdsd-e2e make nvkind-e2e

# Override CUDA toolkit locations used for local GDS preflight builds
CUDA_INCLUDE_DIR=/usr/local/cuda/include CUDA_LIB_DIR=/usr/local/cuda/lib64 make nvkind-e2e
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
