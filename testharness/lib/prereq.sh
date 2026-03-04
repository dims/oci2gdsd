#!/usr/bin/env bash

# Shared prerequisite helpers and stage utilities for test harness scripts.
# Requires testharness/lib/common.sh to be sourced first.

PREREQ_APT_UPDATED="${PREREQ_APT_UPDATED:-0}"

prereq_stage_begin() {
  local name="$1"
  log "prereq stage start: ${name}"
}

prereq_stage_end() {
  local name="$1"
  log "prereq stage done: ${name}"
}

prereq_ensure_apt_available() {
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found; install prerequisites manually"
}

prereq_apt_install() {
  prereq_ensure_apt_available
  if [[ "${PREREQ_APT_UPDATED}" -eq 0 ]]; then
    maybe_sudo apt-get update -y >/dev/null
    PREREQ_APT_UPDATED=1
  fi
  maybe_sudo apt-get install -y "$@" >/dev/null
}

prereq_ensure_cmd_or_install() {
  local cmd="$1"
  local pkg="$2"
  local install_missing="${3:-${INSTALL_MISSING_PREREQS:-true}}"
  if command -v "${cmd}" >/dev/null 2>&1; then
    return 0
  fi
  if ! is_true "${install_missing}"; then
    die "missing required command: ${cmd} (set INSTALL_MISSING_PREREQS=true to auto-install)"
  fi
  log "installing missing prerequisite: ${pkg}"
  prereq_apt_install "${pkg}"
  command -v "${cmd}" >/dev/null 2>&1 || die "failed to install ${cmd} via package ${pkg}"
}

prereq_install_docker_if_missing() {
  local install_missing="${1:-${INSTALL_MISSING_PREREQS:-true}}"
  if command -v docker >/dev/null 2>&1; then
    return 0
  fi
  if ! is_true "${install_missing}"; then
    die "missing required command: docker"
  fi
  log "installing missing prerequisite: docker.io"
  prereq_apt_install docker.io
  maybe_sudo systemctl enable --now docker >/dev/null 2>&1 || true
  command -v docker >/dev/null 2>&1 || die "failed to install docker"
}

prereq_docker_info() {
  maybe_sudo docker info "$@"
}

prereq_ensure_docker_access() {
  if ! prereq_docker_info >/dev/null 2>&1; then
    die "docker daemon is not reachable"
  fi
}

prereq_docker_root() {
  prereq_docker_info --format '{{.DockerRootDir}}' 2>/dev/null || true
}

prereq_check_path_free_gb() {
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
    die "${label} has insufficient free space: ${avail_gb}GiB available < ${min_gb}GiB required"
  fi
}

prereq_install_oras_if_missing() {
  local version="${1:-1.2.3}"
  local install_missing="${2:-${INSTALL_MISSING_PREREQS:-true}}"
  if command -v oras >/dev/null 2>&1; then
    return 0
  fi
  if ! is_true "${install_missing}"; then
    die "missing required command: oras (set INSTALL_MISSING_PREREQS=true to auto-install)"
  fi
  log "installing oras v${version}"
  local tarball="/tmp/oras_${version}_linux_amd64.tar.gz"
  curl -fsSL -o "${tarball}" "https://github.com/oras-project/oras/releases/download/v${version}/oras_${version}_linux_amd64.tar.gz"
  tar -xzf "${tarball}" -C /tmp oras
  maybe_sudo mv /tmp/oras /usr/local/bin/oras
  maybe_sudo chmod +x /usr/local/bin/oras
  rm -f "${tarball}"
  command -v oras >/dev/null 2>&1 || die "failed to install oras"
}

prereq_check_runtime_image_toolchain() {
  local image="$1"
  local probe_log="$2"
  local pre_pull="${3:-true}"
  local probe='set -eu
command -v python3 >/dev/null || { echo "missing: python3"; exit 31; }
command -v c++ >/dev/null 2>&1 || { echo "missing: c++"; exit 32; }
if [ ! -e /usr/local/cuda/lib64/libcufile.so ] && [ ! -e /usr/local/cuda/lib64/libcufile.so.0 ] && [ ! -e /usr/lib/x86_64-linux-gnu/libcufile.so ]; then
  echo "missing: libcufile"
  exit 33
fi
echo "runtime-image-probe:ok"'

  if [[ "${pre_pull}" == "true" ]]; then
    log "pre-pulling runtime image ${image}"
    maybe_sudo docker pull "${image}" >/dev/null
  fi

  log "checking runtime image toolchain: ${image}"
  if ! maybe_sudo docker run --rm --privileged --gpus all --user 0:0 \
    "${image}" /bin/sh -lc "${probe}" >"${probe_log}" 2>&1; then
    cat "${probe_log}" >&2 || true
    if grep -q 'missing: c++' "${probe_log}"; then
      die "runtime image is missing c++ (native torch extension cannot build). Use PYTORCH_RUNTIME_IMAGE=nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1 or equivalent"
    fi
    die "runtime image prerequisite check failed; see ${probe_log}"
  fi
}
