# oci2gdsd

`oci2gdsd` downloads AI model artifacts from OCI registries to a local cache with
strict integrity guarantees and atomic write semantics — so the model your pod starts
with is provably identical to what was pushed, every time.

Think of it as a deterministic, GPU-aware alternative to "just download the weights at
startup." It handles retries, digest verification, concurrency locks, lease tracking, and
garbage collection so your serving code doesn't have to.

## Who this is for

- **ML platform / GPU infrastructure teams** deploying large models on Kubernetes
- **Anyone who wants reproducible, auditable model artifacts** (digest-pinned, not `:latest`)
- **Contributors** curious about the internals — no GPU required to run tests or try the core CLI

---

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| Go | 1.23+ | For building from source |
| Docker or Podman | any recent | For local registry and packaging workflows |
| `oras` CLI | v1.2+ | For pushing OCI artifacts; see [oras.land](https://oras.land) |
| Linux host with A100 + NVMe | — | **Only for GPU/GDS workflows** (see [GPU section](#gpu--gds-acceleration)) |

No GPU is needed to run `ensure`, `status`, `verify`, `release`, `gc`, or `profile` commands.

---

## Concepts

| Term | What it means |
|------|--------------|
| **Digest-pinned ref** | A registry reference like `registry/models/qwen3@sha256:abc...` — immutable, no floating tags |
| **OCI-ModelProfile-v1** | A JSON metadata blob pushed alongside model weights that describes shards, digests, sizes, and load hints |
| **READY marker** | A sentinel file written last during publish; consumers must see it before reading shards |
| **Lease holder** | An identifier (e.g. pod name) that "holds" a model so GC won't delete it while it's in use |
| **GDS / cuFile** | NVIDIA GPU Direct Storage — loads model weights from NVMe directly into VRAM, bypassing CPU |
| **ORAS** | OCI Registry As Storage — the library used to push/pull arbitrary artifacts to any OCI registry |

---

## Try it locally (no GPU needed)

See **[docs/getting-started.md](docs/getting-started.md)** for a self-contained walkthrough:
build the binary, spin up a local registry, push a tiny test artifact, and run the full
`ensure → status → verify → release → gc` lifecycle in under 10 minutes.

For an automated version of that lifecycle:

```bash
make local-e2e
```

---

## Install / Build

```bash
# Standard build (no GPU support)
git clone https://github.com/dims/oci2gdsd
cd oci2gdsd
go build ./cmd/oci2gdsd

# Install to $GOPATH/bin
make install

# Build with GPU Direct Storage support (Linux + CUDA/cuFile required)
CGO_ENABLED=1 go build -tags gds ./cmd/oci2gdsd
```

---

## CLI Commands

| Command | Description |
|---------|-------------|
| `ensure` | Download and pin a model; acquire a lease so GC won't remove it |
| `status` | Query the local record for a specific model+digest |
| `list` | List all locally cached model records |
| `release` | Remove a lease holder; model becomes eligible for GC when no leases remain |
| `gc` | Delete releasable (zero-lease) models to free disk space |
| `verify` | Re-check READY contract and shard digests for a cached model |
| `profile lint` | Validate an OCI-ModelProfile-v1 metadata blob |
| `profile inspect` | Print a summary of model id, framework, shards, and total bytes |
| `gpu probe` | Check whether GPU Direct Storage is available on a device |
| `gpu load` | Benchmark shard loading throughput via GDS |
| `gpu unload` | Release persistent GPU allocations (daemon mode) |
| `gpu status` | List current persistent GPU allocations (daemon mode) |
| `serve` | Run a long-lived daemon exposing a Unix socket HTTP API |

Full flag documentation: **[docs/cli-reference.md](docs/cli-reference.md)**

### Quick example

```bash
# Download and cache a model
oci2gdsd ensure \
  --ref registry.example.com/models/qwen3-0.6b@sha256:abc123... \
  --model-id qwen3-0.6b \
  --lease-holder my-pod-1 \
  --wait --json

# Check it arrived
oci2gdsd status --model-id qwen3-0.6b --digest sha256:abc123... --json
oci2gdsd verify --model-id qwen3-0.6b --digest sha256:abc123... --json

# Clean up when done
oci2gdsd release --model-id qwen3-0.6b --digest sha256:abc123... --lease-holder my-pod-1
oci2gdsd gc --policy lru_no_lease --min-free-bytes 200G --json
```

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `2` | Validation failure |
| `3` | Auth failure |
| `4` | Registry / network failure |
| `5` | Integrity failure (digest/size mismatch) |
| `6` | Filesystem failure |
| `7` | Policy rejection |
| `8` | State corruption |

---

## Local Cache Layout

```text
/var/lib/oci2gdsd/
  state.db                        # lease and status records
  locks/                          # per-model file locks
  tmp/                            # staging area during download
  journal/                        # transaction markers for crash recovery
  models/
    <model-id>/
      <manifest-digest>/
        metadata/model.json       # OCI-ModelProfile-v1
        shards/                   # weight files
        READY                     # written last; read contract boundary
```

---

## Kubernetes Quick Start

Run the local lifecycle e2e, then the GPU/k3s harness:

```bash
# Local no-GPU/no-k8s lifecycle e2e
make local-e2e
```

```bash
# Check/install prerequisites (k3s, Docker, NVIDIA toolkit, etc.)
make k3s-e2e-prereq

# Full e2e: package Qwen3, push to in-cluster registry, preload, run PyTorch smoke test
make k3s-e2e

# Fast iteration after first run (reuse existing cluster and model artifact)
make k3s-e2e-qwen-quick
```

See **[testharness/k3s-e2e/README.md](testharness/k3s-e2e/README.md)** for overrides and expected outputs.

---

## GPU / GDS Acceleration

GPU Direct Storage (GDS) loads model weight files from NVMe directly into GPU memory,
bypassing the CPU and system RAM. This is optional — the core CLI works without it.

Requirements for GDS:
- Linux host with NVIDIA A100 (or compatible) GPU
- Local NVMe storage (`gdscheck -p` must report `NVMe : Supported`)
- NVIDIA driver + `nvidia-fs` module + GDS userspace tools
- Build with `-tags gds` (see Install section)

```bash
# Probe GDS capability on device 0
oci2gdsd gpu probe --device 0 --json

# Benchmark shard loading throughput
oci2gdsd gpu load \
  --model-id qwen3-0.6b \
  --digest sha256:abc123... \
  --device 0 \
  --mode benchmark --json
```

Host qualification runbook: **[docs/direct-gds-recreate-runbook.md](docs/direct-gds-recreate-runbook.md)**
Host-only GDS probe: **[testharness/host-e2e/README.md](testharness/host-e2e/README.md)**

---

## Packaging Models

To push an existing model (e.g. Qwen3 from Hugging Face) as an OCI artifact:

```bash
cd packaging/qwen3-oci-modelprofile-v1
# Build the packager image and run it with your HF token
docker build -t oci2gdsd-packager .
docker run --rm \
  -e HF_TOKEN=hf_... \
  -v ~/.docker:/root/.docker:ro \
  oci2gdsd-packager
```

See **[packaging/qwen3-oci-modelprofile-v1/README.md](packaging/qwen3-oci-modelprofile-v1/README.md)**
for the full workflow and how to get the immutable digest for `oci2gdsd ensure --ref`.

---

## What works today

- Digest-pinned refs required for `ensure` (no floating tags)
- ORAS-based registry pull with Docker credential-store support
- OCI-ModelProfile-v1 parsing, linting, and shard verification
- Idempotent `ensure` with per-model file locks (safe to call concurrently)
- Transactional publish: journal markers + `READY` as final read-contract boundary
- Lease-aware lifecycle: `ensure/status/release/gc`
- Crash recovery: stale transactions cleaned up at startup
- JSON output and stable exit codes throughout
- GPU Direct Storage loader behind `-tags gds`
- Long-running daemon (`serve`) with Unix socket HTTP API for persistent GPU allocations

Not yet implemented: per-blob parallel chunked downloads, signature verification backend,
metrics/event exporters. See **[docs/IMPLEMENTATION-NOTES.md](docs/IMPLEMENTATION-NOTES.md)**.

---

## Documentation

| Document | Audience |
|----------|----------|
| [docs/getting-started.md](docs/getting-started.md) | New users — try it without a GPU |
| [docs/cli-reference.md](docs/cli-reference.md) | All users — full flag and command reference |
| [docs/config-reference.md](docs/config-reference.md) | Operators — config fields and their status |
| [docs/OCI-ModelProfile-v1.md](docs/OCI-ModelProfile-v1.md) | Packagers — artifact spec and schema |
| [docs/design-rationale.md](docs/design-rationale.md) | Contributors — why the design is the way it is |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Everyone — symptom-based fix guide |
| [docs/direct-gds-recreate-runbook.md](docs/direct-gds-recreate-runbook.md) | GPU infra — host qualification steps |
| [docs/IMPLEMENTATION-NOTES.md](docs/IMPLEMENTATION-NOTES.md) | Contributors — what's implemented vs planned |
| [docs/security-hardening-checklist.md](docs/security-hardening-checklist.md) | Security — controls implemented |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Contributors — dev setup, tests, PR guide |
| [testharness/local-e2e/README.md](testharness/local-e2e/README.md) | New users — automated local lifecycle e2e |
| [testharness/k3s-e2e/README.md](testharness/k3s-e2e/README.md) | GPU infra — Kubernetes e2e harness |
| [testharness/host-e2e/README.md](testharness/host-e2e/README.md) | GPU infra — host-only GDS probe |
| [examples/qwen-hello/README.md](examples/qwen-hello/README.md) | GPU infra — full Kubernetes example |
