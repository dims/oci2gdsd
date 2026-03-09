# oci2gdsd

`oci2gdsd` is a model delivery daemon/CLI for OCI-packaged model artifacts with strict integrity, atomic publish semantics, and GPU-aware preload flows.

> **Important**: `oci2gdsd` is experimental and currently proof-of-concept quality.  
> The implementation and deployment patterns are still evolving and have not been fully security evaluated for production hardening.  
> Do not use `oci2gdsd` in production environments without an explicit internal security review and risk acceptance.
> This is a personal project, not backed by the author's employer.

It gives you a deterministic lifecycle for model bytes:

- pull by immutable digest (not floating tags)
- verify bytes against OCI metadata
- publish atomically behind a `READY` contract
- track leases so GC cannot evict in-use models
- preload to GPU memory through strict GDS-oriented paths

## What this repo is for

- Platform teams running GPU workloads on Kubernetes.
- Teams that need reproducible, auditable model delivery from OCI registries.
- Contributors who want to work on model lifecycle and GPU preload infrastructure.

## Start Here

Choose the path that matches your environment.

### 1) No GPU, no Kubernetes (core lifecycle)

```bash
make verify-local
```

This validates `ensure -> status -> verify -> release -> gc` plus negative tests.

Guide: [docs/getting-started.md](docs/getting-started.md)

### 2) A100 host, strict GDS smoke

```bash
make prereq
make verify-smoke
```

This runs local, host-GDS, and k3s smoke gates in order.

Guide: [docs/quickstart-a100.md](docs/quickstart-a100.md)

### 3) Kubernetes DaemonSet end-to-end

```bash
# qwen daemonset full parity
make verify-k3s-qwen

# TensorRT-LLM suite (daemonset + parity)
make verify-k3s-tensor

# vLLM suite (daemonset + parity)
make verify-k3s-vllm

# Run all runtime suites
make verify-k3s-qwen verify-k3s-tensor verify-k3s-vllm
```

Daemon deployment docs:

- Raw manifests: [docs/daemonset-manifest-guide.md](docs/daemonset-manifest-guide.md)
- Helm chart: [docs/helm-daemon-chart.md](docs/helm-daemon-chart.md)
- Harness/runtime knobs: [platform/k3s/README.md](platform/k3s/README.md)

## System Model

`oci2gdsd` has two operating styles:

1. Standalone CLI lifecycle (`ensure`, `verify`, `gc`, `gpu load --mode benchmark`).
2. Daemon mode (`serve`) where workloads call a Unix-socket API for persistent GPU allocations and IPC handoff metadata.

Core guarantees:

- Digest-pinned OCI refs required for reliable identity.
- Transaction journal + atomic publish + `READY` marker as read boundary.
- Lease-aware model lifecycle and GC policy controls.
- Crash-safe recovery of staged transactions.

## Prerequisites

| Requirement | Version | Why |
|---|---|---|
| Go | 1.23+ | Build and unit tests |
| `make` | recent | Top-level verify/prereq targets |
| C/C++ toolchain (`c++`, headers) | recent | Native probe/extension builds in GPU paths |
| Docker | recent | Local registry flows, image builds, harness assets |
| `oras` CLI | v1.2+ | OCI artifact push/pull workflows |
| Linux GPU host + NVMe | required for GDS flows | Strict direct-GDS validation paths |

GPU is not required for core lifecycle commands and local e2e.

## Build and Install

```bash
# Source build
cd /path/to/oci2gdsd
go build -buildvcs=false ./cmd/oci2gdsd

# Install
make install

# Build with GDS support (Linux + CUDA/cuFile toolchain present)
CGO_ENABLED=1 go build -tags gds ./cmd/oci2gdsd
```

## CLI Overview

