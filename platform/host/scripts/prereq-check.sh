#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${HARNESS_DIR}/../.." && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=../../lib/prereq.sh
source "${LIB_DIR}/prereq.sh"
WORK_DIR="${HARNESS_DIR}/work"
RESULTS_DIR="${WORK_DIR}/results"
mkdir -p "${RESULTS_DIR}"

PYTORCH_RUNTIME_IMAGE="${PYTORCH_RUNTIME_IMAGE:-nvcr.io/nvidia/ai-dynamo/vllm-runtime@sha256:de8ac9afb52711b08169e0f58388528c091efae6fb367a6fcfa119edef4bb233}"
REQUIRE_DIRECT_GDS="${REQUIRE_DIRECT_GDS:-true}"
REQUIRE_NVFS_STATS_DELTA_SET="${REQUIRE_NVFS_STATS_DELTA+x}"
REQUIRE_NVFS_STATS_DELTA="${REQUIRE_NVFS_STATS_DELTA:-}"
REQUIRE_NVFS_STATS_DELTA_MODE="${REQUIRE_NVFS_STATS_DELTA_MODE:-auto}"
INSTALL_MISSING_PREREQS="${INSTALL_MISSING_PREREQS:-true}"
ENABLE_FULL_GDS_STACK_REMEDIATION="${ENABLE_FULL_GDS_STACK_REMEDIATION:-true}"
OCI2GDSD_ROOT_PATH="${OCI2GDSD_ROOT_PATH:-/mnt/nvme/oci2gdsd}"
OCI2GDS_STRICT="${OCI2GDS_STRICT:-true}"
OCI2GDS_FORCE_NO_COMPAT="${OCI2GDS_FORCE_NO_COMPAT:-true}"
REQUIRE_STRICT_PROBE_EVIDENCE="${REQUIRE_STRICT_PROBE_EVIDENCE:-true}"
ALLOW_RELAXED_GDS="${ALLOW_RELAXED_GDS:-false}"
MIN_FREE_GB_DOCKER="${MIN_FREE_GB_DOCKER:-80}"
MIN_FREE_GB_MODEL_ROOT="${MIN_FREE_GB_MODEL_ROOT:-20}"
AUTO_CONFIGURE_STORAGE="${AUTO_CONFIGURE_STORAGE:-true}"
VALIDATE_QUICK_EXAMPLE="${VALIDATE_QUICK_EXAMPLE:-true}"

NVFS_STATS_MODE=""

emit_direct_gds_remediation() {
  cat >&2 <<'EOF'
Direct-GDS remediation options:
1. Full remediation bundle (default):
   - align kernel + driver + GDS packages
   - reboot
   - verify gdscheck
   - mount NVMe and move data paths to NVMe
   - run strict gdsio probe
2. Verify platform capability:
   sudo gdscheck -p
3. Keep strict mode (default) for real validation:
   REQUIRE_DIRECT_GDS=true OCI2GDS_STRICT=true OCI2GDS_FORCE_NO_COMPAT=true
4. For non-direct smoke only (not a true GDS pass), relax gates:
   ALLOW_RELAXED_GDS=true REQUIRE_DIRECT_GDS=false OCI2GDS_STRICT=false
EOF
}


configure_docker_data_root() {
  local target="${1:-/mnt/nvme/docker}"
  log "auto-configuring docker data-root=${target}"
  maybe_sudo mkdir -p "${target}"
  local tmp
  tmp="$(mktemp)"
  if maybe_sudo test -f /etc/docker/daemon.json; then
    maybe_sudo cat /etc/docker/daemon.json | jq \
      --arg root "${target}" \
      '. + {"data-root":$root,"default-runtime":"nvidia","features":((.features // {}) + {"cdi":true}),"runtimes":((.runtimes // {}) + {"nvidia":{"path":"nvidia-container-runtime","args":[]}})}' \
      > "${tmp}"
  else
    cat > "${tmp}" <<EOF
{
  "data-root": "${target}",
  "default-runtime": "nvidia",
  "features": { "cdi": true },
  "runtimes": { "nvidia": { "path": "nvidia-container-runtime", "args": [] } }
}
EOF
  fi
  maybe_sudo mv "${tmp}" /etc/docker/daemon.json
  maybe_sudo systemctl restart docker
}

