# A100 Quickstart

This is the shortest path for a fresh A100 Linux host with strict direct-GDS
validation (repo default).

For full host qualification/remediation, use:

- `docs/direct-gds-runbook.md`

## 1) Clone and enter repo

```bash
git clone https://github.com/dims/oci2gdsd.git
cd oci2gdsd
```

## 2) Fast host qualification (before spending test time)

```bash
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
ls /dev/nvme* 2>/dev/null || true
sudo gdscheck -p
```

Hard stop for strict direct-GDS path:

- no guest-visible NVMe
- `NVMe : Supported` cannot be established after bounded remediation

## 3) Run prereqs + smoke

```bash
make prereq
make verify-smoke
```

## 4) Run full k3s runtime suite (2nd-level validation)

```bash
make verify-k3s-qwen verify-k3s-tensor verify-k3s-vllm
```

Runtime-specific knobs/defaults live in:

- `platform/k3s/.env.defaults`
- `platform/k3s/.env.example`
- `platform/k3s/README.md`

## Artifacts

k3s harness artifacts are written under:

- `platform/k3s/work/artifacts/results`
- `platform/k3s/work/artifacts/logs`
- `platform/k3s/work/artifacts/rendered`

## Cleanup

```bash
make clean-k3s
```

If any step fails, use:

- `docs/troubleshooting.md` for symptom-driven triage
- `docs/direct-gds-runbook.md` for strict direct-GDS remediation flow
