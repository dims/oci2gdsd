#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${HARNESS_DIR}/../.." && pwd)"
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
AUTO_CONFIGURE_STORAGE="${AUTO_CONFIGURE_STORAGE:-true}"
VALIDATE_QUICK_EXAMPLE="${VALIDATE_QUICK_EXAMPLE:-true}"

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

emit_direct_gds_remediation() {
  cat >&2 <<'EOF'
Direct-GDS remediation options:
1. Use a host with local NVMe and GDS direct-path support (gdscheck must report "NVMe : Supported").
2. Verify platform capability:
   sudo gdscheck -p
3. Keep strict mode (default) for real validation:
   REQUIRE_DIRECT_GDS=true OCI2GDS_STRICT=true OCI2GDS_FORCE_NO_COMPAT=true
4. For non-direct smoke only (not a true GDS pass), relax gates:
   REQUIRE_DIRECT_GDS=false OCI2GDS_STRICT=false
EOF
}

maybe_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

is_true() {
  local v
  v="$(printf '%s' "${1}" | tr '[:upper:]' '[:lower:]')"
  case "${v}" in
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
    APT_UPDATED=0
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
    emit_direct_gds_remediation
    die "gdscheck reports NVMe unsupported; see ${local_report}"
  fi
fi

check_runtime_image_toolchain "${PYTORCH_RUNTIME_IMAGE}"
check_nvfs_stats_state
check_quick_example_cli_prereq

log "host-e2e prerequisites are satisfied"
