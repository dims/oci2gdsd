#!/usr/bin/env bash
# shellcheck shell=bash

runtime_render_job_template() {
  local rendered="$1"
  local workload_image_key="$2"
  local workload_image_value="$3"
  shift 3

  render_template "${WORKLOAD_DAEMON_TEMPLATE}" "${rendered}" \
    "E2E_NAMESPACE=${E2E_NAMESPACE}" \
    "OCI2GDSD_IMAGE=${OCI2GDSD_CLI_IMAGE}" \
    "${workload_image_key}=${workload_image_value}" \
    "MODEL_REF=${MODEL_REF}" \
    "MODEL_ID=${MODEL_ID}" \
    "MODEL_DIGEST=${MODEL_DIGEST}" \
    "LEASE_HOLDER=${LEASE_HOLDER}" \
    "OCI2GDSD_ROOT_PATH=${OCI2GDSD_ROOT_PATH}" \
    "OCI2GDSD_SOCKET_HOST_PATH=${OCI2GDSD_SOCKET_HOST_PATH}" \
    "REQUIRE_DIRECT_GDS=${REQUIRE_DIRECT_GDS}" \
    "OCI2GDS_STRICT=${OCI2GDS_STRICT}" \
    "RUNTIME_PARITY_MODE=${RUNTIME_PARITY_MODE}" \
    "$@"
}

runtime_emit_markers() {
  printf '%s\n' "$@"
}

runtime_require_full_parity() {
  local runtime_name="$1"
  if [[ "${RUNTIME_PARITY_MODE:-probe}" != "full" ]]; then
    die "${runtime_name} daemon-client requires RUNTIME_PARITY_MODE=full; path-backed modes are removed"
  fi
}

runtime_assert_log_pattern() {
  local log_path="$1"
  local pattern="$2"
  local message="$3"
  grep -Eq "${pattern}" "${log_path}" || die "${message}"
}
