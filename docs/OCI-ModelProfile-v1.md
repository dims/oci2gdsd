# OCI-ModelProfile-v1 Spec

`OCI-ModelProfile-v1` is the metadata contract that `oci2gdsd` uses to treat a model
artifact as deterministic infrastructure input. It is pushed to an OCI registry as the
**config blob** of the model manifest, alongside the shard blobs.

Design rationale and the "why" behind these choices: [docs/design-rationale.md](design-rationale.md)

---

## Schema

The profile is a JSON document. Required fields are marked *.

```json
{
  "schemaVersion": 1,
  "modelId": "qwen3-0.6b",
  "modelRevision": "main",
  "framework": "pytorch",
  "format": "safetensors",
  "shards": [
    {
      "name": "model-00001-of-00004.safetensors",
      "digest": "sha256:e3b0c44298fc1c149afbf4c8996fb924...",
      "size": 5368709120,
      "ordinal": 1,
      "kind": "weight"
    },
    {
      "name": "model-00002-of-00004.safetensors",
      "digest": "sha256:a87ff679a2f3e71d9181a67b7542122c...",
      "size": 5368709120,
      "ordinal": 2,
      "kind": "weight"
    }
  ],
  "integrity": {
    "manifestDigest": "resolved-manifest-digest"
  },
  "loadPlan": {
    "recommendedOrder": [0, 1, 2, 3]
  }
}
```

---

## Field reference

### Top-level fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schemaVersion` | int | * | Must be `1` |
| `modelId` | string | * | Logical model name (e.g. `qwen3-0.6b`). Must match `--model-id` passed to `ensure`. |
| `modelRevision` | string | * | Source revision hint (e.g. `main`, `v3.2`). Not used for identity — digest is authoritative. |
| `framework` | string | * | ML framework: `pytorch`, `gguf`, etc. |
| `format` | string | * | Weight file format: `safetensors` or `gguf` |
| `shards` | array | * | List of shard descriptors (see below) |
| `integrity` | object | * | Digest binding to the manifest (`manifestDigest` required) |
| `loadPlan` | object | | Optional loader hints |

### Shard descriptor fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | * | Filename (must match the blob in the OCI manifest) |
| `digest` | string | * | `sha256:<hex>` digest of the shard file |
| `size` | int64 | * | Byte size of the shard file |
| `ordinal` | int | * | 1-based position in the shard sequence |
| `kind` | string | | Shard class: `weight` or `runtime` |

### `integrity` object

| Field | Type | Description |
|-------|------|-------------|
| `manifestDigest` | string | The OCI manifest digest this profile is bound to. Used by `verify` to confirm the profile hasn't been swapped. |

### `loadPlan` object

| Field | Type | Description |
|-------|------|-------------|
| `recommendedOrder` | []int | Zero-based shard indices in preferred load order. Optional hint for GPU loaders. |

---

## Validation rules enforced by `oci2gdsd`

During `ensure` and `profile lint`, the following are hard errors:

- `schemaVersion` must be `1`
- `modelId`, `modelRevision`, `framework` must be non-empty
- `format` must be `safetensors` or `gguf`
- Every shard must have `name`, `digest`, `size` (> 0), and `ordinal` (> 0)
- If shard `kind` is set, it must be `weight` or `runtime`
- Shard `digest` must be parseable as `sha256:<hex>`
- `integrity.manifestDigest` is required and must be either:
  - a valid digest matching resolved manifest digest, or
  - the literal placeholder `resolved-manifest-digest`
- Downloaded shard bytes must match `digest` and `size` exactly
- Profile `modelId` must match the `--model-id` flag passed to `ensure`

---

## Recommended artifact layout

`OCI-ModelProfile-v1` does not require one exact folder structure, but this convention
keeps profile parsing simple and predictable:

```text
payload/
  metadata/
    model.json             # OCI-ModelProfile-v1 profile (this document's schema)
  shards/
    model-00001-of-0000N.safetensors
    model-00002-of-0000N.safetensors
    ...
```

After `ensure`, the local cache mirrors this layout:

```text
/var/lib/oci2gdsd/models/<model-id>/<manifest-digest>/
  metadata/
    model.json
  shards/
    model-00001-of-0000N.safetensors
    ...
  READY                    # Written last; read contract boundary
```

---

## Pushing an artifact to an OCI registry

Use `oras push` with the correct media types:

```bash
oras push registry.example.com/models/qwen3-0.6b:v1 \
  --artifact-type application/vnd.oci2gdsd.model.v1 \
  --config metadata/model.json:application/vnd.oci2gdsd.model.config.v1+json \
  shards/model-00001-of-00004.safetensors:application/vnd.oci2gdsd.model.shard.v1+safetensors \
  shards/model-00002-of-00004.safetensors:application/vnd.oci2gdsd.model.shard.v1+safetensors \
  shards/model-00003-of-00004.safetensors:application/vnd.oci2gdsd.model.shard.v1+safetensors \
  shards/model-00004-of-00004.safetensors:application/vnd.oci2gdsd.model.shard.v1+safetensors
```

Get the immutable digest for use with `oci2gdsd ensure --ref`:

```bash
oras resolve registry.example.com/models/qwen3-0.6b:v1
# sha256:abcdef1234...
```

See [models/qwen3-oci-modelprofile-v1/README.md](../models/qwen3-oci-modelprofile-v1/README.md)
for the full Hugging Face → OCI packaging workflow.

---

## Evolution rules

- **Additive fields** are allowed when old readers can safely ignore them.
- **Breaking schema changes** require a new profile version (`schemaVersion: 2`).
- **Behavioral tightening** (e.g. stricter lint) should be opt-in before becoming default.

---

## Non-goals (v1)

- Defining framework-specific tensor graph semantics
- Replacing model provenance or signing systems
- Enforcing a single shard format across all model families
- Mandating one snapshotter or runtime implementation

`v1` is a preload and integrity contract, not a complete model packaging standard.

---

## Checklist for profile changes

Any proposed change to `OCI-ModelProfile-v1` should answer:

1. Does this preserve deterministic identity and replayable verification?
2. Does this keep `READY` atomicity guarantees intact?
3. Can existing OCI registries and tooling handle it without custom side channels?
4. Can standalone CLI and Kubernetes init-container flows both consume it?
5. Does it reduce ambiguity rather than introduce it?

If any answer is "no", the change likely belongs in a new profile version or optional extension.
