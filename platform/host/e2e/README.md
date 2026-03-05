# host direct-GDS quick e2e

This harness runs a host-only strict direct-GDS probe for Qwen.
It does not require Kubernetes, and can bootstrap model identity itself.

## Getting a model on disk

**Default path (works from a fresh host):**

```bash
make prereq-host-gds
make verify-host-qwen-smoke
```

Prereq hierarchy:
- Stage 0 (`prereq-local`) runs first via Make dependency.
- Stage 1 (`prereq-host-gds`) adds strict host direct-GDS checks.

`verify-host-qwen-smoke` now auto-seeds identity when needed:
- starts/creates a local OCI registry container (`oci2gdsd-host-registry`)
- builds/runs the Qwen packager
- pushes `localhost:${HOST_LOCAL_REGISTRY_PORT}/models/qwen3-0.6b:v1`
- reads digest from `platform/host/e2e/work/packager/output/manifest-descriptor.json`
- generates a local plain-http registry config and runs `oci2gdsd ensure`/`release`

**Alternative path (explicit identity, skips auto-seed):**

```bash
MODEL_ID=qwen3-0.6b \
MODEL_DIGEST=sha256:... \
MODEL_REF_OVERRIDE=registry.example.com/models/qwen3-0.6b@sha256:... \
make verify-host-qwen-smoke
```

**Reuse existing on-disk model:**

If `READY` already exists under `OCI2GDSD_ROOT_PATH/models/${MODEL_ID}/sha256-*`,
the script reuses that digest first.

Defaults are strict direct-GDS. On hosts where `gdscheck -p` reports
`NVMe : compat/Unsupported`, prereq now attempts non-destructive remediation first
(GDS tooling/modules + NVMe mount/data-path alignment), then fails if direct path is
still unavailable.

If host quick fails with:

```text
error: failed to initialize state lock: open .../state.db.lock: permission denied
```

fix ownership of model root and rerun:

```bash
sudo chown -R "$(id -u):$(id -g)" "${OCI2GDSD_ROOT_PATH:-/mnt/nvme/oci2gdsd}"
```
By default, `verify-host-qwen-smoke` also validates CLI quick-example operations
(`status`, `verify`, and optionally `ensure`/`release`).

## Run

From repo root:

```bash
make prereq-host-gds
make verify-host-qwen-smoke
```

Base dev toolchain expected on the host for full repo workflows:

- `go` (for `make verify-unit` and source builds)
- `make`
- `c++`/build headers (native extension/probe compilation path)

`make prereq-host-gds` auto-installs host prerequisites by default on Ubuntu/Debian (`INSTALL_MISSING_PREREQS=true`) and executes after stage 0 (`prereq-local`).
When `REQUIRE_DIRECT_GDS=true`, it also installs GDS user-space tools (`gdscheck`) if missing and
attempts non-destructive remediation unless a hard blocker is detected (for example no guest-visible NVMe).
It does not mutate GPU driver/kernel packages automatically.
Set `INSTALL_MISSING_PREREQS=false` to run checks only.

Defaults:

- `OCI2GDSD_ROOT_PATH=/mnt/nvme/oci2gdsd`
- `MODEL_ID=qwen3-0.6b`
- `MODEL_DIGEST` auto-detected from newest `READY` entry for `MODEL_ID` when unset
- `MODEL_REF_OVERRIDE` optional; when set, enables `ensure`/`release` quick-example checks
- `AUTO_SEED_MODEL_IDENTITY=true` (bootstrap digest/ref from local packager+registry when missing)
- `HOST_LOCAL_REGISTRY_CONTAINER=oci2gdsd-host-registry`
- `HOST_LOCAL_REGISTRY_PORT=5003`
- `HOST_LOCAL_REGISTRY_IMAGE=registry:2`
- `PACKAGER_IMAGE=oci2gdsd-qwen3-packager:local`
- `HF_REPO=Qwen/Qwen3-0.6B`, `HF_REVISION=main`, `MODEL_REPO=models/qwen3-0.6b`, `MODEL_TAG=v1`
- `VALIDATE_QUICK_EXAMPLE=true` (run CLI lifecycle assertions before probe)
- `QUICK_EXAMPLE_LEASE_HOLDER=verify-host-qwen-smoke`
- `PYTORCH_RUNTIME_IMAGE=nvcr.io/nvidia/ai-dynamo/vllm-runtime@sha256:de8ac9afb52711b08169e0f58388528c091efae6fb367a6fcfa119edef4bb233`
- `OCI2GDS_STRICT=true`
- `REQUIRE_DIRECT_GDS=true`
- `OCI2GDS_FORCE_NO_COMPAT=true` (default fail-fast: sets `CUFILE_ENV_PATH_JSON` with compat-mode disabled for the probe process)
- `OCI2GDS_FORCE_EXIT_AFTER_SUMMARY=true` (default; avoids known teardown crashes in some runtime/toolchain combinations)
- `OCI2GDS_VALIDATE_SAMPLE_BYTES=true` (compares first 4KiB GPU-loaded bytes with host bytes per sampled shard)
- `REQUIRE_NVFS_STATS_DELTA_MODE=auto` (default: require counter deltas only when nvfs stats are enabled)
- `REQUIRE_STRICT_PROBE_EVIDENCE=true` (fail unless probe reports native-cufile + cuFile init success)
- `ALLOW_RELAXED_GDS=false` (default; strict GDS policy must remain enabled)
- `HOST_PROBE_MIN_THROUGHPUT_MIB_S=0` (optional perf floor gate)
- `HOST_PROBE_MAX_REGRESSION_PCT=0` (optional baseline regression gate; `>0` enforces max drop)
- `MIN_FREE_GB_DOCKER=80` (fails fast when Docker data-root free space is below 80 GiB)
- `MIN_FREE_GB_MODEL_ROOT=20` (fails fast when `OCI2GDSD_ROOT_PATH` free space is below 20 GiB)
- `AUTO_CONFIGURE_STORAGE=true` (auto-migrates Docker `data-root` to `/mnt/nvme/docker` when root disk is too small and `/mnt/nvme` has capacity)

