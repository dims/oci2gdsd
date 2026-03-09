#!/usr/bin/env bash
# shellcheck shell=bash

RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${RUNTIME_DIR}/common.sh"

runtime_daemon_apply_configmaps() {
  apply_configmap_from_files "${E2E_NAMESPACE}" "${WORKLOAD_DAEMON_CONFIGMAP}" \
    --from-file=sglang_daemon_client.py="${SGLANG_DAEMON_CLIENT_SCRIPT}" \
    --from-file=sglang_private_model_loader.py="${SGLANG_PRIVATE_LOADER_SCRIPT}" \
    --from-file=daemon_client_common.py="${REPO_ROOT}/platform/k3s/shared/daemon_client_common.py" \
    --from-file=oci2gds_torch_native.cpp="${PYTORCH_DAEMON_NATIVE_CPP}"
}

runtime_daemon_render_job() {
  local rendered="$1"
  runtime_render_job_template "${rendered}" "SGLANG_IMAGE" "${SGLANG_IMAGE}" \
    "SGLANG_PRIVATE_LOADER_SCRIPT_PATH=${SGLANG_PRIVATE_LOADER_SCRIPT_PATH}"
}

runtime_result_log_path() {
  echo "${RESULTS_DIR}/sglang-daemon-client.log"
}

runtime_required_markers() {
  runtime_emit_markers \
    DAEMON_MODEL_ENSURE_READY \
    DAEMON_NO_RUNTIME_ARTIFACT_ACCESS_OK \
    DAEMON_GPU_ALLOCATE_READY \
    DAEMON_RUNTIME_BUNDLE_TIMING \
    DAEMON_RUNTIME_BUNDLE_READY \
    DAEMON_GPU_LOAD_READY \
    DAEMON_GPU_STATUS_OK \
    DAEMON_GPU_ATTACH_OK \
    DAEMON_GPU_HEARTBEAT_OK \
    SGLANG_IPC_TENSOR_MAP_OK \
    SGLANG_PRIVATE_LOADER_INSTALLED \
    SGLANG_PRIVATE_LOADER_OK \
    SGLANG_QWEN_INFER_OK \
    DAEMON_GPU_DETACH_OK \
    DAEMON_GPU_UNLOAD_OK \
    SGLANG_DAEMON_CLIENT_SUCCESS
}

runtime_validate_results() {
  local log_path="$1"
  runtime_require_full_parity "SGLang"
  runtime_assert_log_pattern "${log_path}" \
    'SGLANG_PRIVATE_LOADER_OK .*status=ok' \
    "full parity requires SGLANG_PRIVATE_LOADER_OK status=ok"
  runtime_assert_log_pattern "${log_path}" \
    'SGLANG_PRIVATE_LOADER_OK .*rebound_params=[1-9][0-9]*' \
    "full parity requires rebound_params > 0"
  runtime_assert_log_pattern "${log_path}" \
    'SGLANG_PRIVATE_LOADER_OK .*loaded_tensors=[1-9][0-9]* .*loaded_bytes=[1-9][0-9]{8,}' \
    "full parity requires materialized tensor map coverage"
}
