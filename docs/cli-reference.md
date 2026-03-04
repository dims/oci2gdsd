# oci2gdsd Standalone CLI Reference

This document describes the current CLI behavior implemented in this repo.
It is intentionally implementation-accurate and does not describe planned-only features.

## Command surface

Top-level commands:

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
- `gpu unload`
- `gpu status`
- `serve`

## Global flags

Global flags apply before the command name:

- `--root <abs-path>`
- `--target-root <abs-path>`
- `--registry-config <path-to-yaml>`
- `--log-level <debug|info|warn|error>`
- `--json`
- `--timeout <duration>`

Notes:

- `--registry-config` points to the full standalone config file.
- `--json` changes command output to machine-readable JSON.
- For failures in JSON mode, error JSON is emitted on `stderr`.
- `--timeout` is parsed as Go duration (for example: `30s`, `5m`).

## Command reference

## `ensure`

Materializes a digest-pinned OCI model artifact into local cache and acquires/refreshes a lease.

Flags:

- `--ref <repo@sha256:...>` (required)
- `--model-id <id>` (required)
- `--lease-holder <holder>`
- `--strict-integrity` (optional)
- `--strict-direct-path` (optional)
- `--wait` (optional)
- `--json` (optional command-level override)

Current behavior details:

- `--ref` must be digest-pinned (`repo@sha256:...`).
- `--strict-direct-path` currently enforces a guard: fails if `model_root` appears transient (`/dev/shm` or contains `tmpfs`).
- `--strict-integrity` currently adds an artifact type check when registry manifest `artifactType` is present.
- Profile linting and shard digest/size verification are always enforced during ensure.
- If lock acquisition is pending and `--wait` is not satisfied, result may be `PENDING`.

## `status`

Returns status for one materialized model record.

Flags:

- `--model-id <id>` (required)
- `--digest sha256:...` (required)
- `--json`

## `list`

Lists all local records.

Flags:

- `--json`

## `release`

Releases one lease holder for a model.

Flags:

- `--model-id <id>` (required)
- `--digest sha256:...` (required)
- `--lease-holder <holder>` (required)
- `--cleanup` (optional immediate delete when lease count reaches zero)
- `--json`

## `gc`

Garbage collects releasable, no-lease model paths.

Flags:

- `--policy <policy>` (currently supports only `lru_no_lease`)
- `--min-free-bytes <size>` (accepts units like `200G`, `200GiB`, etc.)
- `--dry-run`
- `--json`

If `--min-free-bytes` is omitted, config `retention.min_free_bytes` is used.

## `verify`

Verifies READY contract and shard integrity of a local materialized model.

Flags:

- `--path <published-model-path>`
- `--model-id <id>`
- `--digest sha256:...`
- `--json`

One of:

- `--path`
- or both `--model-id` + `--digest`

## `profile lint`

Lints OCI-ModelProfile-v1 metadata.

Flags:

- `--ref <repo@sha256:...>`
- `--config <path-to-model-config.(json|yaml|yml)>`
- `--digest sha256:...` (expected digest when linting via `--config`)
- `--json`

One of `--ref` or `--config` is required.

## `profile inspect`

Prints profile summary (model id, framework, format, shard count, total bytes, manifest).

Flags:

- `--ref <repo@sha256:...>`
- `--config <path-to-model-config.(json|yaml|yml)>`
- `--json`

One of `--ref` or `--config` is required.

## `gpu probe`

Probes GPU loader capability for a device.

Flags:

- `--device <index>` (default: `0`)
- `--json`

Returns non-zero (`ExitPolicy`) when direct GPU path is unavailable.

## `gpu load`

Loads shard files from local published model path into GPU path (GDS loader when available, fallback based on strict mode).

Flags:

- `--model-id <id>`
- `--digest sha256:...`
- `--path <published-model-path>`
- `--device <index>` (default: `0`)
- `--chunk-bytes <size>` (default: `16MiB`)
- `--max-shards <n>` (`0` means all)
- `--strict` (default: `true`; standalone CLI rejects `--strict=false`)
- `--mode <benchmark|persistent>` (default: `benchmark`)
- `--json`

Path resolution:

- Uses `--path` directly, or
- resolves from local state using `--model-id` + `--digest`.

Current mode semantics:

- `benchmark`: reads shard files through the configured loader path and reports throughput/progress metadata.
- `persistent`: rejected in standalone one-shot CLI mode with `POLICY_REJECTED`.
  Use `serve` for long-lived process semantics.
- `--strict=false`: rejected in standalone one-shot CLI mode with `POLICY_REJECTED`.
  Standalone benchmark loads are fail-fast direct-GDS only.

## `gpu unload`

Attempts to unload persistent GPU allocations for a model path.

Flags:

- `--model-id <id>`
- `--digest sha256:...`
- `--path <published-model-path>`
- `--lease-holder <holder>` (required)
- `--device <index>` (default: `0`)
- `--json`

Notes:

- In standalone CLI mode, `gpu load --mode persistent` is rejected, so `gpu unload` is
  primarily relevant for embedded/long-running service integrations that keep process state.

## `gpu status`

Lists persistent GPU allocations tracked by the current process for a device.

Flags:

- `--device <index>` (default: `0`)
- `--json`

Notes:

- In standalone one-shot CLI mode this will usually return an empty list because no
  cross-command process state is retained.

## `serve`

Runs a long-lived daemon process over a Unix socket and keeps in-process GPU persistent
allocations alive across API calls.

Flags:

- `--unix-socket <path>` (default: `/tmp/oci2gdsd/daemon.sock`)
- `--socket-perms <octal>` (default: `0600`)
- `--remove-stale-socket` (default: `true`)
- `--shutdown-timeout <duration>` (default: `5s`)
- `--json`

Current HTTP API surface:

- `GET /healthz`
- `POST /v1/gpu/load`
- `POST /v1/gpu/export`
- `POST /v1/gpu/unload`
- `GET /v1/gpu/status?device=<index>`

## Output behavior

Success:

- Human-readable line output by default.
- JSON object/array on `stdout` when `--json` is enabled.

Failure:

- Human-readable error on `stderr` by default.
- JSON error on `stderr` in JSON mode:
  - `status`
  - `reason_code`
  - `message`
  - `exit_code`

## Exit codes

- `0`: success
- `2`: validation failure
- `3`: auth failure
- `4`: registry/network class failure
- `5`: integrity failure
- `6`: filesystem failure
- `7`: policy failure
- `8`: state corruption/internal fallback

## Common reason codes

- `REGISTRY_AUTH_FAILED`
- `REGISTRY_UNREACHABLE`
- `REGISTRY_TIMEOUT`
- `MANIFEST_NOT_FOUND`
- `BLOB_NOT_FOUND`
- `BLOB_SIZE_MISMATCH`
- `BLOB_DIGEST_MISMATCH`
- `PROFILE_LINT_FAILED`
- `DISK_SPACE_INSUFFICIENT`
- `DIRECT_PATH_INELIGIBLE`
- `VALIDATION_FAILED`
- `FILESYSTEM_ERROR`
- `STATE_DB_CORRUPT`

## Quick examples

```bash
oci2gdsd --registry-config ./examples/oci2gdsd.yaml ensure \
  --ref registry.example.com/models/demo@sha256:... \
  --model-id demo \
  --lease-holder session-a \
  --wait \
  --json
```

```bash
oci2gdsd status --model-id demo --digest sha256:... --json
oci2gdsd verify --model-id demo --digest sha256:... --json
oci2gdsd release --model-id demo --digest sha256:... --lease-holder session-a --json
oci2gdsd gc --policy lru_no_lease --min-free-bytes 200G --json
```
