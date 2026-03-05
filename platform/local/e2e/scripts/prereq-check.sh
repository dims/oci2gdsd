#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${HARNESS_DIR}/../../.." && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
# shellcheck source=../../../lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=../../../lib/prereq.sh
source "${LIB_DIR}/prereq.sh"

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

prereq_stage_base_common() {
  prereq_stage_begin "base-common"
  prereq_ensure_cmd_or_install curl curl
  prereq_install_docker_if_missing
  prereq_ensure_cmd_or_install jq jq
  prereq_ensure_docker_access
  prereq_stage_end "base-common"
}

prereq_stage_local_cli() {
  prereq_stage_begin "local-cli"
  prereq_install_oras_if_missing "${ORAS_VERSION}"
  ensure_cmd curl
  ensure_cmd jq
  ensure_cmd oras
  prereq_stage_end "local-cli"
}

prereq_stage_local_builder() {
  prereq_stage_begin "local-builder"
  if [[ ! -x "${REPO_ROOT}/oci2gdsd" ]] && ! command -v oci2gdsd >/dev/null 2>&1; then
    ensure_cmd go
  fi
  prereq_stage_end "local-builder"
}

prereq_stage_local_storage() {
  prereq_stage_begin "local-storage"
  local local_docker_root
  local_docker_root="$(prereq_docker_root)"
  [[ -n "${local_docker_root}" ]] || die "failed to detect DockerRootDir from docker info"
  prereq_check_path_free_gb "docker data-root" "${local_docker_root}" "${MIN_FREE_GB_DOCKER}"
  prereq_check_path_free_gb "local-e2e workspace" "${HARNESS_DIR}" "${MIN_FREE_GB_WORK}"
  prereq_check_path_free_gb "local-e2e root path" "${LOCAL_E2E_ROOT}" "${MIN_FREE_GB_LOCAL_ROOT}"
  prereq_stage_end "local-storage"
}

write_report() {
  {
    echo "# local-e2e prereq $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    prereq_docker_info --format '{{json .}}' || true
  } > "${RESULTS_DIR}/prereq-check.txt" 2>&1
}

log "running local CLI e2e prerequisites"
mkdir -p "${RESULTS_DIR}"
prereq_stage_base_common
prereq_stage_local_cli
prereq_stage_local_builder
prereq_stage_local_storage
write_report
log "local CLI e2e prerequisites are satisfied"
