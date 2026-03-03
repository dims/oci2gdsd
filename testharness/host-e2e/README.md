# host direct-GDS quick e2e

This harness runs a host-only strict direct-GDS probe for a preloaded Qwen model.
It does not require Kubernetes.

## Run

From repo root:

```bash
make host-e2e-qwen-quick
```

Defaults:

- `OCI2GDSD_ROOT_PATH=/mnt/nvme/oci2gdsd`
- `MODEL_ID=qwen3-0.6b`
- `MODEL_DIGEST` auto-detected from newest `READY` entry for `MODEL_ID` when unset
- `PYTORCH_RUNTIME_IMAGE=nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1`
- `OCI2GDS_STRICT=true`
- `REQUIRE_DIRECT_GDS=true`
- `OCI2GDS_FORCE_NO_COMPAT=true` (default fail-fast: sets `CUFILE_ENV_PATH_JSON` with compat-mode disabled for the probe process)
- `OCI2GDS_VALIDATE_SAMPLE_BYTES=true` (compares first 4KiB GPU-loaded bytes with host bytes per sampled shard)
- `REQUIRE_NVFS_STATS_DELTA=true` (default fail-fast hard gate on `/proc/driver/nvidia-fs/stats` `Ops` counter deltas)

## Useful overrides

```bash
# Probe a specific model digest
MODEL_ID=qwen3-0.6b MODEL_DIGEST=sha256:... make host-e2e-qwen-quick

# Use a different model root
OCI2GDSD_ROOT_PATH=/var/lib/oci2gdsd make host-e2e-qwen-quick

# Allow fallback mode (no direct-path enforcement)
OCI2GDS_STRICT=false REQUIRE_DIRECT_GDS=false make host-e2e-qwen-quick

# Relax default fail-fast gates (only if you explicitly want a non-strict run)
OCI2GDS_FORCE_NO_COMPAT=false REQUIRE_NVFS_STATS_DELTA=false make host-e2e-qwen-quick
```

## Output

- `testharness/host-e2e/work/results/gdscheck-host.txt` (when `REQUIRE_DIRECT_GDS=true`)
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
