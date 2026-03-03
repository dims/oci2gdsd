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
- `OCI2GDS_FORCE_NO_COMPAT=false` (optional: sets `CUFILE_ENV_PATH_JSON` with compat-mode disabled for the probe process)
- `OCI2GDS_VALIDATE_SAMPLE_BYTES=true` (compares first 4KiB GPU-loaded bytes with host bytes per sampled shard)
- `REQUIRE_NVFS_STATS_DELTA=false` (optional hard gate on `/proc/driver/nvidia-fs/stats` `Ops` counter deltas)

## Useful overrides

```bash
# Probe a specific model digest
MODEL_ID=qwen3-0.6b MODEL_DIGEST=sha256:... make host-e2e-qwen-quick

# Use a different model root
OCI2GDSD_ROOT_PATH=/var/lib/oci2gdsd make host-e2e-qwen-quick

# Allow fallback mode (no direct-path enforcement)
OCI2GDS_STRICT=false REQUIRE_DIRECT_GDS=false make host-e2e-qwen-quick

# Require nvidia-fs Ops counters to increase (fails if driver stats are unavailable/disabled)
REQUIRE_NVFS_STATS_DELTA=true make host-e2e-qwen-quick
```

## Output

- `testharness/host-e2e/work/results/gdscheck-host.txt` (when `REQUIRE_DIRECT_GDS=true`)
- `testharness/host-e2e/work/results/host-qwen-gds.log`

The probe prints a structured summary line:

- `HOST_QWEN_GDS_PROBE {...}`
