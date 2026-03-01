# oci2gdsd

`oci2gdsd` is a standalone CLI that materializes digest-pinned OCI model artifacts
to a deterministic local model cache with strict integrity checks and atomic publish semantics.

## Commands

- `ensure`
- `status`
- `list`
- `release`
- `gc`
- `verify`
- `profile lint`
- `profile inspect`
- `gpu probe`
- `gpu load`

## Build

```bash
cd /Users/dsrinivas/go/src/github.com/dims/oci2gdsd
go build ./cmd/oci2gdsd
```

Build with GDS loader enabled (Linux + CUDA/cuFile required):

```bash
CGO_ENABLED=1 go build -tags gds ./cmd/oci2gdsd
```

## Quick Start

```bash
oci2gdsd ensure \
  --ref registry.example.com/models/demo@sha256:abcd... \
  --model-id demo \
  --lease-holder run-1 \
  --wait \
  --json
```

```bash
oci2gdsd status --model-id demo --digest sha256:abcd... --json
oci2gdsd verify --model-id demo --digest sha256:abcd... --json
oci2gdsd release --model-id demo --digest sha256:abcd... --lease-holder run-1 --json
oci2gdsd gc --policy lru_no_lease --min-free-bytes 200G --json
```

## Default Layout

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
        shards/*
        READY
```

## Current Scope

- Digest-pinned refs are required for `ensure`.
- ORAS client path is implemented with Docker credential-store support.
- `ensure` is idempotent per `model-id + manifest-digest` with per-model file locks.
- Publish path is transactional with journal markers and `READY` as a final-read contract marker.
- GPU direct loader is available behind `-tags gds` (`gpu probe`, `gpu load`).
- Section 37 high-speed chunked range download semantics are represented in config and HTTP transport tuning, but full per-blob parallel range fetching is not yet implemented.

## Reproducible Qwen3 OCI Packaging

See:

- `/Users/dsrinivas/go/src/github.com/dims/oci2gdsd/packaging/qwen3-oci-modelprofile-v1`

It contains a Dockerized workflow to pull Qwen3 from Hugging Face and push an OCI artifact with `OCI-ModelProfile-v1` semantics for `oci2gdsd`.
