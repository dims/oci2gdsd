# nvkind local integration harness

This harness provisions a local `nvkind` Kubernetes cluster (works on Brev GPU instances), preloads an OCI model with `oci2gdsd` in an init container, runs a GPU-backed PyTorch smoke workload, and validates model lifecycle transitions (`READY` -> `RELEASED`).
It is designed to run directly by an operator on a machine and does not require GitHub Actions.

For host/provider qualification and strict direct-GDS recreate steps, see [`docs/direct-gds-recreate-runbook.md`](../../docs/direct-gds-recreate-runbook.md).

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

## Quick iteration loop

After one full `make nvkind-e2e` run has already created the cluster and packaged/pushed the model, use:

```bash
make nvkind-e2e-qwen-quick
```

This script only:

- re-renders and reapplies `examples/qwen-hello/qwen-nvkind-hello-deployment.yaml.tpl`
- waits for rollout
- probes `/healthz` and `/chat`
- writes logs to `testharness/nvkind-e2e/work/results/qwen-hello.log`

It supports both cluster modes:

- `CLUSTER_MODE=kind` (default)
- `CLUSTER_MODE=k3s` (host-native k3s on Brev/Ubuntu)

For host-native k3s quick iteration:

```bash
CLUSTER_MODE=k3s \
REGISTRY_NAMESPACE=oci-model-registry \
MODEL_REF_OVERRIDE=oci-model-registry.oci-model-registry.svc.cluster.local:5000/models/qwen3-0.6b@sha256:... \
MODEL_DIGEST_OVERRIDE=sha256:... \
make nvkind-e2e-qwen-quick
```

When `CLUSTER_MODE=k3s`, the quick script enforces NVIDIA runtime compatibility by setting:

- `accept-nvidia-visible-devices-envvar-when-unprivileged=true`

and restarting `k3s` only when a change is required.

When `REQUIRE_DIRECT_GDS=true`, quick iterate also runs `gdscheck -p` preflight.
If `gdscheck` reports `NVMe : Unsupported`, true direct path is not available on that host and the run fails fast.

If you want to override the model identity explicitly:

```bash
MODEL_REF_OVERRIDE=oci-model-registry.oci2gdsd-registry.svc.cluster.local:5000/models/qwen3-0.6b@sha256:... \
MODEL_DIGEST_OVERRIDE=sha256:... \
make nvkind-e2e-qwen-quick
```

## Common overrides

```bash
# Use a different model source
HF_REPO=Qwen/Qwen3-0.6B HF_REVISION=main make nvkind-e2e

# Override workload image (default: pytorch/pytorch:2.10.0-cuda12.8-cudnn9-runtime)
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

# Optional: require daemon IPC probe to report status=ok
# (default: true when OCI2GDSD_ENABLE_GDS_IMAGE=true, otherwise false)
REQUIRE_DAEMON_IPC_PROBE=true make nvkind-e2e

# Optional: require direct GDS reads in qwen-hello profile probe
# Runs host preflight (`gdscheck -p`) and fails if NVMe direct support is unavailable,
# then fails if mode_counts.direct is 0.
REQUIRE_DIRECT_GDS=true make nvkind-e2e-qwen-quick

# qwen-hello profile selection:
# - `default`: generic settings
# - `host-direct`: hostPath-backed root (NVMe-friendly) + strict probes
# For k3s, default profile is `host-direct`.
QWEN_HELLO_PROFILE=host-direct make nvkind-e2e-qwen-quick

# Override root path used by init/app pod hostPath (defaults to /mnt/nvme/oci2gdsd in host-direct).
OCI2GDSD_ROOT_PATH=/mnt/nvme/oci2gdsd make nvkind-e2e-qwen-quick

# Override strict probe behavior (host-direct defaults these to true unless explicitly set).
OCI2GDS_STRICT=true OCI2GDS_PROBE_STRICT=true make nvkind-e2e-qwen-quick

# Build a GDS-capable oci2gdsd image for init/daemon containers
OCI2GDSD_ENABLE_GDS_IMAGE=true REQUIRE_DAEMON_IPC_PROBE=true make nvkind-e2e

# Build a dedicated qwen runtime image with oci2gdsd + libcufile and load it into kind
# (default false; enable explicitly when needed)
BUILD_QWEN_GDS_RUNTIME_IMAGE=true make nvkind-e2e

# Or point to a custom Dockerfile for oci2gdsd image builds
OCI2GDSD_DOCKERFILE=testharness/nvkind-e2e/Dockerfile.oci2gdsd.gds make nvkind-e2e

# Use a prebuilt oci2gdsd image and skip local build/load into kind
# (useful for large CUDA/GDS images pushed to a registry)
SKIP_OCI2GDSD_IMAGE_BUILD=true SKIP_OCI2GDSD_IMAGE_LOAD=true \
OCI2GDSD_IMAGE=<registry>/<repo>:<tag> make nvkind-e2e

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
