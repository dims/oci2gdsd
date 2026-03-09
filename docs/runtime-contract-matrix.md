# Runtime Contract Matrix

This document is the human-readable companion to:

- `platform/k3s/contracts/runtime-contract.v1.json`
- `platform/k3s/scripts/validate-runtime-contract.sh`

The goal is to keep strict direct-GDS preconditions consistent across daemon-client runtimes (`pytorch`, `tensorrt`, `vllm`, `sglang`) and fail fast on manifest drift.

## Enforcement

Contract checks run in:

1. `make prereq-k3s` via `platform/k3s/scripts/prereq-check.sh`
2. `make verify-k3s-{qwen,tensor,vllm,sglang}` run paths via `platform/k3s/scripts/run.sh`

Report artifact:

- `platform/k3s/work/artifacts/results/runtime-contract-report.json`

Related harness outputs:

- `platform/k3s/work/artifacts/results/perf-<runtime>-cold.json`
- `platform/k3s/work/artifacts/results/perf-<runtime>-warm.json`
- `platform/k3s/work/artifacts/results/perf-summary.json`

## Baseline Requirements (All daemon-client runtimes)

| Requirement | Status | Why |
|---|---|---|
| `hostIPC: true` | REQUIRED | Cross-pod CUDA IPC handle attach semantics in current design. |
| `hostPID: true` | REQUIRED | Cross-process GPU IPC assumptions in current harness model. |
| `runtimeClassName: nvidia` | REQUIRED | NVIDIA runtime wiring for GPU access. |
| `privileged: true` | REQUIRED | Current test harness assumption for strict GDS bring-up. |
| `nvidia.com/gpu: "1"` requests + limits | REQUIRED | Deterministic GPU scheduling/allocation. |
| daemon socket mount (`/run/oci2gdsd`) | REQUIRED | Workload must call daemon APIs over UDS. |
| no host model-root mount in runtime client jobs | REQUIRED | Runtime pods must not read downloaded artifacts directly. |
| `DEVICE_UUID` + `DEVICE_INDEX` env | REQUIRED | Stable per-device targeting and logging. |
| host `/run/udev` mount | REQUIRED | cuFile/NVIDIA userspace device resolution prerequisites. |
| host `/etc/cufile.json` mount | REQUIRED | Strict no-compat cufile policy source. |
| `CUFILE_ENV_PATH_JSON=/etc/cufile.json` | REQUIRED | Force cufile policy file for runtime process. |
| CUDA include mount (`/usr/local/cuda/include`) | REQUIRED | Native extension/toolchain build path in runtime clients. |

## Runtime-Specific Requirements

| Requirement | PyTorch | TensorRT-LLM | vLLM | SGLang |
|---|---|---|---|---|
| Native torch extension enabled (`OCI2GDS_TORCH_ENABLE_NATIVE`) | REQUIRED | REQUIRED | REQUIRED | REQUIRED |
| Runtime parity mode env (`RUNTIME_PARITY_MODE`) | REQUIRED | REQUIRED | REQUIRED | REQUIRED |
| TensorRT runner/build env (`TRT_MAX_*`) | NOT-NEEDED | REQUIRED | NOT-NEEDED | NOT-NEEDED |
| TensorRT startup/cache wiring (`TENSORRT_STARTUP_MODE`, `host-tensorrt-cache`) | NOT-NEEDED | REQUIRED | NOT-NEEDED | NOT-NEEDED |
| vLLM-specific backend env (`VLLM_ATTENTION_BACKEND`) | NOT-NEEDED | NOT-NEEDED | REQUIRED | NOT-NEEDED |
| SGLang private-loader wiring (`SGLANG_PRIVATE_LOADER_SCRIPT_PATH`, `PYTHONPATH`) | NOT-NEEDED | NOT-NEEDED | NOT-NEEDED | REQUIRED |
| Full parity bind gate env (`REQUIRE_FULL_IPC_BIND`) | NOT-NEEDED | OPTIONAL | REQUIRED | NOT-NEEDED |
| Runtime model ref env (`MODEL_REF`) | REQUIRED | REQUIRED | REQUIRED | REQUIRED |
| Harness perf mode env (`PERF_MODE`) | REQUIRED | REQUIRED | REQUIRED | REQUIRED |
| Runtime no-artifact marker (`DAEMON_NO_RUNTIME_ARTIFACT_ACCESS_OK`) | REQUIRED | REQUIRED | REQUIRED | REQUIRED |
| Runtime-bundle timing marker (`DAEMON_RUNTIME_BUNDLE_TIMING`) | REQUIRED | REQUIRED | REQUIRED | REQUIRED |

## qwen-hello Profile Contract

`qwen-k3s-hello-deployment.yaml.tpl` is validated as a profile contract (separate from daemon-client jobs):

1. `runtimeClassName: nvidia`
2. `privileged: true`
3. explicit `oci2gdsd-daemon` sidecar and `MODEL_REF`/`RUNTIME_BUNDLE_ROOT` runtime envs
4. host `/run/udev` mount
5. host `/dev` pass-through mount to `/host-dev`
6. `MODEL_ROOT_PATH` runtime env is forbidden
7. `preload-model` init container is forbidden
8. `oci2gdsd-root` host model-root volume/mount wiring is forbidden

## Updating the Contract

When adding/changing runtime manifests:

1. Update `runtime-contract.v1.json` first.
2. Update templates.
3. Run `make prereq-k3s` (includes runtime-contract checks).
4. Run runtime suites to confirm behavior:
   - `make verify-k3s-qwen`
   - `make verify-k3s-tensor`
   - `make verify-k3s-vllm`
   - `make verify-k3s-sglang`
5. Confirm runtime logs still emit `DAEMON_NO_RUNTIME_ARTIFACT_ACCESS_OK`.
6. For TensorRT, confirm startup split policy still holds:
   - parity mode: no fastpath marker
   - fast mode: `TENSORRT_ENGINE_FASTPATH_OK cache_hit=...`

If a contract rule is no longer needed, remove it from the contract and document why in this file.
