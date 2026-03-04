#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

AUTO_SEED_MODEL_IDENTITY="${AUTO_SEED_MODEL_IDENTITY:-true}"
AUTO_BUILD_OCI2GDSD_IMAGE="${AUTO_BUILD_OCI2GDSD_IMAGE:-true}"

seed_model_identity_if_needed() {
  if [[ -n "${MODEL_REF_OVERRIDE}" && -n "${MODEL_DIGEST_OVERRIDE}" ]]; then
    return 0
  fi
  if [[ -f "${WORK_DIR}/packager/output/manifest-descriptor.json" ]]; then
    return 0
  fi
  if ! is_true "${AUTO_SEED_MODEL_IDENTITY}"; then
    return 0
  fi
  log "model identity is missing; auto-seeding packager output and in-cluster registry"
  build_packager_image
  apply_registry
  start_registry_port_forward
  package_model_to_registry
}

resolve_model_identity() {
  if [[ -n "${MODEL_REF_OVERRIDE}" && -n "${MODEL_DIGEST_OVERRIDE}" ]]; then
    MODEL_REF="${MODEL_REF_OVERRIDE}"
    MODEL_DIGEST="${MODEL_DIGEST_OVERRIDE}"
  elif [[ -f "${WORK_DIR}/packager/output/manifest-descriptor.json" ]]; then
    MODEL_DIGEST="$(jq -r '.digest // empty' "${WORK_DIR}/packager/output/manifest-descriptor.json")"
    [[ -n "${MODEL_DIGEST}" ]] || die "packager manifest exists but digest is empty: ${WORK_DIR}/packager/output/manifest-descriptor.json"
    MODEL_REF="${REGISTRY_SERVICE}.${REGISTRY_NAMESPACE}.svc.cluster.local:5000/${MODEL_REPO}@${MODEL_DIGEST}"
  else
    die "missing model identity; set MODEL_REF_OVERRIDE and MODEL_DIGEST_OVERRIDE, or run make nvkind-e2e once to generate ${WORK_DIR}/packager/output/manifest-descriptor.json.
Example:
  MODEL_DIGEST_OVERRIDE=sha256:<digest> \\
  MODEL_REF_OVERRIDE=${REGISTRY_SERVICE}.${REGISTRY_NAMESPACE}.svc.cluster.local:5000/${MODEL_REPO}@sha256:<digest> \\
  make nvkind-e2e-qwen-quick"
  fi
  MODEL_ROOT_PATH="${OCI2GDSD_ROOT_PATH}/models/${MODEL_ID}/${MODEL_DIGEST//:/-}"
  export MODEL_REF MODEL_DIGEST MODEL_ROOT_PATH
}

log "starting qwen-hello quick iterate run"
trap 'stop_registry_port_forward' EXIT
if [[ "${CLUSTER_MODE}" == "k3s" ]]; then
  ensure_cmd k3s
else
  ensure_cmd kubectl
fi
ensure_cmd jq
ensure_cmd curl
ensure_cmd gsed

if [[ "${CLUSTER_MODE}" == "k3s" ]]; then
  ensure_k3s_nvidia_runtime_prereqs
fi

if ! kube get nodes >/dev/null 2>&1; then
  die "cluster ${CLUSTER_MODE} is not reachable ($(cluster_hint)); run setup first"
fi

ensure_gpu_capacity
if is_true "${AUTO_BUILD_OCI2GDSD_IMAGE}"; then
  build_and_load_oci2gdsd_image
fi
seed_model_identity_if_needed
resolve_model_identity
log "model_ref=${MODEL_REF}"
log "model_digest=${MODEL_DIGEST}"
log "pytorch_runtime_image=${PYTORCH_RUNTIME_IMAGE}"
log "cluster_mode=${CLUSTER_MODE} ($(cluster_hint))"
log "qwen_hello_profile=${QWEN_HELLO_PROFILE}"
log "oci2gdsd_root_path=${OCI2GDSD_ROOT_PATH}"
log "oci2gds_strict=${OCI2GDS_STRICT} oci2gds_probe_strict=${OCI2GDS_PROBE_STRICT}"
log "oci2gds_force_no_compat=${OCI2GDS_FORCE_NO_COMPAT}"
log "require_direct_gds=${REQUIRE_DIRECT_GDS}"

if [[ "${REQUIRE_DIRECT_GDS}" == "true" ]]; then
  if ! check_direct_gds_platform_support; then
    die "direct GDS requested but platform preflight failed"
  fi
fi

if ! validate_qwen_hello_example; then
  collect_debug
  kube -n "${QWEN_HELLO_NAMESPACE}" logs deploy/qwen-hello -c preload-model || true
  kube -n "${QWEN_HELLO_NAMESPACE}" logs deploy/qwen-hello -c pytorch-api || true
  die "qwen-hello quick iterate validation failed"
fi

log "qwen-hello quick iterate succeeded"
log "artifact: ${WORK_DIR}/results/qwen-hello.log"