| Command | Purpose |
|---|---|
| `ensure` | Pull and publish model bytes from OCI ref, acquire lease |
| `status` | Read model state record |
| `list` | List local records |
| `verify` | Re-check `READY` + shard digests |
| `release` | Drop lease holder |
| `gc` | Evict releasable models by policy |
| `profile lint` | Validate OCI-ModelProfile-v1 config |
| `profile inspect` | Summarize profile metadata |
| `gpu devices` | List visible GPUs |
| `gpu probe` | Validate GDS capability for a GPU |
| `gpu load` | Standalone benchmark shard-read path |
| `gpu status` / `gpu unload` | Inspect and release daemon-managed GPU allocations |
| `serve` | Start daemon Unix socket API |

Reference: [docs/cli-reference.md](docs/cli-reference.md)

### CLI lifecycle example

```bash
oci2gdsd ensure \
  --ref registry.example.com/models/qwen3-0.6b@sha256:abc123... \
  --model-id qwen3-0.6b \
  --lease-holder pod-a \
  --wait --json

oci2gdsd status --model-id qwen3-0.6b --digest sha256:abc123... --json
oci2gdsd verify --model-id qwen3-0.6b --digest sha256:abc123... --json

oci2gdsd release --model-id qwen3-0.6b --digest sha256:abc123... --lease-holder pod-a
oci2gdsd gc --policy lru_no_lease --min-free-bytes 200G --json
```

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `2` | Validation failure |
| `3` | Auth failure |
| `4` | Registry/network failure |
| `5` | Integrity failure |
| `6` | Filesystem failure |
| `7` | Policy rejection |
| `8` | State corruption |

## Kubernetes Modes

The public verify targets run DaemonSet manifest mode (`verify-k3s-{qwen,tensor,vllm}`):
node-local `oci2gdsd serve` DaemonSet + daemon-client workloads with full parity checks.

Runtime policy in this mode:

- runtime pods are allocation-centric (`allocation_id` + runtime-bundle token flow)
- runtime pods have no host model-root access (`MODEL_ROOT_PATH`/`oci2gdsd-root`/`preload-model` patterns are forbidden)
- runtime logs must include `DAEMON_NO_RUNTIME_ARTIFACT_ACCESS_OK`

## Strict GDS Guidance

For direct-GDS qualification and remediation, use:

- [docs/direct-gds-runbook.md](docs/direct-gds-runbook.md)
- [docs/troubleshooting.md](docs/troubleshooting.md)
- [platform/host/README.md](platform/host/README.md)

Official NVIDIA GPUDirect Storage references:

