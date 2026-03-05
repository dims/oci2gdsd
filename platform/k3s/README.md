# k3s local integration harness

This harness targets host-native `k3s` (works on Brev GPU instances), preloads an OCI model with `oci2gdsd` in an init container, runs a GPU-backed workload (PyTorch, TensorRT-LLM, or vLLM daemon-client mode), and validates model lifecycle transitions (`READY` -> `RELEASED`).
It is designed to run directly by an operator on a machine and does not require GitHub Actions.

For host/provider qualification and strict direct-GDS recreate steps, see [`docs/direct-gds-recreate-runbook.md`](../../docs/direct-gds-recreate-runbook.md).
For host-only strict direct-GDS validation (without Kubernetes), see [`platform/host/README.md`](../host/README.md).

## What it validates

- GPU-enabled Kubernetes with NVIDIA GPU Operator.
- Local OCI registry in-cluster for repeatable artifact tests.
- `oci2gdsd ensure/status/verify` in an init container.
- PyTorch container reading preloaded model files and running CUDA compute.
- Optional raw-manifest DaemonSet mode (`E2E_DEPLOY_MODE=daemonset-manifest`) where
  `oci2gdsd serve` is node-level and workloads call daemon GPU APIs directly.
- Validation of the PyTorch qwen workload under `platform/k3s/pytorch`
  by issuing a real `/chat` request and verifying `/healthz` `oci2gds_profile`
  status fields.
- Optional strict gating on daemon IPC probe status (`REQUIRE_DAEMON_IPC_PROBE=true`).
- `oci2gdsd release + gc + status` on the same node as workload pod.

## Workload Layout

- `platform/k3s/shared/`
  - `oci2gdsd-daemonset.yaml.tpl`: shared daemonset stack for `oci2gdsd serve`.
- `platform/k3s/pytorch/`
  - PyTorch daemon-client assets plus the qwen-hello deployment/app/native sources.
- `platform/k3s/tensorrt/`
  - TensorRT-LLM daemon-client manifest and client script.
- `platform/k3s/vllm/`
  - vLLM daemon-client manifest and client script.

## Run

From repo root:

```bash
make prereq
make verify-smoke
make verify-k3s
```

Beginner GPU host walkthrough: [`docs/quickstart-a100.md`](../../docs/quickstart-a100.md)

Primary env defaults/overrides:

- `platform/k3s/.env.defaults`
- `platform/k3s/.env.example`

Prereq hierarchy:
- Stage 0: `prereq-local`
- Stage 1: `prereq-host-gds` (strict host direct-GDS)
- Stage 2: `prereq-k3s` (cluster/runtime checks)

Raw-manifest DaemonSet path (no Helm):

```bash
make verify-k3s-daemonset
make verify-k3s-daemonset-all
```

`make prereq-k3s` validates cluster/runtime/image prerequisites and auto-installs host packages by default (`INSTALL_MISSING_PREREQS=true`) after running stages 0 and 1.
It does not mutate GPU driver/kernel packages automatically.
Set `INSTALL_MISSING_PREREQS=false` to run checks only.

Default storage gates enforced by prereq:

- `MIN_FREE_GB_DOCKER=100` on Docker `data-root`
- `MIN_FREE_GB_K3S=50` on k3s data-dir (auto-detected from `/etc/rancher/k3s/config.yaml`, default `/var/lib/rancher/k3s`)
- `MIN_FREE_GB_OCI2GDS_ROOT=20` on `OCI2GDSD_ROOT_PATH`

If any gate fails, prereq aborts with remediation steps (attach/mount larger disk and move Docker `data-root`).

## Quick iteration loop

Fresh A100 minimum path (intern-friendly):

```bash
make verify-k3s-qwen-smoke
make verify-host-qwen-smoke
```

After any host reboot, verify NVMe mount persistence before running quick targets:

```bash
mountpoint -q /mnt/nvme || sudo mount -t ext4 -o rw,noatime,data=ordered /dev/nvme0n1p1 /mnt/nvme
docker info --format '{{.DockerRootDir}}'
df -h /mnt/nvme /
```

Base dev toolchain expected on the host for full repo workflows:

- `go` (for `make verify-unit` and source builds)
- `make`
- `c++`/build headers (native extension/probe compilation path)

