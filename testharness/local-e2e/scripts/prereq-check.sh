#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${HARNESS_DIR}/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
WORK_DIR="${HARNESS_DIR}/work"
RESULTS_DIR="${WORK_DIR}/results"
MIN_FREE_GB_DOCKER="${MIN_FREE_GB_DOCKER:-10}"
MIN_FREE_GB_WORK="${MIN_FREE_GB_WORK:-2}"
MIN_FREE_GB_LOCAL_ROOT="${MIN_FREE_GB_LOCAL_ROOT:-20}"
INSTALL_MISSING_PREREQS="${INSTALL_MISSING_PREREQS:-true}"
ORAS_VERSION="${ORAS_VERSION:-1.2.3}"
DEFAULT_LOCAL_E2E_ROOT="${WORK_DIR}/state"
if [[ -d /mnt/nvme && -w /mnt/nvme ]]; then
  DEFAULT_LOCAL_E2E_ROOT="/mnt/nvme/oci2gdsd-local-e2e"
fi
LOCAL_E2E_ROOT="${LOCAL_E2E_ROOT:-${DEFAULT_LOCAL_E2E_ROOT}}"

ensure_apt_available() {
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found; install missing prerequisites manually"
}

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1; then
    return
  fi
  [[ "${INSTALL_MISSING_PREREQS}" == "true" ]] || die "missing required command: docker"
  ensure_apt_available
  log "installing docker.io"
  maybe_sudo apt-get update -y
  maybe_sudo apt-get install -y docker.io
  maybe_sudo systemctl enable --now docker
}

install_jq_if_missing() {
  if command -v jq >/dev/null 2>&1; then
    return
  fi
  [[ "${INSTALL_MISSING_PREREQS}" == "true" ]] || die "missing required command: jq"
  ensure_apt_available
  log "installing jq"
  maybe_sudo apt-get update -y
  maybe_sudo apt-get install -y jq
}

install_oras_if_missing() {
  if command -v oras >/dev/null 2>&1; then
    return
  fi
  [[ "${INSTALL_MISSING_PREREQS}" == "true" ]] || die "missing required command: oras"
  log "installing oras v${ORAS_VERSION}"
  local tarball="/tmp/oras_${ORAS_VERSION}_linux_amd64.tar.gz"
  curl -fsSL -o "${tarball}" "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_amd64.tar.gz"
  tar -xzf "${tarball}" -C /tmp oras
  maybe_sudo mv /tmp/oras /usr/local/bin/oras
  maybe_sudo chmod +x /usr/local/bin/oras
}

docker_info() {
  if docker info >/dev/null 2>&1; then
    docker info "$@"
    return 0
  fi
  if sudo docker info >/dev/null 2>&1; then
    sudo docker info "$@"
    return 0
  fi
  return 1
}

check_path_free_gb() {
  local label="$1"
  local path="$2"
  local min_gb="$3"
  local avail_kb required_kb avail_gb mountpoint

  [[ "${min_gb}" =~ ^[0-9]+$ ]] || die "${label} minimum free space is not numeric: ${min_gb}"
  avail_kb="$(path_available_kb "${path}")"
  required_kb=$((min_gb * 1024 * 1024))
  avail_gb=$((avail_kb / 1024 / 1024))
  mountpoint="$(path_mountpoint "${path}")"

  log "${label}: path=${path} mount=${mountpoint} available=${avail_gb}GiB required=${min_gb}GiB"
  if (( avail_kb < required_kb )); then
    die "${label} has insufficient free space: ${avail_gb}GiB available < ${min_gb}GiB required"
  fi
}

log "running local CLI e2e prerequisites"
mkdir -p "${RESULTS_DIR}"

ensure_cmd curl
install_docker_if_missing
install_jq_if_missing
install_oras_if_missing
ensure_cmd curl
ensure_cmd jq
ensure_cmd oras

if ! docker info >/dev/null 2>&1; then
  if sudo docker info >/dev/null 2>&1; then
    warn "docker requires sudo for this user; local-e2e scripts will run docker via sudo"
  else
    die "docker daemon is not reachable"
  fi
fi

if [[ ! -x "${REPO_ROOT}/oci2gdsd" ]] && ! command -v oci2gdsd >/dev/null 2>&1; then
  ensure_cmd go
fi

local_docker_root="$(docker_info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
[[ -n "${local_docker_root}" ]] || die "failed to detect DockerRootDir from docker info"
check_path_free_gb "docker data-root" "${local_docker_root}" "${MIN_FREE_GB_DOCKER}"
check_path_free_gb "local-e2e workspace" "${HARNESS_DIR}" "${MIN_FREE_GB_WORK}"
check_path_free_gb "local-e2e root path" "${LOCAL_E2E_ROOT}" "${MIN_FREE_GB_LOCAL_ROOT}"

{
  echo "# local-e2e prereq $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  docker_info --format '{{json .}}' || true
} > "${RESULTS_DIR}/prereq-check.txt" 2>&1

log "local CLI e2e prerequisites are satisfied"
