# host direct-GDS quick e2e

This harness runs a host-only strict direct-GDS probe for a preloaded Qwen model.
It does not require Kubernetes for the probe itself, but it does need a model already
downloaded to disk.

## Getting a model on disk (pick one)

**Option A — run the full e2e once first (recommended for first-time setup):**

```bash
make k3s-e2e-prereq
make k3s-e2e
```

This provisions a local k3s cluster, packages Qwen3, and runs `oci2gdsd ensure` to
download the model to `OCI2GDSD_ROOT_PATH`. After it completes, the model is on disk
and the host probe can use it.

**Option B — pass model identity explicitly (skips Kubernetes entirely):**

If you already have a model digest and registry ref, pass them directly:

```bash
MODEL_ID=qwen3-0.6b \
MODEL_DIGEST=sha256:... \
MODEL_REF_OVERRIDE=registry.example.com/models/qwen3-0.6b@sha256:... \
make host-e2e-prereq
make host-e2e-qwen-quick
```

When `MODEL_REF_OVERRIDE` is set, `host-e2e-qwen-quick` runs an idempotent
`oci2gdsd ensure` + `release` cycle as part of quick-example lifecycle validation.

**Option C — model is already on disk:**

If you've previously run the full e2e or manually downloaded the model, just run:

```bash
make host-e2e-prereq
make host-e2e-qwen-quick
```

The prereq script auto-detects the newest `READY` entry for `MODEL_ID` under
`OCI2GDSD_ROOT_PATH`.

Defaults are strict direct-GDS. On hosts where `gdscheck -p` reports
`NVMe : compat/Unsupported`, the target intentionally fails fast.
By default, `host-e2e-qwen-quick` also validates CLI quick-example operations
(`status`, `verify`, and optionally `ensure`/`release`).

## Run

From repo root:

```bash
make host-e2e-prereq
make host-e2e-qwen-quick
```

`make host-e2e-prereq` auto-installs host prerequisites by default on Ubuntu/Debian (`INSTALL_MISSING_PREREQS=true`).
When `REQUIRE_DIRECT_GDS=true`, it also attempts to install GDS user-space tools (`gdscheck`) if missing.
Set `INSTALL_MISSING_PREREQS=false` to run checks only.

Defaults:

- `OCI2GDSD_ROOT_PATH=/mnt/nvme/oci2gdsd`
- `MODEL_ID=qwen3-0.6b`
- `MODEL_DIGEST` auto-detected from newest `READY` entry for `MODEL_ID` when unset
- `MODEL_REF_OVERRIDE` optional; when set, enables `ensure`/`release` quick-example checks
- `VALIDATE_QUICK_EXAMPLE=true` (run CLI lifecycle assertions before probe)
- `QUICK_EXAMPLE_LEASE_HOLDER=host-e2e-qwen-quick`
- `PYTORCH_RUNTIME_IMAGE=nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1`
- `OCI2GDS_STRICT=true`
- `REQUIRE_DIRECT_GDS=true`
- `OCI2GDS_FORCE_NO_COMPAT=true` (default fail-fast: sets `CUFILE_ENV_PATH_JSON` with compat-mode disabled for the probe process)
- `OCI2GDS_FORCE_EXIT_AFTER_SUMMARY=false` (default; set `true` only if you need to bypass known teardown crashes in specific runtime/toolchain combinations)
- `OCI2GDS_VALIDATE_SAMPLE_BYTES=true` (compares first 4KiB GPU-loaded bytes with host bytes per sampled shard)
- `REQUIRE_NVFS_STATS_DELTA=false` (default relaxed because some direct-path environments still report zero `Ops` counters)
- `MIN_FREE_GB_DOCKER=80` (fails fast when Docker data-root free space is below 80 GiB)
- `MIN_FREE_GB_MODEL_ROOT=20` (fails fast when `OCI2GDSD_ROOT_PATH` free space is below 20 GiB)
- `AUTO_CONFIGURE_STORAGE=true` (auto-migrates Docker `data-root` to `/mnt/nvme/docker` when root disk is too small and `/mnt/nvme` has capacity)

Assumptions:

- Probe container runs with `--privileged` by default in this harness.
- Probe compiles native extension from shared source file: `examples/qwen-hello/native/oci2gds_torch_native.cpp`.

Runtime dependency behavior:

- `examples/qwen-hello/app/deps_bootstrap.py` is check-only by default and fails fast when required Python packages are missing.
- Optional runtime `pip install` is debug-only via `OCI2GDS_ALLOW_RUNTIME_PIP_INSTALL=true`.

## Useful overrides

```bash
# Probe a specific model digest
MODEL_ID=qwen3-0.6b MODEL_DIGEST=sha256:... make host-e2e-qwen-quick

# Validate full quick-example lifecycle (ensure/status/verify/release)
MODEL_ID=qwen3-0.6b \
MODEL_DIGEST=sha256:... \
MODEL_REF_OVERRIDE=registry.example.com/models/qwen3-0.6b@sha256:... \
make host-e2e-qwen-quick

# Use a different model root
OCI2GDSD_ROOT_PATH=/var/lib/oci2gdsd make host-e2e-qwen-quick

# Allow fallback mode (no direct-path enforcement)
OCI2GDS_STRICT=false REQUIRE_DIRECT_GDS=false make host-e2e-qwen-quick

# Optional: force immediate process exit after summary (debug-only workaround)
OCI2GDS_FORCE_EXIT_AFTER_SUMMARY=true make host-e2e-qwen-quick

# Tighten nvfs counter requirement explicitly (optional)
REQUIRE_NVFS_STATS_DELTA=true make host-e2e-qwen-quick

# Skip CLI quick-example lifecycle validation
VALIDATE_QUICK_EXAMPLE=false make host-e2e-qwen-quick

# Override storage gates (GiB) if your model/image footprint differs
MIN_FREE_GB_DOCKER=120 MIN_FREE_GB_MODEL_ROOT=40 make host-e2e-prereq
```

## Output

- `testharness/host-e2e/work/results/gdscheck-host.txt` (when `REQUIRE_DIRECT_GDS=true`)
- `testharness/host-e2e/work/results/quick-example-status.json`
- `testharness/host-e2e/work/results/quick-example-verify.json`
- `testharness/host-e2e/work/results/quick-example-ensure.json` (only when `MODEL_REF_OVERRIDE` is set)
- `testharness/host-e2e/work/results/quick-example-release.json` (only when `MODEL_REF_OVERRIDE` is set)
- `testharness/host-e2e/work/results/host-qwen-gds.log`

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
REQUIRE_NVFS_STATS_DELTA=true make host-e2e-qwen-quick
```

If strict no-compat init fails (for example `cuFileDriverOpen failed` under `OCI2GDS_FORCE_NO_COMPAT=true`), the harness now fails fast with an explicit error.
That is intentional under fail-fast defaults; only use `OCI2GDS_FORCE_NO_COMPAT=false` temporarily for debugging.

## Storage remediation

When `host-e2e-prereq` fails with an insufficient-space error, use a larger mounted disk (prefer NVMe) and move Docker storage there:

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
