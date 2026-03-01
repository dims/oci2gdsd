#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

trap 'stop_registry_port_forward' EXIT

log "starting nvkind e2e harness"
bootstrap_tools
configure_nvidia_runtime
create_nvkind_cluster
install_gpu_operator
verify_gpu_pod

build_and_load_oci2gdsd_image
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
render_template "${HARNESS_DIR}/manifests/pytorch-script-configmap.yaml.tpl" "${WORK_DIR}/rendered/pytorch-script-configmap.yaml" \
  "E2E_NAMESPACE=${E2E_NAMESPACE}"
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

kubectl --context "${KUBECTL_CONTEXT}" apply -f "${WORK_DIR}/rendered/namespace.yaml"
kubectl --context "${KUBECTL_CONTEXT}" apply -f "${WORK_DIR}/rendered/oci2gdsd-configmap.yaml"
kubectl --context "${KUBECTL_CONTEXT}" apply -f "${WORK_DIR}/rendered/pytorch-script-configmap.yaml"
kubectl --context "${KUBECTL_CONTEXT}" -n "${E2E_NAMESPACE}" delete job/oci2gdsd-pytorch-smoke --ignore-not-found >/dev/null
kubectl --context "${KUBECTL_CONTEXT}" apply -f "${WORK_DIR}/rendered/workload-job.yaml"

log "waiting for workload job completion"
if ! kubectl --context "${KUBECTL_CONTEXT}" -n "${E2E_NAMESPACE}" wait job/oci2gdsd-pytorch-smoke --for=condition=Complete --timeout=1800s; then
  collect_debug
  kubectl --context "${KUBECTL_CONTEXT}" -n "${E2E_NAMESPACE}" logs job/oci2gdsd-pytorch-smoke -c preload-model || true
  kubectl --context "${KUBECTL_CONTEXT}" -n "${E2E_NAMESPACE}" logs job/oci2gdsd-pytorch-smoke -c pytorch-smoke || true
  die "workload job failed"
fi

kubectl --context "${KUBECTL_CONTEXT}" -n "${E2E_NAMESPACE}" logs job/oci2gdsd-pytorch-smoke -c preload-model > "${WORK_DIR}/results/preload.log"
kubectl --context "${KUBECTL_CONTEXT}" -n "${E2E_NAMESPACE}" logs job/oci2gdsd-pytorch-smoke -c pytorch-smoke > "${WORK_DIR}/results/pytorch.log"

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
    kubectl --context "${KUBECTL_CONTEXT}" -n "${QWEN_HELLO_NAMESPACE}" logs deploy/qwen-hello -c preload-model || true
    kubectl --context "${KUBECTL_CONTEXT}" -n "${QWEN_HELLO_NAMESPACE}" logs deploy/qwen-hello -c hello || true
    die "qwen hello example validation failed"
  fi
  cleanup_qwen_hello_example
fi

POD_NAME="$(kubectl --context "${KUBECTL_CONTEXT}" -n "${E2E_NAMESPACE}" get pod -l job-name=oci2gdsd-pytorch-smoke -o jsonpath='{.items[0].metadata.name}')"
NODE_NAME="$(kubectl --context "${KUBECTL_CONTEXT}" -n "${E2E_NAMESPACE}" get pod "${POD_NAME}" -o jsonpath='{.spec.nodeName}')"
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

kubectl --context "${KUBECTL_CONTEXT}" -n "${E2E_NAMESPACE}" delete job/oci2gdsd-release-gc --ignore-not-found >/dev/null
kubectl --context "${KUBECTL_CONTEXT}" apply -f "${WORK_DIR}/rendered/release-job.yaml"
log "waiting for release job completion"
if ! kubectl --context "${KUBECTL_CONTEXT}" -n "${E2E_NAMESPACE}" wait job/oci2gdsd-release-gc --for=condition=Complete --timeout=600s; then
  collect_debug
  kubectl --context "${KUBECTL_CONTEXT}" -n "${E2E_NAMESPACE}" logs job/oci2gdsd-release-gc || true
  die "release/gc job failed"
fi

kubectl --context "${KUBECTL_CONTEXT}" -n "${E2E_NAMESPACE}" logs job/oci2gdsd-release-gc > "${WORK_DIR}/results/release-gc.log"
if ! grep -q '"status": "RELEASED"' "${WORK_DIR}/results/release-gc.log"; then
  die "release/gc lifecycle did not end in RELEASED status"
fi

log "nvkind e2e harness completed successfully"
log "artifacts:"
log "  ${WORK_DIR}/results/preload.log"
log "  ${WORK_DIR}/results/pytorch.log"
if [[ -f "${WORK_DIR}/results/qwen-hello.log" ]]; then
  log "  ${WORK_DIR}/results/qwen-hello.log"
fi
log "  ${WORK_DIR}/results/release-gc.log"
