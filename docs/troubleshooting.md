# Troubleshooting Guide

> **New here?** Before anything else, run `make k3s-e2e-prereq` (or `make host-e2e-prereq`
> for host-only). That single step auto-installs missing tools and catches the most common
> setup problems. If you're on a machine without an A100 + NVMe, see §4 and §14 first —
> strict direct-GDS requires specific hardware.

This guide is for failures we repeatedly observed while running:

- `make k3s-e2e-qwen-quick`
- `make host-e2e-qwen-quick`

Use it together with:

- [docs/direct-gds-recreate-runbook.md](direct-gds-recreate-runbook.md)
- [testharness/k3s-e2e/README.md](../testharness/k3s-e2e/README.md)
- [testharness/host-e2e/README.md](../testharness/host-e2e/README.md)

## 1) Fast Triage By Symptom

| Symptom | What it usually means | First action |
|---|---|---|
| `REQUIRE_DIRECT_GDS=true but direct-GDS platform preflight failed` | Host is not direct-path capable right now | Run `gdscheck -p` and check `NVMe : Supported` |
| Pod `CrashLoopBackOff` with `No help topic for 'enable-cuda-compat'` | NVIDIA container toolkit is too old for runtime hook used by container stack | Upgrade to toolkit `>= 1.18.2`, restart runtime (`docker`, `k3s`) |
| `error loading config file "/etc/rancher/k3s/k3s.yaml": permission denied` | Non-root user reading k3s kubeconfig without permission | Use `sudo k3s kubectl ...` or configure kubeconfig mode |
| Runtime image precheck fails with `missing: c++` | Selected runtime image cannot build native extension path | Use `PYTORCH_RUNTIME_IMAGE=nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1` |
| Space errors during pull/build/apply | Docker/k3s/model root on small boot disk | Move Docker data-root and k3s/model paths to `/mnt/nvme` |
| Direct probe says ok but NVFS counters stay zero | `nvidia-fs` IO stats disabled | Enable `rw_stats_enabled=1` or keep counter gate disabled |
| qwen quick fails with missing model digest/ref | Quick mode does not have model identity yet | Run full `make k3s-e2e` once or pass explicit `MODEL_*_OVERRIDE` |
| No `nvidia.com/gpu` allocatable | GPU operator/device plugin not ready | Install/repair GPU operator, then re-check node allocatable |

## 2) Preflight First, Always

Before any quick run on a fresh host:

```bash
make k3s-e2e-prereq
make host-e2e-prereq
```

The prereq scripts already check and/or auto-fix common issues:

- required tools (`docker`, `k3s`, `nvidia-ctk`, `gdscheck`, etc.)
- runtime image sanity (`python3`, `c++`, `libcufile`)
- privileged-container assumptions for GDS workloads
- storage minimums and optional auto-migration to `/mnt/nvme`
- direct-path gate (`gdscheck -p`) when `REQUIRE_DIRECT_GDS=true`

## 3) Frequently Missing Install/Setup/Config (Fresh Hosts)

These were the most common missing pieces in repeated bring-up runs.

| Missing item | Why it matters | What to set/install |
|---|---|---|
| NVIDIA container toolkit too old | Pods fail at startup with `No help topic for 'enable-cuda-compat'` | Upgrade to `nvidia-container-toolkit>=1.18.2` + restart `docker` and `k3s` |
| GDS userspace tools (`gdscheck`) | Strict direct gate cannot validate platform | Install `nvidia-gds` or `gds-tools-*` packages |
| Direct-path capable kernel/driver alignment | `gdscheck -p` stays unsupported | Use validated NVIDIA stack (driver + `nvidia-fs` + compatible kernel); reboot and re-verify |
| Guest-visible local NVMe | No true NVMe direct path available | Choose provider/instance exposing `/dev/nvme*`; mount NVMe for model/storage paths |
| Docker data-root on tiny boot disk | Image pulls/builds fail or stall | Move Docker root to `/mnt/nvme/docker` |
| k3s data-dir on tiny boot disk | Cluster/system images fill root | Move k3s data-dir to `/mnt/nvme/k3s` |
| Runtime image lacks compiler/libcufile | Native probe path fails (`missing: c++`) | Use `nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1` (current known-good default) |
| k3s kubeconfig permissions | `permission denied` errors for `kubectl` | Use `sudo k3s kubectl ...` (or relax kubeconfig mode deliberately) |
| GPU operator/device plugin not ready | No `nvidia.com/gpu` allocatable | Install/fix GPU operator before workload apply |
| nvfs IO stats disabled | Ops counters remain zero even with direct probe | `echo 1 > /sys/module/nvidia_fs/parameters/rw_stats_enabled` when counter proof is required |

One-time bootstrap (Ubuntu-based hosts, representative):

```bash
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  nvidia-container-toolkit=1.18.2-1 \
  nvidia-container-toolkit-base=1.18.2-1 \
  nvidia-container-runtime=3.14.0-1 \
  libnvidia-container-tools \
  libnvidia-container1 \
  nvidia-fs \
  nvidia-gds-12-6
sudo systemctl restart docker
sudo systemctl restart k3s
```

Storage baseline we repeatedly needed:

