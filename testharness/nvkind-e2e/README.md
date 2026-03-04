# nvkind local integration harness

This harness provisions a local `nvkind` Kubernetes cluster (works on Brev GPU instances), preloads an OCI model with `oci2gdsd` in an init container, runs a GPU-backed PyTorch smoke workload, and validates model lifecycle transitions (`READY` -> `RELEASED`).
It is designed to run directly by an operator on a machine and does not require GitHub Actions.

For host/provider qualification and strict direct-GDS recreate steps, see [`docs/direct-gds-recreate-runbook.md`](../../docs/direct-gds-recreate-runbook.md).
For host-only strict direct-GDS validation (without Kubernetes), see [`testharness/host-e2e/README.md`](../host-e2e/README.md).

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
make nvkind-e2e-prereq
make nvkind-e2e
```

`make nvkind-e2e-prereq` validates cluster/runtime/image prerequisites and auto-installs host packages by default (`INSTALL_MISSING_PREREQS=true`).
Set `INSTALL_MISSING_PREREQS=false` to run checks only.

Default storage gates enforced by prereq:

- `MIN_FREE_GB_DOCKER=100` on Docker `data-root`
- `MIN_FREE_GB_K3S=50` on k3s data-dir when `CLUSTER_MODE=k3s` (auto-detected from `/etc/rancher/k3s/config.yaml`, default `/var/lib/rancher/k3s`)
- `MIN_FREE_GB_OCI2GDS_ROOT=20` on `OCI2GDSD_ROOT_PATH`

If any gate fails, prereq aborts with remediation steps (attach/mount larger disk and move Docker `data-root`).

## Quick iteration loop

After one full `make nvkind-e2e` run has already created the cluster and packaged/pushed the model, use:

```bash
make nvkind-e2e-prereq
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

# Override workload image (default: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1)
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

# Default behavior is fail-fast GDS mode:
# - REQUIRE_DIRECT_GDS=true
# - OCI2GDS_STRICT=true
# - OCI2GDS_PROBE_STRICT=true
# - OCI2GDS_FORCE_NO_COMPAT=true
# - privileged container securityContext for GPU/GDS workload containers
# You can still set them explicitly:
REQUIRE_DIRECT_GDS=true OCI2GDS_STRICT=true OCI2GDS_PROBE_STRICT=true OCI2GDS_FORCE_NO_COMPAT=true make nvkind-e2e-qwen-quick

# qwen-hello profile selection:
# - `default`: generic settings
# - `host-direct`: hostPath-backed root (NVMe-friendly) + strict probes
# For k3s, default profile is `host-direct`.
QWEN_HELLO_PROFILE=host-direct make nvkind-e2e-qwen-quick

# Override root path used by init/app pod hostPath (defaults to /mnt/nvme/oci2gdsd in host-direct).
OCI2GDSD_ROOT_PATH=/mnt/nvme/oci2gdsd make nvkind-e2e-qwen-quick

# Explicit opt-out (debug only): relax strict/direct enforcement.
REQUIRE_DIRECT_GDS=false OCI2GDS_STRICT=false OCI2GDS_PROBE_STRICT=false OCI2GDS_FORCE_NO_COMPAT=false make nvkind-e2e-qwen-quick

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

# Override storage gates (GiB) if needed
MIN_FREE_GB_DOCKER=150 MIN_FREE_GB_K3S=80 MIN_FREE_GB_OCI2GDS_ROOT=40 make nvkind-e2e-prereq

# Override detected k3s data-dir explicitly (optional)
K3S_DATA_DIR=/mnt/nvme/k3s make nvkind-e2e-prereq
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
