# A100 Quickstart

This is the shortest path for a fresh A100 Linux host.
It assumes strict direct-GDS validation is required (default in this repo).

## 1) Clone and enter repo

```bash
git clone https://github.com/dims/oci2gdsd.git
cd oci2gdsd
```

## 2) Review optional overrides

Defaults live in:

- `platform/k3s/.env.defaults`
- `platform/k3s/.env.example`

Optional overrides can be exported before running targets (for example `OCI2GDSD_ROOT_PATH=/mnt/nvme/oci2gdsd`).

## 3) Run full prereq chain

```bash
make prereq
```

This runs local + host + k3s prerequisite checks in order.

## 4) Run smoke validation

```bash
make verify-smoke
```

This executes:

- `verify-unit`
- `verify-local`
- `verify-host-qwen-smoke`
- `verify-k3s-qwen-smoke` (includes runtime-contract checks for qwen/pytorch path)

## 5) Run full k3s e2e

Inline qwen path:

```bash
make verify-k3s
```

Daemonset qwen path:

```bash
make verify-k3s-daemonset
```

All daemonset runtimes (qwen + TensorRT-LLM + vLLM):

```bash
make verify-k3s-daemonset-all
```

Parity-focused daemonset runtime checks:

```bash
make verify-k3s-daemonset-parity-all
```

## Artifacts

k3s harness artifacts are written under:

- `platform/k3s/work/artifacts/results`
- `platform/k3s/work/artifacts/logs`
- `platform/k3s/work/artifacts/rendered`

## Cleanup

```bash
make clean-k3s
```
