# k3s Harness (Strict GDS + 4 Runtimes)

This harness runs host-native `k3s` on a GPU host (Brev-friendly), deploys
`oci2gdsd` as a daemonset, and validates full parity daemon-client flows for:

- qwen/PyTorch
- TensorRT-LLM
- vLLM
- SGLang

It enforces strict direct-GDS behavior by default and fails fast on contract
or environment drift.

Related references:

- [`docs/direct-gds-runbook.md`](../../docs/direct-gds-runbook.md)
- [`docs/troubleshooting.md`](../../docs/troubleshooting.md)
- [`docs/runtime-contract-matrix.md`](../../docs/runtime-contract-matrix.md)
- [`platform/host/README.md`](../host/README.md)

## Verify Targets

From repo root:

```bash
make verify-k3s-pytorch
make verify-k3s-tensor
make verify-k3s-vllm
make verify-k3s-sglang
```

Run all suites:

```bash
make verify-k3s-pytorch verify-k3s-tensor verify-k3s-vllm verify-k3s-sglang
```

Each target runs `prereq-k3s` first.

## Runtime Mapping

- `verify-k3s-pytorch` -> `WORKLOAD_RUNTIME=pytorch`
- `verify-k3s-tensor` -> `WORKLOAD_RUNTIME=tensorrt`
- `verify-k3s-vllm` -> `WORKLOAD_RUNTIME=vllm`
- `verify-k3s-sglang` -> `WORKLOAD_RUNTIME=sglang`

All 4 run in daemonset-manifest mode with parity checks enabled. TensorRT also
supports `TENSORRT_STARTUP_MODE=fast` for cached engine reuse while keeping
`RUNTIME_PARITY_MODE=full`.

Runtime no-artifact policy is enforced in both manifest validation and runtime logs:

- no `MODEL_ROOT_PATH` env
- no `oci2gdsd-root` runtime mount
- no `preload-model` init flow
- required runtime marker: `DAEMON_NO_RUNTIME_ARTIFACT_ACCESS_OK`

## What Prereq Validates

`make prereq-k3s` (via stage chain `prereq-local` -> `prereq-host-gds` ->
`prereq-k3s`) checks:

- storage headroom (`MIN_FREE_GB_DOCKER`, `MIN_FREE_GB_K3S`,
  `MIN_FREE_GB_OCI2GDS_ROOT`)
- k3s cluster readiness + GPU allocatable capacity
- NVIDIA runtime/tooling prerequisites
- runtime contract validation
- strict direct-GDS preflight and policy gates

Defaults/overrides are defined in:

- `platform/k3s/.env.defaults`
- `platform/k3s/.env.example`

## Strict Defaults

Default harness policy is strict:

- `REQUIRE_DIRECT_GDS=true`
- `OCI2GDS_STRICT=true`
- `OCI2GDS_PROBE_STRICT=true`
- `OCI2GDS_FORCE_NO_COMPAT=true`
- `ALLOW_RELAXED_GDS=false`
- `RUNTIME_PARITY_MODE=full`

vLLM additionally requires:

- `REQUIRE_FULL_IPC_BIND=true`

For debug-only relaxed runs:

```bash
ALLOW_RELAXED_GDS=true \
REQUIRE_DIRECT_GDS=false \
OCI2GDS_STRICT=false \
OCI2GDS_PROBE_STRICT=false \
OCI2GDS_FORCE_NO_COMPAT=false \
make verify-k3s-pytorch
```

## Common Overrides

Use prebuilt model identity (skip local package/push):

```bash
MODEL_DIGEST_OVERRIDE=sha256:... \
MODEL_REF_OVERRIDE=oci-model-registry.oci-model-registry.svc.cluster.local:5000/models/qwen3-0.6b@sha256:... \
make verify-k3s-pytorch
```

Use a prebuilt daemon image (skip local build/load):

```bash
SKIP_OCI2GDSD_IMAGE_BUILD=true \
SKIP_OCI2GDSD_IMAGE_LOAD=true \
OCI2GDSD_IMAGE=<registry>/<repo>:<tag> \
make verify-k3s-pytorch
```

Toggle qwen-hello and local host GDS checks:

```bash
VALIDATE_QWEN_HELLO=false make verify-k3s-pytorch
VALIDATE_LOCAL_GDS=false make verify-k3s-pytorch
```

Enable TensorRT fast startup mode (persistent engine cache reuse):

```bash
TENSORRT_STARTUP_MODE=fast \
TENSORRT_ENGINE_CACHE_HOST_PATH=/mnt/nvme/oci2gdsd-tensorrt-cache \
make verify-k3s-tensor
```

Storage and namespace overrides:

```bash
OCI2GDSD_ROOT_PATH=/mnt/nvme/oci2gdsd make verify-k3s-pytorch
MIN_FREE_GB_DOCKER=150 MIN_FREE_GB_K3S=80 MIN_FREE_GB_OCI2GDS_ROOT=40 make prereq-k3s
E2E_NAMESPACE=oci2gdsd-e2e make verify-k3s-pytorch
```

## Artifacts

Harness outputs under `platform/k3s/work/artifacts/results`:

- `pytorch-daemon-client.log`
- `tensorrt-daemon-client.log`
- `vllm-daemon-client.log`
- `sglang-daemon-client.log`
- `qwen-hello.log`
- `daemonset.log`
- `release-gc.log`
- `environment-report.txt`
- `runtime-contract-report.json`
- `perf-<runtime>-cold.json`
- `perf-<runtime>-warm.json`
- `perf-summary.json`
- `workload-perf-summary.json` (compatibility alias)

## Perf Policy

Harness reports a two-leg performance model:

1. Artifact leg: allocation + runtime bundle retrieval.
2. Runtime leg: parity bind/import + inference startup.

TensorRT split policy:

- `TENSORRT_STARTUP_MODE=parity` must not emit fastpath markers.
- `TENSORRT_STARTUP_MODE=fast` must emit `TENSORRT_ENGINE_FASTPATH_OK` and classify run as cold (`cache_hit=false`) or warm (`cache_hit=true`).

Harness perf behavior:

- `K3S_PERF_MODES` defaults to `cold,warm`.
- p50/p95 warm-vs-cold regression gate uses `PERF_MAX_REGRESSION_PCT` (default `35`), with `PERF_MAX_REGRESSION_FIRST_TOKEN_PCT` (default `50`) for the `first-token` phase.
- absolute SLO gate is enabled by default via `PERF_ENFORCE_ABSOLUTE_SLO=true`.
- runtime-level absolute budgets are controlled by `PERF_SLO_*_MAX_MS` vars.
- phase-level absolute budgets are controlled by `PERF_SLO_PHASE_*_MAX_MS` vars.
- required per-run phase timings: `ensure`, `bundle`, `load`, `tensor-map`, `bind`, `first-token`.
- runtime-bundle prepare timing marker `DAEMON_RUNTIME_BUNDLE_TIMING` is required and is exported in perf JSON as `api_observed.runtime_bundle_prepare_ms`.

## Cleanup

```bash
make clean-k3s
```
