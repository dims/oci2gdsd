# DaemonSet Manifest Guide

This guide describes the raw-manifest deployment path for running `oci2gdsd serve`
as a node-level daemon and validating GPU load/export lifecycle from a workload pod.

## Files

- `examples/daemonset/oci2gdsd-daemonset.yaml.tpl`
- `examples/daemonset/pytorch-daemon-client-job.yaml.tpl`
- `examples/daemonset/pytorch_daemon_client.py`

## What this mode does

1. Deploys a privileged `oci2gdsd` DaemonSet on GPU nodes.
   - Daemon pod uses `runtimeClassName: nvidia` and sets `NVIDIA_VISIBLE_DEVICES=all`.
2. Shares hostPath cache root and UNIX socket with workload pods.
3. Uses an init container (`ensure/status/verify`) to pull OCI model shards.
4. Runs a PyTorch workload that calls daemon APIs:
   - `POST /v1/gpu/load` (`mode=persistent`)
   - `POST /v1/gpu/export`
   - `GET /v1/gpu/status`
   - `POST /v1/gpu/unload`

## Harness entrypoint (recommended)

```bash
make k3s-e2e-daemonset-manifest
```

Equivalent explicit mode toggle:

```bash
E2E_DEPLOY_MODE=daemonset-manifest make k3s-e2e
```

## Key environment variables

- `OCI2GDSD_DAEMON_NAMESPACE` (default `oci2gdsd-daemon`)
- `OCI2GDSD_SOCKET_HOST_PATH` (default `/var/run/oci2gdsd`)
- `OCI2GDSD_ROOT_PATH` (default `/mnt/nvme/oci2gdsd` in host-direct profile)
- `REQUIRE_DIRECT_GDS` (default `true`)

## Success markers

The daemon-client workload log (`testharness/k3s-e2e/work/results/pytorch-daemon-client.log`) must include:

- `DAEMON_GPU_LOAD_READY`
- `DAEMON_GPU_EXPORT_OK`
- `DAEMON_GPU_STATUS_OK`
- `DAEMON_GPU_UNLOAD_OK`
- `PYTORCH_DAEMON_CLIENT_SUCCESS`

The harness also checks preload readiness (`"status": "READY"`) and runs release/gc validation.
