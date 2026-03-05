#!/usr/bin/env bash
# shellcheck shell=bash

runtime_daemon_apply_configmaps() {
  apply_configmap_from_files "${E2E_NAMESPACE}" "${WORKLOAD_DAEMON_CONFIGMAP}" \
    --from-file=pytorch_daemon_client.py="${PYTORCH_DAEMON_CLIENT_SCRIPT}" \
    --from-file=oci2gds_torch_native.cpp="${PYTORCH_DAEMON_NATIVE_CPP}"
}

runtime_daemon_render_job() {
  local rendered="$1"
  render_template "${WORKLOAD_DAEMON_TEMPLATE}" "${rendered}" \
    "E2E_NAMESPACE=${E2E_NAMESPACE}" \
    "OCI2GDSD_IMAGE=${OCI2GDSD_CLI_IMAGE}" \
    "PYTORCH_IMAGE=${PYTORCH_IMAGE}" \
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
  echo "${RESULTS_DIR}/pytorch-daemon-client.log"
}

runtime_required_markers() {
  cat <<'EOF'
DAEMON_GPU_LOAD_READY
DAEMON_GPU_EXPORT_OK
DAEMON_GPU_ATTACH_OK
DAEMON_GPU_HEARTBEAT_OK
DAEMON_GPU_STATUS_OK
DAEMON_QWEN_IPC_BIND_OK
DAEMON_GPU_DETACH_OK
DAEMON_GPU_UNLOAD_OK
PYTORCH_DAEMON_CLIENT_SUCCESS
EOF
}
