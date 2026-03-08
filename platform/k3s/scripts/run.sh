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
WORKLOAD_DURATION_MS=0
WORKLOAD_PERF_MODE=""
WORKLOAD_FASTPATH_PHASE="n/a"
WORKLOAD_FASTPATH_CACHE_HIT="n/a"
PERF_MODE_REPORTS=()
PERF_MODES=()

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

parse_perf_modes() {
  local raw="${K3S_PERF_MODES:-cold,warm}"
  local token
  IFS=',' read -r -a PERF_MODES <<< "${raw}"
  if (( ${#PERF_MODES[@]} == 0 )); then
    die "K3S_PERF_MODES must not be empty"
  fi
  for token in "${PERF_MODES[@]}"; do
    token="$(echo "${token}" | tr '[:upper:]' '[:lower:]' | xargs)"
    case "${token}" in
      cold|warm)
        ;;
      *)
        die "unsupported performance mode ${token}; expected cold or warm"
        ;;
    esac
  done
}

runtime_mode_log_path() {
  local base
  base="$(runtime_result_log_path)"
  if [[ "${base}" == *.log ]]; then
    echo "${base%.log}-${WORKLOAD_PERF_MODE}.log"
    return
  fi
  echo "${base}-${WORKLOAD_PERF_MODE}.log"
}

phase_duration_ms_from_log() {
  local log_path="$1"
  local phase="$2"
  local duration
  duration="$(
    grep -E "DAEMON_PHASE_TIMING phase=${phase} " "${log_path}" \
      | tail -n1 \
      | gsed -n 's/.*duration_ms=\([0-9]\+\).*/\1/p'
  )"
  [[ -n "${duration}" ]] || die "missing DAEMON_PHASE_TIMING phase=${phase} in ${log_path}"
  echo "${duration}"
}

resolve_tensorrt_fastpath_state() {
  local log_path="$1"
  WORKLOAD_FASTPATH_PHASE="n/a"
  WORKLOAD_FASTPATH_CACHE_HIT="n/a"
  if [[ "${WORKLOAD_RUNTIME}" != "tensorrt" ]]; then
    return
  fi
  if grep -Eq 'TENSORRT_ENGINE_FASTPATH_OK .*cache_hit=true' "${log_path}"; then
    WORKLOAD_FASTPATH_CACHE_HIT="true"
    WORKLOAD_FASTPATH_PHASE="warm"
  elif grep -Eq 'TENSORRT_ENGINE_FASTPATH_OK .*cache_hit=false' "${log_path}"; then
    WORKLOAD_FASTPATH_CACHE_HIT="false"
    WORKLOAD_FASTPATH_PHASE="cold"
  fi
  if [[ "${TENSORRT_STARTUP_MODE}" == "fast" ]]; then
    case "${WORKLOAD_PERF_MODE}" in
      cold)
        [[ "${WORKLOAD_FASTPATH_CACHE_HIT}" == "false" ]] || die "TensorRT fast cold run must report cache_hit=false"
        ;;
      warm)
        [[ "${WORKLOAD_FASTPATH_CACHE_HIT}" == "true" ]] || die "TensorRT fast warm run must report cache_hit=true"
        ;;
    esac
  fi
}

