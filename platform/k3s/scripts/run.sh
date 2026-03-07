#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=../runtimes/pytorch.sh
source "${WORKLOAD_ADAPTER_SCRIPT}"

trap 'stop_registry_port_forward' EXIT

WORKLOAD_JOB_NAME=""
WORKLOAD_CONTAINER_NAME=""
WORKLOAD_RESULT_LOG=""

validate_runtime_contracts() {
  local validator="${SCRIPT_DIR}/validate-runtime-contract.sh"
  [[ -x "${validator}" ]] || die "runtime contract validator is missing or not executable: ${validator}"
  "${validator}" \
    --runtime "${WORKLOAD_RUNTIME}" \
    --include-qwen \
    --report "${RESULTS_DIR}/runtime-contract-report.json"
}

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

  render_template "${HARNESS_DIR}/manifests/workload-job.yaml.tpl" "${RENDERED_DIR}/workload-job.yaml" \
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
  kube apply -f "${RENDERED_DIR}/workload-job.yaml"

  WORKLOAD_JOB_NAME="oci2gdsd-pytorch-smoke"
  WORKLOAD_CONTAINER_NAME="pytorch-smoke"
  WORKLOAD_RESULT_LOG="${RESULTS_DIR}/pytorch.log"
}

deploy_daemonset_workload_job() {
  apply_daemonset_stack
  runtime_daemon_apply_configmaps
  local rendered="${RENDERED_DIR}/${WORKLOAD_RUNTIME}-daemon-client-job.yaml"
  runtime_daemon_render_job "${rendered}"
  kube -n "${E2E_NAMESPACE}" delete "job/${WORKLOAD_DAEMON_JOB_NAME}" --ignore-not-found >/dev/null
  kube apply -f "${rendered}"
  WORKLOAD_RESULT_LOG="$(runtime_result_log_path)"
  WORKLOAD_JOB_NAME="${WORKLOAD_DAEMON_JOB_NAME}"
  WORKLOAD_CONTAINER_NAME="${WORKLOAD_DAEMON_CONTAINER_NAME}"
}

wait_for_workload_and_collect() {
  log "waiting for workload job completion: ${WORKLOAD_JOB_NAME}"
  local rc=0
  wait_for_job_completion_or_fail "${WORKLOAD_JOB_NAME}" 1800 || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    collect_debug
    if [[ "${E2E_DEPLOY_MODE}" == "inline-daemon" ]]; then
      kube -n "${E2E_NAMESPACE}" logs "job/${WORKLOAD_JOB_NAME}" -c preload-model || true
    fi
    kube -n "${E2E_NAMESPACE}" logs "job/${WORKLOAD_JOB_NAME}" -c "${WORKLOAD_CONTAINER_NAME}" || true
    if [[ "${E2E_DEPLOY_MODE}" == "daemonset-manifest" ]]; then
      capture_daemonset_logs "${RESULTS_DIR}/daemonset.log" || true
    fi
    if [[ "${rc}" -eq 2 ]]; then
      die "workload job timed out (${WORKLOAD_JOB_NAME})"
    fi
    die "workload job failed (${WORKLOAD_JOB_NAME})"
  fi
  runtime_drift_checkpoint "post-workload-job"

  kube -n "${E2E_NAMESPACE}" logs "job/${WORKLOAD_JOB_NAME}" -c "${WORKLOAD_CONTAINER_NAME}" > "${WORKLOAD_RESULT_LOG}"

  if [[ "${E2E_DEPLOY_MODE}" == "inline-daemon" ]]; then
    kube -n "${E2E_NAMESPACE}" logs "job/${WORKLOAD_JOB_NAME}" -c preload-model > "${RESULTS_DIR}/preload.log"
    if ! grep -q '"status": "READY"' "${RESULTS_DIR}/preload.log"; then
      die "preload init container did not report READY"
    fi
    if ! grep -q 'PYTORCH_SMOKE_SUCCESS' "${WORKLOAD_RESULT_LOG}"; then
      die "pytorch smoke container did not report success marker"
    fi
    return 0
  fi

  local marker
  while IFS= read -r marker; do
    [[ -n "${marker}" ]] || continue
    if ! grep -q "${marker}" "${WORKLOAD_RESULT_LOG}"; then
      die "daemon-client workload log is missing marker: ${marker}"
    fi
  done < <(runtime_required_markers)
  if declare -F runtime_validate_results >/dev/null 2>&1; then
    runtime_validate_results "${WORKLOAD_RESULT_LOG}"
  fi
  capture_daemonset_logs "${RESULTS_DIR}/daemonset.log" || true
}

