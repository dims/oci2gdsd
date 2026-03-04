#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=../../lib/prereq.sh
source "${LIB_DIR}/prereq.sh"

INSTALL_MISSING_PREREQS="${INSTALL_MISSING_PREREQS:-true}"
PREPULL_RUNTIME_IMAGE="${PREPULL_RUNTIME_IMAGE:-true}"

check_runtime_image_toolchain() {
  prereq_check_runtime_image_toolchain \
    "$1" \
    "${WORK_DIR}/results/runtime-image-prereq.log" \
    "${PREPULL_RUNTIME_IMAGE}"
}

check_privileged_assumptions() {
  local qwen_template="${QWEN_HELLO_TEMPLATE}"
  local workload_template="${HARNESS_DIR}/manifests/workload-job.yaml.tpl"
  local daemonset_template="${OCI2GDSD_DAEMON_TEMPLATE}"
  local daemon_client_template="${PYTORCH_DAEMON_CLIENT_TEMPLATE}"

  if ! grep -Eq 'privileged:[[:space:]]*true' "${qwen_template}"; then
    die "qwen template does not declare privileged container securityContext: ${qwen_template}"
  fi
  if ! grep -Eq 'privileged:[[:space:]]*true' "${workload_template}"; then
    die "workload template does not declare privileged container securityContext: ${workload_template}"
  fi
  if ! grep -Eq 'privileged:[[:space:]]*true' "${daemonset_template}"; then
    die "daemonset template does not declare privileged container securityContext: ${daemonset_template}"
  fi
  if ! grep -Eq 'privileged:[[:space:]]*true' "${daemon_client_template}"; then
    die "daemon-client template does not declare privileged container securityContext: ${daemon_client_template}"
  fi
}

prereq_stage_base_common() {
  prereq_stage_begin "base-common"
  if [[ "${INSTALL_MISSING_PREREQS}" == "true" ]]; then
    bootstrap_tools
  else
    ensure_cmd docker
    ensure_cmd jq
    ensure_cmd gsed
    ensure_cmd curl
    ensure_cmd nvidia-smi
    ensure_cmd k3s
    ensure_cmd nvidia-ctk
  fi
  prereq_ensure_docker_access
  check_storage_prereqs
  prereq_stage_end "base-common"
}

prereq_stage_host_direct_gds() {
  prereq_stage_begin "host-direct-gds"
  if [[ "${REQUIRE_DIRECT_GDS}" == "true" ]]; then
    if ! check_direct_gds_platform_support; then
      die "REQUIRE_DIRECT_GDS=true but direct-GDS platform preflight failed"
    fi
  fi
  prereq_stage_end "host-direct-gds"
}

prereq_stage_k3s_cluster() {
  prereq_stage_begin "k3s-cluster"
  ensure_k3s_nvidia_runtime_prereqs
  if ! kube get nodes >/dev/null 2>&1; then
    die "cluster ${CLUSTER_MODE} is not reachable ($(cluster_hint))"
  fi
  prereq_stage_end "k3s-cluster"
}

prereq_stage_k3s_runtime() {
  prereq_stage_begin "k3s-runtime"
  mkdir -p "${WORK_DIR}/results"
  check_runtime_image_toolchain "${PYTORCH_RUNTIME_IMAGE}"
  check_privileged_assumptions
  write_environment_report
  prereq_stage_end "k3s-runtime"
}

log "running k3s prerequisite checks"
log "assumption: all GPU/GDS workload containers run privileged"
prereq_stage_base_common
prereq_stage_host_direct_gds
prereq_stage_k3s_cluster
prereq_stage_k3s_runtime
log "k3s prerequisites are satisfied"