`make verify-k3s-qwen-smoke` now auto-handles the common first-run setup:

- checks/installs prerequisites
- installs host k3s automatically when `k3s` is missing
- installs GDS user-space tools (`gdscheck`/`gdsio`) when `REQUIRE_DIRECT_GDS=true` and missing
- auto-configures storage to `/mnt/nvme` when root disk is too small (unless `AUTO_CONFIGURE_STORAGE=false`)
- builds and loads `oci2gdsd` image into cluster (unless `AUTO_BUILD_OCI2GDSD_IMAGE=false`)
- installs GPU Operator if `nvidia.com/gpu` is not allocatable (unless `AUTO_INSTALL_GPU_OPERATOR=false`)
  - pinned chart version defaults to `GPU_OPERATOR_CHART_VERSION=v25.10.1`
- auto-seeds model identity + in-cluster registry packaging if missing (unless `AUTO_SEED_MODEL_IDENTITY=false`)

If pods fail with `No help topic for 'enable-cuda-compat'`, upgrade container toolkit and restart runtimes:

```bash
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  nvidia-container-toolkit=1.18.2-1 \
  nvidia-container-toolkit-base=1.18.2-1 \
  nvidia-container-runtime=3.14.0-1 \
  libnvidia-container-tools=1.18.2-1 \
  libnvidia-container1=1.18.2-1
sudo systemctl restart docker
sudo systemctl restart k3s
```

After that, `make verify-host-qwen-smoke` validates host direct-GDS with the model now present under `OCI2GDSD_ROOT_PATH`.

By default this harness is strict (`REQUIRE_DIRECT_GDS=true`). If `gdscheck -p` reports
`NVMe : compat/Unsupported`, the target requires strict functional proof from
`gdsio -x 0 -I 1` on the workload path plus NVFS registration evidence
(`devices` non-empty or `modules` contains `nvme`). It runs a non-destructive remediation attempt
first, then fails if neither `gdscheck` nor strict `gdsio` proves direct NVMe path.

If you prefer explicit staged runs:

```bash
make prereq-k3s
make verify-k3s-qwen-smoke
```

This script only:

- re-renders and reapplies `platform/k3s/pytorch/qwen-k3s-hello-deployment.yaml.tpl`
- applies qwen app/native ConfigMaps from standalone files under `platform/k3s/pytorch/app` and `platform/k3s/pytorch/native`
- waits for rollout
- probes `/healthz` and `/chat`
- writes logs to `platform/k3s/work/artifacts/results/qwen-hello.log`

For host-native k3s quick iteration:

```bash
REGISTRY_NAMESPACE=oci-model-registry \
MODEL_REF_OVERRIDE=oci-model-registry.oci-model-registry.svc.cluster.local:5000/models/qwen3-0.6b@sha256:... \
MODEL_DIGEST_OVERRIDE=sha256:... \
make verify-k3s-qwen-smoke
```

## Model Identity For Quick Runs

`make verify-k3s-qwen-smoke` needs a model digest and in-cluster OCI ref.
By default, missing identity is auto-seeded (`AUTO_SEED_MODEL_IDENTITY=true`).
There are three supported ways to provide this:

1. Run `make verify-k3s` once on the same host.
This generates `platform/k3s/work/packager/output/manifest-descriptor.json`,
which quick mode can reuse automatically.

2. Pass explicit overrides (recommended for repeatability):

```bash
MODEL_DIGEST_OVERRIDE=sha256:<digest> \
MODEL_REF_OVERRIDE=oci-model-registry.oci-model-registry.svc.cluster.local:5000/models/qwen3-0.6b@sha256:<digest> \
make verify-k3s-qwen-smoke
```

3. Derive digest from preloaded host model cache and export overrides:

```bash
digest_dir="$(ls -1dt /mnt/nvme/oci2gdsd/models/qwen3-0.6b/sha256-* | head -n1)"
digest="sha256:${digest_dir##*/sha256-}"
export MODEL_DIGEST_OVERRIDE="${digest}"
export MODEL_REF_OVERRIDE="oci-model-registry.oci-model-registry.svc.cluster.local:5000/models/qwen3-0.6b@${digest}"
make verify-k3s-qwen-smoke
```

