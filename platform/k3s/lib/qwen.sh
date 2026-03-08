#!/usr/bin/env bash
# shellcheck shell=bash

assert_profile_probe_perf_gates() {
  local throughput="$1"
  local duration_ms="$2"
  local min_required="${MIN_PROFILE_PROBE_MIB_S}"
  local baseline_file="${PROFILE_PROBE_BASELINE_FILE}"
  local max_reg_pct="${PROFILE_PROBE_MAX_REGRESSION_PCT}"

  if ! [[ "${min_required}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    die "MIN_PROFILE_PROBE_MIB_S must be numeric (got ${min_required})"
  fi
  if ! [[ "${max_reg_pct}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    die "PROFILE_PROBE_MAX_REGRESSION_PCT must be numeric (got ${max_reg_pct})"
  fi
  awk -v t="${throughput}" -v m="${min_required}" 'BEGIN {exit !(t+0 >= m+0)}' || \
    die "profile probe throughput too low: ${throughput} MiB/s < ${min_required} MiB/s"

  mkdir -p "$(dirname "${baseline_file}")"
  if [[ ! -f "${baseline_file}" ]]; then
    jq -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson throughput "$(printf '%s' "${throughput}")" \
      --argjson duration_ms "$(printf '%s' "${duration_ms}")" \
      '{created_at:$ts, throughput_mib_s:$throughput, duration_ms:$duration_ms}' > "${baseline_file}"
    log "created profile probe baseline: ${baseline_file}"
    return 0
  fi
  if [[ "${max_reg_pct}" == "0" || "${max_reg_pct}" == "0.0" ]]; then
    return 0
  fi
  local baseline_throughput
  baseline_throughput="$(jq -r '.throughput_mib_s // 0' "${baseline_file}" 2>/dev/null || echo 0)"
  local min_allowed
  min_allowed="$(awk -v b="${baseline_throughput}" -v p="${max_reg_pct}" 'BEGIN {printf "%.2f", b * (1 - (p/100.0))}')"
  awk -v t="${throughput}" -v m="${min_allowed}" 'BEGIN {exit !(t+0 >= m+0)}' || \
    die "profile probe throughput regression exceeded threshold: current=${throughput} baseline=${baseline_throughput} max_regression_pct=${max_reg_pct} min_allowed=${min_allowed}"
}

assert_qwen_no_artifact_access_manifest() {
  local rendered="$1"
  local forbidden=(
    '-[[:space:]]+name:[[:space:]]*MODEL_ROOT_PATH'
    '-[[:space:]]+name:[[:space:]]*oci2gdsd-root'
    '-[[:space:]]+name:[[:space:]]*preload-model'
  )
  local pattern
  for pattern in "${forbidden[@]}"; do
    if grep -Eq -- "${pattern}" "${rendered}"; then
      die "qwen-hello manifest must not expose runtime artifact roots: ${pattern}"
    fi
  done
}

validate_qwen_hello_example() {
  local template="${QWEN_HELLO_TEMPLATE}"
  local app_dir="${REPO_ROOT}/platform/k3s/pytorch/app"
  local native_dir="${REPO_ROOT}/platform/k3s/pytorch/native"
  local qwen_hello_oci2gds_strict="${QWEN_HELLO_OCI2GDS_STRICT:-false}"
  local qwen_hello_oci2gds_probe_strict="${QWEN_HELLO_OCI2GDS_PROBE_STRICT:-false}"
  local qwen_hello_oci2gds_force_no_compat="${QWEN_HELLO_OCI2GDS_FORCE_NO_COMPAT:-false}"
  local qwen_hello_require_strict_profile_probe="${QWEN_HELLO_REQUIRE_STRICT_PROFILE_PROBE:-false}"
  local qwen_hello_require_direct_gds="${QWEN_HELLO_REQUIRE_DIRECT_GDS:-false}"
  local qwen_hello_require_no_compat_evidence="${QWEN_HELLO_REQUIRE_NO_COMPAT_EVIDENCE:-false}"
  local qwen_hello_require_daemon_ipc_probe="${QWEN_HELLO_REQUIRE_DAEMON_IPC_PROBE:-false}"
  if [[ ! -f "${template}" ]]; then
    warn "missing example template: ${template}"
    return 1
  fi
  [[ -f "${app_dir}/qwen_server.py" ]] || die "missing qwen app script: ${app_dir}/qwen_server.py"
  [[ -f "${app_dir}/deps_bootstrap.py" ]] || die "missing qwen deps script: ${app_dir}/deps_bootstrap.py"
  [[ -f "${native_dir}/oci2gds_torch_native.cpp" ]] || die "missing native source: ${native_dir}/oci2gds_torch_native.cpp"

  ensure_namespace "${QWEN_HELLO_NAMESPACE}"
  apply_configmap_from_files "${QWEN_HELLO_NAMESPACE}" "qwen-hello-app" \
    --from-file=qwen_server.py="${app_dir}/qwen_server.py" \
    --from-file=deps_bootstrap.py="${app_dir}/deps_bootstrap.py"
  apply_configmap_from_files "${QWEN_HELLO_NAMESPACE}" "qwen-hello-native" \
    --from-file=oci2gds_torch_native.cpp="${native_dir}/oci2gds_torch_native.cpp"

  mkdir -p "${RENDERED_DIR}" "${RESULTS_DIR}"
  local rendered="${RENDERED_DIR}/qwen-hello.yaml"
  render_template "${template}" "${rendered}" \
    "QWEN_HELLO_NAMESPACE=${QWEN_HELLO_NAMESPACE}" \
    "MODEL_ID=${MODEL_ID}" \
    "MODEL_REF=${MODEL_REF}" \
    "MODEL_DIGEST=${MODEL_DIGEST}" \
    "OCI2GDSD_IMAGE=${OCI2GDSD_IMAGE}" \
    "OCI2GDSD_ROOT_PATH=${OCI2GDSD_ROOT_PATH}" \
    "OCI2GDS_STRICT=${qwen_hello_oci2gds_strict}" \
    "OCI2GDS_PROBE_STRICT=${qwen_hello_oci2gds_probe_strict}" \
    "OCI2GDS_FORCE_NO_COMPAT=${qwen_hello_oci2gds_force_no_compat}" \
    "OCI2GDS_DAEMON_ENABLE=${OCI2GDS_DAEMON_ENABLE}" \
    "OCI2GDS_DAEMON_PROBE_SHARDS=${OCI2GDS_DAEMON_PROBE_SHARDS}" \
    "PYTORCH_RUNTIME_IMAGE=${PYTORCH_RUNTIME_IMAGE}" \
    "LEASE_HOLDER=${LEASE_HOLDER}"
  assert_qwen_no_artifact_access_manifest "${rendered}"

  if ! grep -q 'runtimeClassName: nvidia' "${rendered}"; then
    gsed -i 's|restartPolicy: Always|restartPolicy: Always\
      runtimeClassName: nvidia|' "${rendered}"
  fi

  kube apply -f "${rendered}"
  kube -n "${QWEN_HELLO_NAMESPACE}" \
    rollout status deploy/qwen-hello --timeout=1800s
  local log_file="${RESULTS_DIR}/qwen-hello.log"
  : > "${log_file}"
  local pod_name
  pod_name="$(kube -n "${QWEN_HELLO_NAMESPACE}" \
    get pod -l app=qwen-hello -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${pod_name}" ]]; then
    warn "failed to resolve qwen-hello pod name"
    return 1
  fi

  local pf_pid_file="${WORK_DIR}/qwen-hello-port-forward.pid"
  local pf_log="${LOG_DIR}/qwen-hello-port-forward.log"
  local local_port="${QWEN_HELLO_LOCAL_PORT:-18080}"
  rm -f "${pf_pid_file}"
  kube -n "${QWEN_HELLO_NAMESPACE}" \
    port-forward svc/qwen-hello "${local_port}:8000" >"${pf_log}" 2>&1 &
  echo "$!" > "${pf_pid_file}"

  local start_ts timeout_secs now
  start_ts="$(date +%s)"
  timeout_secs=300
  while true; do
    if curl -fsS "http://127.0.0.1:${local_port}/healthz" >/dev/null 2>&1; then
      break
    fi
    now="$(date +%s)"
    if (( now - start_ts >= timeout_secs )); then
      warn "qwen hello API did not become healthy within ${timeout_secs}s"
      if [[ -s "${pf_log}" ]]; then
        warn "port-forward log:"
        cat "${pf_log}" >&2 || true
      fi
      if [[ -f "${pf_pid_file}" ]]; then
        kill "$(cat "${pf_pid_file}")" 2>/dev/null || true
      fi
      return 1
    fi
    sleep 3
  done

  local prompt='Explain in one sentence what GPU model preloading helps with.'
  local health_response
  health_response="$(curl -fsS "http://127.0.0.1:${local_port}/healthz" || true)"
  local health_status
  health_status="$(printf '%s' "${health_response}" | jq -r '.status // empty' 2>/dev/null || true)"
  local oci2gds_profile_status
  oci2gds_profile_status="$(printf '%s' "${health_response}" | jq -r '.oci2gds_profile.status // empty' 2>/dev/null || true)"
  local oci2gds_profile_backend
  oci2gds_profile_backend="$(printf '%s' "${health_response}" | jq -r '.oci2gds_profile.backend // empty' 2>/dev/null || true)"
  local oci2gds_backend
  oci2gds_backend="$(printf '%s' "${health_response}" | jq -r '.oci2gds_backend.backend // empty' 2>/dev/null || true)"
  local oci2gds_mode_counts
  oci2gds_mode_counts="$(printf '%s' "${health_response}" | jq -r '.oci2gds_profile.mode_counts // "{}"' 2>/dev/null || true)"
  local oci2gds_direct_count
  oci2gds_direct_count="$(printf '%s' "${health_response}" | jq -r '
    (.oci2gds_profile.mode_counts // {}) |
    (if type=="string" then (try fromjson catch {}) elif type=="object" then . else {} end) |
    .direct // 0
  ' 2>/dev/null || true)"
  local oci2gds_compat_count
  oci2gds_compat_count="$(printf '%s' "${health_response}" | jq -r '
    (.oci2gds_profile.mode_counts // {}) |
    (if type=="string" then (try fromjson catch {}) elif type=="object" then . else {} end) |
    .compat // 0
  ' 2>/dev/null || true)"
  local oci2gds_force_no_compat
  oci2gds_force_no_compat="$(printf '%s' "${health_response}" | jq -r '(.oci2gds_backend.force_no_compat // .oci2gds_profile.force_no_compat // false) | tostring' 2>/dev/null || true)"
  local oci2gds_cufile_env_path
  oci2gds_cufile_env_path="$(printf '%s' "${health_response}" | jq -r '.oci2gds_backend.cufile_env_path // .oci2gds_profile.cufile_env_path // ""' 2>/dev/null || true)"
  local oci2gds_cufile_init_ok
  oci2gds_cufile_init_ok="$(printf '%s' "${health_response}" | jq -r '(.oci2gds_profile.cufile_init_ok // false) | tostring' 2>/dev/null || true)"
  local oci2gds_probe_duration_ms
  oci2gds_probe_duration_ms="$(printf '%s' "${health_response}" | jq -r '.oci2gds_profile.duration_ms // 0' 2>/dev/null || true)"
  local oci2gds_probe_throughput_mib_s
  oci2gds_probe_throughput_mib_s="$(printf '%s' "${health_response}" | jq -r '.oci2gds_profile.throughput_mib_s // 0' 2>/dev/null || true)"
  local oci2gds_ipc_status
  oci2gds_ipc_status="$(printf '%s' "${health_response}" | jq -r '.oci2gds_ipc.status // empty' 2>/dev/null || true)"
  local oci2gds_ipc_backend
  oci2gds_ipc_backend="$(printf '%s' "${health_response}" | jq -r '.oci2gds_ipc.import_backend // empty' 2>/dev/null || true)"
  local response
  response="$(curl -fsS -X POST "http://127.0.0.1:${local_port}/chat" \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg prompt "${prompt}" '{prompt:$prompt}')" || true)"
  local answer
  answer="$(printf '%s' "${response}" | jq -r '.answer // empty' 2>/dev/null || true)"

  kube -n "${QWEN_HELLO_NAMESPACE}" \
    logs "pod/${pod_name}" -c pytorch-api > "${log_file}" 2>/dev/null || true
  printf '\nQWEN_K3S_HELLO_HEALTH_RESPONSE %s\n' "${health_response}" >> "${log_file}"
  printf '\nQWEN_K3S_HELLO_CHAT_RESPONSE %s\n' "${response}" >> "${log_file}"

  if [[ -f "${pf_pid_file}" ]]; then
    kill "$(cat "${pf_pid_file}")" 2>/dev/null || true
    rm -f "${pf_pid_file}"
  fi

  if [[ -z "${answer}" ]]; then
    warn "qwen hello API returned empty answer; response=${response}"
    return 1
  fi
  if [[ "${health_status}" != "ok" ]]; then
    warn "qwen hello health status is not ok: ${health_status}"
    return 1
  fi
  if [[ -z "${oci2gds_profile_status}" || "${oci2gds_profile_status}" != "ok" ]]; then
    warn "qwen hello oci2gds profile probe failed: status=${oci2gds_profile_status} backend=${oci2gds_profile_backend} mode_counts=${oci2gds_mode_counts}"
    return 1
  fi
  if [[ "${qwen_hello_require_strict_profile_probe}" == "true" ]]; then
    if [[ "${oci2gds_profile_backend}" != "native-cufile" ]]; then
      warn "strict profile probe backend check failed: profile_backend=${oci2gds_profile_backend} runtime_backend=${oci2gds_backend}"
      return 1
    fi
    if [[ "${oci2gds_cufile_init_ok}" != "true" ]]; then
      warn "strict profile probe cufile init check failed: cufile_init_ok=${oci2gds_cufile_init_ok}"
      return 1
    fi
  fi
  if [[ "${qwen_hello_require_direct_gds}" == "true" ]]; then
    if [[ -z "${oci2gds_direct_count}" || "${oci2gds_direct_count}" == "0" ]]; then
      warn "qwen hello direct GDS requirement failed: direct_count=${oci2gds_direct_count} mode_counts=${oci2gds_mode_counts}"
      return 1
    fi
  fi
  if [[ "${qwen_hello_require_no_compat_evidence}" == "true" && "${qwen_hello_oci2gds_force_no_compat}" == "true" ]]; then
    if [[ "${oci2gds_force_no_compat}" != "true" ]]; then
      warn "force-no-compat evidence missing from health payload: force_no_compat=${oci2gds_force_no_compat}"
      return 1
    fi
    if [[ -z "${oci2gds_cufile_env_path}" ]]; then
      warn "force-no-compat evidence missing: cufile_env_path is empty"
      return 1
    fi
    if [[ "${oci2gds_compat_count}" != "0" ]]; then
      warn "compat mode reads observed despite OCI2GDS_FORCE_NO_COMPAT=true: compat_count=${oci2gds_compat_count}"
      return 1
    fi
  fi
  if [[ "${qwen_hello_require_daemon_ipc_probe}" == "true" && "${oci2gds_ipc_status}" != "ok" ]]; then
    warn "qwen hello daemon ipc probe not ok: status=${oci2gds_ipc_status} backend=${oci2gds_ipc_backend}"
    return 1
  fi
  assert_profile_probe_perf_gates "${oci2gds_probe_throughput_mib_s}" "${oci2gds_probe_duration_ms}"
  log "qwen profile probe perf: duration_ms=${oci2gds_probe_duration_ms} throughput_mib_s=${oci2gds_probe_throughput_mib_s}"
  printf 'QWEN_K3S_HELLO_SUCCESS prompt=%s answer=%s oci2gds_profile_status=%s oci2gds_backend=%s oci2gds_mode_counts=%s oci2gds_ipc_status=%s oci2gds_ipc_backend=%s\n' \
    "${prompt}" "${answer}" "${oci2gds_profile_status}" "${oci2gds_backend}" "${oci2gds_mode_counts}" "${oci2gds_ipc_status}" "${oci2gds_ipc_backend}" >> "${log_file}"
  printf 'QWEN_K3S_HELLO_PROFILE_PROBE backend=%s direct=%s compat=%s cufile_init_ok=%s force_no_compat=%s cufile_env_path=%s duration_ms=%s throughput_mib_s=%s\n' \
    "${oci2gds_profile_backend}" "${oci2gds_direct_count}" "${oci2gds_compat_count}" "${oci2gds_cufile_init_ok}" "${oci2gds_force_no_compat}" "${oci2gds_cufile_env_path}" "${oci2gds_probe_duration_ms}" "${oci2gds_probe_throughput_mib_s}" >> "${log_file}"
  return 0
}

cleanup_qwen_hello_example() {
  local local_port="${QWEN_HELLO_LOCAL_PORT:-18080}"

  # Defensive: stop any stale qwen-hello service port-forward processes first.
  while IFS= read -r pf_pid; do
    [[ -n "${pf_pid}" ]] || continue
    kill "${pf_pid}" >/dev/null 2>&1 || true
  done < <(pgrep -f "[k]3s kubectl -n ${QWEN_HELLO_NAMESPACE} port-forward svc/qwen-hello ${local_port}:8000" || true)

  kube delete namespace "${QWEN_HELLO_NAMESPACE}" --ignore-not-found --wait=false >/dev/null || true
  if kube get namespace "${QWEN_HELLO_NAMESPACE}" >/dev/null 2>&1; then
    if ! kube wait --for=delete "namespace/${QWEN_HELLO_NAMESPACE}" --timeout=120s >/dev/null 2>&1; then
      warn "qwen-hello namespace deletion timed out; forcing cleanup"
      kube -n "${QWEN_HELLO_NAMESPACE}" delete pod --all --force --grace-period=0 >/dev/null 2>&1 || true
      maybe_sudo k3s kubectl get namespace "${QWEN_HELLO_NAMESPACE}" -o json 2>/dev/null \
        | jq '.spec.finalizers=[]' \
        | maybe_sudo k3s kubectl replace --raw "/api/v1/namespaces/${QWEN_HELLO_NAMESPACE}/finalize" -f - >/dev/null 2>&1 || true
    fi
  fi
}

collect_debug() {
  warn "collecting debug artifacts"
  kube get nodes -o wide || true
  kube get pods -A || true
  kube -n gpu-operator get pods -o wide || true
  kube -n "${OCI2GDSD_DAEMON_NAMESPACE}" get pods -o wide || true
  kube -n "${E2E_NAMESPACE}" get pods -o wide || true
  kube -n "${E2E_NAMESPACE}" get jobs || true
  kube -n "${QWEN_HELLO_NAMESPACE}" get pods -o wide || true
}
