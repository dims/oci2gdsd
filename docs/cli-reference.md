# oci2gdsd Standalone CLI Reference

This document describes the current CLI behavior implemented in this repo.
It is intentionally implementation-accurate and does not describe planned-only features.

New here? Start with [docs/getting-started.md](getting-started.md) for a hands-on walkthrough.

## Command surface

Top-level commands:

| Command | Description |
|---------|-------------|
| `ensure` | Download and cache a model; acquire a lease |
| `status` | Query status of one cached model record |
| `list` | List all cached model records |
| `release` | Remove a lease holder from a model |
| `gc` | Garbage collect zero-lease models |
| `verify` | Re-check READY contract and shard digests |
| `profile lint` | Validate OCI-ModelProfile-v1 metadata |
| `profile inspect` | Print model id, shards, total bytes |
| `gpu probe` | Check GPU Direct Storage availability |
| `gpu load` | Benchmark shard loading via GDS |
| `gpu unload` | Release persistent GPU allocations |
| `gpu status` | List current persistent GPU allocations |
| `serve` | Run long-lived daemon on a Unix socket |

## Global flags

Global flags apply before the command name:

```bash
oci2gdsd [GLOBAL FLAGS] <command> [COMMAND FLAGS]
```

- `--root <abs-path>` — state directory root (default: `/var/lib/oci2gdsd`)
- `--target-root <abs-path>` — published model path root
- `--registry-config <path-to-yaml>` — full standalone config file
- `--log-level <debug|info|warn|error>`
- `--json` — machine-readable JSON output on stdout; errors go to stderr
- `--timeout <duration>` — Go duration, e.g. `30s`, `5m`

Notes:

- `--registry-config` points to the full standalone config file.
- `--json` changes command output to machine-readable JSON.
- For failures in JSON mode, error JSON is emitted on `stderr`.
- `--timeout` is parsed as Go duration (for example: `30s`, `5m`).

---

## `ensure`

Materializes a digest-pinned OCI model artifact into local cache and acquires/refreshes a lease.

```bash
oci2gdsd \
  --root /var/lib/oci2gdsd \
  ensure \
  --ref registry.example.com/models/qwen3-0.6b@sha256:abc123... \
  --model-id qwen3-0.6b \
  --lease-holder my-pod-run-1 \
  --wait \
  --json
```

Flags:

- `--ref <repo@sha256:...>` (required) — digest-pinned OCI reference
- `--model-id <id>` (required) — logical name for the model (used as directory and lease key)
- `--lease-holder <holder>` — identifier for the caller holding the lease (e.g. pod name or job ID)
- `--strict-integrity` — adds artifact type check when manifest `artifactType` is present
- `--strict-direct-path` — fails if `model_root` is on a transient path (`/dev/shm` or tmpfs)
- `--wait` — wait for lock if another `ensure` is in progress for the same model+digest
- `--json`

Current behavior:

- `--ref` must be digest-pinned (`repo@sha256:...`). Tags like `:latest` are rejected.
- Profile linting and shard digest/size verification are always enforced.
- If a lock is held and `--wait` is not passed, result may be `PENDING`.
- Running again with the same ref + lease-holder is safe (idempotent).

---

## `status`

Returns the current status for one cached model record.

```bash
oci2gdsd \
  --root /var/lib/oci2gdsd \
  status \
  --model-id qwen3-0.6b \
  --digest sha256:abc123... \
  --json
```

Flags:

- `--model-id <id>` (required)
- `--digest sha256:...` (required)
- `--json`

---

## `list`

Lists all local model records with their status and lease holders.

```bash
oci2gdsd --root /var/lib/oci2gdsd list --json
```

Flags:

- `--json`

---

## `release`

Removes one lease holder from a model. When all leases are removed, the model becomes
eligible for garbage collection.

```bash
oci2gdsd \
  --root /var/lib/oci2gdsd \
  release \
  --model-id qwen3-0.6b \
  --digest sha256:abc123... \
  --lease-holder my-pod-run-1 \
  --json
```

Flags:

- `--model-id <id>` (required)
- `--digest sha256:...` (required)
- `--lease-holder <holder>` (required)
- `--cleanup` — immediately delete the model directory when lease count reaches zero
- `--json`

---

## `gc`

Garbage collects releasable (zero-lease) model paths to free disk space.

