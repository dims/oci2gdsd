#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

resolve_model_identity() {
  if [[ -n "${MODEL_REF_OVERRIDE}" && -n "${MODEL_DIGEST_OVERRIDE}" ]]; then
    MODEL_REF="${MODEL_REF_OVERRIDE}"
    MODEL_DIGEST="${MODEL_DIGEST_OVERRIDE}"
  elif [[ -f "${WORK_DIR}/packager/output/manifest-descriptor.json" ]]; then
    MODEL_DIGEST="$(jq -r '.digest // empty' "${WORK_DIR}/packager/output/manifest-descriptor.json")"
    [[ -n "${MODEL_DIGEST}" ]] || die "packager manifest exists but digest is empty: ${WORK_DIR}/packager/output/manifest-descriptor.json"
    MODEL_REF="${REGISTRY_SERVICE}.${REGISTRY_NAMESPACE}.svc.cluster.local:5000/${MODEL_REPO}@${MODEL_DIGEST}"
  else
    die "missing model identity; set MODEL_REF_OVERRIDE and MODEL_DIGEST_OVERRIDE, or run make nvkind-e2e once to generate ${WORK_DIR}/packager/output/manifest-descriptor.json"
  fi
  MODEL_ROOT_PATH="${OCI2GDSD_ROOT_PATH}/models/${MODEL_ID}/${MODEL_DIGEST//:/-}"
  export MODEL_REF MODEL_DIGEST MODEL_ROOT_PATH
}

log "starting qwen-hello quick iterate run"
ensure_cmd kubectl
ensure_cmd jq
ensure_cmd curl
ensure_cmd gsed

if ! kubectl --context "${KUBECTL_CONTEXT}" get nodes >/dev/null 2>&1; then
  die "cluster context ${KUBECTL_CONTEXT} is not reachable; run make nvkind-e2e first"
fi

resolve_model_identity
log "model_ref=${MODEL_REF}"
log "model_digest=${MODEL_DIGEST}"
log "pytorch_runtime_image=${PYTORCH_RUNTIME_IMAGE}"

if ! validate_qwen_hello_example; then
  collect_debug
  kubectl --context "${KUBECTL_CONTEXT}" -n "${QWEN_HELLO_NAMESPACE}" logs deploy/qwen-hello -c preload-model || true
  kubectl --context "${KUBECTL_CONTEXT}" -n "${QWEN_HELLO_NAMESPACE}" logs deploy/qwen-hello -c pytorch-api || true
  die "qwen-hello quick iterate validation failed"
fi

log "qwen-hello quick iterate succeeded"
log "artifact: ${WORK_DIR}/results/qwen-hello.log"
