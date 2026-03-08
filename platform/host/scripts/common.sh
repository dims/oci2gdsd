#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
# shellcheck source=../../lib/common.sh
source "${LIB_DIR}/common.sh"

enforce_strict_gds_policy() {
  enforce_boolean_true_policy \
    "ALLOW_RELAXED_GDS" \
    "strict GDS policy" \
    REQUIRE_DIRECT_GDS \
    OCI2GDS_STRICT \
    OCI2GDS_FORCE_NO_COMPAT \
    REQUIRE_STRICT_PROBE_EVIDENCE
}

resolve_nvfs_stats_mode() {
  if [[ -n "${REQUIRE_NVFS_STATS_DELTA_SET}" ]]; then
    if is_true "${REQUIRE_NVFS_STATS_DELTA}"; then
      NVFS_STATS_MODE="required"
    else
      NVFS_STATS_MODE="off"
    fi
  else
    NVFS_STATS_MODE="$(printf '%s' "${REQUIRE_NVFS_STATS_DELTA_MODE}" | tr '[:upper:]' '[:lower:]')"
  fi
  case "${NVFS_STATS_MODE}" in
    auto|required|off) ;;
    *) die "invalid REQUIRE_NVFS_STATS_DELTA_MODE=${NVFS_STATS_MODE} (expected auto|required|off)" ;;
  esac
}