Assumptions:

- Probe container runs with `--privileged` by default in this harness.
- Probe compiles native extension from shared source file: `platform/k3s/examples/qwen-hello/native/oci2gds_torch_native.cpp`.

Runtime dependency behavior:

- `platform/k3s/examples/qwen-hello/app/deps_bootstrap.py` is check-only by default and fails fast when required Python packages are missing.
- Optional runtime `pip install` is debug-only via `OCI2GDS_ALLOW_RUNTIME_PIP_INSTALL=true`.

## Useful overrides

```bash
# Probe a specific model digest
MODEL_ID=qwen3-0.6b MODEL_DIGEST=sha256:... make verify-host-qwen-smoke

# Validate full quick-example lifecycle (ensure/status/verify/release)
MODEL_ID=qwen3-0.6b \
MODEL_DIGEST=sha256:... \
MODEL_REF_OVERRIDE=registry.example.com/models/qwen3-0.6b@sha256:... \
make verify-host-qwen-smoke

# Use a different model root
OCI2GDSD_ROOT_PATH=/var/lib/oci2gdsd make verify-host-qwen-smoke

# Allow fallback mode (debug-only; strict policy guard must be explicitly relaxed)
ALLOW_RELAXED_GDS=true OCI2GDS_STRICT=false REQUIRE_DIRECT_GDS=false OCI2GDS_FORCE_NO_COMPAT=false make verify-host-qwen-smoke

# Optional: disable immediate process exit after summary (debug-only)
OCI2GDS_FORCE_EXIT_AFTER_SUMMARY=false make verify-host-qwen-smoke

# nvfs counter gate modes:
# - auto (default): require deltas only when stats are enabled
# - required: always require deltas
# - off: never require deltas
REQUIRE_NVFS_STATS_DELTA_MODE=required make verify-host-qwen-smoke

# Optional perf gates
HOST_PROBE_MIN_THROUGHPUT_MIB_S=5000 HOST_PROBE_MAX_REGRESSION_PCT=20 make verify-host-qwen-smoke

# Skip CLI quick-example lifecycle validation
VALIDATE_QUICK_EXAMPLE=false make verify-host-qwen-smoke

# Override storage gates (GiB) if your model/image footprint differs
MIN_FREE_GB_DOCKER=120 MIN_FREE_GB_MODEL_ROOT=40 make prereq-host-gds
```

## Output

- `platform/host/e2e/work/results/gdscheck-host.txt` (when `REQUIRE_DIRECT_GDS=true`)
- `platform/host/e2e/work/results/quick-example-status.json`
- `platform/host/e2e/work/results/quick-example-verify.json`
- `platform/host/e2e/work/results/quick-example-ensure.json` (only when `MODEL_REF_OVERRIDE` is set)
- `platform/host/e2e/work/results/quick-example-release.json` (only when `MODEL_REF_OVERRIDE` is set)
- `platform/host/e2e/work/results/host-qwen-gds.log`
- `platform/host/e2e/work/results/host-qwen-gds-summary.json`
- `platform/host/e2e/work/results/host-qwen-probe-baseline.json`
- `platform/host/e2e/work/results/environment-report.txt`

The probe prints a structured summary line:

- `HOST_QWEN_GDS_PROBE {...}`

## nvfs IO stats counters

If `/proc/driver/nvidia-fs/stats` shows `IO stats: Disabled`, `Ops` counter deltas are not reliable proof.
The harness now reports this state and warns automatically.

To enable kernel-side rw counters for stronger counter-based validation:

```bash
sudo sh -c 'echo 1 > /sys/module/nvidia_fs/parameters/rw_stats_enabled'
cat /sys/module/nvidia_fs/parameters/rw_stats_enabled
```

Then run with a hard gate:

```bash
REQUIRE_NVFS_STATS_DELTA_MODE=required make verify-host-qwen-smoke
```

If strict no-compat init fails (for example `cuFileDriverOpen failed` under `OCI2GDS_FORCE_NO_COMPAT=true`), the harness now fails fast with an explicit error.
That is intentional under fail-fast defaults; only use `OCI2GDS_FORCE_NO_COMPAT=false` temporarily for debugging.

## Storage remediation

When `prereq-host-gds` fails with an insufficient-space error, use a larger mounted disk (prefer NVMe) and move Docker storage there:

```bash
sudo mkdir -p /mnt/nvme/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'JSON'
{
  "data-root": "/mnt/nvme/docker",
  "default-runtime": "nvidia",
  "features": { "cdi": true },
  "runtimes": { "nvidia": { "path": "nvidia-container-runtime", "args": [] } }
}
JSON
sudo systemctl restart docker
```