maybe_auto_configure_storage() {
  if ! is_true "${AUTO_CONFIGURE_STORAGE}"; then
    return 0
  fi
  if [[ ! -d /mnt/nvme ]]; then
    return 0
  fi

  local docker_root docker_need docker_avail nvme_avail
  docker_root="$(maybe_sudo docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  [[ -n "${docker_root}" ]] || return 0
  docker_need=$((MIN_FREE_GB_DOCKER * 1024 * 1024))
  docker_avail="$(path_available_kb "${docker_root}")"
  nvme_avail="$(path_available_kb "/mnt/nvme")"
  if (( docker_avail < docker_need )) && [[ "${docker_root}" != /mnt/nvme/* ]] && (( nvme_avail >= docker_need )); then
    configure_docker_data_root "/mnt/nvme/docker"
  fi
}

emit_storage_remediation() {
  cat >&2 <<'EOF'
Storage remediation options:
1. Attach/mount a larger data disk (prefer local NVMe), for example at /mnt/nvme.
2. Move Docker data-root to that disk:
   sudo mkdir -p /mnt/nvme/docker
   sudo tee /etc/docker/daemon.json >/dev/null <<JSON
   {
     "data-root": "/mnt/nvme/docker",
     "default-runtime": "nvidia",
     "features": { "cdi": true },
     "runtimes": { "nvidia": { "path": "nvidia-container-runtime", "args": [] } }
   }
JSON
   sudo systemctl restart docker
3. Place OCI2GDSD_ROOT_PATH on the larger disk, e.g.:
   OCI2GDSD_ROOT_PATH=/mnt/nvme/oci2gdsd
4. As a temporary fallback only, prune local artifacts:
   docker system prune -af --volumes
EOF
}

check_path_free_gb() {
  local label="$1"
  local path="$2"
  local min_gb="$3"
  local avail_kb required_kb avail_gb mountpoint

  is_uint "${min_gb}" || die "${label} minimum free space is not numeric: ${min_gb}"
  avail_kb="$(path_available_kb "${path}")"
  required_kb=$((min_gb * 1024 * 1024))
  avail_gb=$((avail_kb / 1024 / 1024))
  mountpoint="$(path_mountpoint "${path}")"

  log "${label}: path=${path} mount=${mountpoint} available=${avail_gb}GiB required=${min_gb}GiB"
  if (( avail_kb < required_kb )); then
    emit_storage_remediation
    die "${label} has insufficient free space: ${avail_gb}GiB available < ${min_gb}GiB required (path=${path}, mount=${mountpoint})"
  fi
}

check_storage_prereqs() {
  maybe_auto_configure_storage

  local docker_root
  docker_root="$(maybe_sudo docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  [[ -n "${docker_root}" ]] || die "failed to detect DockerRootDir from docker info"

  check_path_free_gb "docker data-root" "${docker_root}" "${MIN_FREE_GB_DOCKER}"
  check_path_free_gb "oci2gdsd root path" "${OCI2GDSD_ROOT_PATH}" "${MIN_FREE_GB_MODEL_ROOT}"
}

ensure_root_writable() {
  maybe_sudo mkdir -p "${OCI2GDSD_ROOT_PATH}"
  if [[ -w "${OCI2GDSD_ROOT_PATH}" ]]; then
    return 0
  fi
  if is_true "${INSTALL_MISSING_PREREQS}"; then
    log "granting current user write access to ${OCI2GDSD_ROOT_PATH}"
    maybe_sudo chown -R "$(id -u):$(id -g)" "${OCI2GDSD_ROOT_PATH}" || true
  fi
  [[ -w "${OCI2GDSD_ROOT_PATH}" ]] || die "oci2gdsd root path is not writable: ${OCI2GDSD_ROOT_PATH}"
}

ensure_apt_available() {
  prereq_ensure_apt_available
}

apt_install() {
  prereq_apt_install "$@"
}

ensure_cmd_or_install() {
  prereq_ensure_cmd_or_install "$1" "$2" "${INSTALL_MISSING_PREREQS}"
}

install_gds_tools_if_missing() {
  if gdscheck_binary >/dev/null 2>&1; then
    return
  fi
  ensure_apt_available
  log "installing GPUDirect Storage user-space tools (gdscheck)"

  local repo_list="/etc/apt/sources.list.d/cuda-ubuntu2204-x86_64.list"
  if ! maybe_sudo test -f "${repo_list}"; then
    local keyring="/tmp/cuda-keyring_1.1-1_all.deb"
    curl -fsSL -o "${keyring}" \
      "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb"
    maybe_sudo dpkg -i "${keyring}" >/dev/null
    PREREQ_APT_UPDATED=0
  fi

  apt_install nvidia-gds || true
  if gdscheck_binary >/dev/null 2>&1; then
    return
  fi
  apt_install gds-tools-12-8 || true
  if gdscheck_binary >/dev/null 2>&1; then
    return
  fi
  apt_install gds-tools-12-6 || true
  if gdscheck_binary >/dev/null 2>&1; then
    return
  fi

  die "failed to install gdscheck automatically; install nvidia-gds (or gds-tools) manually"
}

has_guest_nvme() {
  ls /dev/nvme*n1 >/dev/null 2>&1 || ls /dev/nvme*n1p* >/dev/null 2>&1 || ls /dev/nvme[0-9] >/dev/null 2>&1
}

find_nvme_mount_candidate() {
  lsblk -pnro NAME,TYPE,FSTYPE,MOUNTPOINT | awk '$1 ~ /^\/dev\/nvme/ && $2=="part" && $3!="" && $4=="" {print $1; exit 0}'
}

find_nvme_raw_disk_candidate() {
  lsblk -pnro NAME,TYPE | awk '$1 ~ /^\/dev\/nvme/ && $2=="disk" {print $1; exit 0}'
}

attempt_full_gds_remediation_bundle() {
  local gdscheck_bin="$1"
  local log_file="${RESULTS_DIR}/gds-remediation.log"
  local post_report="${RESULTS_DIR}/gdscheck-prereq-post-remediation.txt"
  local needs_reboot=0

  : > "${log_file}"
  {
    echo "## full remediation attempt $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "kernel_before=$(uname -r)"
    echo "driver_before=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
  } >> "${log_file}"

  if ! has_guest_nvme; then
    {
      echo "hard_blocker=no_guest_nvme"
      echo "lsblk:"
      lsblk -f || true
    } >> "${log_file}"
    return 2
  fi

  if is_true "${INSTALL_MISSING_PREREQS}"; then
    if is_true "${ENABLE_FULL_GDS_STACK_REMEDIATION}"; then
      {
        echo "step=baseline_gds_stack_alignment"
        echo "action=install nvidia-fs-dkms nvidia-fs nvidia-gds-12-6 gds-tools-12-6 linux-headers-\$(uname -r)"
      } >> "${log_file}"
      ensure_apt_available
      apt_install --allow-change-held-packages \
        nvidia-fs-dkms \
        nvidia-fs \
        nvidia-gds-12-6 \
        gds-tools-12-6 \
        "linux-headers-$(uname -r)" >> "${log_file}" 2>&1 || true
    else
      {
        echo "non_destructive_step=skip_driver_kernel_package_mutation"
      } >> "${log_file}"
    fi
  fi

  maybe_sudo modprobe nvidia_fs >> "${log_file}" 2>&1 || true

  if is_true "${INSTALL_MISSING_PREREQS}" && is_true "${ENABLE_FULL_GDS_STACK_REMEDIATION}" && ! lsmod | grep -q '^nvidia_fs'; then
    {
      echo "step=known_good_driver_kernel_bundle"
      echo "action=install nvidia-driver-570-open + linux-image-nvidia + linux-modules-nvidia-fs-5.15.0-1096-nvidia"
    } >> "${log_file}"
    maybe_sudo apt-mark unhold \
      nvidia-driver-565 \
      nvidia-driver-565-open \
      nvidia-dkms-565 \
      nvidia-dkms-565-open \
      nvidia-kernel-source-565 \
      nvidia-kernel-source-565-open \
      nvidia-prime >> "${log_file}" 2>&1 || true
    maybe_sudo apt-get purge -y nvidia-prime >> "${log_file}" 2>&1 || true
    apt_install --allow-change-held-packages \
      nvidia-driver-570-open \
      nvidia-fs \
      nvidia-gds-12-6 \
      gds-tools-12-6 \
      linux-image-nvidia \
      linux-modules-nvidia-fs-5.15.0-1096-nvidia \
      linux-headers-5.15.0-1096-nvidia >> "${log_file}" 2>&1 || true
    maybe_sudo dkms autoinstall -k 5.15.0-1096-nvidia >> "${log_file}" 2>&1 || true
    maybe_sudo update-initramfs -u -k 5.15.0-1096-nvidia >> "${log_file}" 2>&1 || true
    maybe_sudo modprobe nvidia_fs >> "${log_file}" 2>&1 || true
  fi

  maybe_sudo mkdir -p /mnt/nvme >> "${log_file}" 2>&1 || true
  if ! mountpoint -q /mnt/nvme; then
    local part
    part="$(find_nvme_mount_candidate || true)"
    if [[ -z "${part}" ]]; then
      local raw_disk
      raw_disk="$(find_nvme_raw_disk_candidate || true)"
      if [[ -n "${raw_disk}" ]]; then
        local part_name="${raw_disk}p1"
        if ! lsblk -pnro NAME "${raw_disk}" | grep -q "^${part_name}$"; then
          maybe_sudo parted -s "${raw_disk}" mklabel gpt >> "${log_file}" 2>&1 || true
          maybe_sudo parted -s "${raw_disk}" mkpart primary ext4 0% 100% >> "${log_file}" 2>&1 || true
        fi
        if ! maybe_sudo blkid "${part_name}" >/dev/null 2>&1; then
          maybe_sudo mkfs.ext4 -F "${part_name}" >> "${log_file}" 2>&1 || true
        fi
        part="${part_name}"
      fi
    fi
    if [[ -n "${part}" ]]; then
      if ! maybe_sudo mount -o rw,noatime,data=ordered "${part}" /mnt/nvme >> "${log_file}" 2>&1; then
        maybe_sudo mkfs.ext4 -F "${part}" >> "${log_file}" 2>&1 || true
        maybe_sudo mount -o rw,noatime,data=ordered "${part}" /mnt/nvme >> "${log_file}" 2>&1 || true
      fi
      echo "mounted_nvme_part=${part}" >> "${log_file}"
    else
      echo "mounted_nvme_part=none" >> "${log_file}"
    fi
  fi

  if mountpoint -q /mnt/nvme; then
    configure_docker_data_root "/mnt/nvme/docker" >> "${log_file}" 2>&1 || true
  fi

  if [[ -f /var/run/reboot-required || -f /run/reboot-required ]]; then
    needs_reboot=1
  fi
  echo "reboot_required=${needs_reboot}" >> "${log_file}"

  maybe_sudo "${gdscheck_bin}" -p > "${post_report}" 2>&1 || true
  cat "${post_report}" >> "${log_file}" 2>&1 || true

  if grep -Eq 'NVMe[[:space:]]*:[[:space:]]*Supported' "${post_report}"; then
    return 0
  fi
  if [[ "${needs_reboot}" -eq 1 ]]; then
    return 3
  fi
  return 1
}

run_strict_gdsio_probe() {
  local report="$1"
  local probe_dir="${DIRECT_GDS_PROBE_DIR:-${OCI2GDSD_ROOT_PATH}}"
  local gdsio
  gdsio="$(gdsio_binary || true)"
  if [[ -z "${gdsio}" ]]; then
    warn "gdsio not found; cannot run strict direct-path functional probe"
    return 1
  fi
  maybe_sudo mkdir -p "${probe_dir}" >/dev/null 2>&1 || true
  local tmp
  tmp="$(mktemp)"
  if ! maybe_sudo "${gdsio}" \
    -D "${probe_dir}" \
    -d 0 \
    -w 1 \
    -s 1G \
    -i 1M \
    -x 0 \
    -I 1 >"${tmp}" 2>&1; then
    cat "${tmp}" > "${report}" 2>/dev/null || true
    rm -f "${tmp}"
    return 1
  fi
  cat "${tmp}" > "${report}" 2>/dev/null || true
  rm -f "${tmp}"
  if grep -Eiq 'compat' "${report}"; then
    return 1
  fi
  if ! ls /dev/nvidia-fs* >/dev/null 2>&1; then
    return 1
  fi
  local nvfs_registered=0
  if [[ -r /proc/driver/nvidia-fs/devices ]] && maybe_sudo test -s /proc/driver/nvidia-fs/devices; then
    nvfs_registered=1
  fi
  if [[ "${nvfs_registered}" -eq 0 ]] && [[ -r /proc/driver/nvidia-fs/modules ]]; then
    if maybe_sudo grep -Eiq '(^|[[:space:]])nvme([[:space:]]|:)' /proc/driver/nvidia-fs/modules; then
      nvfs_registered=1
    fi
  fi
  if [[ "${nvfs_registered}" -eq 0 ]]; then
    return 1
  fi
  return 0
}

check_runtime_image_toolchain() {
  prereq_check_runtime_image_toolchain "$1" "${RESULTS_DIR}/runtime-image-prereq.log" "true"
}

check_nvfs_stats_state() {
  local f="/sys/module/nvidia_fs/parameters/rw_stats_enabled"
  if [[ ! -r "${f}" ]]; then
    warn "cannot read ${f}; nvfs counter assertions may be unavailable"
    if [[ "${NVFS_STATS_MODE}" == "required" ]]; then
      die "REQUIRE_NVFS_STATS_DELTA_MODE=required but ${f} is not readable"
    fi
    return 0
  fi
  local v
  v="$(cat "${f}" 2>/dev/null || true)"
  if [[ "${v}" == "1" ]]; then
    log "nvidia-fs rw_stats_enabled=1"
    return 0
  fi
  warn "nvidia-fs rw_stats_enabled=${v:-unknown}; nvfs Ops counters may stay zero"
  warn "enable with: sudo sh -c 'echo 1 > /sys/module/nvidia_fs/parameters/rw_stats_enabled'"
  if [[ "${NVFS_STATS_MODE}" == "required" ]]; then
    die "REQUIRE_NVFS_STATS_DELTA_MODE=required requires rw_stats_enabled=1"
  fi
}

check_quick_example_cli_prereq() {
  if ! is_true "${VALIDATE_QUICK_EXAMPLE}"; then
    return 0
  fi
  if [[ -n "${OCI2GDSD_BIN:-}" ]]; then
    [[ -x "${OCI2GDSD_BIN}" ]] || die "OCI2GDSD_BIN is not executable: ${OCI2GDSD_BIN}"
    return 0
  fi
  if command -v oci2gdsd >/dev/null 2>&1; then
    return 0
  fi
  if [[ -x "${REPO_ROOT}/oci2gdsd" ]]; then
    return 0
  fi
  if command -v go >/dev/null 2>&1; then
    return 0
  fi
  die "VALIDATE_QUICK_EXAMPLE=true requires oci2gdsd CLI or Go toolchain (set VALIDATE_QUICK_EXAMPLE=false to skip lifecycle validation)"
}

write_environment_report() {
  local out="${RESULTS_DIR}/environment-report.txt"
  {
    echo "# host-e2e prereq environment $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "runtime_image=${PYTORCH_RUNTIME_IMAGE}"
    echo "require_direct_gds=${REQUIRE_DIRECT_GDS}"
    echo "nvfs_stats_mode=${NVFS_STATS_MODE}"
    echo "docker_root=$(maybe_sudo docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
    echo "kernel=$(uname -r)"
    echo "---- nvidia-smi ----"
    nvidia-smi || true
    echo "---- runtime image digest ----"
    maybe_sudo docker image inspect "${PYTORCH_RUNTIME_IMAGE}" --format '{{json .RepoDigests}}' 2>/dev/null || true
    echo "---- gdscheck prereq ----"
    cat "${RESULTS_DIR}/gdscheck-prereq.txt" 2>/dev/null || true
    echo "---- runtime image prereq ----"
    cat "${RESULTS_DIR}/runtime-image-prereq.log" 2>/dev/null || true
  } > "${out}" 2>&1
  log "wrote environment report: ${out}"
}

prereq_stage_base_common() {
  prereq_stage_begin "base-common"
  ensure_cmd_or_install python3 python3
  ensure_cmd_or_install jq jq
  ensure_cmd_or_install curl curl
  ensure_cmd_or_install docker docker.io
  command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi not found; GPU runtime not available"
  prereq_ensure_docker_access
  check_storage_prereqs
  ensure_root_writable
  prereq_stage_end "base-common"
}

prereq_stage_host_direct_gds() {
  prereq_stage_begin "host-direct-gds"
  if is_true "${REQUIRE_DIRECT_GDS}"; then
    local gdsio_report="${RESULTS_DIR}/gdsio-prereq.txt"
    if is_true "${INSTALL_MISSING_PREREQS}"; then
      install_gds_tools_if_missing
    fi
    gdscheck="$(gdscheck_binary || true)"
    if [[ -z "${gdscheck}" ]]; then
      emit_direct_gds_remediation
      die "gdscheck not found while REQUIRE_DIRECT_GDS=true"
    fi
    local_report="${RESULTS_DIR}/gdscheck-prereq.txt"
    if ! maybe_sudo "${gdscheck}" -p >"${local_report}" 2>&1; then
      emit_direct_gds_remediation
      die "gdscheck -p failed; see ${local_report}"
    fi
    if ! grep -Eq 'NVMe[[:space:]]*:[[:space:]]*Supported' "${local_report}"; then
      if has_guest_nvme && run_strict_gdsio_probe "${gdsio_report}"; then
        warn "gdscheck reports NVMe unsupported, but strict gdsio direct probe succeeded (see ${gdsio_report}); continuing"
        prereq_stage_end "host-direct-gds"
        return 0
      fi
      if attempt_full_gds_remediation_bundle "${gdscheck}"; then
        log "full GDS remediation succeeded; proceeding with strict validation"
        cp "${RESULTS_DIR}/gdscheck-prereq-post-remediation.txt" "${local_report}" || true
        if ! grep -Eq 'NVMe[[:space:]]*:[[:space:]]*Supported' "${local_report}"; then
          if has_guest_nvme && run_strict_gdsio_probe "${gdsio_report}"; then
            warn "post-remediation gdscheck still reports NVMe unsupported, but strict gdsio direct probe succeeded (see ${gdsio_report}); continuing"
            prereq_stage_end "host-direct-gds"
            return 0
          fi
          emit_direct_gds_remediation
          die "full GDS remediation completed but neither gdscheck nor strict gdsio proved direct NVMe path; see ${local_report} and ${gdsio_report}"
        fi
      else
        rc=$?
        if [[ "${rc}" -ne 2 ]] && has_guest_nvme && run_strict_gdsio_probe "${gdsio_report}"; then
          warn "full remediation did not mark NVMe supported in gdscheck, but strict gdsio direct probe succeeded (see ${gdsio_report}); continuing"
          prereq_stage_end "host-direct-gds"
          return 0
        fi
        emit_direct_gds_remediation
        if [[ "${rc}" -eq 2 ]]; then
          die "gdscheck direct preflight failed and host has no guest-visible NVMe (/dev/nvme*); see ${local_report} and ${RESULTS_DIR}/gds-remediation.log"
        fi
        if [[ "${rc}" -eq 3 ]]; then
          die "full GDS remediation attempted but reboot is required before strict validation; reboot host and rerun prereq (see ${RESULTS_DIR}/gds-remediation.log)"
        fi
        die "full GDS remediation attempted but NVMe direct path is still unavailable; see ${local_report} and ${RESULTS_DIR}/gds-remediation.log"
      fi
    fi
  fi
  prereq_stage_end "host-direct-gds"
}

prereq_stage_host_runtime() {
  prereq_stage_begin "host-runtime-image"
  check_runtime_image_toolchain "${PYTORCH_RUNTIME_IMAGE}"
  check_nvfs_stats_state
  check_quick_example_cli_prereq
  write_environment_report
  prereq_stage_end "host-runtime-image"
}

log "running host-e2e prerequisite checks"
log "assumption: probe containers run with --privileged"
enforce_strict_gds_policy
resolve_nvfs_stats_mode
prereq_stage_base_common
prereq_stage_host_direct_gds
prereq_stage_host_runtime
log "host-e2e prerequisites are satisfied"
