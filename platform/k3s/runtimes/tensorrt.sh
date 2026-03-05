#!/usr/bin/env bash
# shellcheck shell=bash

runtime_daemon_apply_configmaps() {
  apply_configmap_from_files "${E2E_NAMESPACE}" "${WORKLOAD_DAEMON_CONFIGMAP}" \
    --from-file=tensorrt_daemon_client.py="${TENSORRT_DAEMON_CLIENT_SCRIPT}" \
    --from-file=oci2gds_torch_native.cpp="${PYTORCH_DAEMON_NATIVE_CPP}"
}

runtime_daemon_render_job() {
  local rendered="$1"
  render_template "${WORKLOAD_DAEMON_TEMPLATE}" "${rendered}" \
    "E2E_NAMESPACE=${E2E_NAMESPACE}" \
    "OCI2GDSD_IMAGE=${OCI2GDSD_CLI_IMAGE}" \
    "TENSORRTLLM_IMAGE=${TENSORRTLLM_IMAGE}" \
    "MODEL_REF=${MODEL_REF}" \
    "MODEL_ID=${MODEL_ID}" \
    "MODEL_DIGEST=${MODEL_DIGEST}" \
    "MODEL_ROOT_PATH=${MODEL_ROOT_PATH}" \
    "LEASE_HOLDER=${LEASE_HOLDER}" \
    "OCI2GDSD_ROOT_PATH=${OCI2GDSD_ROOT_PATH}" \
    "OCI2GDSD_SOCKET_HOST_PATH=${OCI2GDSD_SOCKET_HOST_PATH}" \
    "REQUIRE_DIRECT_GDS=${REQUIRE_DIRECT_GDS}" \
    "OCI2GDS_STRICT=${OCI2GDS_STRICT}" \
    "RUNTIME_PARITY_MODE=${RUNTIME_PARITY_MODE}"
}

runtime_result_log_path() {
  echo "${RESULTS_DIR}/tensorrt-daemon-client.log"
}

runtime_required_markers() {
  cat <<'EOF'
DAEMON_GPU_LOAD_READY
DAEMON_GPU_STATUS_OK
DAEMON_GPU_ATTACH_OK
DAEMON_GPU_HEARTBEAT_OK
TENSORRT_IPC_TENSOR_MAP_OK
TENSORRT_IPC_BIND_OK
TENSORRT_IPC_IMPORT_OK
TENSORRT_ENGINE_BUILD_OK
TENSORRT_GDS_RUNNER_READY
TENSORRT_QWEN_INFER_OK
DAEMON_GPU_DETACH_OK
DAEMON_GPU_UNLOAD_OK
TENSORRT_DAEMON_CLIENT_SUCCESS
EOF
  if [[ "${RUNTIME_PARITY_MODE:-probe}" == "full" ]]; then
    cat <<'EOF'
TENSORRT_FULL_SOURCE_OK
EOF
  fi
}

runtime_validate_results() {
  local log_path="$1"
  if [[ "${RUNTIME_PARITY_MODE:-probe}" != "full" ]]; then
    return 0
  fi
  grep -Eq 'TENSORRT_IPC_BIND_OK .*status=ok' "${log_path}" || die "full parity requires TENSORRT_IPC_BIND_OK status=ok"
  grep -Eq 'TENSORRT_IPC_IMPORT_OK .*status=ok' "${log_path}" || die "full parity requires TENSORRT_IPC_IMPORT_OK status=ok"
  grep -Eq 'TENSORRT_IPC_IMPORT_OK .*unresolved_shards=0' "${log_path}" || die "full parity requires unresolved_shards=0"
  grep -Eq 'TENSORRT_FULL_SOURCE_OK .*source=ipc_materialized .*fallback_reads=0' "${log_path}" || die "full parity requires source=ipc_materialized and fallback_reads=0"
}
