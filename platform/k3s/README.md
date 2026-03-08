# k3s Harness (Strict GDS + 3 Runtimes)

This harness runs host-native `k3s` on a GPU host (Brev-friendly), deploys
`oci2gdsd` as a daemonset, and validates full parity daemon-client flows for:

- qwen/PyTorch
- TensorRT-LLM
- vLLM

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
make verify-k3s-qwen
make verify-k3s-tensor
make verify-k3s-vllm
```

Run all suites:

```bash
make verify-k3s-qwen verify-k3s-tensor verify-k3s-vllm
```

Each target runs `prereq-k3s` first.

## Runtime Mapping

- `verify-k3s-qwen` -> `WORKLOAD_RUNTIME=pytorch`
- `verify-k3s-tensor` -> `WORKLOAD_RUNTIME=tensorrt`
- `verify-k3s-vllm` -> `WORKLOAD_RUNTIME=vllm`

All 3 run in daemonset-manifest mode with parity checks enabled.

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
make verify-k3s-qwen
```

## Common Overrides

Use prebuilt model identity (skip local package/push):

```bash
MODEL_DIGEST_OVERRIDE=sha256:... \
MODEL_REF_OVERRIDE=oci-model-registry.oci-model-registry.svc.cluster.local:5000/models/qwen3-0.6b@sha256:... \
make verify-k3s-qwen
```

Use a prebuilt daemon image (skip local build/load):

```bash
SKIP_OCI2GDSD_IMAGE_BUILD=true \
SKIP_OCI2GDSD_IMAGE_LOAD=true \
OCI2GDSD_IMAGE=<registry>/<repo>:<tag> \
make verify-k3s-qwen
```

Toggle qwen-hello and local host GDS checks:

```bash
VALIDATE_QWEN_HELLO=false make verify-k3s-qwen
VALIDATE_LOCAL_GDS=false make verify-k3s-qwen
```

Storage and namespace overrides:

```bash
OCI2GDSD_ROOT_PATH=/mnt/nvme/oci2gdsd make verify-k3s-qwen
MIN_FREE_GB_DOCKER=150 MIN_FREE_GB_K3S=80 MIN_FREE_GB_OCI2GDS_ROOT=40 make prereq-k3s
E2E_NAMESPACE=oci2gdsd-e2e make verify-k3s-qwen
```

## Artifacts

Harness outputs under `platform/k3s/work/artifacts/results`:

- `pytorch-daemon-client.log`
- `tensorrt-daemon-client.log`
- `vllm-daemon-client.log`
- `qwen-hello.log`
- `daemonset.log`
- `release-gc.log`
- `environment-report.txt`
- `runtime-contract-report.json`

## Cleanup

```bash
make clean-k3s
```
