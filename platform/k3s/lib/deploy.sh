#!/usr/bin/env bash
# shellcheck shell=bash

render_template() {
  local src="$1"
  local dst="$2"
  shift 2
  cp "${src}" "${dst}"
  local kv
  for kv in "$@"; do
    local key="${kv%%=*}"
    local value="${kv#*=}"
    gsed -i "s|__${key}__|${value}|g" "${dst}"
  done
}

ensure_namespace() {
  local ns="$1"
  if kube get namespace "${ns}" >/dev/null 2>&1; then
    return
  fi
  kube create namespace "${ns}" >/dev/null
}

apply_configmap_from_files() {
  local ns="$1"
  local name="$2"
  shift 2
  kube create configmap "${name}" -n "${ns}" "$@" --dry-run=client -o yaml | kube apply -f -
}

apply_daemonset_stack() {
  mkdir -p "${RENDERED_DIR}"
  local rendered="${RENDERED_DIR}/oci2gdsd-daemonset.yaml"
  render_template "${OCI2GDSD_DAEMON_TEMPLATE}" "${rendered}" \
    "OCI2GDSD_DAEMON_NAMESPACE=${OCI2GDSD_DAEMON_NAMESPACE}" \
    "OCI2GDSD_ROOT_PATH=${OCI2GDSD_ROOT_PATH}" \
    "OCI2GDSD_SOCKET_HOST_PATH=${OCI2GDSD_SOCKET_HOST_PATH}" \
    "OCI2GDSD_IMAGE=${OCI2GDSD_IMAGE}"
  kube apply -f "${rendered}"
  kube -n "${OCI2GDSD_DAEMON_NAMESPACE}" rollout status daemonset/oci2gdsd-daemon --timeout=900s
}

capture_daemonset_logs() {
  local out="${1:-${RESULTS_DIR}/daemonset.log}"
  mkdir -p "$(dirname "${out}")"
  local pod_name
  pod_name="$(kube -n "${OCI2GDSD_DAEMON_NAMESPACE}" get pod \
    -l app.kubernetes.io/name=oci2gdsd-daemon \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${pod_name}" ]]; then
    warn "failed to resolve oci2gdsd daemon pod name in namespace ${OCI2GDSD_DAEMON_NAMESPACE}"
    return 1
  fi
  kube -n "${OCI2GDSD_DAEMON_NAMESPACE}" logs "pod/${pod_name}" > "${out}" 2>/dev/null || true
}

apply_registry() {
  mkdir -p "${RENDERED_DIR}"
  local rendered="${RENDERED_DIR}/registry.yaml"
  render_template "${HARNESS_DIR}/manifests/registry.yaml.tpl" "${rendered}" \
    "REGISTRY_NAMESPACE=${REGISTRY_NAMESPACE}" \
    "REGISTRY_SERVICE=${REGISTRY_SERVICE}"
  kube apply -f "${rendered}"
  kube -n "${REGISTRY_NAMESPACE}" rollout status deploy/"${REGISTRY_SERVICE}" --timeout=180s
}

start_registry_port_forward() {
  if [[ -f "${PF_PID_FILE}" ]]; then
    local stale_pid
    stale_pid="$(cat "${PF_PID_FILE}" || true)"
    if [[ -n "${stale_pid}" ]] && kill -0 "${stale_pid}" 2>/dev/null; then
      kill "${stale_pid}" || true
    fi
    rm -f "${PF_PID_FILE}"
  fi

  kube -n "${REGISTRY_NAMESPACE}" \
    port-forward svc/"${REGISTRY_SERVICE}" "${LOCAL_REGISTRY_PORT}:5000" \
    > "${LOG_DIR}/registry-port-forward.log" 2>&1 &
  echo $! > "${PF_PID_FILE}"

  local pid
  pid="$(cat "${PF_PID_FILE}")"
  local attempts="${REGISTRY_PORT_FORWARD_RETRIES:-60}"
  local delay="${REGISTRY_PORT_FORWARD_RETRY_DELAY_SEC:-1}"
  local i
  for ((i=1; i<=attempts; i++)); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      warn "registry port-forward exited early (pid=${pid})"
      if [[ -f "${LOG_DIR}/registry-port-forward.log" ]]; then
        warn "registry port-forward log:"
        cat "${LOG_DIR}/registry-port-forward.log" >&2 || true
      fi
      die "registry port-forward failed to stay running"
    fi
    if curl --max-time 2 -fsS "http://127.0.0.1:${LOCAL_REGISTRY_PORT}/v2/_catalog" >/dev/null 2>&1; then
      log "registry port-forward is ready on 127.0.0.1:${LOCAL_REGISTRY_PORT}"
      return 0
    fi
    sleep "${delay}"
  done

  warn "registry endpoint did not become ready after ${attempts} attempts"
  if [[ -f "${LOG_DIR}/registry-port-forward.log" ]]; then
    warn "registry port-forward log:"
    cat "${LOG_DIR}/registry-port-forward.log" >&2 || true
  fi
  die "registry readiness check failed at 127.0.0.1:${LOCAL_REGISTRY_PORT}"
}

stop_registry_port_forward() {
  if [[ -f "${PF_PID_FILE}" ]]; then
    local pid
    pid="$(cat "${PF_PID_FILE}" || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" || true
    fi
    rm -f "${PF_PID_FILE}"
  fi
}

package_model_to_registry() {
  if [[ -n "${MODEL_REF_OVERRIDE}" && -n "${MODEL_DIGEST_OVERRIDE}" ]]; then
    MODEL_DIGEST="${MODEL_DIGEST_OVERRIDE}"
    MODEL_REF="${MODEL_REF_OVERRIDE}"
    export MODEL_DIGEST MODEL_REF
    log "using pre-existing model ref override: ${MODEL_REF}"
    return
  fi
  local packager_work="${WORK_DIR}/packager"
  mkdir -p "${packager_work}"
  mkdir -p "${packager_work}/.cache/huggingface"
  log "packaging model ${HF_REPO}@${HF_REVISION} to local registry"
  docker run --rm --network host \
    -u "$(id -u):$(id -g)" \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    -e HOME="/work" \
    -e HF_HOME="/work/.cache/huggingface" \
    -e XDG_CACHE_HOME="/work/.cache" \
    -v "${packager_work}:/work" \
    "${PACKAGER_IMAGE}" \
    --hf-repo "${HF_REPO}" \
    --hf-revision "${HF_REVISION}" \
    --model-id "${MODEL_ID}" \
    --oci-ref "localhost:${LOCAL_REGISTRY_PORT}/${MODEL_REPO}:${MODEL_TAG}" \
    --plain-http
  MODEL_DIGEST="$(jq -r '.digest' "${packager_work}/output/manifest-descriptor.json")"
  if [[ -z "${MODEL_DIGEST}" || "${MODEL_DIGEST}" == "null" ]]; then
    die "failed to parse model digest from manifest-descriptor.json"
  fi
  MODEL_REF="${REGISTRY_SERVICE}.${REGISTRY_NAMESPACE}.svc.cluster.local:5000/${MODEL_REPO}@${MODEL_DIGEST}"
  export MODEL_DIGEST MODEL_REF
  log "model digest: ${MODEL_DIGEST}"
  log "model ref for pods: ${MODEL_REF}"
}