write_perf_mode_report() {
  local mode="$1"
  local output_path="${RESULTS_DIR}/perf-${WORKLOAD_RUNTIME}-${mode}.json"
  local startup_mode="n/a"
  if [[ "${WORKLOAD_RUNTIME}" == "tensorrt" ]]; then
    startup_mode="${TENSORRT_STARTUP_MODE}"
  fi
  local ensure_ms bundle_ms load_ms tensor_map_ms bind_ms first_token_ms
  ensure_ms="$(phase_duration_ms_from_log "${WORKLOAD_RESULT_LOG}" "ensure")"
  bundle_ms="$(phase_duration_ms_from_log "${WORKLOAD_RESULT_LOG}" "bundle")"
  load_ms="$(phase_duration_ms_from_log "${WORKLOAD_RESULT_LOG}" "load")"
  tensor_map_ms="$(phase_duration_ms_from_log "${WORKLOAD_RESULT_LOG}" "tensor-map")"
  bind_ms="$(phase_duration_ms_from_log "${WORKLOAD_RESULT_LOG}" "bind")"
  first_token_ms="$(phase_duration_ms_from_log "${WORKLOAD_RESULT_LOG}" "first-token")"
  resolve_tensorrt_fastpath_state "${WORKLOAD_RESULT_LOG}"

  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg runtime "${WORKLOAD_RUNTIME}" \
    --arg mode "${mode}" \
    --arg parity_mode "${RUNTIME_PARITY_MODE}" \
    --arg startup_mode "${startup_mode}" \
    --arg fastpath_phase "${WORKLOAD_FASTPATH_PHASE}" \
    --arg fastpath_cache_hit "${WORKLOAD_FASTPATH_CACHE_HIT}" \
    --argjson workload_duration_ms "${WORKLOAD_DURATION_MS}" \
    --argjson ensure_ms "${ensure_ms}" \
    --argjson bundle_ms "${bundle_ms}" \
    --argjson load_ms "${load_ms}" \
    --argjson tensor_map_ms "${tensor_map_ms}" \
    --argjson bind_ms "${bind_ms}" \
    --argjson first_token_ms "${first_token_ms}" \
    '{
      timestamp: $ts,
      runtime: $runtime,
      mode: $mode,
      parity_mode: $parity_mode,
      startup_mode: $startup_mode,
      workload_duration_ms: $workload_duration_ms,
      fastpath_phase: $fastpath_phase,
      fastpath_cache_hit: $fastpath_cache_hit,
      phases: {
        ensure: {duration_ms: $ensure_ms},
        bundle: {duration_ms: $bundle_ms},
        load: {"duration_ms": $load_ms},
        "tensor-map": {"duration_ms": $tensor_map_ms},
        bind: {"duration_ms": $bind_ms},
        "first-token": {"duration_ms": $first_token_ms}
      }
    }' > "${output_path}"
  PERF_MODE_REPORTS+=("${output_path}")
  cp "${output_path}" "${RESULTS_DIR}/workload-perf-summary.json"
  log "wrote workload perf mode report: ${output_path}"
}

