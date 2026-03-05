#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/../../../lib" && pwd)"
# shellcheck source=../../../lib/common.sh
source "${LIB_DIR}/common.sh"

binary_is_usable() {
  local candidate="$1"
  [[ -x "${candidate}" ]] || return 1
  "${candidate}" --help >/dev/null 2>&1
}

resolve_oci2gdsd_bin() {
  if [[ -n "${OCI2GDSD_BIN:-}" ]]; then
    binary_is_usable "${OCI2GDSD_BIN}" || die "OCI2GDSD_BIN is not usable on this host: ${OCI2GDSD_BIN}"
    return
  fi
  if [[ -n "${WORK_DIR:-}" ]] && binary_is_usable "${WORK_DIR}/oci2gdsd"; then
    OCI2GDSD_BIN="${WORK_DIR}/oci2gdsd"
    return
  fi
  if [[ -n "${REPO_ROOT:-}" ]] && binary_is_usable "${REPO_ROOT}/oci2gdsd"; then
    OCI2GDSD_BIN="${REPO_ROOT}/oci2gdsd"
    return
  fi
  if [[ -n "${HARNESS_DIR:-}" ]] && binary_is_usable "${HARNESS_DIR}/../../../oci2gdsd"; then
    OCI2GDSD_BIN="${HARNESS_DIR}/../../../oci2gdsd"
    return
  fi
  if command -v oci2gdsd >/dev/null 2>&1; then
    local installed_bin
    installed_bin="$(command -v oci2gdsd)"
    if binary_is_usable "${installed_bin}"; then
      OCI2GDSD_BIN="${installed_bin}"
      return
    fi
  fi

  ensure_cmd go
  [[ -n "${WORK_DIR:-}" ]] || die "WORK_DIR is required to build local oci2gdsd binary"
  local build_root="${REPO_ROOT:-${HARNESS_DIR}/../../..}"
  OCI2GDSD_BIN="${WORK_DIR}/oci2gdsd"
  log "building oci2gdsd binary for local e2e"
  (cd "${build_root}" && go build -o "${OCI2GDSD_BIN}" ./cmd/oci2gdsd)
}

run_cli() {
  [[ -n "${CONFIG_PATH:-}" ]] || die "CONFIG_PATH is required"
  "${OCI2GDSD_BIN}" --registry-config "${CONFIG_PATH}" "$@"
}
