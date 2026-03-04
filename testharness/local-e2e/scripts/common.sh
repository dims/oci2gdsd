#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
# shellcheck source=../../lib/common.sh
source "${LIB_DIR}/common.sh"

resolve_oci2gdsd_bin() {
  if [[ -n "${OCI2GDSD_BIN:-}" ]]; then
    [[ -x "${OCI2GDSD_BIN}" ]] || die "OCI2GDSD_BIN is not executable: ${OCI2GDSD_BIN}"
    return
  fi
  if [[ -n "${WORK_DIR:-}" && -x "${WORK_DIR}/oci2gdsd" ]]; then
    OCI2GDSD_BIN="${WORK_DIR}/oci2gdsd"
    return
  fi
  if [[ -n "${REPO_ROOT:-}" && -x "${REPO_ROOT}/oci2gdsd" ]]; then
    OCI2GDSD_BIN="${REPO_ROOT}/oci2gdsd"
    return
  fi
  if [[ -n "${HARNESS_DIR:-}" && -x "${HARNESS_DIR}/../../oci2gdsd" ]]; then
    OCI2GDSD_BIN="${HARNESS_DIR}/../../oci2gdsd"
    return
  fi
  if command -v oci2gdsd >/dev/null 2>&1; then
    OCI2GDSD_BIN="$(command -v oci2gdsd)"
    return
  fi

  ensure_cmd go
  [[ -n "${WORK_DIR:-}" ]] || die "WORK_DIR is required to build local oci2gdsd binary"
  local build_root="${REPO_ROOT:-${HARNESS_DIR}/../..}"
  OCI2GDSD_BIN="${WORK_DIR}/oci2gdsd"
  log "building oci2gdsd binary for local e2e"
  (cd "${build_root}" && go build -o "${OCI2GDSD_BIN}" ./cmd/oci2gdsd)
}

run_cli() {
  [[ -n "${CONFIG_PATH:-}" ]] || die "CONFIG_PATH is required"
  "${OCI2GDSD_BIN}" --registry-config "${CONFIG_PATH}" "$@"
}
