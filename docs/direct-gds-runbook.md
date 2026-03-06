# Direct GDS Environment Bring-up Runbook

Audience: operators minting fresh GPU hosts and validating strict direct GDS for `oci2gdsd`.

Scope:
- host qualification (A100 + NVMe + NVIDIA GDS stack)
- minimal-step remediation (no blind kitchen-sink installs)
- strict acceptance gates before running k3s/e2e

Policy:
- default to strict (`REQUIRE_DIRECT_GDS=true`)
- apply only the next required remediation step
- re-test after each step
- timebox per host/provider (max 30 minutes)

Authoritative GPUDirect Storage references:

- [NVIDIA GDS Overview Guide](https://docs.nvidia.com/gpudirect-storage/overview-guide/index.html)
- [NVIDIA GDS Troubleshooting Guide](https://docs.nvidia.com/gpudirect-storage/troubleshooting-guide/index.html)
- [NVIDIA GDS Release Notes](https://docs.nvidia.com/gpudirect-storage/release-notes/index.html)

---

## 1) Success Criteria (Strict)

A host is strict-qualified only when all are true:

1. Guest-visible NVMe exists (`/dev/nvme*`).
2. `nvidia_fs` module is loadable and healthy.
3. `gdscheck -p` reports `NVMe : Supported`.
4. strict `gdsio` (`-x 0`) succeeds on the target NVMe mount.
5. No evidence of forced compat fallback in the validated path.

Important nuance:
- `/proc/driver/nvidia-fs/stats` can show zero op counters when IO stats are disabled.
- zero counters alone are not a hard fail.

---

## 2) Fast Qualification (5-10 minutes)

Run this first on every new host:

```bash
set -euo pipefail
uname -a
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
lsblk -f
ls /dev/nvme* 2>/dev/null || true
lsmod | grep nvidia_fs || true
(gdscheck -p || /usr/local/cuda/gds/tools/gdscheck -p)
```

Interpretation:

1. No `/dev/nvme*`: non-qualifying for strict NVMe->GPU direct path. Stop and replace host.
2. NVMe present + `NVMe : Supported`: continue to strict probe.
3. NVMe present + `NVMe : Unsupported`: remediate by signature below.
4. `nvidia_fs` load/symbol errors: resolve kernel/driver/GDS mismatch first.

---

## 3) Decision Tree Remediation (Minimal Next Step)

## A) No guest NVMe visible

Symptom:
- `ls /dev/nvme*` is empty.

Action:
- do not spend cycles on deep remediation
- capture artifacts, delete host, try a different shape/provider

## B) NVMe exists but no usable filesystem/mount

Symptom:
- partition missing or unformatted
- `/mnt/nvme` not mounted

Action:

```bash
sudo parted -s /dev/nvme0n1 mklabel gpt || true
sudo parted -s /dev/nvme0n1 mkpart primary ext4 0% 100% || true
sudo mkfs.ext4 -F /dev/nvme0n1p1
sudo mkdir -p /mnt/nvme
sudo mount -t ext4 -o rw,noatime,data=ordered /dev/nvme0n1p1 /mnt/nvme
mount | grep /mnt/nvme
```

Re-run qualification.

## C) `nvidia_fs` fails to load (`Unknown symbol nvidia_p2p_*`)

Symptom:
- `modprobe nvidia_fs` fails
- dmesg shows `Unknown symbol nvidia_p2p_*`

Step C1 (minimal package alignment):

```bash
sudo apt-get update -y
sudo apt-get install -y --allow-change-held-packages \
  nvidia-fs-dkms nvidia-fs nvidia-gds-12-6 gds-tools-12-6
sudo modprobe nvidia_fs || true
```

If still failing, step C2 (open-driver alignment):

```bash
sudo apt-mark unhold nvidia-driver-565 nvidia-driver-565-open \
  nvidia-dkms-565 nvidia-dkms-565-open \
  nvidia-kernel-source-565 nvidia-kernel-source-565-open \
  nvidia-prime || true
sudo apt-get purge -y nvidia-prime || true
sudo apt-get install -y --allow-change-held-packages nvidia-driver-565-open
sudo reboot
```

If still failing, step C3 (full known-good bundle from successful A100 runs):

```bash
sudo apt-get update -y
sudo apt-get install -y --allow-change-held-packages \
  nvidia-driver-570-open \
  nvidia-fs \
  nvidia-gds-12-6 \
  gds-tools-12-6 \
  linux-image-nvidia \
  linux-modules-nvidia-fs-5.15.0-1096-nvidia \
  linux-headers-5.15.0-1096-nvidia
sudo dkms autoinstall -k 5.15.0-1096-nvidia
sudo update-initramfs -u -k 5.15.0-1096-nvidia
sudo reboot
```

Post-reboot verification:

```bash
uname -r
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
lsmod | grep nvidia_fs || true
gdscheck -p | egrep -i 'NVMe|IOMMU|use_compat_mode|GPU'
```

## D) `gdscheck` remains ambiguous

Run strict functional probe before deciding:

```bash
GDSIO=$(command -v gdsio || true)
if [ -z "$GDSIO" ] && [ -x /usr/libexec/gds/tools/gdsio ]; then GDSIO=/usr/libexec/gds/tools/gdsio; fi
if [ -z "$GDSIO" ] && [ -x /usr/local/cuda/gds/tools/gdsio ]; then GDSIO=/usr/local/cuda/gds/tools/gdsio; fi

sudo "$GDSIO" -D /mnt/nvme -d 0 -w 1 -s 1G -i 1M -x 0 -I 1
sudo cat /proc/driver/nvidia-fs/modules || true
sudo cat /proc/driver/nvidia-fs/devices || true
sudo cat /proc/driver/nvidia-fs/stats || true
```

Decision:

1. strict `gdsio -x 0` fails: host is not strict-ready.
2. strict `gdsio -x 0` succeeds: proceed.
3. no NVMe registration evidence after full remediation + timebox: treat as non-qualifying for strict claims.

## E) Disk/runtime preflight failures

If pulls/builds fail due space, move Docker data-root to NVMe:

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

Keep `OCI2GDSD_ROOT_PATH` on NVMe (`/mnt/nvme/oci2gdsd`).

---

## 4) k3s Bring-up Rules (What Matters)

For this repo in practice:

1. GPU workload pods must set `runtimeClassName: nvidia`.
2. GPU workload containers are expected to run privileged in this harness.
3. If you use a smoke pod, use an image/runtime combination where `nvidia-smi` is available.
4. If `k3s ctr images import -` becomes a bottleneck/failure path, disable runtime preloads and allow pod pull-on-demand.

Recommended e2e overrides for fresh nodes when import piping is unstable:

```bash
PRELOAD_WORKLOAD_IMAGE=false \
PRELOAD_PYTORCH_RUNTIME_IMAGE=false \
PRELOAD_TENSORRTLLM_RUNTIME_IMAGE=false \
PRELOAD_VLLM_RUNTIME_IMAGE=false
```

---

## 5) Validation Sequence After Host Qualification

Run in order:

1. `make verify-unit`
2. `make verify-local`
3. `make verify-k3s-runtime-contract-all`
4. `make verify-smoke`
5. `make verify-k3s-daemonset`
6. `make verify-k3s-tensor-e2e-daemonset`
7. `make verify-k3s-vllm-e2e-daemonset`
8. `make verify-k3s-daemonset-all`
9. `make verify-k3s-daemonset-parity-all`

If strict host qualification fails, do not report strict direct-GDS pass for downstream e2e.

---

## 6) Stop Criteria (Cost/Time Discipline)

Stop and replace host when any is true:

1. no guest-visible NVMe
2. `nvidia_fs` remains unloadable after C2/C3
3. strict `gdsio -x 0` cannot be established within 30 minutes
4. platform topology clearly blocks strict direct path

---

## 7) Artifact Checklist (Capture Every Run)

Save these per run under a timestamped folder:

1. `uname -a`
2. `nvidia-smi`
3. `lsblk -f`
4. `gdscheck -p`
5. strict `gdsio` output
6. `/proc/driver/nvidia-fs/modules`
7. `/proc/driver/nvidia-fs/devices` (if present)
8. `/proc/driver/nvidia-fs/stats`
9. harness logs (`platform/host/work/results`, `platform/k3s/work/artifacts/results`)

---

## 8) Common Failure Signatures

1. `Error: exec: "nvidia-smi": executable file not found` in k3s smoke pod:
   - missing NVIDIA runtime class/runtime wiring for that pod.
2. `torch.cuda.is_available() is false` in daemon client jobs:
   - workload pod missing NVIDIA runtime class/wiring.
3. `json.decoder.JSONDecodeError: Extra data` in daemon clients:
   - daemon HTTP response parsing too strict; use tolerant JSON parsing.
4. `ctr: unrecognized image format` during `k3s ctr images import -`:
   - avoid preloading large digest-pinned runtime images; use pull-on-demand.

---

## 9) One-Command Triage Block

```bash
set -euo pipefail
uname -a
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
lsblk -f
ls /dev/nvme* 2>/dev/null || true
lsmod | grep nvidia_fs || true
(gdscheck -p || /usr/local/cuda/gds/tools/gdscheck -p)

if [ -e /dev/nvme0n1p1 ]; then
  sudo mkdir -p /mnt/nvme
  mount | grep -q '/mnt/nvme' || sudo mount -t ext4 -o rw,noatime,data=ordered /dev/nvme0n1p1 /mnt/nvme || true
fi

GDSIO=$(command -v gdsio || true)
if [ -z "$GDSIO" ] && [ -x /usr/libexec/gds/tools/gdsio ]; then GDSIO=/usr/libexec/gds/tools/gdsio; fi
if [ -z "$GDSIO" ] && [ -x /usr/local/cuda/gds/tools/gdsio ]; then GDSIO=/usr/local/cuda/gds/tools/gdsio; fi
if [ -n "$GDSIO" ] && mount | grep -q '/mnt/nvme'; then
  sudo "$GDSIO" -D /mnt/nvme -d 0 -w 1 -s 1G -i 1M -x 0 -I 1 || true
fi

sudo cat /proc/driver/nvidia-fs/modules || true
sudo cat /proc/driver/nvidia-fs/devices || true
sudo cat /proc/driver/nvidia-fs/stats || true
```
