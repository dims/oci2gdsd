#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

CONTRACT_FILE="${CONTRACT_FILE:-${HARNESS_DIR}/contracts/runtime-contract.v1.json}"
REPORT_FILE="${REPORT_FILE:-${RESULTS_DIR}/runtime-contract-report.json}"
TARGET_RUNTIME="${WORKLOAD_RUNTIME}"
CHECK_ALL=false
INCLUDE_QWEN=false

usage() {
  cat <<'EOF'
Usage: validate-runtime-contract.sh [--runtime <name>] [--all-runtimes] [--include-qwen] [--contract <path>] [--report <path>]

Options:
  --runtime <name>     Validate one runtime contract (pytorch|tensorrt|vllm).
  --all-runtimes       Validate all runtime contracts in contract file.
  --include-qwen       Also validate qwen-hello deployment template contract.
  --contract <path>    Override contract JSON path.
  --report <path>      Override JSON report output path.
  -h, --help           Show usage.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)
      [[ $# -ge 2 ]] || die "--runtime requires a value"
      TARGET_RUNTIME="$2"
      shift 2
      ;;
    --all-runtimes)
      CHECK_ALL=true
      shift
      ;;
    --include-qwen)
      INCLUDE_QWEN=true
      shift
      ;;
    --contract)
      [[ $# -ge 2 ]] || die "--contract requires a value"
      CONTRACT_FILE="$2"
      shift 2
      ;;
    --report)
      [[ $# -ge 2 ]] || die "--report requires a value"
      REPORT_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -f "${CONTRACT_FILE}" ]] || die "runtime contract file not found: ${CONTRACT_FILE}"
mkdir -p "$(dirname "${REPORT_FILE}")"

json_lines_to_array() {
  local path="$1"
  jq -R -s 'split("\n") | map(select(length > 0))' "${path}"
}

resolve_template_path() {
  local template_path="$1"
  if [[ "${template_path}" = /* ]]; then
    printf '%s\n' "${template_path}"
    return
  fi
  printf '%s/%s\n' "${REPO_ROOT}" "${template_path}"
}

OVERALL_OK=true
TMP_ENTRIES="$(mktemp)"
trap 'rm -f "${TMP_ENTRIES}"' EXIT

validate_target() {
  local target_name="$1"
  local template_raw="$2"
  local required_query="$3"
  local forbidden_query="$4"
  local template
  template="$(resolve_template_path "${template_raw}")"
  [[ -f "${template}" ]] || die "missing template for ${target_name}: ${template}"

  local req_tmp forbid_tmp
  req_tmp="$(mktemp)"
  forbid_tmp="$(mktemp)"

  local required_patterns=()
  while IFS= read -r p; do
    required_patterns+=("${p}")
  done < <(jq -r "${required_query}" "${CONTRACT_FILE}")

  local forbidden_patterns=()
  while IFS= read -r p; do
    forbidden_patterns+=("${p}")
  done < <(jq -r "${forbidden_query}" "${CONTRACT_FILE}")

  local p
  if (( ${#required_patterns[@]} > 0 )); then
    for p in "${required_patterns[@]}"; do
      [[ -n "${p}" ]] || continue
      if ! grep -Eq -- "${p}" "${template}"; then
        printf '%s\n' "${p}" >> "${req_tmp}"
      fi
    done
  fi

  if (( ${#forbidden_patterns[@]} > 0 )); then
    for p in "${forbidden_patterns[@]}"; do
      [[ -n "${p}" ]] || continue
      if grep -Eq -- "${p}" "${template}"; then
        printf '%s\n' "${p}" >> "${forbid_tmp}"
      fi
    done
  fi

  local status="ok"
  if [[ -s "${req_tmp}" || -s "${forbid_tmp}" ]]; then
    status="failed"
    OVERALL_OK=false
    warn "runtime contract mismatch target=${target_name} template=${template}"
    if [[ -s "${req_tmp}" ]]; then
      while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        warn "  missing required pattern: ${line}"
      done < "${req_tmp}"
    fi
    if [[ -s "${forbid_tmp}" ]]; then
      while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        warn "  matched forbidden pattern: ${line}"
      done < "${forbid_tmp}"
    fi
  else
    log "runtime contract OK target=${target_name} template=${template}"
  fi

  local missing_json forbidden_json
  missing_json="$(json_lines_to_array "${req_tmp}")"
  forbidden_json="$(json_lines_to_array "${forbid_tmp}")"

  jq -n \
    --arg target "${target_name}" \
    --arg template "${template}" \
    --arg status "${status}" \
    --argjson missing_required "${missing_json}" \
    --argjson matched_forbidden "${forbidden_json}" \
    '{target:$target, template:$template, status:$status, missing_required:$missing_required, matched_forbidden:$matched_forbidden}' \
    >> "${TMP_ENTRIES}"

  rm -f "${req_tmp}" "${forbid_tmp}"
}

validate_runtime() {
  local runtime="$1"
  local template_raw
  template_raw="$(jq -r --arg r "${runtime}" '.runtimes[$r].template // empty' "${CONTRACT_FILE}")"
  [[ -n "${template_raw}" ]] || die "runtime ${runtime} is not defined in contract ${CONTRACT_FILE}"

  validate_target \
    "runtime:${runtime}" \
    "${template_raw}" \
    ".baseline.required_patterns[]?, .runtimes[\"${runtime}\"].required_patterns[]?" \
    ".runtimes[\"${runtime}\"].forbidden_patterns[]?"
}

if [[ "${CHECK_ALL}" == "true" ]]; then
  runtime_list=()
  while IFS= read -r runtime; do
    runtime_list+=("${runtime}")
  done < <(jq -r '.runtimes | keys[]' "${CONTRACT_FILE}")
else
  runtime_list=("${TARGET_RUNTIME}")
fi

for runtime in "${runtime_list[@]}"; do
  validate_runtime "${runtime}"
done

if [[ "${INCLUDE_QWEN}" == "true" ]]; then
  qwen_template="$(jq -r '.qwen_hello.template // empty' "${CONTRACT_FILE}")"
  [[ -n "${qwen_template}" ]] || die "qwen_hello.template is missing from contract ${CONTRACT_FILE}"
  validate_target \
    "profile:qwen_hello" \
    "${qwen_template}" \
    ".qwen_hello.required_patterns[]?" \
    ".qwen_hello.forbidden_patterns[]?"
fi

entries_json="$(jq -s '.' "${TMP_ENTRIES}")"
contract_version="$(jq -r '.contract_version // "unknown"' "${CONTRACT_FILE}")"

jq -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg contract_file "${CONTRACT_FILE}" \
  --arg contract_version "${contract_version}" \
  --arg runtime_mode "$([[ "${CHECK_ALL}" == "true" ]] && echo "all-runtimes" || echo "single-runtime")" \
  --arg runtime "${TARGET_RUNTIME}" \
  --arg include_qwen "${INCLUDE_QWEN}" \
  --argjson entries "${entries_json}" \
  '{
    timestamp: $ts,
    contract_file: $contract_file,
    contract_version: $contract_version,
    runtime_mode: $runtime_mode,
    runtime: $runtime,
    include_qwen: ($include_qwen == "true"),
    entries: $entries
  }' > "${REPORT_FILE}"

log "wrote runtime contract report: ${REPORT_FILE}"
if [[ "${OVERALL_OK}" != "true" ]]; then
  die "runtime contract validation failed"
fi

log "runtime contract validation passed"
