# OCI-ModelProfile-v1: Design Rationale

This document captures the principles behind `OCI-ModelProfile-v1` so future contributors
can evaluate changes against the original intent.

For the schema reference and field documentation, see [docs/OCI-ModelProfile-v1.md](OCI-ModelProfile-v1.md).

---

## Problem statement

General OCI image semantics are excellent for software distribution, but model serving
preload has additional requirements:

- Large payload integrity must be provable without ambiguity.
- Runtime consumers need deterministic, machine-readable metadata.
- Partial writes must never be observed as "ready."
- Registry content should remain portable across clouds and providers.
- Kubernetes and standalone workflows should share one artifact format.

`OCI-ModelProfile-v1` defines the minimal structure needed to satisfy those requirements.

---

## Core principles

### 1) Deterministic identity

The model artifact is addressed by immutable digest (`<repo>@sha256:...`). The profile
must bind shard metadata to that digest so any materialized local copy can be re-verified
with no hidden state.

Consequences:

- `ensure` requires digest-pinned refs; tags like `:latest` are rejected.
- Status, lease, and GC are keyed by `model-id + manifest-digest`, not by name alone.

### 2) Explicit data contract

The profile is not optional documentation. It is a required control-plane payload
describing:

- model identity and revision hints,
- shard list and expected load order,
- content digests and byte sizes,
- optional loader and runtime hints.

Consequences:

- Parsing and linting failures are hard errors, not warnings.
- Missing or invalid fields block readiness.

### 3) Atomic visibility

Consumers must never see half-materialized model state.

Consequences:

- `oci2gdsd` writes into temp and journal paths first.
- The final model directory is only considered consumable after metadata and all shard
  checks pass.
- `READY` is the last write and the read contract boundary.

### 4) Integrity-first over convenience

Model startup reliability is more important than permissive behavior.

Consequences:

- Digest and size mismatches fail the operation.
- `verify` is first-class and repeatable.
- Strict integrity is the default posture for production.

### 5) OCI-native interoperability

The format should work in any OCI-compliant registry and tooling stack (oras,
containerd, ecosystem scanners), without proprietary transport requirements.

Consequences:

- Artifacts are published as OCI manifest + config + blobs.
- Metadata lives in OCI payloads and labels, not external side channels.

### 6) Operationally composable

One artifact format should serve:

- standalone CLI workflows,
- Kubernetes init-container preload flows,
- future controller or operator automation.

Consequences:

- Output and status are machine-readable (`--json`).
- Lease and lifecycle operations are explicit (`ensure/status/release/gc`).

---

## Why we define stricter conventions than generic OCI

OCI allows many equivalent encodings. For model preload, that flexibility can create
ambiguity: layer ordering, duplicated metadata, non-obvious shard mapping.

`OCI-ModelProfile-v1` deliberately narrows flexibility where ambiguity hurts operations:

- canonical profile location and schema,
- explicit shard descriptors with digest + size,
- strict linkage between profile and manifest digest.

This reduces integration bugs and supports deterministic automation.
