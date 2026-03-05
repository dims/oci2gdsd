#!/usr/bin/env bash
# shellcheck shell=bash

runtime_daemon_apply_configmaps() {
  apply_configmap_from_files "${E2E_NAMESPACE}" "${WORKLOAD_DAEMON_CONFIGMAP}" \
    --from-file=vllm_daemon_client.py="${VLLM_DAEMON_CLIENT_SCRIPT}"
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
    "OCI2GDS_STRICT=${OCI2GDS_STRICT}"
}

runtime_result_log_path() {
  echo "${RESULTS_DIR}/vllm-daemon-client.log"
}

runtime_required_markers() {
  cat <<'EOF'
DAEMON_GPU_LOAD_READY
DAEMON_GPU_STATUS_OK
VLLM_LOADER_REGISTERED
VLLM_OCI2GDS_LOAD_OK
VLLM_QWEN_INFER_OK
DAEMON_GPU_UNLOAD_OK
VLLM_DAEMON_CLIENT_SUCCESS
EOF
}
