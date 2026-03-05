#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

log "cleaning k3s e2e resources"
stop_registry_port_forward || true

kube delete namespace "${E2E_NAMESPACE}" --ignore-not-found >/dev/null || true
kube delete namespace "${QWEN_HELLO_NAMESPACE}" --ignore-not-found >/dev/null || true
kube delete namespace "${REGISTRY_NAMESPACE}" --ignore-not-found >/dev/null || true

rm -rf "${WORK_DIR}/rendered" "${WORK_DIR}/results" "${WORK_DIR}/packager" "${LOG_DIR}" "${PF_PID_FILE}" || true
log "cleanup complete"