log "starting k3s e2e harness"
validate_runtime_contracts
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

mkdir -p "${RENDERED_DIR}" "${RESULTS_DIR}"
write_environment_report
runtime_drift_checkpoint "pre-workload-deploy"

render_template "${HARNESS_DIR}/manifests/namespace.yaml.tpl" "${RENDERED_DIR}/namespace.yaml" \
  "E2E_NAMESPACE=${E2E_NAMESPACE}"
render_template "${HARNESS_DIR}/manifests/oci2gdsd-configmap.yaml.tpl" "${RENDERED_DIR}/oci2gdsd-configmap.yaml" \
  "E2E_NAMESPACE=${E2E_NAMESPACE}" \
  "OCI2GDSD_ROOT_PATH=${OCI2GDSD_ROOT_PATH}"

kube apply -f "${RENDERED_DIR}/namespace.yaml"
kube apply -f "${RENDERED_DIR}/oci2gdsd-configmap.yaml"
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
  log "validating platform/k3s/pytorch/qwen-hello deployment"
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

render_template "${HARNESS_DIR}/manifests/release-job.yaml.tpl" "${RENDERED_DIR}/release-job.yaml" \
  "E2E_NAMESPACE=${E2E_NAMESPACE}" \
  "OCI2GDSD_IMAGE=${RELEASE_IMAGE}" \
  "MODEL_ID=${MODEL_ID}" \
  "MODEL_DIGEST=${MODEL_DIGEST}" \
  "LEASE_HOLDER=${LEASE_HOLDER}" \
  "NODE_NAME=${NODE_NAME}" \
  "OCI2GDSD_ROOT_PATH=${OCI2GDSD_ROOT_PATH}"

kube -n "${E2E_NAMESPACE}" delete job/oci2gdsd-release-gc --ignore-not-found >/dev/null
kube apply -f "${RENDERED_DIR}/release-job.yaml"
log "waiting for release job completion"
if ! kube -n "${E2E_NAMESPACE}" wait job/oci2gdsd-release-gc --for=condition=Complete --timeout=600s; then
  collect_debug
  kube -n "${E2E_NAMESPACE}" logs job/oci2gdsd-release-gc || true
  die "release/gc job failed"
fi

kube -n "${E2E_NAMESPACE}" logs job/oci2gdsd-release-gc > "${RESULTS_DIR}/release-gc.log"
if ! grep -q '"status": "RELEASED"' "${RESULTS_DIR}/release-gc.log"; then
  die "release/gc lifecycle did not end in RELEASED status"
fi

log "k3s e2e harness completed successfully"
log "artifacts:"
if [[ -f "${RESULTS_DIR}/preload.log" ]]; then
  log "  ${RESULTS_DIR}/preload.log"
fi
log "  ${WORKLOAD_RESULT_LOG}"
if [[ -f "${RESULTS_DIR}/qwen-hello.log" ]]; then
  log "  ${RESULTS_DIR}/qwen-hello.log"
fi
if [[ -f "${RESULTS_DIR}/daemonset.log" ]]; then
  log "  ${RESULTS_DIR}/daemonset.log"
fi
log "  ${RESULTS_DIR}/release-gc.log"