- [GDS Overview Guide](https://docs.nvidia.com/gpudirect-storage/overview-guide/index.html)
- [GDS Troubleshooting Guide](https://docs.nvidia.com/gpudirect-storage/troubleshooting-guide/index.html)
- [GDS Release Notes](https://docs.nvidia.com/gpudirect-storage/release-notes/index.html)

Key point: this repo is biased toward strict direct-GDS validation for GPU flows. If host/provider capability is insufficient, verification targets should fail fast rather than silently accept compat-only paths.

## GPU Load Contract

Current contract in this repo:

- `gpu load --mode benchmark` (CLI): throughput probe path; GPU buffers are released before command exit.
- Daemon API persistent mode (`serve` + `/v2/gpu/load`): daemon owns persistent allocations for process lifetime and can export CUDA IPC metadata.
- Daemon API lifecycle includes attach/heartbeat/detach endpoints and tensor-map metadata used by runtime integration checks.
- Daemon exposes runtime cache counters at `GET /v2/gpu/cache-metrics` (runtime-bundle/tensor-map hit/miss/eviction).

## Performance Model

Daemonset verification uses a two-leg model:

1. Artifact leg (cold/warm): `gpu/allocate` + runtime-bundle token hydration.
2. Runtime leg (policy leg): IPC parity binding + runtime inference path checks.

TensorRT policy:

- `TENSORRT_STARTUP_MODE=parity` (default): no fastpath marker allowed.
- `TENSORRT_STARTUP_MODE=fast`: fastpath marker required with explicit `cache_hit=true|false`.

Harness emits per-run summary JSON:

- `platform/k3s/work/artifacts/results/perf-<runtime>-cold.json`
- `platform/k3s/work/artifacts/results/perf-<runtime>-warm.json`
- `platform/k3s/work/artifacts/results/perf-summary.json`
- compatibility alias: `platform/k3s/work/artifacts/results/workload-perf-summary.json`

Each run records phase timings for:

- `ensure`
- `bundle`
- `load`
- `tensor-map`
- `bind`
- `first-token`
- API-observed runtime-bundle prepare timing (`api_observed.runtime_bundle_prepare_ms`)

Harness mode defaults:

- `K3S_PERF_MODES=cold,warm`
- p50/p95 warm-vs-cold regression gate: `PERF_MAX_REGRESSION_PCT=35` (overrideable), with `PERF_MAX_REGRESSION_FIRST_TOKEN_PCT=50` for `first-token`
- absolute SLO gate enabled: `PERF_ENFORCE_ABSOLUTE_SLO=true`
- runtime-level absolute budgets via `PERF_SLO_<RUNTIME>_<MODE>_MAX_MS`
- phase-level absolute budgets via `PERF_SLO_PHASE_*`

## Packaging Models as OCI Artifacts

Qwen3 packaging assets are provided here:

- [models/qwen3-oci-modelprofile-v1/README.md](models/qwen3-oci-modelprofile-v1/README.md)

Typical flow:

```bash
cd models/qwen3-oci-modelprofile-v1
docker build -t oci2gdsd-packager .
docker run --rm \
  -e HF_TOKEN=hf_... \
  -v ~/.docker:/root/.docker:ro \
  oci2gdsd-packager
```

## Local Cache Layout

```text
/var/lib/oci2gdsd/
  state.db
  locks/
  tmp/
  journal/
  models/
    <model-id>/
      <manifest-digest>/
        metadata/model.json
        shards/
        READY
```

## Make Targets

Run `make help` for the generated list.

Common entrypoints:

- `make prereq`
- `make verify-local`
- `make verify-smoke`
- `make verify-k3s-qwen`
- `make verify-k3s-tensor`
- `make verify-k3s-vllm`
- `make clean-k3s`
- `make clean`

## Documentation Index

Core docs:

- [docs/getting-started.md](docs/getting-started.md)
- [docs/quickstart-a100.md](docs/quickstart-a100.md)
- [docs/cli-reference.md](docs/cli-reference.md)
- [docs/config-reference.md](docs/config-reference.md)
- [docs/OCI-ModelProfile-v1.md](docs/OCI-ModelProfile-v1.md)
- [docs/architecture-diagram.md](docs/architecture-diagram.md)
- [docs/design-rationale.md](docs/design-rationale.md)
- [docs/security-hardening-checklist.md](docs/security-hardening-checklist.md)
- [docs/IMPLEMENTATION-NOTES.md](docs/IMPLEMENTATION-NOTES.md)

Operational docs:

- [docs/troubleshooting.md](docs/troubleshooting.md)
- [docs/direct-gds-runbook.md](docs/direct-gds-runbook.md)
- [docs/daemonset-manifest-guide.md](docs/daemonset-manifest-guide.md)
- [docs/helm-daemon-chart.md](docs/helm-daemon-chart.md)

Platform/runtime docs:

- [platform/local/README.md](platform/local/README.md)
- [platform/host/README.md](platform/host/README.md)
- [platform/k3s/README.md](platform/k3s/README.md)
- [platform/k3s/pytorch/qwen-hello.md](platform/k3s/pytorch/qwen-hello.md)
- [platform/k3s/tensorrt/README.md](platform/k3s/tensorrt/README.md)
- [platform/k3s/vllm/README.md](platform/k3s/vllm/README.md)

Contributor guide:

- [CONTRIBUTING.md](CONTRIBUTING.md)

## Status Snapshot

Implemented and exercised in repo targets:

- Strict, digest-anchored model lifecycle with journaling and crash-safe publish.
- Lease-aware GC and lifecycle APIs.
- Daemon mode with GPU allocation lifecycle and runtime integration test paths.
- k3s harness covering PyTorch, TensorRT-LLM, and vLLM daemon-client scenarios.

Planned/future areas are tracked in implementation notes and planning docs under `docs/` and `~/notes`.
