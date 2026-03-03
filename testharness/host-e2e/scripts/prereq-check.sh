#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK_DIR="${HARNESS_DIR}/work"
RESULTS_DIR="${WORK_DIR}/results"
mkdir -p "${RESULTS_DIR}"

PYTORCH_RUNTIME_IMAGE="${PYTORCH_RUNTIME_IMAGE:-nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1}"
REQUIRE_DIRECT_GDS="${REQUIRE_DIRECT_GDS:-true}"
REQUIRE_NVFS_STATS_DELTA="${REQUIRE_NVFS_STATS_DELTA:-false}"
INSTALL_MISSING_PREREQS="${INSTALL_MISSING_PREREQS:-true}"
OCI2GDSD_ROOT_PATH="${OCI2GDSD_ROOT_PATH:-/mnt/nvme/oci2gdsd}"
MIN_FREE_GB_DOCKER="${MIN_FREE_GB_DOCKER:-80}"
MIN_FREE_GB_MODEL_ROOT="${MIN_FREE_GB_MODEL_ROOT:-20}"

APT_UPDATED=0

_ts() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  echo "[$(_ts)] $*"
}

warn() {
  echo "[$(_ts)] WARN: $*" >&2
}

die() {
  echo "[$(_ts)] ERROR: $*" >&2
  exit 1
}

maybe_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

is_true() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

is_uint() {
  [[ "${1}" =~ ^[0-9]+$ ]]
}

nearest_existing_path() {
  local p="$1"
  while [[ ! -e "${p}" ]]; do
    local parent
    parent="$(dirname "${p}")"
    if [[ "${parent}" == "${p}" ]]; then
      break
    fi
    p="${parent}"
  done
  echo "${p}"
}

path_available_kb() {
  local p="$1"
  local existing
  existing="$(nearest_existing_path "${p}")"
  df -Pk "${existing}" | awk 'NR==2 {print $4}'
}

path_mountpoint() {
  local p="$1"
  local existing
  existing="$(nearest_existing_path "${p}")"
  df -Pk "${existing}" | awk 'NR==2 {print $6}'
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
  local docker_root
  docker_root="$(maybe_sudo docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  [[ -n "${docker_root}" ]] || die "failed to detect DockerRootDir from docker info"

  check_path_free_gb "docker data-root" "${docker_root}" "${MIN_FREE_GB_DOCKER}"
  check_path_free_gb "oci2gdsd root path" "${OCI2GDSD_ROOT_PATH}" "${MIN_FREE_GB_MODEL_ROOT}"
}

ensure_apt_available() {
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found; install prerequisites manually"
}

apt_install() {
  ensure_apt_available
  if [[ "${APT_UPDATED}" -eq 0 ]]; then
    maybe_sudo apt-get update -y >/dev/null
    APT_UPDATED=1
  fi
  maybe_sudo apt-get install -y "$@" >/dev/null
}

ensure_cmd_or_install() {
  local cmd="$1"
  local pkg="$2"
  if command -v "${cmd}" >/dev/null 2>&1; then
    return 0
  fi
  if ! is_true "${INSTALL_MISSING_PREREQS}"; then
    die "missing required command: ${cmd} (set INSTALL_MISSING_PREREQS=true to auto-install)"
  fi
  log "installing missing prerequisite: ${pkg}"
  apt_install "${pkg}"
  command -v "${cmd}" >/dev/null 2>&1 || die "failed to install ${cmd} via package ${pkg}"
}

gdscheck_binary() {
  if command -v gdscheck >/dev/null 2>&1; then
    command -v gdscheck
    return 0
  fi
  if [[ -x /usr/local/cuda/gds/tools/gdscheck ]]; then
    echo "/usr/local/cuda/gds/tools/gdscheck"
    return 0
  fi
  if [[ -x /usr/local/cuda-12.6/gds/tools/gdscheck ]]; then
    echo "/usr/local/cuda-12.6/gds/tools/gdscheck"
    return 0
  fi
  return 1
}

check_runtime_image_toolchain() {
  local image="$1"
  local probe_log="${RESULTS_DIR}/runtime-image-prereq.log"
  local probe='set -eu
command -v python3 >/dev/null || { echo "missing: python3"; exit 31; }
command -v c++ >/dev/null 2>&1 || { echo "missing: c++"; exit 32; }
if [ ! -e /usr/local/cuda/lib64/libcufile.so ] && [ ! -e /usr/local/cuda/lib64/libcufile.so.0 ] && [ ! -e /usr/lib/x86_64-linux-gnu/libcufile.so ]; then
  echo "missing: libcufile"
  exit 33
fi
echo "runtime-image-probe:ok"'

  log "checking runtime image toolchain: ${image}"
  maybe_sudo docker pull "${image}" >/dev/null
  if ! maybe_sudo docker run --rm --privileged --gpus all --user 0:0 \
    "${image}" /bin/sh -lc "${probe}" >"${probe_log}" 2>&1; then
    cat "${probe_log}" >&2 || true
    if grep -q 'missing: c++' "${probe_log}"; then
      die "runtime image is missing c++ (native torch extension cannot build). Use PYTORCH_RUNTIME_IMAGE=nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1 or an equivalent image with a compiler"
    fi
    die "runtime image prerequisite check failed; see ${probe_log}"
  fi
}

check_nvfs_stats_state() {
  local f="/sys/module/nvidia_fs/parameters/rw_stats_enabled"
  if [[ ! -r "${f}" ]]; then
    warn "cannot read ${f}; nvfs counter assertions may be unavailable"
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
  if is_true "${REQUIRE_NVFS_STATS_DELTA}"; then
    die "REQUIRE_NVFS_STATS_DELTA=true requires rw_stats_enabled=1"
  fi
}

log "running host-e2e prerequisite checks"
log "assumption: probe containers run with --privileged"

ensure_cmd_or_install python3 python3
ensure_cmd_or_install jq jq
ensure_cmd_or_install docker docker.io

command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi not found; GPU runtime not available"

if ! maybe_sudo docker info >/dev/null 2>&1; then
  die "docker daemon is not reachable"
fi

check_storage_prereqs

if is_true "${REQUIRE_DIRECT_GDS}"; then
  gdscheck="$(gdscheck_binary || true)"
  [[ -n "${gdscheck}" ]] || die "gdscheck not found while REQUIRE_DIRECT_GDS=true"
  local_report="${RESULTS_DIR}/gdscheck-prereq.txt"
  if ! maybe_sudo "${gdscheck}" -p >"${local_report}" 2>&1; then
    die "gdscheck -p failed; see ${local_report}"
  fi
  if ! grep -Eq 'NVMe[[:space:]]*:[[:space:]]*Supported' "${local_report}"; then
    die "gdscheck reports NVMe unsupported; see ${local_report}"
  fi
fi

check_runtime_image_toolchain "${PYTORCH_RUNTIME_IMAGE}"
check_nvfs_stats_state

log "host-e2e prerequisites are satisfied"