If you use a non-default registry service/namespace, replace
`oci-model-registry.oci-model-registry.svc.cluster.local:5000` accordingly.

The quick script enforces NVIDIA runtime compatibility by setting:

- `accept-nvidia-visible-devices-envvar-when-unprivileged=true`

and restarting `k3s` only when a change is required.

When `REQUIRE_DIRECT_GDS=true`, quick iterate runs `gdscheck -p` plus strict
`gdsio -x 0 -I 1` functional preflight. If preflight is not direct-ready, the harness
attempts non-destructive remediation by default. It only fails immediately when a hard
blocker is detected (for example no guest-visible `/dev/nvme*`).

If you want to override the model identity explicitly:

```bash
MODEL_REF_OVERRIDE=oci-model-registry.oci-model-registry.svc.cluster.local:5000/models/qwen3-0.6b@sha256:... \
MODEL_DIGEST_OVERRIDE=sha256:... \
make verify-k3s-qwen-smoke
```

## Common overrides

```bash
# Use a different model source
HF_REPO=Qwen/Qwen3-0.6B HF_REVISION=main make verify-k3s

# Override workload image (default pinned digest of nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1)
PYTORCH_IMAGE=pytorch/pytorch:2.4.1-cuda12.1-cudnn9-runtime make verify-k3s

# Reuse an already pushed model artifact and skip package/push
MODEL_REF_OVERRIDE=oci-model-registry.oci-model-registry.svc.cluster.local:5000/models/qwen3-0.6b@sha256:... \
MODEL_DIGEST_OVERRIDE=sha256:... \
make verify-k3s

# Run full e2e in raw-manifest daemonset mode
make verify-k3s-daemonset

# Run full e2e in raw-manifest daemonset mode with TensorRT-LLM workload
make verify-k3s-tensor-e2e-daemonset

# Run full e2e in raw-manifest daemonset mode with vLLM plugin workload
make verify-k3s-vllm-e2e-daemonset

# Equivalent via explicit mode toggle
E2E_DEPLOY_MODE=daemonset-manifest make verify-k3s

# Skip qwen-hello example validation (enabled by default)
VALIDATE_QWEN_HELLO=false make verify-k3s

# Skip local host GDS preflight (`gpu probe` + `gpu load --mode benchmark`)
VALIDATE_LOCAL_GDS=false make verify-k3s

# Optional: pre-load workload image(s) into k3s containerd (default true)
PRELOAD_WORKLOAD_IMAGE=true make verify-k3s

# Optional: pre-load the qwen-hello PyTorch runtime image into k3s containerd (default true)
PRELOAD_PYTORCH_RUNTIME_IMAGE=true make verify-k3s

# Optional: pre-load TensorRT-LLM runtime image (default true for TensorRT runtime)
PRELOAD_TENSORRTLLM_RUNTIME_IMAGE=true make verify-k3s-tensor-e2e-daemonset

# Optional: pre-load vLLM runtime image (default true for vLLM runtime)
PRELOAD_VLLM_RUNTIME_IMAGE=true make verify-k3s-vllm-e2e-daemonset

# Optional: require daemon IPC probe to report status=ok
# (default: true when OCI2GDSD_ENABLE_GDS_IMAGE=true, otherwise false)
REQUIRE_DAEMON_IPC_PROBE=true make verify-k3s

# Default behavior is fail-fast GDS mode:
# - REQUIRE_DIRECT_GDS=true
# - OCI2GDS_STRICT=true
# - OCI2GDS_PROBE_STRICT=true
# - OCI2GDS_FORCE_NO_COMPAT=true
# - REQUIRE_STRICT_PROFILE_PROBE=true
# - REQUIRE_NO_COMPAT_EVIDENCE=true
# - RUNTIME_DRIFT_CHECKPOINTS=true
# - ALLOW_RELAXED_GDS=false
# - privileged container securityContext for GPU/GDS workload containers
# You can still set them explicitly:
REQUIRE_DIRECT_GDS=true OCI2GDS_STRICT=true OCI2GDS_PROBE_STRICT=true OCI2GDS_FORCE_NO_COMPAT=true make verify-k3s-qwen-smoke

# Optional profile probe perf gates
MIN_PROFILE_PROBE_MIB_S=3000 PROFILE_PROBE_MAX_REGRESSION_PCT=20 make verify-k3s-qwen-smoke

# qwen-hello profile selection:
# - `default`: generic settings
# - `host-direct`: hostPath-backed root (NVMe-friendly) + strict probes
# For k3s, default profile is `host-direct`.
QWEN_HELLO_PROFILE=host-direct make verify-k3s-qwen-smoke

# Override root path used by init/app pod hostPath (defaults to /mnt/nvme/oci2gdsd in host-direct).
OCI2GDSD_ROOT_PATH=/mnt/nvme/oci2gdsd make verify-k3s-qwen-smoke

# Explicit opt-out (debug only): relax strict/direct enforcement.
ALLOW_RELAXED_GDS=true REQUIRE_DIRECT_GDS=false OCI2GDS_STRICT=false OCI2GDS_PROBE_STRICT=false OCI2GDS_FORCE_NO_COMPAT=false make verify-k3s-qwen-smoke

# Build a GDS-capable oci2gdsd image for init/daemon containers
OCI2GDSD_ENABLE_GDS_IMAGE=true REQUIRE_DAEMON_IPC_PROBE=true make verify-k3s

# Build a dedicated qwen runtime image with oci2gdsd + libcufile and load it into k3s
# (default false; enable explicitly when needed)
BUILD_QWEN_GDS_RUNTIME_IMAGE=true make verify-k3s

# Override the Docker target when using the shared Dockerfile
OCI2GDSD_DOCKER_TARGET=runtime-gds OCI2GDSD_ENABLE_GDS_IMAGE=true make verify-k3s

# Use a prebuilt oci2gdsd image and skip local build/load into k3s
# (useful for large CUDA/GDS images pushed to a registry)
SKIP_OCI2GDSD_IMAGE_BUILD=true SKIP_OCI2GDSD_IMAGE_LOAD=true \
OCI2GDSD_IMAGE=<registry>/<repo>:<tag> make verify-k3s

# Force namespace name
E2E_NAMESPACE=oci2gdsd-e2e make verify-k3s

# Override CUDA toolkit locations used for local GDS preflight builds
CUDA_INCLUDE_DIR=/usr/local/cuda/include CUDA_LIB_DIR=/usr/local/cuda/lib64 make verify-k3s

# Override storage gates (GiB) if needed
MIN_FREE_GB_DOCKER=150 MIN_FREE_GB_K3S=80 MIN_FREE_GB_OCI2GDS_ROOT=40 make prereq-k3s

# Override detected k3s data-dir explicitly (optional)
K3S_DATA_DIR=/mnt/nvme/k3s make prereq-k3s

# Disable automatic storage/runtime/model bootstrap helpers (debug only)
AUTO_CONFIGURE_STORAGE=false AUTO_INSTALL_GPU_OPERATOR=false AUTO_SEED_MODEL_IDENTITY=false make verify-k3s-qwen-smoke

# Override pinned GPU Operator chart version when required
GPU_OPERATOR_CHART_VERSION=v25.10.1 make verify-k3s-qwen-smoke
```

## Cleanup

```bash
make clean-k3s
```

## Artifacts

Logs are written under:

- `platform/k3s/work/artifacts/results/preload.log`
- `platform/k3s/work/artifacts/results/pytorch.log`
- `platform/k3s/work/artifacts/results/pytorch-daemon-client.log` (daemonset-manifest mode)
- `platform/k3s/work/artifacts/results/tensorrt-daemon-client.log` (daemonset-manifest mode with `WORKLOAD_RUNTIME=tensorrt`)
- `platform/k3s/work/artifacts/results/vllm-daemon-client.log` (daemonset-manifest mode with `WORKLOAD_RUNTIME=vllm`)
- `platform/k3s/work/artifacts/results/daemonset.log` (daemonset-manifest mode)
- `platform/k3s/work/artifacts/results/qwen-hello.log`
- `platform/k3s/work/artifacts/results/release-gc.log`
- `platform/k3s/work/artifacts/results/environment-report.txt`
- `platform/k3s/work/artifacts/results/qwen-profile-probe-baseline.json`
