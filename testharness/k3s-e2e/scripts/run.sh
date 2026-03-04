#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

trap 'stop_registry_port_forward' EXIT

log "starting k3s e2e harness"
bootstrap_tools
configure_nvidia_runtime
ensure_k3s_cluster_ready
install_gpu_operator

CLEAN_STALE_WORKLOADS_BEFORE_RUN="${CLEAN_STALE_WORKLOADS_BEFORE_RUN:-true}"
if is_true "${CLEAN_STALE_WORKLOADS_BEFORE_RUN}"; then
  log "cleaning stale workload namespaces (${E2E_NAMESPACE}, ${QWEN_HELLO_NAMESPACE}) before run"
  kube delete namespace "${E2E_NAMESPACE}" --ignore-not-found >/dev/null || true
  kube delete namespace "${QWEN_HELLO_NAMESPACE}" --ignore-not-found >/dev/null || true
  kube wait --for=delete namespace/"${E2E_NAMESPACE}" --timeout=180s >/dev/null 2>&1 || true
  kube wait --for=delete namespace/"${QWEN_HELLO_NAMESPACE}" --timeout=180s >/dev/null 2>&1 || true
fi

verify_gpu_pod
validate_local_gds_loader

build_and_load_oci2gdsd_image
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

render_template "${HARNESS_DIR}/manifests/namespace.yaml.tpl" "${WORK_DIR}/rendered/namespace.yaml" \
  "E2E_NAMESPACE=${E2E_NAMESPACE}"
render_template "${HARNESS_DIR}/manifests/oci2gdsd-configmap.yaml.tpl" "${WORK_DIR}/rendered/oci2gdsd-configmap.yaml" \
  "E2E_NAMESPACE=${E2E_NAMESPACE}" \
  "OCI2GDSD_ROOT_PATH=${OCI2GDSD_ROOT_PATH}"
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

kube apply -f "${WORK_DIR}/rendered/namespace.yaml"
kube apply -f "${WORK_DIR}/rendered/oci2gdsd-configmap.yaml"
SMOKE_SCRIPT="${HARNESS_DIR}/scripts/pytorch_smoke.py"
[[ -f "${SMOKE_SCRIPT}" ]] || die "missing pytorch smoke script: ${SMOKE_SCRIPT}"
apply_configmap_from_files "${E2E_NAMESPACE}" "pytorch-smoke-script" \
  --from-file=pytorch_smoke.py="${SMOKE_SCRIPT}"
kube -n "${E2E_NAMESPACE}" delete job/oci2gdsd-pytorch-smoke --ignore-not-found >/dev/null
kube apply -f "${WORK_DIR}/rendered/workload-job.yaml"

log "waiting for workload job completion"
if ! kube -n "${E2E_NAMESPACE}" wait job/oci2gdsd-pytorch-smoke --for=condition=Complete --timeout=1800s; then
  collect_debug
  kube -n "${E2E_NAMESPACE}" logs job/oci2gdsd-pytorch-smoke -c preload-model || true
  kube -n "${E2E_NAMESPACE}" logs job/oci2gdsd-pytorch-smoke -c pytorch-smoke || true
  die "workload job failed"
fi

kube -n "${E2E_NAMESPACE}" logs job/oci2gdsd-pytorch-smoke -c preload-model > "${WORK_DIR}/results/preload.log"
kube -n "${E2E_NAMESPACE}" logs job/oci2gdsd-pytorch-smoke -c pytorch-smoke > "${WORK_DIR}/results/pytorch.log"

if ! grep -q '"status": "READY"' "${WORK_DIR}/results/preload.log"; then
  die "preload init container did not report READY"
fi
if ! grep -q 'PYTORCH_SMOKE_SUCCESS' "${WORK_DIR}/results/pytorch.log"; then
  die "pytorch smoke container did not report success marker"
fi

if [[ "${VALIDATE_QWEN_HELLO}" == "true" ]]; then
  log "validating examples/qwen-hello deployment"
  if ! validate_qwen_hello_example; then
    collect_debug
    kube -n "${QWEN_HELLO_NAMESPACE}" logs deploy/qwen-hello -c preload-model || true
    kube -n "${QWEN_HELLO_NAMESPACE}" logs deploy/qwen-hello -c oci2gdsd-daemon || true
    kube -n "${QWEN_HELLO_NAMESPACE}" logs deploy/qwen-hello -c pytorch-api || true
    die "qwen hello example validation failed"
  fi
  cleanup_qwen_hello_example
fi

POD_NAME="$(kube -n "${E2E_NAMESPACE}" get pod -l job-name=oci2gdsd-pytorch-smoke -o jsonpath='{.items[0].metadata.name}')"
NODE_NAME="$(kube -n "${E2E_NAMESPACE}" get pod "${POD_NAME}" -o jsonpath='{.spec.nodeName}')"
if [[ -z "${NODE_NAME}" ]]; then
  die "failed to resolve node name for workload pod"
fi
log "workload pod ran on node: ${NODE_NAME}"

render_template "${HARNESS_DIR}/manifests/release-job.yaml.tpl" "${WORK_DIR}/rendered/release-job.yaml" \
  "E2E_NAMESPACE=${E2E_NAMESPACE}" \
  "OCI2GDSD_IMAGE=${OCI2GDSD_IMAGE}" \
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
log "  ${WORK_DIR}/results/pytorch.log"
if [[ -f "${WORK_DIR}/results/qwen-hello.log" ]]; then
  log "  ${WORK_DIR}/results/qwen-hello.log"
fi
log "  ${WORK_DIR}/results/release-gc.log"
