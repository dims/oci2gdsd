#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${HARNESS_DIR}/../.." && pwd)"
WORK_DIR="${HARNESS_DIR}/work"
RESULTS_DIR="${WORK_DIR}/results"
mkdir -p "${RESULTS_DIR}"

MODEL_ID="${MODEL_ID:-qwen3-0.6b}"
MODEL_DIGEST="${MODEL_DIGEST:-}"
MODEL_REF_OVERRIDE="${MODEL_REF_OVERRIDE:-}"
OCI2GDSD_ROOT_PATH="${OCI2GDSD_ROOT_PATH:-/mnt/nvme/oci2gdsd}"
OCI2GDSD_BIN="${OCI2GDSD_BIN:-}"
OCI2GDSD_REGISTRY_CONFIG="${OCI2GDSD_REGISTRY_CONFIG:-}"
VALIDATE_QUICK_EXAMPLE="${VALIDATE_QUICK_EXAMPLE:-true}"
QUICK_EXAMPLE_LEASE_HOLDER="${QUICK_EXAMPLE_LEASE_HOLDER:-host-e2e-qwen-quick}"
PYTORCH_RUNTIME_IMAGE="${PYTORCH_RUNTIME_IMAGE:-nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1}"
OCI2GDS_CHUNK_BYTES="${OCI2GDS_CHUNK_BYTES:-4194304}"
OCI2GDS_SAMPLE_BYTES_PER_SHARD="${OCI2GDS_SAMPLE_BYTES_PER_SHARD:-8388608}"
OCI2GDS_STRICT="${OCI2GDS_STRICT:-true}"
REQUIRE_DIRECT_GDS="${REQUIRE_DIRECT_GDS:-true}"
OCI2GDS_FORCE_NO_COMPAT="${OCI2GDS_FORCE_NO_COMPAT:-true}"
OCI2GDS_FORCE_EXIT_AFTER_SUMMARY="${OCI2GDS_FORCE_EXIT_AFTER_SUMMARY:-false}"
OCI2GDS_VALIDATE_SAMPLE_BYTES="${OCI2GDS_VALIDATE_SAMPLE_BYTES:-true}"
# FIXME: Defaulted to false because some valid direct-path environments still
# report zero nvfs Ops counters; re-enable true-by-default after counter
# reliability is proven across supported providers/kernel/runtime combos.
REQUIRE_NVFS_STATS_DELTA="${REQUIRE_NVFS_STATS_DELTA:-false}"
OCI2GDSD_BIN_MODE=""
declare -a OCI2GDSD_CMD=()
declare -a OCI2GDSD_GLOBAL_ARGS=()

_ts() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  echo "[$(_ts)] $*"
}

warn() {
  echo "[$(_ts)] WARN: $*" >&2
}

die() {
  echo "[$(_ts)] ERROR: $*" >&2
  exit 1
}

ensure_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "missing required command: ${cmd}"
}

maybe_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

is_true() {
  local v
  v="$(printf '%s' "${1}" | tr '[:upper:]' '[:lower:]')"
  case "${v}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_oci2gdsd_cmd() {
  if [[ -n "${OCI2GDSD_BIN}" ]]; then
    [[ -x "${OCI2GDSD_BIN}" ]] || die "OCI2GDSD_BIN is not executable: ${OCI2GDSD_BIN}"
    OCI2GDSD_CMD=("${OCI2GDSD_BIN}")
    OCI2GDSD_BIN_MODE="direct"
    return 0
  fi
  if command -v oci2gdsd >/dev/null 2>&1; then
    OCI2GDSD_CMD=("$(command -v oci2gdsd)")
    OCI2GDSD_BIN_MODE="direct"
    return 0
  fi
  if [[ -x "${REPO_ROOT}/oci2gdsd" ]]; then
    OCI2GDSD_CMD=("${REPO_ROOT}/oci2gdsd")
    OCI2GDSD_BIN_MODE="direct"
    return 0
  fi
  if command -v go >/dev/null 2>&1; then
    OCI2GDSD_CMD=("go" "run" "./cmd/oci2gdsd")
    OCI2GDSD_BIN_MODE="go-run"
    return 0
  fi
  die "could not resolve oci2gdsd CLI; install oci2gdsd or Go toolchain, or set OCI2GDSD_BIN"
}

