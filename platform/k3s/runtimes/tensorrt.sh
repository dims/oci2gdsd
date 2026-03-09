#!/usr/bin/env bash
# shellcheck shell=bash

RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${RUNTIME_DIR}/common.sh"

runtime_daemon_apply_configmaps() {
  apply_configmap_from_files "${E2E_NAMESPACE}" "${WORKLOAD_DAEMON_CONFIGMAP}" \
    --from-file=tensorrt_daemon_client.py="${TENSORRT_DAEMON_CLIENT_SCRIPT}" \
    --from-file=daemon_client_common.py="${REPO_ROOT}/platform/k3s/shared/daemon_client_common.py" \
    --from-file=oci2gds_torch_native.cpp="${PYTORCH_DAEMON_NATIVE_CPP}"
}

runtime_daemon_render_job() {
  local rendered="$1"
  runtime_render_job_template "${rendered}" "TENSORRTLLM_IMAGE" "${TENSORRTLLM_IMAGE}" \
    "TENSORRT_STARTUP_MODE=${TENSORRT_STARTUP_MODE}" \
    "TENSORRT_ENGINE_CACHE_HOST_PATH=${TENSORRT_ENGINE_CACHE_HOST_PATH}"
}

runtime_result_log_path() {
  echo "${RESULTS_DIR}/tensorrt-daemon-client.log"
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
    TENSORRT_IPC_TENSOR_MAP_OK \
    TENSORRT_IPC_BIND_OK \
    TENSORRT_IPC_IMPORT_OK \
    TENSORRT_ENGINE_BUILD_OK \
    TENSORRT_GDS_RUNNER_READY \
    TENSORRT_QWEN_INFER_OK \
    DAEMON_GPU_DETACH_OK \
    DAEMON_GPU_UNLOAD_OK \
    TENSORRT_FULL_SOURCE_OK \
    TENSORRT_DAEMON_CLIENT_SUCCESS
}

runtime_validate_results() {
  local log_path="$1"
  runtime_require_full_parity "TensorRT"
  runtime_assert_log_pattern "${log_path}" \
    'TENSORRT_STARTUP_MODE_OK mode=(parity|fast)' \
    "TensorRT run must report startup mode"
  if [[ "${TENSORRT_STARTUP_MODE}" == "parity" ]]; then
    runtime_assert_log_pattern "${log_path}" \
      'TENSORRT_ENGINE_BUILD_OK .*startup_mode=parity' \
      "parity mode must emit startup_mode=parity engine build marker"
    if grep -Eq 'TENSORRT_ENGINE_FASTPATH_OK' "${log_path}"; then
      die "parity mode must not emit fastpath marker"
    fi
  else
    runtime_assert_log_pattern "${log_path}" \
      'TENSORRT_ENGINE_BUILD_OK .*startup_mode=fast' \
      "fast mode must emit startup_mode=fast engine build marker"
    runtime_assert_log_pattern "${log_path}" \
      'TENSORRT_ENGINE_FASTPATH_OK .*cache_hit=(true|false) .*built=(true|false)' \
      "fast mode must emit fastpath cache hit/miss marker"
  fi
  runtime_assert_log_pattern "${log_path}" \
    'TENSORRT_IPC_BIND_OK .*status=ok' \
    "full parity requires TENSORRT_IPC_BIND_OK status=ok"
  runtime_assert_log_pattern "${log_path}" \
    'TENSORRT_IPC_IMPORT_OK .*status=ok' \
    "full parity requires TENSORRT_IPC_IMPORT_OK status=ok"
  runtime_assert_log_pattern "${log_path}" \
    'TENSORRT_IPC_IMPORT_OK .*unresolved_shards=0' \
    "full parity requires unresolved_shards=0"
  runtime_assert_log_pattern "${log_path}" \
    'TENSORRT_FULL_SOURCE_OK .*source=ipc_materialized .*fallback_reads=0' \
    "full parity requires source=ipc_materialized and fallback_reads=0"
}
