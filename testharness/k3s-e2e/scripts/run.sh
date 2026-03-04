#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

trap 'stop_registry_port_forward' EXIT

WORKLOAD_JOB_NAME=""
WORKLOAD_CONTAINER_NAME=""
WORKLOAD_RESULT_LOG=""

wait_for_job_completion_or_fail() {
  local job_name="$1"
  local timeout_secs="${2:-1800}"
  local elapsed=0
  local interval=5

  while true; do
    local succeeded failed failed_condition
    succeeded="$(kube -n "${E2E_NAMESPACE}" get "job/${job_name}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
    failed="$(kube -n "${E2E_NAMESPACE}" get "job/${job_name}" -o jsonpath='{.status.failed}' 2>/dev/null || true)"
    failed_condition="$(kube -n "${E2E_NAMESPACE}" get "job/${job_name}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"

    if [[ "${succeeded:-0}" =~ ^[1-9][0-9]*$ ]]; then
      return 0
    fi
    if [[ "${failed:-0}" =~ ^[1-9][0-9]*$ || "${failed_condition}" == "True" ]]; then
      return 1
    fi
    if (( elapsed >= timeout_secs )); then
      return 2
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done
}

deploy_inline_workload_job() {
  SMOKE_SCRIPT="${HARNESS_DIR}/scripts/pytorch_smoke.py"
  [[ -f "${SMOKE_SCRIPT}" ]] || die "missing pytorch smoke script: ${SMOKE_SCRIPT}"

  render_template "${HARNESS_DIR}/manifests/workload-job.yaml.tpl" "${WORK_DIR}/rendered/workload-job.yaml" \
    "E2E_NAMESPACE=${E2E_NAMESPACE}" \
    "OCI2GDSD_IMAGE=${OCI2GDSD_IMAGE}" \
    "PYTORCH_IMAGE=${PYTORCH_IMAGE}" \
    "MODEL_REF=${MODEL_REF}" \
    "MODEL_ID=${MODEL_ID}" \
    "MODEL_DIGEST=${MODEL_DIGEST}" \
    "MODEL_ROOT_PATH=${MODEL_ROOT_PATH}" \
    "LEASE_HOLDER=${LEASE_HOLDER}" \
    "OCI2GDSD_ROOT_PATH=${OCI2GDSD_ROOT_PATH}"

  apply_configmap_from_files "${E2E_NAMESPACE}" "pytorch-smoke-script" \
    --from-file=pytorch_smoke.py="${SMOKE_SCRIPT}"
  kube -n "${E2E_NAMESPACE}" delete job/oci2gdsd-pytorch-smoke --ignore-not-found >/dev/null
  kube apply -f "${WORK_DIR}/rendered/workload-job.yaml"

  WORKLOAD_JOB_NAME="oci2gdsd-pytorch-smoke"
  WORKLOAD_CONTAINER_NAME="pytorch-smoke"
  WORKLOAD_RESULT_LOG="${WORK_DIR}/results/pytorch.log"
}

deploy_daemonset_workload_job() {
  apply_daemonset_stack
  apply_configmap_from_files "${E2E_NAMESPACE}" "pytorch-daemon-client-script" \
    --from-file=pytorch_daemon_client.py="${PYTORCH_DAEMON_CLIENT_SCRIPT}" \
    --from-file=oci2gds_torch_native.cpp="${PYTORCH_DAEMON_NATIVE_CPP}"

  render_template "${PYTORCH_DAEMON_CLIENT_TEMPLATE}" "${WORK_DIR}/rendered/pytorch-daemon-client-job.yaml" \
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

  kube -n "${E2E_NAMESPACE}" delete job/oci2gdsd-pytorch-daemon-client --ignore-not-found >/dev/null
  kube apply -f "${WORK_DIR}/rendered/pytorch-daemon-client-job.yaml"

  WORKLOAD_JOB_NAME="oci2gdsd-pytorch-daemon-client"
  WORKLOAD_CONTAINER_NAME="pytorch-daemon-client"
  WORKLOAD_RESULT_LOG="${WORK_DIR}/results/pytorch-daemon-client.log"
}

