#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

log "cleaning nvkind e2e resources"
stop_registry_port_forward || true

if kind get clusters 2>/dev/null | grep -Fxq "${CLUSTER_NAME}"; then
  kubectl --context "${KUBECTL_CONTEXT}" delete namespace "${E2E_NAMESPACE}" --ignore-not-found >/dev/null || true
  kubectl --context "${KUBECTL_CONTEXT}" delete namespace "${REGISTRY_NAMESPACE}" --ignore-not-found >/dev/null || true
  if command -v nvkind >/dev/null 2>&1; then
    nvkind cluster delete --name="${CLUSTER_NAME}" || true
  fi
  kind delete cluster --name "${CLUSTER_NAME}" || true
fi

rm -rf "${WORK_DIR}/rendered" "${WORK_DIR}/results" "${WORK_DIR}/packager" "${LOG_DIR}" "${PF_PID_FILE}" || true
log "cleanup complete"
