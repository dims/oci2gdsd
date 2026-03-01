# OCI-ModelProfile-v1: Rationale and Design Principles

## Why this document exists

`OCI-ModelProfile-v1` is the contract that lets `oci2gdsd` treat a model artifact as
deterministic infrastructure input rather than best-effort content. This document captures
the principles behind that contract so future contributors can evaluate changes against
the original intent.

## Problem statement

General OCI image semantics are excellent for software distribution, but model serving
preload has additional requirements:

- Large payload integrity must be provable without ambiguity.
- Runtime consumers need deterministic, machine-readable metadata.
- Partial writes must never be observed as "ready."
- Registry content should remain portable across clouds/providers.
- K8s and standalone workflows should share one artifact format.

`OCI-ModelProfile-v1` defines the minimal structure needed to satisfy those requirements.

## Core principles

## 1) Deterministic identity

The model artifact is addressed by immutable digest (`<repo>@sha256:...`). The profile
must bind shard metadata to that digest so any materialized local copy can be re-verified
with no hidden state.

Consequence:

- `ensure` requires digest-pinned refs.
- Status, lease, and GC are keyed by `model-id + manifest-digest`.

## 2) Explicit data contract

The profile is not optional documentation. It is a required control-plane payload
describing:

- model identity and revision hints,
- shard list and expected order,
- content digests and byte sizes,
- optional loader/runtime hints.

Consequence:

- Parsing/linting failures are hard errors, not warnings.
- Missing/invalid fields block readiness.

## 3) Atomic visibility

Consumers must never see half-materialized model state.

Consequence:

- `oci2gdsd` writes into temp/journal paths first.
- Final model directory is only considered consumable after metadata and all shard checks pass.
- `READY` is the last write and the read contract boundary.

## 4) Integrity-first over convenience

Model startup reliability is more important than permissive behavior.

Consequence:

- Digest/size mismatches fail the operation.
- `verify` is first-class and repeatable.
- Strict integrity mode remains the default posture for production.

## 5) OCI-native interoperability

The format should work in any OCI-compliant registry and tooling stack (oras/containerd/ecosystem scanners),
without proprietary transport requirements.

Consequence:

- Artifact is published as OCI manifest + config + blobs.
- Metadata lives in OCI payloads and labels, not external side channels.

## 6) Operationally composable

One artifact format should serve:

- standalone CLI workflows,
- K8s init-container preload flows,
- future controller/operator automation.

Consequence:

- Output/status is machine-readable (`--json`).
- Lease and lifecycle operations are explicit (`ensure/status/release/gc`).

## Recommended artifact layout

`OCI-ModelProfile-v1` does not require one exact folder tree, but it assumes a
clear separation between metadata and shard payloads. A practical convention:

```text
payload/
  metadata/
    model.json             # canonical OCI-ModelProfile-v1 profile
  shards/
    model-00001-of-0000N.safetensors
    ...
```

This convention keeps profile parsing simple and predictable while remaining OCI-native.

## Why we still define stricter conventions than generic OCI

OCI allows many equivalent encodings. For model preload, that flexibility can create
ambiguity (layer ordering, duplicated metadata, non-obvious shard mapping).

`OCI-ModelProfile-v1` deliberately narrows flexibility where ambiguity hurts operations:

- canonical profile location and schema,
- explicit shard descriptors with digest+size,
- strict linkage between profile and manifest digest.

This reduces integration bugs and supports deterministic automation.

## Non-goals (v1)

- Defining framework-specific tensor graph semantics.
- Replacing model provenance/signing systems.
- Enforcing a single shard format across all model families.
- Mandating one snapshotter/runtime implementation.

`v1` is a preload and integrity contract, not a complete model packaging standard.

## Evolution rules

To keep compatibility stable:

- Additive fields are allowed when old readers can ignore them safely.
- Breaking schema changes require a new profile version.
- Behavioral tightening (e.g., stricter lint) should be opt-in before becoming default.

## Acceptance checklist for future changes

Any proposed change to `OCI-ModelProfile-v1` should answer:

1. Does this preserve deterministic identity and replayable verification?
2. Does this keep `READY` atomicity guarantees intact?
3. Can existing OCI registries/tooling handle it without custom side channels?
4. Can standalone and K8s flows both consume it?
5. Does it reduce ambiguity rather than introduce it?

If any answer is "no", the change likely belongs in a new profile version or optional extension.