wait_for_workload_and_collect() {
  log "waiting for workload job completion: ${WORKLOAD_JOB_NAME}"
  local rc=0
  wait_for_job_completion_or_fail "${WORKLOAD_JOB_NAME}" 1800 || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    collect_debug
    kube -n "${E2E_NAMESPACE}" logs "job/${WORKLOAD_JOB_NAME}" -c preload-model || true
    kube -n "${E2E_NAMESPACE}" logs "job/${WORKLOAD_JOB_NAME}" -c "${WORKLOAD_CONTAINER_NAME}" || true
    if [[ "${E2E_DEPLOY_MODE}" == "daemonset-manifest" ]]; then
      capture_daemonset_logs "${WORK_DIR}/results/daemonset.log" || true
    fi
    if [[ "${rc}" -eq 2 ]]; then
      die "workload job timed out (${WORKLOAD_JOB_NAME})"
    fi
    die "workload job failed (${WORKLOAD_JOB_NAME})"
  fi
  runtime_drift_checkpoint "post-workload-job"

  kube -n "${E2E_NAMESPACE}" logs "job/${WORKLOAD_JOB_NAME}" -c preload-model > "${WORK_DIR}/results/preload.log"
  kube -n "${E2E_NAMESPACE}" logs "job/${WORKLOAD_JOB_NAME}" -c "${WORKLOAD_CONTAINER_NAME}" > "${WORKLOAD_RESULT_LOG}"

  if ! grep -q '"status": "READY"' "${WORK_DIR}/results/preload.log"; then
    die "preload init container did not report READY"
  fi

  if [[ "${E2E_DEPLOY_MODE}" == "inline-daemon" ]]; then
    if ! grep -q 'PYTORCH_SMOKE_SUCCESS' "${WORKLOAD_RESULT_LOG}"; then
      die "pytorch smoke container did not report success marker"
    fi
    return 0
  fi

  local marker
  for marker in \
    "DAEMON_GPU_LOAD_READY" \
    "DAEMON_GPU_EXPORT_OK" \
    "DAEMON_GPU_STATUS_OK" \
    "DAEMON_QWEN_IPC_BIND_OK" \
    "DAEMON_GPU_UNLOAD_OK" \
    "PYTORCH_DAEMON_CLIENT_SUCCESS"; do
    if ! grep -q "${marker}" "${WORKLOAD_RESULT_LOG}"; then
      die "daemon-client workload log is missing marker: ${marker}"
    fi
  done
  capture_daemonset_logs "${WORK_DIR}/results/daemonset.log" || true
}

log "starting k3s e2e harness"
bootstrap_tools
configure_nvidia_runtime
ensure_k3s_cluster_ready
install_gpu_operator
ensure_gpu_capacity
runtime_drift_checkpoint "run-start"

CLEAN_STALE_WORKLOADS_BEFORE_RUN="${CLEAN_STALE_WORKLOADS_BEFORE_RUN:-true}"
if is_true "${CLEAN_STALE_WORKLOADS_BEFORE_RUN}"; then
  log "cleaning stale workload namespaces (${E2E_NAMESPACE}, ${QWEN_HELLO_NAMESPACE}) before run"
  kube delete namespace "${E2E_NAMESPACE}" --ignore-not-found >/dev/null || true
  kube delete namespace "${QWEN_HELLO_NAMESPACE}" --ignore-not-found >/dev/null || true
  kube wait --for=delete namespace/"${E2E_NAMESPACE}" --timeout=180s >/dev/null 2>&1 || true
  kube wait --for=delete namespace/"${QWEN_HELLO_NAMESPACE}" --timeout=180s >/dev/null 2>&1 || true
  if [[ "${E2E_DEPLOY_MODE}" == "daemonset-manifest" ]]; then
    log "cleaning stale daemon namespace (${OCI2GDSD_DAEMON_NAMESPACE}) before run"
    kube delete namespace "${OCI2GDSD_DAEMON_NAMESPACE}" --ignore-not-found >/dev/null || true
    kube wait --for=delete namespace/"${OCI2GDSD_DAEMON_NAMESPACE}" --timeout=180s >/dev/null 2>&1 || true
  fi
fi

verify_gpu_pod
validate_local_gds_loader
runtime_drift_checkpoint "post-local-validation"

build_and_load_oci2gdsd_image
build_and_load_cli_image_if_needed
build_and_load_qwen_gds_runtime_image
preload_workload_image
if [[ -n "${MODEL_REF_OVERRIDE:-}" && -n "${MODEL_DIGEST_OVERRIDE:-}" ]]; then
  log "MODEL_REF_OVERRIDE and MODEL_DIGEST_OVERRIDE set; skipping local model packaging"
  package_model_to_registry
else
  build_packager_image
  apply_registry
  start_registry_port_forward
  package_model_to_registry
fi

mkdir -p "${WORK_DIR}/rendered" "${WORK_DIR}/results"
write_environment_report
runtime_drift_checkpoint "pre-workload-deploy"

