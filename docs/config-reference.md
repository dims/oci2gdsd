# oci2gdsd Config Reference (Current Implementation)

This document maps config fields to **actual current behavior** in this repo.

Status labels used below:

- `active`: read and used in runtime behavior
- `validation-only`: checked for validity, not used to drive runtime behavior
- `reserved`: present in schema/defaults but not currently used by runtime path

## Load order and overrides

Config resolution:

1. built-in defaults (`DefaultConfig()`)
2. YAML file from `--registry-config`
3. global CLI overrides:
   - `--root`
   - `--target-root`
   - `--log-level`

When reserved fields are set to non-default values, the CLI emits `warning:` lines on `stderr` so operators can see that those fields are currently no-ops.

## Path and core fields

- `root` (`active`): base state directory.
- `model_root` (`active`): final published model path root.
- `tmp_root` (`active`): transaction staging root.
- `locks_root` (`active`): per-model lock files.
- `journal_dir` (`active`): transaction journal records.
- `state_db` (`active`): local JSON state DB path.
- `log_level` (`reserved`): accepted/overridable but currently not wired to logger behavior.

All path fields must be absolute paths.

## `registry` section

- `registry.timeout_seconds` (`active`): contributes to request timeout fallback.
- `registry.request_timeout_seconds` (`active`): primary timeout used by registry client.
- `registry.plain_http` (`active`): sets ORAS repo `PlainHTTP`.
- `registry.auth.docker_config_path` (`active`): docker auth file path fallback.

- `registry.retries` (`reserved`)
- `registry.backoff_initial_ms` (`reserved`)
- `registry.backoff_max_ms` (`reserved`)
- `registry.mirrors` (`reserved`)
- `registry.headers` (`reserved`)
- `registry.auth.mode` (`reserved`)

## `transfer` section

- `transfer.stream_buffer_bytes` (`active`): buffer for shard streaming writes.
- `transfer.max_shards_concurrent_per_model` (`active`): base per-model shard download worker count.

- `transfer.max_models_concurrent` (`reserved`)
- `transfer.max_connections_per_registry` (`reserved`)
- `transfer.max_resume_attempts` (`reserved`)

## `download` section

Actively used in ORAS HTTP client:

- `download.max_idle_conns` (`active`)
- `download.max_idle_conns_per_host` (`active`)
- `download.max_conns_per_host` (`active`)
- `download.response_header_timeout_sec` (`active`)
- `download.retry.max_retries` (`active`)
- `download.retry.min_backoff_ms` (`active`)
- `download.retry.max_backoff_ms` (`active`)

Actively used in ensure download scheduling/buffering:

- `download.max_concurrent_requests_global` (`active`): caps effective shard-worker fanout.
- `download.max_concurrent_requests_per_model` (`active`): per-model cap for effective shard-worker fanout.
- `download.max_concurrent_chunks_per_blob` (`active`): contributes to effective per-model shard-worker fanout.
- `download.chunk_size_bytes` (`active`): chunk/buffer size used for shard download streaming.

In daemonset runs this controls the artifact leg (allocation + runtime-bundle preparation)
of the two-leg startup model before runtime parity/inference validation.

Still reserved:

- `download.request_timeout_sec` (`reserved`)
- `download.retry.jitter` (`reserved`)

## `integrity` section

- `integrity.strict_signature` + `integrity.allow_unsigned_in_dev` (`validation-only`):
  cannot both be `true`.

- `integrity.strict_digest` (`reserved`)
- `integrity.strict_signature` (`reserved` runtime)
- `integrity.allow_unsigned_in_dev` (`reserved` runtime)

Note: integrity enforcement currently comes from explicit code paths (`ensure` lint + blob digest/size verify), not from these toggles.

## `publish` section

Actively used:

- `publish.fsync_files` (`active`)
- `publish.fsync_directory` (`active`)

Present but currently not read as runtime toggles:

- `publish.require_ready_marker` (`reserved`)
- `publish.atomic_publish` (`reserved`)
- `publish.deny_partial_reads` (`reserved`)

Note: current publish path is always atomic rename + READY contract regardless of those reserved flags.

## `retention` section

Actively used:

- `retention.policy` (`active`, currently only `lru_no_lease` supported)
- `retention.min_free_bytes` (`active`, used by `ensure` space guard and GC target)

Not currently used:

- `retention.max_models` (`reserved`)
- `retention.ttl_hours` (`reserved`)
- `retention.emergency_low_space_mode` (`reserved`)

## `observability` section

All currently `reserved`:

- `observability.metrics_enabled`
- `observability.metrics_listen`
- `observability.events_json_log`

No metrics endpoint/event pipeline is wired yet.

## `security` section

Actively used:

- `security.model_id_allowlist_regex` (`active`): optional regex gate for `--model-id` on service-backed paths (`ensure`, `status`, `release`, `verify`, and standalone `gpu load` when model-id is provided).

Behavior:

- when empty (default), model IDs are validated only by structural checks (single path component, no separators, non-empty).
- when set, model ID must pass both structural checks and regex match.
- invalid regex at config load time fails validation.

## Validation rules enforced today

- all major path fields must be absolute
- `transfer.max_shards_concurrent_per_model > 0`
- `transfer.stream_buffer_bytes > 0`
- `download.max_concurrent_requests_global > 0`
- `download.max_concurrent_requests_per_model > 0`
- `download.max_concurrent_chunks_per_blob > 0`
- `download.chunk_size_bytes > 0`
- `retention.min_free_bytes >= 0`
- `integrity.strict_signature && integrity.allow_unsigned_in_dev` is invalid
- `registry.auth.docker_config_path` must be absolute when set
- `security.model_id_allowlist_regex` must compile when set

## Minimal working config

For most users, this is enough (defaults cover the rest):

```yaml
root: /var/lib/oci2gdsd
model_root: /var/lib/oci2gdsd/models
tmp_root: /var/lib/oci2gdsd/tmp
locks_root: /var/lib/oci2gdsd/locks
journal_dir: /var/lib/oci2gdsd/journal
state_db: /var/lib/oci2gdsd/state.db

registry:
  request_timeout_seconds: 30
  plain_http: false
  auth:
    docker_config_path: /etc/oci2gdsd/docker-config.json

transfer:
  stream_buffer_bytes: 4194304

download:
  max_idle_conns: 256
  max_idle_conns_per_host: 128
  max_conns_per_host: 128
  response_header_timeout_sec: 5
  retry:
    max_retries: 8
    min_backoff_ms: 30
    max_backoff_ms: 300000

publish:
  fsync_files: true
  fsync_directory: true

retention:
  policy: lru_no_lease
  min_free_bytes: 214748364800

security:
  model_id_allowlist_regex: "^[a-z0-9][a-z0-9._-]*$"
```

## Size value parsing

Byte sizes accepted by CLI/config parsing include:

- raw integer bytes (`214748364800`)
- suffix forms: `K`, `M`, `G`, `T`, `KB`, `MB`, `GB`, `TB`, `KiB`, `MiB`, `GiB`, `TiB`

Current unit semantics:

- decimal/SI: `K`, `M`, `G`, `T`, `KB`, `MB`, `GB`, `TB` map to `1000^n`
- binary/IEC: `Ki`, `Mi`, `Gi`, `Ti`, `KiB`, `MiB`, `GiB`, `TiB` map to `1024^n`

Used by:

- `gc --min-free-bytes`
