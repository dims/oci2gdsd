#!/usr/bin/env bash
# shellcheck shell=bash

RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${RUNTIME_DIR}/common.sh"

runtime_daemon_apply_configmaps() {
  apply_configmap_from_files "${E2E_NAMESPACE}" "${WORKLOAD_DAEMON_CONFIGMAP}" \
    --from-file=pytorch_daemon_client.py="${PYTORCH_DAEMON_CLIENT_SCRIPT}" \
    --from-file=daemon_client_common.py="${REPO_ROOT}/platform/k3s/shared/daemon_client_common.py" \
    --from-file=oci2gds_torch_native.cpp="${PYTORCH_DAEMON_NATIVE_CPP}"
}

runtime_daemon_render_job() {
  local rendered="$1"
  runtime_render_job_template "${rendered}" "PYTORCH_IMAGE" "${PYTORCH_IMAGE}"
}

runtime_result_log_path() {
  echo "${RESULTS_DIR}/pytorch-daemon-client.log"
}

runtime_required_markers() {
  runtime_emit_markers \
    DAEMON_MODEL_ENSURE_READY \
    DAEMON_NO_RUNTIME_ARTIFACT_ACCESS_OK \
    DAEMON_GPU_ALLOCATE_READY \
    DAEMON_RUNTIME_BUNDLE_READY \
    DAEMON_GPU_LOAD_READY \
    DAEMON_GPU_TENSOR_MAP_OK \
    DAEMON_GPU_ATTACH_OK \
    DAEMON_GPU_HEARTBEAT_OK \
    DAEMON_GPU_STATUS_OK \
    DAEMON_QWEN_IPC_BIND_OK \
    DAEMON_GPU_DETACH_OK \
    DAEMON_GPU_UNLOAD_OK \
    PYTORCH_FULL_PARITY_OK \
    PYTORCH_DAEMON_CLIENT_SUCCESS
}

runtime_validate_results() {
  local log_path="$1"
  runtime_require_full_parity "PyTorch"
  runtime_assert_log_pattern "${log_path}" \
    'DAEMON_QWEN_IPC_BIND_OK .*rebound_params=[1-9][0-9]*' \
    "full parity requires rebound_params > 0"
  runtime_assert_log_pattern "${log_path}" \
    'PYTORCH_FULL_PARITY_OK .*status=ok .*parity_mode=full' \
    "full parity requires PYTORCH_FULL_PARITY_OK status=ok"
}