render_template "${HARNESS_DIR}/manifests/namespace.yaml.tpl" "${WORK_DIR}/rendered/namespace.yaml" \
  "E2E_NAMESPACE=${E2E_NAMESPACE}"
render_template "${HARNESS_DIR}/manifests/oci2gdsd-configmap.yaml.tpl" "${WORK_DIR}/rendered/oci2gdsd-configmap.yaml" \
  "E2E_NAMESPACE=${E2E_NAMESPACE}" \
  "OCI2GDSD_ROOT_PATH=${OCI2GDSD_ROOT_PATH}"

kube apply -f "${WORK_DIR}/rendered/namespace.yaml"
kube apply -f "${WORK_DIR}/rendered/oci2gdsd-configmap.yaml"
case "${E2E_DEPLOY_MODE}" in
  inline-daemon)
    deploy_inline_workload_job
    ;;
  daemonset-manifest)
    deploy_daemonset_workload_job
    ;;
  *)
    die "unsupported E2E_DEPLOY_MODE=${E2E_DEPLOY_MODE}"
    ;;
esac
wait_for_workload_and_collect

if [[ "${VALIDATE_QWEN_HELLO}" == "true" ]]; then
  log "validating examples/qwen-hello deployment"
  if ! validate_qwen_hello_example; then
    collect_debug
    kube -n "${QWEN_HELLO_NAMESPACE}" logs deploy/qwen-hello -c preload-model || true
    kube -n "${QWEN_HELLO_NAMESPACE}" logs deploy/qwen-hello -c oci2gdsd-daemon || true
    kube -n "${QWEN_HELLO_NAMESPACE}" logs deploy/qwen-hello -c pytorch-api || true
    die "qwen hello example validation failed"
  fi
  runtime_drift_checkpoint "post-qwen-validation"
  cleanup_qwen_hello_example
fi

POD_NAME="$(kube -n "${E2E_NAMESPACE}" get pod -l "job-name=${WORKLOAD_JOB_NAME}" -o jsonpath='{.items[0].metadata.name}')"
NODE_NAME="$(kube -n "${E2E_NAMESPACE}" get pod "${POD_NAME}" -o jsonpath='{.spec.nodeName}')"
if [[ -z "${NODE_NAME}" ]]; then
  die "failed to resolve node name for workload pod"
fi
log "workload pod ran on node: ${NODE_NAME}"

RELEASE_IMAGE="${OCI2GDSD_IMAGE}"
if [[ "${E2E_DEPLOY_MODE}" == "daemonset-manifest" ]]; then
  RELEASE_IMAGE="${OCI2GDSD_CLI_IMAGE}"
fi

render_template "${HARNESS_DIR}/manifests/release-job.yaml.tpl" "${WORK_DIR}/rendered/release-job.yaml" \
  "E2E_NAMESPACE=${E2E_NAMESPACE}" \
  "OCI2GDSD_IMAGE=${RELEASE_IMAGE}" \
  "MODEL_ID=${MODEL_ID}" \
  "MODEL_DIGEST=${MODEL_DIGEST}" \
  "LEASE_HOLDER=${LEASE_HOLDER}" \
  "NODE_NAME=${NODE_NAME}" \
  "OCI2GDSD_ROOT_PATH=${OCI2GDSD_ROOT_PATH}"

kube -n "${E2E_NAMESPACE}" delete job/oci2gdsd-release-gc --ignore-not-found >/dev/null
kube apply -f "${WORK_DIR}/rendered/release-job.yaml"
log "waiting for release job completion"
if ! kube -n "${E2E_NAMESPACE}" wait job/oci2gdsd-release-gc --for=condition=Complete --timeout=600s; then
  collect_debug
  kube -n "${E2E_NAMESPACE}" logs job/oci2gdsd-release-gc || true
  die "release/gc job failed"
fi

kube -n "${E2E_NAMESPACE}" logs job/oci2gdsd-release-gc > "${WORK_DIR}/results/release-gc.log"
if ! grep -q '"status": "RELEASED"' "${WORK_DIR}/results/release-gc.log"; then
  die "release/gc lifecycle did not end in RELEASED status"
fi

log "k3s e2e harness completed successfully"
log "artifacts:"
log "  ${WORK_DIR}/results/preload.log"
log "  ${WORKLOAD_RESULT_LOG}"
if [[ -f "${WORK_DIR}/results/qwen-hello.log" ]]; then
  log "  ${WORK_DIR}/results/qwen-hello.log"
fi
if [[ -f "${WORK_DIR}/results/daemonset.log" ]]; then
  log "  ${WORK_DIR}/results/daemonset.log"
fi
log "  ${WORK_DIR}/results/release-gc.log"
