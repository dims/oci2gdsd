#!/usr/bin/env bash
# shellcheck shell=bash

RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${RUNTIME_DIR}/common.sh"

runtime_daemon_apply_configmaps() {
  apply_configmap_from_files "${E2E_NAMESPACE}" "${WORKLOAD_DAEMON_CONFIGMAP}" \
    --from-file=vllm_daemon_client.py="${VLLM_DAEMON_CLIENT_SCRIPT}" \
    --from-file=oci2gds_torch_native.cpp="${PYTORCH_DAEMON_NATIVE_CPP}"
}

runtime_daemon_render_job() {
  local rendered="$1"
  runtime_render_job_template "${rendered}" "VLLM_IMAGE" "${VLLM_IMAGE}" \
    "REQUIRE_FULL_IPC_BIND=${REQUIRE_FULL_IPC_BIND}"
}

runtime_result_log_path() {
  echo "${RESULTS_DIR}/vllm-daemon-client.log"
}

runtime_required_markers() {
  runtime_emit_markers \
    DAEMON_MODEL_ENSURE_READY \
    DAEMON_RUNTIME_BUNDLE_READY \
    DAEMON_GPU_LOAD_READY \
    DAEMON_GPU_STATUS_OK \
    DAEMON_GPU_ATTACH_OK \
    DAEMON_GPU_HEARTBEAT_OK \
    VLLM_IPC_TENSOR_MAP_OK \
    VLLM_IPC_BIND_OK \
    VLLM_LOADER_REGISTERED \
    VLLM_OCI2GDS_LOAD_OK \
    VLLM_QWEN_INFER_OK \
    DAEMON_GPU_DETACH_OK \
    DAEMON_GPU_UNLOAD_OK \
    VLLM_DAEMON_CLIENT_SUCCESS
}

runtime_validate_results() {
  local log_path="$1"
  runtime_require_full_parity "vLLM"
  if [[ "${REQUIRE_FULL_IPC_BIND}" != "true" ]]; then
    die "vLLM daemon-client requires REQUIRE_FULL_IPC_BIND=true"
  fi
  runtime_assert_log_pattern "${log_path}" \
    'VLLM_IPC_BIND_OK .*status=ok' \
    "full parity requires VLLM_IPC_BIND_OK status=ok"
  runtime_assert_log_pattern "${log_path}" \
    'VLLM_IPC_BIND_OK .*unresolved=0' \
    "full parity requires VLLM IPC unresolved=0"
  runtime_assert_log_pattern "${log_path}" \
    'VLLM_IPC_BIND_OK .*rebound_params=[1-9][0-9]*' \
    "full parity requires vLLM rebound_params > 0"
}
