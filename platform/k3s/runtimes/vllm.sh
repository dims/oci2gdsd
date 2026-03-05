#!/usr/bin/env bash
# shellcheck shell=bash

runtime_daemon_apply_configmaps() {
  apply_configmap_from_files "${E2E_NAMESPACE}" "${WORKLOAD_DAEMON_CONFIGMAP}" \
    --from-file=vllm_daemon_client.py="${VLLM_DAEMON_CLIENT_SCRIPT}" \
    --from-file=oci2gds_torch_native.cpp="${PYTORCH_DAEMON_NATIVE_CPP}"
}

runtime_daemon_render_job() {
  local rendered="$1"
  render_template "${WORKLOAD_DAEMON_TEMPLATE}" "${rendered}" \
    "E2E_NAMESPACE=${E2E_NAMESPACE}" \
    "OCI2GDSD_IMAGE=${OCI2GDSD_CLI_IMAGE}" \
    "VLLM_IMAGE=${VLLM_IMAGE}" \
    "MODEL_REF=${MODEL_REF}" \
    "MODEL_ID=${MODEL_ID}" \
    "MODEL_DIGEST=${MODEL_DIGEST}" \
    "MODEL_ROOT_PATH=${MODEL_ROOT_PATH}" \
    "LEASE_HOLDER=${LEASE_HOLDER}" \
    "OCI2GDSD_ROOT_PATH=${OCI2GDSD_ROOT_PATH}" \
    "OCI2GDSD_SOCKET_HOST_PATH=${OCI2GDSD_SOCKET_HOST_PATH}" \
    "REQUIRE_DIRECT_GDS=${REQUIRE_DIRECT_GDS}" \
    "OCI2GDS_STRICT=${OCI2GDS_STRICT}" \
    "RUNTIME_PARITY_MODE=${RUNTIME_PARITY_MODE}" \
    "REQUIRE_FULL_IPC_BIND=${REQUIRE_FULL_IPC_BIND}"
}

runtime_result_log_path() {
  echo "${RESULTS_DIR}/vllm-daemon-client.log"
}

runtime_required_markers() {
  cat <<'EOF'
DAEMON_GPU_LOAD_READY
DAEMON_GPU_STATUS_OK
DAEMON_GPU_ATTACH_OK
DAEMON_GPU_HEARTBEAT_OK
VLLM_IPC_TENSOR_MAP_OK
VLLM_IPC_BIND_OK
VLLM_LOADER_REGISTERED
VLLM_OCI2GDS_LOAD_OK
VLLM_QWEN_INFER_OK
DAEMON_GPU_DETACH_OK
DAEMON_GPU_UNLOAD_OK
VLLM_DAEMON_CLIENT_SUCCESS
EOF
}