resolve_oci2gdsd_global_args() {
  if [[ -n "${OCI2GDSD_REGISTRY_CONFIG}" ]]; then
    [[ -f "${OCI2GDSD_REGISTRY_CONFIG}" ]] || die "OCI2GDSD_REGISTRY_CONFIG does not exist: ${OCI2GDSD_REGISTRY_CONFIG}"
    OCI2GDSD_GLOBAL_ARGS=(--registry-config "${OCI2GDSD_REGISTRY_CONFIG}")
    return 0
  fi
  OCI2GDSD_GLOBAL_ARGS=(--root "${OCI2GDSD_ROOT_PATH}")
}

run_oci2gdsd() {
  if [[ "${OCI2GDSD_BIN_MODE}" == "go-run" ]]; then
    (cd "${REPO_ROOT}" && "${OCI2GDSD_CMD[@]}" "${OCI2GDSD_GLOBAL_ARGS[@]}" "$@")
    return $?
  fi
  "${OCI2GDSD_CMD[@]}" "${OCI2GDSD_GLOBAL_ARGS[@]}" "$@"
}

auto_detect_model_digest_from_ready() {
  local base="${OCI2GDSD_ROOT_PATH}/models/${MODEL_ID}"
  [[ -d "${base}" ]] || return 1
  local candidate=""
  while IFS= read -r dir; do
    [[ -d "${dir}" ]] || continue
    if [[ -f "${dir}/READY" ]]; then
      candidate="${dir}"
      break
    fi
  done < <(ls -1dt "${base}"/* 2>/dev/null || true)
  [[ -n "${candidate}" ]] || return 1
  local bn
  bn="$(basename "${candidate}")"
  [[ "${bn}" == sha256-* ]] || return 1
  MODEL_DIGEST="sha256:${bn#sha256-}"
  return 0
}

resolve_model_digest() {
  if [[ -n "${MODEL_DIGEST}" ]]; then
    return 0
  fi
  if [[ "${MODEL_REF_OVERRIDE}" == *@sha256:* ]]; then
    MODEL_DIGEST="${MODEL_REF_OVERRIDE##*@}"
  fi
  if [[ -z "${MODEL_DIGEST}" ]]; then
    auto_detect_model_digest_from_ready || true
  fi
  [[ -n "${MODEL_DIGEST}" ]] || die "MODEL_DIGEST is required (or provide MODEL_REF_OVERRIDE with @sha256:<digest>)"
}

gdscheck_binary() {
  if command -v gdscheck >/dev/null 2>&1; then
    command -v gdscheck
    return 0
  fi
  if [[ -x /usr/local/cuda/gds/tools/gdscheck ]]; then
    echo "/usr/local/cuda/gds/tools/gdscheck"
    return 0
  fi
  if [[ -x /usr/local/cuda-12.6/gds/tools/gdscheck ]]; then
    echo "/usr/local/cuda-12.6/gds/tools/gdscheck"
    return 0
  fi
  return 1
}

resolve_model_root() {
  local base="${OCI2GDSD_ROOT_PATH}/models/${MODEL_ID}"
  [[ -d "${base}" ]] || die "model base path missing: ${base}"

  if [[ -n "${MODEL_DIGEST}" ]]; then
    MODEL_ROOT_PATH="${base}/${MODEL_DIGEST//:/-}"
  else
    local candidate=""
    while IFS= read -r dir; do
      [[ -d "${dir}" ]] || continue
      if [[ -f "${dir}/READY" ]]; then
        candidate="${dir}"
        break
      fi
    done < <(ls -1dt "${base}"/* 2>/dev/null || true)
    [[ -n "${candidate}" ]] || die "no READY model found under ${base}; set MODEL_DIGEST explicitly"
    MODEL_ROOT_PATH="${candidate}"
    local bn
    bn="$(basename "${MODEL_ROOT_PATH}")"
    if [[ "${bn}" == sha256-* ]]; then
      MODEL_DIGEST="sha256:${bn#sha256-}"
    fi
  fi

  [[ -d "${MODEL_ROOT_PATH}" ]] || die "model root missing: ${MODEL_ROOT_PATH}"
  [[ -f "${MODEL_ROOT_PATH}/READY" ]] || die "READY marker missing: ${MODEL_ROOT_PATH}/READY"
  [[ -f "${MODEL_ROOT_PATH}/metadata/model.json" ]] || die "metadata missing: ${MODEL_ROOT_PATH}/metadata/model.json"
  export MODEL_ROOT_PATH MODEL_DIGEST
}

run_gds_preflight() {
  local gdscheck
  gdscheck="$(gdscheck_binary)" || die "gdscheck not found"
  local report="${RESULTS_DIR}/gdscheck-host.txt"
  local tmp_report
  tmp_report="$(mktemp)"
  if ! maybe_sudo "${gdscheck}" -p >"${tmp_report}" 2>&1; then
    cat "${tmp_report}" >"${report}" 2>/dev/null || true
    rm -f "${tmp_report}"
    die "gdscheck -p failed; see ${report}"
  fi
  cat "${tmp_report}" >"${report}"
  rm -f "${tmp_report}"

  if ! grep -Eq 'NVMe[[:space:]]*:[[:space:]]*Supported' "${report}"; then
    die "gdscheck reports NVMe unsupported; see ${report}"
  fi
  log "gdscheck preflight passed (report: ${report})"
}

check_nvfs_rw_stats_state() {
  local f="/sys/module/nvidia_fs/parameters/rw_stats_enabled"
  if [[ ! -r "${f}" ]]; then
    warn "cannot read ${f}; nvfs counter assertions may be unavailable"
    return 0
  fi
  local v
  v="$(cat "${f}" 2>/dev/null || true)"
  if [[ "${v}" == "1" ]]; then
    log "nvidia-fs rw_stats_enabled=1 (kernel counters enabled)"
    return 0
  fi
  warn "nvidia-fs rw_stats_enabled=${v:-unknown} (kernel IO counters disabled)"
  warn "enable with: sudo sh -c 'echo 1 > /sys/module/nvidia_fs/parameters/rw_stats_enabled'"
  if is_true "${REQUIRE_NVFS_STATS_DELTA}"; then
    die "REQUIRE_NVFS_STATS_DELTA=true requires rw_stats_enabled=1"
  fi
}

validate_quick_example_cli() {
  if ! is_true "${VALIDATE_QUICK_EXAMPLE}"; then
    log "skipping quick-example CLI lifecycle validation (VALIDATE_QUICK_EXAMPLE=false)"
    return 0
  fi

  local status_json="${RESULTS_DIR}/quick-example-status.json"
  local verify_json="${RESULTS_DIR}/quick-example-verify.json"
  local ensure_json="${RESULTS_DIR}/quick-example-ensure.json"
  local release_json="${RESULTS_DIR}/quick-example-release.json"
  local ran_ensure=0

  if [[ -n "${MODEL_REF_OVERRIDE}" ]]; then
    log "quick-example validation: ensure model_ref=${MODEL_REF_OVERRIDE}"
    run_oci2gdsd ensure \
      --ref "${MODEL_REF_OVERRIDE}" \
      --model-id "${MODEL_ID}" \
      --lease-holder "${QUICK_EXAMPLE_LEASE_HOLDER}" \
      --wait \
      --json | tee "${ensure_json}"
    jq -e --arg model "${MODEL_ID}" --arg digest "${MODEL_DIGEST}" \
      '.status == "READY" and .model_id == $model and .manifest_digest == $digest' \
      "${ensure_json}" >/dev/null || die "quick-example ensure assertion failed (see ${ensure_json})"
    ran_ensure=1
  else
    warn "MODEL_REF_OVERRIDE is not set; skipping quick-example ensure/release checks"
  fi

  log "quick-example validation: status"
  run_oci2gdsd status \
    --model-id "${MODEL_ID}" \
    --digest "${MODEL_DIGEST}" \
    --json | tee "${status_json}"
  jq -e --arg model "${MODEL_ID}" --arg digest "${MODEL_DIGEST}" \
    '.status == "READY" and .model_id == $model and .manifest_digest == $digest' \
    "${status_json}" >/dev/null || die "quick-example status assertion failed (see ${status_json})"

  log "quick-example validation: verify"
  run_oci2gdsd verify \
    --model-id "${MODEL_ID}" \
    --digest "${MODEL_DIGEST}" \
    --json | tee "${verify_json}"
  jq -e --arg model "${MODEL_ID}" --arg digest "${MODEL_DIGEST}" \
    '.status == "READY" and .model_id == $model and .manifest_digest == $digest' \
    "${verify_json}" >/dev/null || die "quick-example verify assertion failed (see ${verify_json})"

  if [[ "${ran_ensure}" -eq 1 ]]; then
    log "quick-example validation: release lease-holder=${QUICK_EXAMPLE_LEASE_HOLDER}"
    run_oci2gdsd release \
      --model-id "${MODEL_ID}" \
      --digest "${MODEL_DIGEST}" \
      --lease-holder "${QUICK_EXAMPLE_LEASE_HOLDER}" \
      --json | tee "${release_json}"
    jq -e --arg model "${MODEL_ID}" --arg digest "${MODEL_DIGEST}" \
      '.model_id == $model and .manifest_digest == $digest and (.status == "READY" or .status == "RELEASED")' \
      "${release_json}" >/dev/null || die "quick-example release assertion failed (see ${release_json})"
  fi

  log "quick-example CLI lifecycle validation passed"
}

run_host_probe() {
  local probe_log="${RESULTS_DIR}/host-qwen-gds.log"
  local probe_script="${SCRIPT_DIR}/host_qwen_probe.py"
  local native_cpp="${REPO_ROOT}/examples/qwen-hello/native/oci2gds_torch_native.cpp"
  [[ -f "${probe_script}" ]] || die "missing probe script: ${probe_script}"
  [[ -f "${native_cpp}" ]] || die "missing native source: ${native_cpp}"

  log "running host probe image=${PYTORCH_RUNTIME_IMAGE}"
  maybe_sudo docker run --rm --privileged --gpus all --user 0:0 -i \
    -e MODEL_ROOT_PATH="${MODEL_ROOT_PATH}" \
    -e MODEL_ID="${MODEL_ID}" \
    -e MODEL_DIGEST="${MODEL_DIGEST}" \
    -e OCI2GDS_CHUNK_BYTES="${OCI2GDS_CHUNK_BYTES}" \
    -e OCI2GDS_SAMPLE_BYTES_PER_SHARD="${OCI2GDS_SAMPLE_BYTES_PER_SHARD}" \
    -e OCI2GDS_STRICT="${OCI2GDS_STRICT}" \
    -e REQUIRE_DIRECT_GDS="${REQUIRE_DIRECT_GDS}" \
    -e OCI2GDS_FORCE_NO_COMPAT="${OCI2GDS_FORCE_NO_COMPAT}" \
    -e OCI2GDS_FORCE_EXIT_AFTER_SUMMARY="${OCI2GDS_FORCE_EXIT_AFTER_SUMMARY}" \
    -e OCI2GDS_VALIDATE_SAMPLE_BYTES="${OCI2GDS_VALIDATE_SAMPLE_BYTES}" \
    -e REQUIRE_NVFS_STATS_DELTA="${REQUIRE_NVFS_STATS_DELTA}" \
    -e OCI2GDS_TORCH_NATIVE_VERBOSE="${OCI2GDS_TORCH_NATIVE_VERBOSE:-0}" \
    -e OCI2GDS_NATIVE_CPP_PATH="/opt/oci2gdsd/native/oci2gds_torch_native.cpp" \
    -v "${OCI2GDSD_ROOT_PATH}:${OCI2GDSD_ROOT_PATH}:ro" \
    -v /run/udev:/run/udev:ro \
    -v /dev:/host-dev:ro \
    -v "${probe_script}:/opt/oci2gdsd/host_qwen_probe.py:ro" \
    -v "${native_cpp}:/opt/oci2gdsd/native/oci2gds_torch_native.cpp:ro" \
    "${PYTORCH_RUNTIME_IMAGE}" \
    python3 /opt/oci2gdsd/host_qwen_probe.py | tee "${probe_log}"

  local summary
  summary="$(grep '^HOST_QWEN_GDS_PROBE ' "${probe_log}" | tail -n1 | cut -d' ' -f2- || true)"
  [[ -n "${summary}" ]] || die "probe summary missing in ${probe_log}"
  printf '%s\n' "${summary}" | jq .
  local io_stats_enabled
  local rw_stats_enabled
  local read_delta
  local batch_delta
  io_stats_enabled="$(printf '%s\n' "${summary}" | jq -r 'if (.nvfs_ops_before | has("io_stats_enabled")) then (.nvfs_ops_before.io_stats_enabled | tostring) else "unknown" end' 2>/dev/null || true)"
  rw_stats_enabled="$(printf '%s\n' "${summary}" | jq -r 'if (.nvfs_ops_before | has("rw_stats_enabled")) then (.nvfs_ops_before.rw_stats_enabled | tostring) else "unknown" end' 2>/dev/null || true)"
  read_delta="$(printf '%s\n' "${summary}" | jq -r '.nvfs_ops_delta.read // 0' 2>/dev/null || true)"
  batch_delta="$(printf '%s\n' "${summary}" | jq -r '.nvfs_ops_delta.batchio // 0' 2>/dev/null || true)"
  if [[ "${io_stats_enabled}" != "true" || "${rw_stats_enabled}" != "true" ]]; then
    warn "nvfs IO stats appear disabled in probe (io_stats_enabled=${io_stats_enabled}, rw_stats_enabled=${rw_stats_enabled}); counter-based proof is not available"
  else
    log "nvfs counter deltas: read=${read_delta} batchio=${batch_delta}"
  fi
  log "host qwen probe succeeded (artifact: ${probe_log})"
}

log "starting host-only qwen direct-GDS quick e2e"
ensure_cmd docker
ensure_cmd jq
ensure_cmd python3
resolve_oci2gdsd_cmd
resolve_oci2gdsd_global_args
resolve_model_digest

log "model_digest=${MODEL_DIGEST}"
log "validate_quick_example=${VALIDATE_QUICK_EXAMPLE}"
log "strict=${OCI2GDS_STRICT} require_direct_gds=${REQUIRE_DIRECT_GDS}"
log "force_no_compat=${OCI2GDS_FORCE_NO_COMPAT} force_exit_after_summary=${OCI2GDS_FORCE_EXIT_AFTER_SUMMARY} validate_sample_bytes=${OCI2GDS_VALIDATE_SAMPLE_BYTES} require_nvfs_stats_delta=${REQUIRE_NVFS_STATS_DELTA}"
if [[ -n "${MODEL_REF_OVERRIDE}" ]]; then
  log "model_ref_override=${MODEL_REF_OVERRIDE}"
fi

validate_quick_example_cli

resolve_model_root
log "model_root_path=${MODEL_ROOT_PATH}"

if is_true "${REQUIRE_DIRECT_GDS}"; then
  run_gds_preflight
fi

check_nvfs_rw_stats_state
run_host_probe
