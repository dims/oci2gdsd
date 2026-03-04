# local CLI lifecycle e2e

This harness runs a real no-GPU, no-Kubernetes end-to-end validation of core CLI
semantics:

1. start local OCI registry
2. push a tiny OCI-ModelProfile-v1 artifact
3. run `ensure`
4. run `status`
5. run `list`
6. run `verify`
7. run `profile lint` and `profile inspect`
8. run `release`
9. run `gc`
10. confirm final `status=RELEASED`

## Run

From repo root:

```bash
make local-e2e-prereq
make local-e2e
```

For a one-liner:

```bash
make local-e2e
```

## Defaults

- `REGISTRY_NAME=oci2gdsd-local-e2e-registry`
- `REGISTRY_PORT=5004`
- `MODEL_ID=test-model`
- `MODEL_REPO=models/test-model`
- `MODEL_TAG=v1`
- `LEASE_HOLDER=local-e2e`
- `LOCAL_E2E_ROOT=/mnt/nvme/oci2gdsd-local-e2e` when `/mnt/nvme` exists, otherwise `testharness/local-e2e/work/state`

## Useful overrides

```bash
# Use a custom binary
OCI2GDSD_BIN=/path/to/oci2gdsd make local-e2e

# Use a different local registry port
REGISTRY_PORT=5008 make local-e2e

# Tighten prereq storage gates (GiB)
MIN_FREE_GB_DOCKER=20 MIN_FREE_GB_WORK=5 MIN_FREE_GB_LOCAL_ROOT=40 make local-e2e-prereq
```

## Artifacts

- `testharness/local-e2e/work/results/prereq-check.txt`
- `testharness/local-e2e/work/results/oras-push.log`
- `testharness/local-e2e/work/results/ensure.json`
- `testharness/local-e2e/work/results/status-ready.json`
- `testharness/local-e2e/work/results/list-ready.json`
- `testharness/local-e2e/work/results/verify.json`
- `testharness/local-e2e/work/results/profile-lint.json`
- `testharness/local-e2e/work/results/profile-inspect.json`
- `testharness/local-e2e/work/results/release.json`
- `testharness/local-e2e/work/results/gc.json`
- `testharness/local-e2e/work/results/status-released.json`
- `testharness/local-e2e/work/results/summary.txt`
