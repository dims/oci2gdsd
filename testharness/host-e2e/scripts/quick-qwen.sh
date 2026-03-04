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
OCI2GDSD_ROOT_PATH="${OCI2GDSD_ROOT_PATH:-/mnt/nvme/oci2gdsd}"
PYTORCH_RUNTIME_IMAGE="${PYTORCH_RUNTIME_IMAGE:-nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1}"
OCI2GDS_CHUNK_BYTES="${OCI2GDS_CHUNK_BYTES:-4194304}"
OCI2GDS_SAMPLE_BYTES_PER_SHARD="${OCI2GDS_SAMPLE_BYTES_PER_SHARD:-8388608}"
OCI2GDS_STRICT="${OCI2GDS_STRICT:-true}"
REQUIRE_DIRECT_GDS="${REQUIRE_DIRECT_GDS:-true}"
OCI2GDS_FORCE_NO_COMPAT="${OCI2GDS_FORCE_NO_COMPAT:-true}"
OCI2GDS_VALIDATE_SAMPLE_BYTES="${OCI2GDS_VALIDATE_SAMPLE_BYTES:-true}"
# FIXME: Defaulted to false because some valid direct-path environments still
# report zero nvfs Ops counters; re-enable true-by-default after counter
# reliability is proven across supported providers/kernel/runtime combos.
REQUIRE_NVFS_STATS_DELTA="${REQUIRE_NVFS_STATS_DELTA:-false}"

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
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
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

resolve_model_root
log "model_root_path=${MODEL_ROOT_PATH}"
log "model_digest=${MODEL_DIGEST}"
log "strict=${OCI2GDS_STRICT} require_direct_gds=${REQUIRE_DIRECT_GDS}"
log "force_no_compat=${OCI2GDS_FORCE_NO_COMPAT} validate_sample_bytes=${OCI2GDS_VALIDATE_SAMPLE_BYTES} require_nvfs_stats_delta=${REQUIRE_NVFS_STATS_DELTA}"

if is_true "${REQUIRE_DIRECT_GDS}"; then
  run_gds_preflight
fi

check_nvfs_rw_stats_state
run_host_probe