```bash
# Dry run first to see what would be deleted
oci2gdsd --root /var/lib/oci2gdsd gc \
  --policy lru_no_lease \
  --min-free-bytes 200G \
  --dry-run \
  --json

# Actually delete
oci2gdsd --root /var/lib/oci2gdsd gc \
  --policy lru_no_lease \
  --min-free-bytes 200G \
  --json
```

Flags:

- `--policy <policy>` — currently only `lru_no_lease` is supported
- `--min-free-bytes <size>` — target free space; accepts `200G`, `200GiB`, etc.
- `--dry-run` — report what would be deleted without deleting
- `--json`

If `--min-free-bytes` is omitted, the value from `config.retention.min_free_bytes` is used.

---

## `verify`

Re-verifies the READY contract and shard integrity of a locally cached model.
Reads every shard on disk and compares against the profile's recorded digests and sizes.

```bash
# Verify by model-id + digest
oci2gdsd \
  --root /var/lib/oci2gdsd \
  verify \
  --model-id qwen3-0.6b \
  --digest sha256:abc123... \
  --json

# Verify by path directly
oci2gdsd verify \
  --path /var/lib/oci2gdsd/models/qwen3-0.6b/sha256-abc123... \
  --json
```

Flags:

- `--path <published-model-path>` — direct path to the model directory
- `--model-id <id>` + `--digest sha256:...` — alternative to `--path`
- `--json`

One of `--path` or `--model-id` + `--digest` is required.

---

## `profile lint`

Validates OCI-ModelProfile-v1 metadata from a registry ref or a local file.

```bash
# Lint from registry
oci2gdsd profile lint \
  --ref localhost:5000/models/qwen3-0.6b@sha256:abc123... \
  --json

# Lint from local file
oci2gdsd profile lint \
  --config /path/to/model.json \
  --digest sha256:abc123... \
  --json
```

Flags:

- `--ref <repo@sha256:...>` — fetch and lint config from registry
- `--config <path>` — lint a local `.json`, `.yaml`, or `.yml` file
- `--digest sha256:...` — expected digest to validate against when using `--config`
- `--json`

One of `--ref` or `--config` is required.

---

## `profile inspect`

Prints a human-readable (or JSON) summary of a model profile: model id, framework,
format, shard count, total bytes, and manifest digest.

```bash
# Inspect from registry
oci2gdsd profile inspect \
  --ref localhost:5000/models/qwen3-0.6b@sha256:abc123... \
  --json

# Inspect from local file
oci2gdsd profile inspect \
  --config /var/lib/oci2gdsd/models/qwen3-0.6b/sha256-abc123.../metadata/model.json \
  --json
```

Flags:

- `--ref <repo@sha256:...>`
- `--config <path>`
- `--json`

One of `--ref` or `--config` is required.

---

## `gpu devices`

Lists visible GPUs with canonical UUID and local CUDA index. Use this to pick a
`--device-uuid` for all GPU commands.

```bash
oci2gdsd gpu devices --json
```

Flags:

- `--json`

---

## `gpu probe`

Probes GPU Direct Storage (GDS) capability for a device. Requires the binary to be
built with `-tags gds` and a compatible NVIDIA driver stack.

```bash
oci2gdsd gpu probe --device-uuid GPU-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee --json
```

Flags:

- `--device-uuid <GPU-...>` — canonical GPU UUID (required)
- `--json`

Returns non-zero (`ExitPolicy`) when direct GPU path is unavailable.

---

## `gpu load`

Runs standalone benchmark reads through the GDS loader (when available). This command is
one-shot and does not create persistent daemon allocations.

```bash
# Benchmark mode: load shards, report throughput, release
oci2gdsd gpu load \
  --model-id qwen3-0.6b \
  --digest sha256:abc123... \
  --device-uuid GPU-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee \
  --mode benchmark \
  --json
```

Flags:

- `--model-id <id>` — resolve path from local state
- `--digest sha256:...` — used with `--model-id` to find the model path
- `--path <published-model-path>` — alternative to `--model-id` + `--digest`
- `--device-uuid <GPU-...>` (required)
- `--chunk-bytes <size>` (default: `16MiB`) — chunk size for shard reads
- `--max-shards <n>` — limit to first N shards; `0` means all
- `--strict` (default: `true`) — fail if direct GDS path is unavailable; `false` is rejected in standalone mode
- `--mode <benchmark|persistent>` (default: `benchmark`)
- `--json`

Mode semantics:

- `benchmark`: reads shards through the GDS path and reports throughput. GPU memory is freed on completion.
- `persistent`: rejected in standalone CLI mode; persistent allocations are daemon-only (`/v2/gpu/allocate`).

---

## `gpu unload`

Releases a daemon-managed persistent allocation by `allocation_id`.

```bash
oci2gdsd gpu unload \
  --allocation-id alloc_1710000000000000000_1 \
  --json
```

Flags:

- `--allocation-id <id>` (required)
- `--json`

`gpu unload` is intended for embedded/daemon integrations where allocation IDs are tracked.

---

## `gpu status`

Lists persistent GPU allocations tracked by the current process.

```bash
oci2gdsd gpu status --device-uuid GPU-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee --json
```

Flags:

- `--device-uuid <GPU-...>` (required)
- `--json`

Note: in one-shot CLI mode this returns an empty list because no cross-invocation state is kept.

---

## `serve`

Runs a long-lived daemon listening on a Unix socket. Keeps persistent GPU allocations
alive across HTTP API calls. Used by Kubernetes workloads where the app container needs
to call into `oci2gdsd` over IPC.

```bash
oci2gdsd serve \
  --unix-socket /tmp/oci2gdsd/daemon.sock \
  --json
```

Flags:

- `--unix-socket <path>` (default: `/tmp/oci2gdsd/daemon.sock`)
- `--socket-perms <octal>` (default: `0600`)
- `--remove-stale-socket` (default: `true`) — remove socket file on startup if stale
- `--shutdown-timeout <duration>` (default: `5s`)
- `--json`

HTTP API surface:

```
GET  /healthz
POST /v2/model/ensure
POST /v2/model/verify
GET  /v2/runtime-bundles/{token}
GET  /v2/gpu/devices
POST /v2/gpu/allocate
POST /v2/gpu/load
POST /v2/gpu/export
POST /v2/gpu/tensor-map
POST /v2/gpu/attach
POST /v2/gpu/heartbeat
POST /v2/gpu/detach
POST /v2/gpu/unload
GET  /v2/gpu/status?device_uuid=<GPU-...>
```

Runtime daemon-client paths are allocation-centric: runtime callers first create an
allocation (`/v2/gpu/allocate`), then fetch runtime files via tokenized bundle
download (`/v2/runtime-bundles/{token}`), and then use allocation-scoped GPU
lifecycle calls (`attach`, `heartbeat`, `tensor-map`, `export`, `detach`, `unload`).
`/v2/gpu/load` is allocation-only (`allocation_id` request surface).

`POST /v2/gpu/tensor-map` returns a safetensors-derived tensor index for each shard
with byte ranges and optional exported CUDA IPC handle metadata. This endpoint is used by
the k3s daemon-client runtime parity checks.

---

## Output behavior

**Success:**
- Human-readable text on `stdout` by default.
- JSON object/array on `stdout` when `--json` is enabled.

**Failure:**
- Human-readable error on `stderr` by default.
- JSON error on `stderr` in JSON mode with fields:
  - `status`
  - `reason_code`
  - `message`
  - `exit_code`

---

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `2` | Validation failure |
| `3` | Auth failure |
| `4` | Registry / network failure |
| `5` | Integrity failure (digest or size mismatch) |
| `6` | Filesystem failure |
| `7` | Policy rejection |
| `8` | State corruption / internal fallback |

---

## Common reason codes

| Code | When |
|------|------|
| `REGISTRY_AUTH_FAILED` | Credentials missing or rejected |
| `REGISTRY_UNREACHABLE` | Network or DNS failure |
| `REGISTRY_TIMEOUT` | Registry took too long to respond |
| `MANIFEST_NOT_FOUND` | Ref not found in registry |
| `BLOB_NOT_FOUND` | Shard blob missing from registry |
| `BLOB_SIZE_MISMATCH` | Downloaded blob has wrong byte count |
| `BLOB_DIGEST_MISMATCH` | Downloaded blob has wrong sha256 |
| `PROFILE_LINT_FAILED` | OCI-ModelProfile-v1 validation failed |
| `DISK_SPACE_INSUFFICIENT` | Not enough free space to proceed |
| `DIRECT_PATH_INELIGIBLE` | Model root is on a non-direct-path filesystem |
| `VALIDATION_FAILED` | General validation error |
| `FILESYSTEM_ERROR` | Local filesystem operation failed |
| `STATE_DB_CORRUPT` | state.db cannot be parsed or is inconsistent |
| `POLICY_REJECTED` | Operation rejected by current policy |
