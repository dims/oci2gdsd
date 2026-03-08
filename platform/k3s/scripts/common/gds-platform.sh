#!/usr/bin/env bash
# shellcheck shell=bash

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
  local post_report="${RESULTS_DIR}/gdscheck-post-remediation.txt"
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

  echo "non_destructive_step=skip_driver_kernel_package_mutation" >> "${log_file}"
  maybe_sudo modprobe nvidia_fs >> "${log_file}" 2>&1 || true

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
      maybe_sudo mount -o rw,noatime,data=ordered "${part}" /mnt/nvme >> "${log_file}" 2>&1 || true
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

check_direct_gds_platform_support() {
  local gdscheck
  local gdsio_report="${RESULTS_DIR}/gdsio-preflight.txt"
  if ! gdscheck="$(gdscheck_binary)"; then
    if has_guest_nvme && run_strict_gdsio_probe "${gdsio_report}"; then
      warn "gdscheck not found, but strict gdsio direct probe succeeded (see ${gdsio_report}); continuing"
      return 0
    fi
    warn "gdscheck not found; cannot verify direct GDS platform support"
    emit_direct_gds_remediation
    return 1
  fi
  mkdir -p "${RESULTS_DIR}"
  maybe_sudo chown -R "$(id -u):$(id -g)" "${RESULTS_DIR}" >/dev/null 2>&1 || true
  local report="${RESULTS_DIR}/gdscheck.txt"
  local tmp_report
  tmp_report="$(mktemp)"
  if ! maybe_sudo "${gdscheck}" -p >"${tmp_report}" 2>&1; then
    cat "${tmp_report}" >"${report}" 2>/dev/null || true
    rm -f "${tmp_report}"
    warn "gdscheck failed; see ${report}"
    emit_direct_gds_remediation
    return 1
  fi
  cat "${tmp_report}" >"${report}"
  rm -f "${tmp_report}"
  if ! grep -Eq 'NVMe[[:space:]]*:[[:space:]]*Supported' "${report}"; then
    if has_guest_nvme && run_strict_gdsio_probe "${gdsio_report}"; then
      warn "gdscheck reports NVMe unsupported, but strict gdsio direct probe succeeded (see ${gdsio_report}); continuing"
      return 0
    fi
    if attempt_full_gds_remediation_bundle "${gdscheck}"; then
      log "full GDS remediation succeeded; proceeding with strict validation"
      cp "${RESULTS_DIR}/gdscheck-post-remediation.txt" "${report}" || true
      if grep -Eq 'NVMe[[:space:]]*:[[:space:]]*Supported' "${report}"; then
        return 0
      fi
      if has_guest_nvme && run_strict_gdsio_probe "${gdsio_report}"; then
        warn "post-remediation gdscheck still reports NVMe unsupported, but strict gdsio direct probe succeeded (see ${gdsio_report}); continuing"
        return 0
      fi
      warn "full remediation completed but neither gdscheck nor strict gdsio proved direct NVMe path"
      emit_direct_gds_remediation
      return 1
    fi
    local rc=$?
    if [[ "${rc}" -ne 2 ]] && has_guest_nvme && run_strict_gdsio_probe "${gdsio_report}"; then
      warn "full remediation did not mark NVMe supported in gdscheck, but strict gdsio direct probe succeeded (see ${gdsio_report}); continuing"
      return 0
    fi
    if [[ "${rc}" -eq 2 ]]; then
      warn "gdscheck direct preflight failed and host has no guest-visible NVMe (/dev/nvme*)"
    elif [[ "${rc}" -eq 3 ]]; then
      warn "full GDS remediation attempted but reboot is required before strict validation"
    else
      warn "full GDS remediation attempted but NVMe direct path is still unavailable"
    fi
    emit_direct_gds_remediation
    return 1
  fi
  return 0
}