```bash
sudo mkdir -p /mnt/nvme/docker /mnt/nvme/k3s /mnt/nvme/oci2gdsd
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

Validate after setup:

```bash
nvidia-ctk --version
sudo gdscheck -p | grep -E 'NVMe|IOMMU'
docker info --format '{{.DockerRootDir}}'
df -h
```

## 4) Direct GDS Not Available

### How to confirm

```bash
sudo gdscheck -p
lsblk -f
```

Required signal for strict mode:

- `NVMe : Supported`

Common fail patterns seen repeatedly:

- no guest-visible NVMe device
- provider disk is virtio/SCSI only
- software RAID path presented instead of raw NVMe
- host kernel/driver stack not aligned with working GDS path

### What to do

1. Use a provider/instance with guest-visible local NVMe.
2. Keep model root on that NVMe mount (for example `/mnt/nvme/oci2gdsd`).
3. Re-run prereq and quick targets.
4. If still unsupported after one bounded remediation attempt, stop and change host/provider.

## 5) `enable-cuda-compat` Hook Failure

Observed error:

```text
No help topic for 'enable-cuda-compat'
```

Root cause observed multiple times:

- NVIDIA container toolkit/runtime hook version too old for generated CDI hook usage.

Fix:

```bash
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  nvidia-container-toolkit=1.18.2-1 \
  nvidia-container-toolkit-base=1.18.2-1 \
  nvidia-container-runtime=3.14.0-1 \
  libnvidia-container-tools \
  libnvidia-container1
sudo systemctl restart docker
sudo systemctl restart k3s
```

Verify:

```bash
nvidia-ctk --version
nvidia-cdi-hook --help | grep enable-cuda-compat
```

## 6) k3s Access and Runtime Issues

### Kubeconfig permission denied

Symptom:

```text
open /etc/rancher/k3s/k3s.yaml: permission denied
```

Use:

```bash
sudo k3s kubectl get nodes
```

The harness already uses `sudo k3s kubectl` when needed (`K3S_USE_SUDO=true` default).

### NVIDIA runtime envvar injection issue

For k3s mode, prereq ensures:

- `accept-nvidia-visible-devices-envvar-when-unprivileged=true`

and restarts k3s only if changed.

## 7) Storage and Pull Failures

Large pulls/builds are common in this repo (runtime images + model artifacts).
Repeated issue: boot/root disk fills up.

Recommended layout:

- `/mnt/nvme/docker` for Docker data-root
- `/mnt/nvme/k3s` for k3s data-dir
- `/mnt/nvme/oci2gdsd` for model root

Quick check:

```bash
docker info --format '{{.DockerRootDir}}'
df -h
```

The prereq scripts enforce minimum free space and can auto-configure storage if `/mnt/nvme` has capacity.

## 8) Runtime Image Toolchain Mismatch

Repeated issue:

- runtime image lacks `c++`, causing native extension setup to fail.

Recommended default in this repo:

```bash
PYTORCH_RUNTIME_IMAGE=nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1
```

The prereq check now probes runtime image contents before full run.

## 9) Strict Mode and No-Compat Behavior

Current defaults are intentionally fail-fast for real GDS validation:

- `REQUIRE_DIRECT_GDS=true`
- `OCI2GDS_STRICT=true`
- `OCI2GDS_PROBE_STRICT=true`
- `OCI2GDS_FORCE_NO_COMPAT=true`

If strict direct path cannot be initialized, runs should fail, not silently pass in compat mode.
Only disable strict/no-compat temporarily for debugging.

## 10) NVFS Counters Stay Zero

Repeated observation:

- direct probe can report `mode_counts={"direct":...}` while kernel Ops counters stay zero.

Most often this is because IO stats are disabled:

```bash
cat /proc/driver/nvidia-fs/stats | grep 'IO stats'
cat /sys/module/nvidia_fs/parameters/rw_stats_enabled
```

Enable counters:

```bash
sudo sh -c 'echo 1 > /sys/module/nvidia_fs/parameters/rw_stats_enabled'
```

Repo default now uses `REQUIRE_NVFS_STATS_DELTA_MODE=auto` to avoid false negatives in environments where counters remain unavailable. Use `REQUIRE_NVFS_STATS_DELTA_MODE=required` for hard counter gating when you know counters are enabled.

## 11) Quick Target Fails Due To Model Identity

`make k3s-e2e-qwen-quick` needs model digest and registry ref.

Ways to satisfy:

1. Run `make k3s-e2e` once to seed identity artifacts.
2. Set explicit overrides:

```bash
MODEL_DIGEST_OVERRIDE=sha256:... \
MODEL_REF_OVERRIDE=oci-model-registry.oci-model-registry.svc.cluster.local:5000/models/qwen3-0.6b@sha256:... \
make k3s-e2e-qwen-quick
```

## 12) Recommended Recovery Sequence (Fresh A100)

1. Run prereq:

```bash
make k3s-e2e-prereq
```

2. If toolkit hook error appears, upgrade toolkit/runtime and restart services.
3. Re-run:

```bash
make k3s-e2e-qwen-quick
make host-e2e-qwen-quick
```

4. If direct gate still fails:
   - re-check `gdscheck -p`
   - verify guest-visible NVMe and mount path
   - if unsupported after bounded attempts, switch host/provider

## 13) What To Attach In Bug Reports

For fast triage, include:

1. `testharness/k3s-e2e/work/results/gdscheck.txt`
2. `testharness/host-e2e/work/results/gdscheck-host.txt`
3. `testharness/k3s-e2e/work/results/qwen-hello.log`
4. `testharness/host-e2e/work/results/host-qwen-gds.log`
5. `nvidia-smi` output
6. `uname -r`
7. `nvidia-ctk --version`
8. `docker info --format '{{.DockerRootDir}}'`

## 14) Non-Goals and Known Limits

- Nested containerized Kubernetes can run app-level validation, but strict direct-path fidelity depends on host/provider topology.
- Provider capability varies significantly; some A100 offerings never expose usable direct NVMe path.
- Fast runs rely on privileged containers for current GDS probe mechanics.
