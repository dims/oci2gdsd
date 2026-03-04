#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${HARNESS_DIR}/../.." && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"
WORK_DIR="${HARNESS_DIR}/work"
RESULTS_DIR="${WORK_DIR}/results"
CONFIG_PATH="${WORK_DIR}/local-config.yaml"
OCI2GDSD_BIN="${OCI2GDSD_BIN:-}"
MODEL_ID="${MODEL_ID:-test-model}"
MODEL_REPO="${MODEL_REPO:-models/test-model}"
MODEL_TAG="${MODEL_TAG:-v1}"
REGISTRY_PORT="${REGISTRY_PORT:-5004}"
DEFAULT_LOCAL_E2E_ROOT="${WORK_DIR}/state"
if [[ -d /mnt/nvme && -w /mnt/nvme ]]; then
  DEFAULT_LOCAL_E2E_ROOT="/mnt/nvme/oci2gdsd-local-e2e"
fi
LOCAL_E2E_ROOT="${LOCAL_E2E_ROOT:-${DEFAULT_LOCAL_E2E_ROOT}}"

mkdir -p "${RESULTS_DIR}"

ensure_local_config() {
  if [[ -f "${CONFIG_PATH}" ]]; then
    return 0
  fi
  log "missing local-e2e config; creating minimal standalone config at ${CONFIG_PATH}"
  mkdir -p "${WORK_DIR}" "${LOCAL_E2E_ROOT}"
  cat > "${CONFIG_PATH}" <<EOF
root: ${LOCAL_E2E_ROOT}
model_root: ${LOCAL_E2E_ROOT}/models
tmp_root: ${LOCAL_E2E_ROOT}/tmp
locks_root: ${LOCAL_E2E_ROOT}/locks
journal_dir: ${LOCAL_E2E_ROOT}/journal
state_db: ${LOCAL_E2E_ROOT}/state.db
registry:
  plain_http: true
retention:
  min_free_bytes: 0
EOF
}

extract_error_json() {
  local path="$1"
  jq -c . "${path}" 2>/dev/null || true
}

expect_reason() {
  local expected_reason="$1"
  local name="$2"
  shift 2
  local out="${RESULTS_DIR}/${name}.stdout"
  local err="${RESULTS_DIR}/${name}.stderr"
  set +e
  "$@" >"${out}" 2>"${err}"
  local rc=$?
  set -e
  [[ "${rc}" -ne 0 ]] || die "${name}: expected failure but command exited 0"
  local err_json
  err_json="$(extract_error_json "${err}")"
  if [[ -z "${err_json}" ]]; then
    err_json="$(extract_error_json "${out}")"
  fi
  [[ -n "${err_json}" ]] || die "${name}: expected JSON error payload on stderr or stdout"
  printf '%s\n' "${err_json}" | jq -e --arg reason "${expected_reason}" '.reason_code == $reason' >/dev/null || \
    die "${name}: expected reason_code=${expected_reason}; got: ${err_json}"
}

expect_reason_any() {
  local expected_csv="$1"
  local name="$2"
  shift 2
  local out="${RESULTS_DIR}/${name}.stdout"
  local err="${RESULTS_DIR}/${name}.stderr"
  set +e
  "$@" >"${out}" 2>"${err}"
  local rc=$?
  set -e
  [[ "${rc}" -ne 0 ]] || die "${name}: expected failure but command exited 0"
  local err_json reason
  err_json="$(extract_error_json "${err}")"
  if [[ -z "${err_json}" ]]; then
    err_json="$(extract_error_json "${out}")"
  fi
  [[ -n "${err_json}" ]] || die "${name}: expected JSON error payload on stderr or stdout"
  reason="$(printf '%s\n' "${err_json}" | jq -r '.reason_code // empty')"
  [[ -n "${reason}" ]] || die "${name}: missing reason_code in stderr JSON"
  IFS=',' read -r -a allowed <<< "${expected_csv}"
  local ok=1
  local r
  for r in "${allowed[@]}"; do
    if [[ "${reason}" == "${r}" ]]; then
      ok=0
      break
    fi
  done
  [[ "${ok}" -eq 0 ]] || die "${name}: expected reason_code in [${expected_csv}], got ${reason}"
}

expect_lint_invalid() {
  local cfg="${WORK_DIR}/malicious-profile.json"
  cat > "${cfg}" <<EOF
{
  "schemaVersion": 1,
  "modelId": "malicious",
  "modelRevision": "v1",
  "framework": "pytorch",
  "format": "safetensors",
  "shards": [
    {
      "name": "../escape.safetensors",
      "digest": "sha256:$(printf '0%.0s' {1..64})",
      "size": 1,
      "ordinal": 1,
      "kind": "weight"
    }
  ],
  "integrity": {
    "manifestDigest": "sha256:$(printf '1%.0s' {1..64})"
  }
}
EOF
  local out="${RESULTS_DIR}/negative-profile-lint.stdout"
  local err="${RESULTS_DIR}/negative-profile-lint.stderr"
  set +e
  run_cli profile lint --config "${cfg}" --json >"${out}" 2>"${err}"
  local rc=$?
  set -e
  [[ "${rc}" -ne 0 ]] || die "negative-profile-lint: expected non-zero exit code"
  jq -e '.valid == false' "${out}" >/dev/null || die "negative-profile-lint: expected valid=false"
  jq -e '.errors | map(select(test("shards\\[[0-9]+\\]\\.name is invalid|invalid shard name|invalid shard"; "i"))) | length > 0' "${out}" >/dev/null || \
    die "negative-profile-lint: expected invalid shard-name error"
}

log "starting local-e2e negative tests"
ensure_cmd jq
ensure_local_config
resolve_oci2gdsd_bin

expect_reason "VALIDATION_FAILED" "negative-status-missing-digest" \
  run_cli status \
    --model-id "${MODEL_ID}" \
    --json

expect_reason "VALIDATION_FAILED" "negative-profile-lint-missing-source" \
  run_cli profile lint \
    --json

expect_reason "VALIDATION_FAILED" "negative-profile-inspect-missing-config" \
  run_cli profile inspect \
    --config "/tmp/does-not-exist-modelprofile.json" \
    --json

expect_reason_any "REGISTRY_UNREACHABLE,REGISTRY_TIMEOUT,MANIFEST_NOT_FOUND" "negative-profile-lint-unreachable-registry" \
  run_cli profile lint \
    --ref "localhost:1/models/missing@sha256:$(printf 'f%.0s' {1..64})" \
    --json

expect_lint_invalid

cat > "${RESULTS_DIR}/negative-summary.txt" <<EOF
verify-local: negative-suite-success
checked_reasons=VALIDATION_FAILED(status-missing-digest),VALIDATION_FAILED(profile-lint-missing-source),VALIDATION_FAILED(profile-inspect-missing-config),REGISTRY_UNREACHABLE|REGISTRY_TIMEOUT|MANIFEST_NOT_FOUND,PROFILE_LINT_FAILED-via-lint-result
EOF

log "local-e2e negative tests completed successfully"
log "artifacts:"
log "  ${RESULTS_DIR}/negative-summary.txt"