write_perf_summary() {
  local summary_path="${RESULTS_DIR}/perf-summary.json"
  (( ${#PERF_MODE_REPORTS[@]} > 0 )) || die "no perf mode reports were generated"
  local runs_json
  runs_json="$(jq -s '.' "${PERF_MODE_REPORTS[@]}")"

  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg runtime "${WORKLOAD_RUNTIME}" \
    --argjson runs "${runs_json}" \
    '
    def quantile($vals; $q):
      if ($vals | length) == 0 then 0
      else
        ($vals | sort) as $s
        | ($s | length) as $n
        | (($q * ($n - 1)) | floor) as $idx
        | ($s[$idx] // 0)
      end;
    def phase_stats($phase):
      ([ $runs[] | .phases[$phase].duration_ms ] | map(tonumber)) as $vals
      | {
          samples: ($vals | length),
          p50_ms: quantile($vals; 0.50),
          p95_ms: quantile($vals; 0.95),
          values_ms: $vals
        };
    {
      timestamp: $ts,
      runtime: $runtime,
      run_count: ($runs | length),
      runs: $runs,
      phases: {
        ensure: phase_stats("ensure"),
        bundle: phase_stats("bundle"),
        load: phase_stats("load"),
        "tensor-map": phase_stats("tensor-map"),
        bind: phase_stats("bind"),
        "first-token": phase_stats("first-token")
      }
    }' > "${summary_path}"
  cp "${summary_path}" "${RESULTS_DIR}/workload-perf-summary.json"
  log "wrote perf summary: ${summary_path}"
}

enforce_perf_regression_gates() {
  local summary_path="${RESULTS_DIR}/perf-summary.json"
  [[ -f "${summary_path}" ]] || die "perf summary missing: ${summary_path}"
  local max_regression_pct="${PERF_MAX_REGRESSION_PCT:-35}"

  local has_cold has_warm
  has_cold="$(jq -r '[.runs[].mode] | index("cold") != null' "${summary_path}")"
  has_warm="$(jq -r '[.runs[].mode] | index("warm") != null' "${summary_path}")"
  if [[ "${has_cold}" != "true" || "${has_warm}" != "true" ]]; then
    log "skipping p50/p95 regression gates because cold and warm runs were not both present"
    return
  fi

  local phases=("ensure" "bundle" "load" "tensor-map" "bind" "first-token")
  local phase
  for phase in "${phases[@]}"; do
    local cold_p50 warm_p50 cold_p95 warm_p95 p50_limit p95_limit
    cold_p50="$(jq -r --arg phase "${phase}" '.runs[] | select(.mode=="cold") | .phases[$phase].duration_ms' "${summary_path}" | head -n1)"
    warm_p50="$(jq -r --arg phase "${phase}" '.runs[] | select(.mode=="warm") | .phases[$phase].duration_ms' "${summary_path}" | head -n1)"
    cold_p95="${cold_p50}"
    warm_p95="${warm_p50}"
    [[ -n "${cold_p50}" && -n "${warm_p50}" ]] || die "missing cold/warm phase durations for ${phase}"

    p50_limit="$(jq -n --argjson cold "${cold_p50}" --argjson pct "${max_regression_pct}" '($cold * (100 + $pct) / 100)')"
    p95_limit="$(jq -n --argjson cold "${cold_p95}" --argjson pct "${max_regression_pct}" '($cold * (100 + $pct) / 100)')"
    jq -en \
      --argjson warm_p50 "${warm_p50}" \
      --argjson warm_p95 "${warm_p95}" \
      --argjson p50_limit "${p50_limit}" \
      --argjson p95_limit "${p95_limit}" \
      '$warm_p50 <= $p50_limit and $warm_p95 <= $p95_limit' >/dev/null || \
      die "perf regression gate failed for phase=${phase}: warm_p50=${warm_p50} warm_p95=${warm_p95} limit=${p50_limit} max_regression_pct=${max_regression_pct}"
  done
  log "perf regression gates passed (max_regression_pct=${max_regression_pct})"
}

deploy_daemonset_workload_job() {
  apply_daemonset_stack
  runtime_daemon_apply_configmaps
  local rendered="${RENDERED_DIR}/${WORKLOAD_RUNTIME}-daemon-client-job-${WORKLOAD_PERF_MODE}.yaml"
  export PERF_MODE="${WORKLOAD_PERF_MODE}"
  runtime_daemon_render_job "${rendered}"
  if declare -F runtime_assert_no_artifact_access_manifest >/dev/null 2>&1; then
    runtime_assert_no_artifact_access_manifest "${rendered}"
  fi
  kube -n "${E2E_NAMESPACE}" delete "job/${WORKLOAD_DAEMON_JOB_NAME}" --ignore-not-found >/dev/null
  kube apply -f "${rendered}"
  WORKLOAD_RESULT_LOG="$(runtime_mode_log_path)"
  WORKLOAD_JOB_NAME="${WORKLOAD_DAEMON_JOB_NAME}"
  WORKLOAD_CONTAINER_NAME="${WORKLOAD_DAEMON_CONTAINER_NAME}"
}

wait_for_workload_and_collect() {
  log "waiting for workload job completion: ${WORKLOAD_JOB_NAME} (mode=${WORKLOAD_PERF_MODE})"
  local rc=0
  local started_at ended_at
  started_at="$(date +%s)"
  wait_for_job_completion_or_fail "${WORKLOAD_JOB_NAME}" 1800 || rc=$?
  ended_at="$(date +%s)"
  WORKLOAD_DURATION_MS="$(( (ended_at - started_at) * 1000 ))"
  if [[ "${rc}" -ne 0 ]]; then
    collect_debug
    kube -n "${E2E_NAMESPACE}" logs "job/${WORKLOAD_JOB_NAME}" -c "${WORKLOAD_CONTAINER_NAME}" || true
    capture_daemonset_logs "${RESULTS_DIR}/daemonset.log" || true
    if [[ "${rc}" -eq 2 ]]; then
      die "workload job timed out (${WORKLOAD_JOB_NAME})"
    fi
    die "workload job failed (${WORKLOAD_JOB_NAME})"
  fi
  runtime_drift_checkpoint "post-workload-job-${WORKLOAD_PERF_MODE}"

  kube -n "${E2E_NAMESPACE}" logs "job/${WORKLOAD_JOB_NAME}" -c "${WORKLOAD_CONTAINER_NAME}" > "${WORKLOAD_RESULT_LOG}"

  local marker
  while IFS= read -r marker; do
    [[ -n "${marker}" ]] || continue
    if ! grep -q "${marker}" "${WORKLOAD_RESULT_LOG}"; then
      die "daemon-client workload log is missing marker (${WORKLOAD_PERF_MODE}): ${marker}"
    fi
  done < <(runtime_required_markers)
  if declare -F runtime_validate_results >/dev/null 2>&1; then
    runtime_validate_results "${WORKLOAD_RESULT_LOG}"
  fi

  local canonical_log
  canonical_log="$(runtime_result_log_path)"
  cp "${WORKLOAD_RESULT_LOG}" "${canonical_log}"

  write_perf_mode_report "${WORKLOAD_PERF_MODE}"
  capture_daemonset_logs "${RESULTS_DIR}/daemonset.log" || true
}

run_workload_perf_matrix() {
  parse_perf_modes
  local mode
  for mode in "${PERF_MODES[@]}"; do
    mode="$(echo "${mode}" | tr '[:upper:]' '[:lower:]' | xargs)"
    WORKLOAD_PERF_MODE="${mode}"
    log "running workload mode=${WORKLOAD_PERF_MODE} runtime=${WORKLOAD_RUNTIME}"
    deploy_daemonset_workload_job
    wait_for_workload_and_collect
  done
  write_perf_summary
  enforce_perf_regression_gates
}

log "starting k3s e2e harness"
[[ "${E2E_DEPLOY_MODE}" == "daemonset-manifest" ]] || die "k3s harness requires E2E_DEPLOY_MODE=daemonset-manifest"
[[ "${RUNTIME_PARITY_MODE}" == "full" ]] || die "k3s harness requires RUNTIME_PARITY_MODE=full"
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
  log "cleaning stale daemon namespace (${OCI2GDSD_DAEMON_NAMESPACE}) before run"
  kube delete namespace "${OCI2GDSD_DAEMON_NAMESPACE}" --ignore-not-found >/dev/null || true
  kube wait --for=delete namespace/"${OCI2GDSD_DAEMON_NAMESPACE}" --timeout=180s >/dev/null 2>&1 || true
fi

verify_gpu_pod
validate_local_gds_loader
runtime_drift_checkpoint "post-local-validation"

build_and_load_oci2gdsd_image
build_and_load_cli_image_if_needed
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
run_workload_perf_matrix

if [[ "${VALIDATE_QWEN_HELLO}" == "true" ]]; then
  log "validating platform/k3s/pytorch/qwen-hello deployment"
  if ! validate_qwen_hello_example; then
    collect_debug
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

RELEASE_IMAGE="${OCI2GDSD_CLI_IMAGE}"

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
if (( ${#PERF_MODE_REPORTS[@]} > 0 )); then
  local_perf_file=""
  for local_perf_file in "${PERF_MODE_REPORTS[@]}"; do
    log "  ${local_perf_file}"
  done
fi
log "  ${RESULTS_DIR}/perf-summary.json"
log "  ${RESULTS_DIR}/workload-perf-summary.json"
if [[ -f "${RESULTS_DIR}/qwen-hello.log" ]]; then
  log "  ${RESULTS_DIR}/qwen-hello.log"
fi
if [[ -f "${RESULTS_DIR}/daemonset.log" ]]; then
  log "  ${RESULTS_DIR}/daemonset.log"
fi
log "  ${RESULTS_DIR}/release-gc.log"
