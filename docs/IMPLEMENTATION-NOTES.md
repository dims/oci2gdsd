# oci2gdsd Implementation Notes

## Implemented

- Standalone CLI behavior documented in [cli-reference.md](cli-reference.md).
- Digest-pinned ref enforcement for `ensure`.
- ORAS-based registry interactions:
  - manifest resolve/fetch
  - config fetch
  - shard fetch
  - docker credential store integration
  - tuned HTTP transport + retry policy hooks
- `OCI-ModelProfile-v1` parsing and lint checks:
  - required field checks
  - digest format checks
  - shard ordinal checks
  - manifest/profile linkage checks
  - profile config parsing from JSON and YAML file inputs
- Atomic publish path with state transitions and durable transaction markers:
  - `TXN_STARTED`
  - `TXN_BLOBS_WRITTEN`
  - `TXN_BLOBS_VERIFIED`
  - `TXN_METADATA_WRITTEN`
  - `TXN_READY_WRITTEN`
  - `TXN_COMMITTED`
- `READY` read contract enforcement.
- Standalone CLI `gpu load` contract is explicit benchmark mode; `--mode persistent` is rejected in one-shot CLI mode.
- `serve` command is implemented for long-running process integrations and exposes daemon GPU API endpoints (`/v1/gpu/load`, `/v1/gpu/export`, `/v1/gpu/attach`, `/v1/gpu/heartbeat`, `/v1/gpu/detach`, `/v1/gpu/unload`, `/v1/gpu/status`).
- Persistent unload now guards against active attachment clients and requires detach (or TTL expiry) before freeing allocations.
- GDS persistent loader handles non-4KiB tail bytes by switching tail copy to a non-`O_DIRECT` fd in non-strict mode.
- `gpu unload` and `gpu status` commands are implemented; they are primarily useful for embedded/long-running process integrations.
- Lease-aware release and GC behavior.
- Crash-recovery guardrails for stale temp paths and inconsistent READY entries
  using lightweight READY/metadata/shard-size checks at startup.
- Registry error classifier now prioritizes typed ORAS `errcode.ErrorResponse` mapping (auth/not-found/timeout) before string fallback.
- Machine-oriented JSON outputs and stable exit code mapping.

## Not Yet Implemented

- Per-blob parallel chunked range download engine from Section 37.
- Signature verification backend integration (strict signature toggle is present, verifier integration is pending).
- Metrics/event exporter endpoints.
- Full mirror failover policy with per-host telemetry and reason-class counters.

## Testing Coverage

- Byte-size parsing
- Profile lint valid/invalid cases
- Verify contract (READY + metadata + shard digest/size)

## Operational Runbooks

- Direct GDS recreate runbook: [direct-gds-recreate-runbook.md](direct-gds-recreate-runbook.md)
