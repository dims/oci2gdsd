# Direct GDS Recreate Runbook

Date baseline: 2026-03-03

This is the short, versioned runbook for reproducing the bring-up path we used for
`oci2gdsd` direct-GDS testing and quick Qwen iteration.

## 1) Where We Tested

| Environment | Status | Summary |
|---|---|---|
| A100 host with guest-visible NVMe and NVIDIA kernel stack | Partial pass | Host strict GDS probes passed (either `gdscheck -p` showed `NVMe : Supported`, or strict `gdsio -x 0 -I 1` succeeded on NVMe-backed path). |
| A100 host without guest-visible NVMe (virtio-only) | Fail | `NVMe : Unsupported`, compat mode remained enabled; true direct NVMe->GPU path unavailable. |
| Nested containerized Kubernetes | Fail for strict direct | App flow can run, but strict direct-path probe can still fail due to platform/runtime topology. |
| Host-native `k3s` + NVIDIA runtime | Best integration signal | Use this for quick iteration once host-level direct GDS is already qualified. |

## 2) First Gate: Host Qualification (5-10 min)

Run on candidate host:

```bash
set -euo pipefail
uname -a
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
lsblk -f
lsmod | grep nvidia_fs || true
/usr/local/cuda/gds/tools/gdscheck -p
```

Pass condition:

1. At least one direct-path proof succeeds:
   - `gdscheck -p` includes `NVMe : Supported`, or
   - strict `gdsio -x 0 -I 1` succeeds on the NVMe-backed workload path and NVMe registration is visible in NVFS (`/proc/driver/nvidia-fs/devices` non-empty, or `/proc/driver/nvidia-fs/modules` contains `nvme`).
2. NVMe device is visible in guest (`/dev/nvme*`).
3. Free space gates for harness are satisfied (default):
   - Docker data-root: at least `100 GiB` free (`MIN_FREE_GB_DOCKER`)
   - k3s root (`/var/lib/rancher/k3s`): at least `50 GiB` free (`MIN_FREE_GB_K3S`)
   - `OCI2GDSD_ROOT_PATH`: at least `20 GiB` free (`MIN_FREE_GB_OCI2GDS_ROOT`)

Fast fail condition:

1. Only virtio disk (for example `vda`) and no NVMe path.
2. Both direct proofs fail after one remediation attempt/timebox.

Default policy for this repo:

1. Run the full remediation bundle in §3 unless a hard blocker is obvious up front (for example no guest-visible `/dev/nvme*`).
2. Do not silently relax strict direct-path requirements in normal validation flows.

## 3) Host Bring-Up That Worked

On qualifying hosts, this alignment was required:

```bash
sudo apt-get update
sudo apt-get install -y nvidia-driver-570-open nvidia-fs nvidia-gds-12-6 linux-image-nvidia
sudo reboot
```

If `apt` is stuck in a broken half-configured NVIDIA state (common after interrupted installs),
clean it first, then run the alignment install:

```bash
sudo apt-get purge -y \
  cuda-drivers-565 cuda-drivers-fabricmanager-565 \
  nvidia-driver-565-server nvidia-fs nvidia-fs-dkms nvidia-prime
sudo dpkg --configure -a
sudo apt-get -f install -y
sudo apt-get -s check
```

Post-reboot verify:

```bash
uname -r
nvidia-smi
lsmod | grep nvidia_fs
/usr/local/cuda/gds/tools/gdscheck -p
```

Expected key line: `NVMe : Supported`

Mount NVMe with sane options for strict checks:

```bash
sudo mkdir -p /mnt/nvme
sudo mount -t ext4 -o rw,noatime,data=ordered /dev/nvme0n1p1 /mnt/nvme
```

Move Docker data-root to the larger mount before heavy pulls:

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
docker info --format '{{.DockerRootDir}}'
```

After any reboot, re-check that `/mnt/nvme` is actually mounted before running harness targets:

```bash
mountpoint -q /mnt/nvme || sudo mount -t ext4 -o rw,noatime,data=ordered /dev/nvme0n1p1 /mnt/nvme
df -h /mnt/nvme /
docker info --format '{{.DockerRootDir}}'
```

If `/mnt/nvme` is not mounted, Docker may silently fall back to root-disk backed `/mnt/nvme/docker`
and fail storage gates later.

Strict gdsio probe:

```bash
sudo /usr/libexec/gds/tools/gdsio -D /mnt/nvme -d 0 -w 1 -s 1G -i 1M -x 0 -I 1
```

## 4) Quick Qwen Recreate (k3s Host-Direct)

In this repo, quick iteration defaults were wired for host-direct on k3s:

1. `QWEN_HELLO_PROFILE=host-direct` (default)
2. `OCI2GDSD_ROOT_PATH=/mnt/nvme/oci2gdsd` (unless overridden)
3. `OCI2GDS_STRICT=true` and `OCI2GDS_PROBE_STRICT=true` (unless overridden)

Run:

```bash
cd /path/to/oci2gdsd
QWEN_HELLO_PROFILE=host-direct REQUIRE_DIRECT_GDS=true make verify-k3s-qwen-smoke
```

## 5) Capture Artifacts Every Time

Save these for each run:

1. `gdscheck -p` output
2. strict `gdsio -x 0` output
3. NVFS registration evidence (`/proc/driver/nvidia-fs/devices` and `/proc/driver/nvidia-fs/modules`)
4. quick-qwen log (`platform/k3s/work/artifacts/results/qwen-hello.log`)
5. any `gpu probe`/profile lines reporting direct/fallback counts

## 6) Operator Timeboxes

1. Qualification pass: 10 minutes.
2. Remediation attempts per provider: 30 minutes max.
3. If both `gdscheck` and strict `gdsio -x 0 -I 1` fail (or no guest NVMe path), stop and delete instance.
