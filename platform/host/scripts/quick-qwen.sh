#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${HARNESS_DIR}/../.." && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"
WORK_DIR="${HARNESS_DIR}/work"
RESULTS_DIR="${WORK_DIR}/results"
mkdir -p "${RESULTS_DIR}"

MODEL_ID="${MODEL_ID:-qwen3-0.6b}"
MODEL_DIGEST="${MODEL_DIGEST:-}"
MODEL_REF_OVERRIDE="${MODEL_REF_OVERRIDE:-}"
AUTO_SEED_MODEL_IDENTITY="${AUTO_SEED_MODEL_IDENTITY:-true}"
PACKAGER_IMAGE="${PACKAGER_IMAGE:-oci2gdsd-qwen3-packager:local}"
HF_REPO="${HF_REPO:-Qwen/Qwen3-0.6B}"
HF_REVISION="${HF_REVISION:-main}"
MODEL_REPO="${MODEL_REPO:-models/qwen3-0.6b}"
MODEL_TAG="${MODEL_TAG:-v1}"
HOST_LOCAL_REGISTRY_CONTAINER="${HOST_LOCAL_REGISTRY_CONTAINER:-oci2gdsd-host-registry}"
HOST_LOCAL_REGISTRY_IMAGE="${HOST_LOCAL_REGISTRY_IMAGE:-registry:2}"
HOST_LOCAL_REGISTRY_PORT="${HOST_LOCAL_REGISTRY_PORT:-5003}"
OCI2GDSD_ROOT_PATH="${OCI2GDSD_ROOT_PATH:-/mnt/nvme/oci2gdsd}"
OCI2GDSD_BIN="${OCI2GDSD_BIN:-}"
OCI2GDSD_REGISTRY_CONFIG="${OCI2GDSD_REGISTRY_CONFIG:-}"
VALIDATE_QUICK_EXAMPLE="${VALIDATE_QUICK_EXAMPLE:-true}"
QUICK_EXAMPLE_LEASE_HOLDER="${QUICK_EXAMPLE_LEASE_HOLDER:-host-qwen-smoke}"
PYTORCH_RUNTIME_IMAGE="${PYTORCH_RUNTIME_IMAGE:-nvcr.io/nvidia/ai-dynamo/vllm-runtime@sha256:de8ac9afb52711b08169e0f58388528c091efae6fb367a6fcfa119edef4bb233}"
OCI2GDS_CHUNK_BYTES="${OCI2GDS_CHUNK_BYTES:-4194304}"
OCI2GDS_SAMPLE_BYTES_PER_SHARD="${OCI2GDS_SAMPLE_BYTES_PER_SHARD:-8388608}"
OCI2GDS_STRICT="${OCI2GDS_STRICT:-true}"
REQUIRE_DIRECT_GDS="${REQUIRE_DIRECT_GDS:-true}"
OCI2GDS_FORCE_NO_COMPAT="${OCI2GDS_FORCE_NO_COMPAT:-true}"
OCI2GDS_FORCE_EXIT_AFTER_SUMMARY="${OCI2GDS_FORCE_EXIT_AFTER_SUMMARY:-true}"
OCI2GDS_VALIDATE_SAMPLE_BYTES="${OCI2GDS_VALIDATE_SAMPLE_BYTES:-true}"
# FIXME: Defaulted to false because some valid direct-path environments still
# report zero nvfs Ops counters; re-enable true-by-default after counter
# reliability is proven across supported providers/kernel/runtime combos.
REQUIRE_NVFS_STATS_DELTA_SET="${REQUIRE_NVFS_STATS_DELTA+x}"
REQUIRE_NVFS_STATS_DELTA="${REQUIRE_NVFS_STATS_DELTA:-}"
REQUIRE_NVFS_STATS_DELTA_MODE="${REQUIRE_NVFS_STATS_DELTA_MODE:-auto}"
REQUIRE_STRICT_PROBE_EVIDENCE="${REQUIRE_STRICT_PROBE_EVIDENCE:-true}"
HOST_PROBE_MIN_THROUGHPUT_MIB_S="${HOST_PROBE_MIN_THROUGHPUT_MIB_S:-0}"
HOST_PROBE_MAX_REGRESSION_PCT="${HOST_PROBE_MAX_REGRESSION_PCT:-0}"
HOST_PROBE_BASELINE_FILE="${HOST_PROBE_BASELINE_FILE:-${RESULTS_DIR}/host-qwen-probe-baseline.json}"
ALLOW_RELAXED_GDS="${ALLOW_RELAXED_GDS:-false}"
OCI2GDSD_BIN_MODE=""
declare -a OCI2GDSD_CMD=()
declare -a OCI2GDSD_GLOBAL_ARGS=()
NVFS_STATS_MODE=""

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

manifest_descriptor_path() {
  echo "${WORK_DIR}/packager/output/manifest-descriptor.json"
}

ensure_plain_http_registry_config() {
  if [[ -n "${OCI2GDSD_REGISTRY_CONFIG}" ]]; then
    return 0
  fi
  local cfg="${WORK_DIR}/generated-host-registry-config.yaml"
  cat > "${cfg}" <<EOF
root: ${OCI2GDSD_ROOT_PATH}
model_root: ${OCI2GDSD_ROOT_PATH}/models
tmp_root: ${OCI2GDSD_ROOT_PATH}/tmp
locks_root: ${OCI2GDSD_ROOT_PATH}/locks
journal_dir: ${OCI2GDSD_ROOT_PATH}/journal
state_db: ${OCI2GDSD_ROOT_PATH}/state.db
registry:
  plain_http: true
retention:
  min_free_bytes: 0
EOF
  OCI2GDSD_REGISTRY_CONFIG="${cfg}"
  export OCI2GDSD_REGISTRY_CONFIG
}

local_registry_ready() {
  curl --max-time 2 -fsS "http://127.0.0.1:${HOST_LOCAL_REGISTRY_PORT}/v2/" >/dev/null 2>&1
}

ensure_local_registry_running() {
  if maybe_sudo docker ps --format '{{.Names}}' | grep -Fxq "${HOST_LOCAL_REGISTRY_CONTAINER}"; then
    :
  elif maybe_sudo docker ps -a --format '{{.Names}}' | grep -Fxq "${HOST_LOCAL_REGISTRY_CONTAINER}"; then
    log "starting local registry container ${HOST_LOCAL_REGISTRY_CONTAINER}"
    maybe_sudo docker start "${HOST_LOCAL_REGISTRY_CONTAINER}" >/dev/null
  else
    log "creating local registry container ${HOST_LOCAL_REGISTRY_CONTAINER} on 127.0.0.1:${HOST_LOCAL_REGISTRY_PORT}"
    maybe_sudo docker run -d --restart unless-stopped \
      --name "${HOST_LOCAL_REGISTRY_CONTAINER}" \
      -p "${HOST_LOCAL_REGISTRY_PORT}:5000" \
      "${HOST_LOCAL_REGISTRY_IMAGE}" >/dev/null
  fi

  local attempts=60
  local delay=1
  local i
  for ((i=1; i<=attempts; i++)); do
    if local_registry_ready; then
      log "local registry is ready on 127.0.0.1:${HOST_LOCAL_REGISTRY_PORT}"
      return 0
    fi
    sleep "${delay}"
  done
  die "local registry readiness check failed on 127.0.0.1:${HOST_LOCAL_REGISTRY_PORT}"
}

build_packager_image() {
  log "building packager image ${PACKAGER_IMAGE}"
  maybe_sudo docker build -t "${PACKAGER_IMAGE}" "${REPO_ROOT}/models/qwen3-oci-modelprofile-v1"
}

seed_from_packager_to_local_registry() {
  local packager_work="${WORK_DIR}/packager"
  local descriptor
  descriptor="$(manifest_descriptor_path)"
  mkdir -p "${packager_work}" "${packager_work}/.cache/huggingface"
  log "packaging model ${HF_REPO}@${HF_REVISION} to localhost:${HOST_LOCAL_REGISTRY_PORT}/${MODEL_REPO}:${MODEL_TAG}"
  maybe_sudo docker run --rm --network host \
    -u "$(id -u):$(id -g)" \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    -e HOME="/work" \
    -e HF_HOME="/work/.cache/huggingface" \
    -e XDG_CACHE_HOME="/work/.cache" \
    -v "${packager_work}:/work" \
    "${PACKAGER_IMAGE}" \
    --hf-repo "${HF_REPO}" \
    --hf-revision "${HF_REVISION}" \
    --model-id "${MODEL_ID}" \
    --oci-ref "localhost:${HOST_LOCAL_REGISTRY_PORT}/${MODEL_REPO}:${MODEL_TAG}" \
    --plain-http
  [[ -f "${descriptor}" ]] || die "manifest descriptor missing after packaging: ${descriptor}"
  MODEL_DIGEST="$(jq -r '.digest // empty' "${descriptor}")"
  [[ -n "${MODEL_DIGEST}" ]] || die "packager digest is empty in ${descriptor}"
  MODEL_REF_OVERRIDE="localhost:${HOST_LOCAL_REGISTRY_PORT}/${MODEL_REPO}@${MODEL_DIGEST}"
  export MODEL_DIGEST MODEL_REF_OVERRIDE
  ensure_plain_http_registry_config
}

adopt_manifest_descriptor_if_present() {
  local descriptor
  descriptor="$(manifest_descriptor_path)"
  [[ -f "${descriptor}" ]] || return 1
  local digest
  digest="$(jq -r '.digest // empty' "${descriptor}")"
  [[ -n "${digest}" ]] || return 1
  MODEL_DIGEST="${digest}"
  MODEL_REF_OVERRIDE="localhost:${HOST_LOCAL_REGISTRY_PORT}/${MODEL_REPO}@${MODEL_DIGEST}"
  export MODEL_DIGEST MODEL_REF_OVERRIDE
  ensure_plain_http_registry_config
  log "using existing manifest descriptor identity digest=${MODEL_DIGEST}"
  return 0
}

seed_model_identity_if_needed() {
  if [[ -n "${MODEL_DIGEST}" ]]; then
    return 0
  fi
  if [[ "${MODEL_REF_OVERRIDE}" == *@sha256:* ]]; then
    MODEL_DIGEST="${MODEL_REF_OVERRIDE##*@}"
    return 0
  fi
  if auto_detect_model_digest_from_ready; then
    log "using READY model digest from local cache: ${MODEL_DIGEST}"
    return 0
  fi
  if adopt_manifest_descriptor_if_present; then
    return 0
  fi
  if ! is_true "${AUTO_SEED_MODEL_IDENTITY}"; then
    return 0
  fi
  log "model identity is missing; auto-seeding local registry + packager output"
  ensure_local_registry_running
  build_packager_image
  seed_from_packager_to_local_registry
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
  local gdsio_report="${RESULTS_DIR}/gdsio-host.txt"
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
    local gdsio
    gdsio="$(gdsio_binary || true)"
    if [[ -n "${gdsio}" ]]; then
      maybe_sudo mkdir -p "${OCI2GDSD_ROOT_PATH}" >/dev/null 2>&1 || true
      if maybe_sudo "${gdsio}" \
        -D "${OCI2GDSD_ROOT_PATH}" \
        -d 0 \
        -w 1 \
        -s 1G \
        -i 1M \
        -x 0 \
        -I 1 >"${gdsio_report}" 2>&1 && ! grep -Eiq 'compat' "${gdsio_report}"; then
        local nvfs_registered=0
        if ls /dev/nvidia-fs* >/dev/null 2>&1; then
          if [[ -r /proc/driver/nvidia-fs/devices ]] && maybe_sudo test -s /proc/driver/nvidia-fs/devices; then
            nvfs_registered=1
          fi
          if [[ "${nvfs_registered}" -eq 0 ]] && [[ -r /proc/driver/nvidia-fs/modules ]]; then
            if maybe_sudo grep -Eiq '(^|[[:space:]])nvme([[:space:]]|:)' /proc/driver/nvidia-fs/modules; then
              nvfs_registered=1
            fi
          fi
        fi
        if [[ "${nvfs_registered}" -eq 1 ]]; then
          warn "gdscheck reports NVMe unsupported, but strict gdsio direct probe with NVFS registration succeeded (see ${gdsio_report}); continuing"
          return 0
        fi
      fi
    fi
    die "gdscheck reports NVMe unsupported and strict gdsio probe did not pass; see ${report} and ${gdsio_report}"
  fi
  log "gdscheck preflight passed (report: ${report})"
}

check_nvfs_rw_stats_state() {
  local f="/sys/module/nvidia_fs/parameters/rw_stats_enabled"
  if [[ ! -r "${f}" ]]; then
    warn "cannot read ${f}; nvfs counter assertions may be unavailable"
    if [[ "${NVFS_STATS_MODE}" == "required" ]]; then
      die "REQUIRE_NVFS_STATS_DELTA_MODE=required but ${f} is not readable"
    fi
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
  if [[ "${NVFS_STATS_MODE}" == "required" ]]; then
    die "REQUIRE_NVFS_STATS_DELTA_MODE=required requires rw_stats_enabled=1"
  fi
}

write_environment_report() {
  local out="${RESULTS_DIR}/environment-report.txt"
  {
    echo "# host-e2e environment report $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "repo_root=${REPO_ROOT}"
    echo "model_id=${MODEL_ID}"
    echo "model_digest=${MODEL_DIGEST}"
    echo "runtime_image=${PYTORCH_RUNTIME_IMAGE}"
    echo "strict=${OCI2GDS_STRICT}"
    echo "require_direct_gds=${REQUIRE_DIRECT_GDS}"
    echo "force_no_compat=${OCI2GDS_FORCE_NO_COMPAT}"
    echo "nvfs_stats_mode=${NVFS_STATS_MODE}"
    echo "docker_root=$(maybe_sudo docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
    echo "kernel=$(uname -r)"
    echo "os=$(uname -s)"
    echo "---- nvidia-smi ----"
    nvidia-smi || true
    echo "---- runtime image digest ----"
    maybe_sudo docker image inspect "${PYTORCH_RUNTIME_IMAGE}" --format '{{json .RepoDigests}}' 2>/dev/null || true
    echo "---- gdscheck -p ----"
    local gdscheck
    gdscheck="$(gdscheck_binary || true)"
    if [[ -n "${gdscheck}" ]]; then
      maybe_sudo "${gdscheck}" -p || true
    else
      echo "gdscheck: unavailable"
    fi
    echo "---- nvfs stats ----"
    cat /proc/driver/nvidia-fs/stats 2>/dev/null || true
  } > "${out}" 2>&1
  log "wrote environment report: ${out}"
}

host_runtime_checkpoint() {
  local label="$1"
  log "host runtime checkpoint: ${label}"
  command -v nvidia-smi >/dev/null 2>&1 || die "host runtime checkpoint failed (${label}): nvidia-smi not found"
  nvidia-smi -L >/dev/null 2>&1 || die "host runtime checkpoint failed (${label}): nvidia-smi -L failed"
  [[ -d /run/udev ]] || die "host runtime checkpoint failed (${label}): /run/udev missing"
  if ! ls /dev/nvidia-fs* >/dev/null 2>&1; then
    warn "host runtime checkpoint (${label}): /dev/nvidia-fs* missing; relying on strict functional direct-path probes"
  fi
  if is_true "${REQUIRE_DIRECT_GDS}"; then
    run_gds_preflight
  fi
}

assert_min_throughput() {
  local throughput="$1"
  local min_required="${HOST_PROBE_MIN_THROUGHPUT_MIB_S}"
  if ! [[ "${min_required}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    die "HOST_PROBE_MIN_THROUGHPUT_MIB_S must be numeric (got ${min_required})"
  fi
  awk -v t="${throughput}" -v m="${min_required}" 'BEGIN {exit !(t+0 >= m+0)}' || \
    die "host probe throughput too low: ${throughput} MiB/s < ${min_required} MiB/s"
}

apply_baseline_regression_gate() {
  local throughput="$1"
  local duration_ms="$2"
  local baseline="${HOST_PROBE_BASELINE_FILE}"
  local max_reg_pct="${HOST_PROBE_MAX_REGRESSION_PCT}"

  if ! [[ "${max_reg_pct}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    die "HOST_PROBE_MAX_REGRESSION_PCT must be numeric (got ${max_reg_pct})"
  fi

  mkdir -p "$(dirname "${baseline}")"
  if [[ ! -f "${baseline}" ]]; then
    jq -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson throughput "$(printf '%s' "${throughput}")" \
      --argjson duration_ms "$(printf '%s' "${duration_ms}")" \
      '{created_at:$ts, throughput_mib_s:$throughput, duration_ms:$duration_ms}' > "${baseline}"
    log "created host probe baseline: ${baseline}"
    return 0
  fi

  local baseline_throughput
  baseline_throughput="$(jq -r '.throughput_mib_s // 0' "${baseline}" 2>/dev/null || echo 0)"
  if [[ "${max_reg_pct}" == "0" || "${max_reg_pct}" == "0.0" ]]; then
    return 0
  fi
  local min_allowed
  min_allowed="$(awk -v b="${baseline_throughput}" -v p="${max_reg_pct}" 'BEGIN {printf "%.2f", b * (1 - (p/100.0))}')"
  awk -v t="${throughput}" -v m="${min_allowed}" 'BEGIN {exit !(t+0 >= m+0)}' || \
    die "host probe throughput regression exceeded threshold: current=${throughput} baseline=${baseline_throughput} max_regression_pct=${max_reg_pct} min_allowed=${min_allowed}"
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
  local native_cpp="${REPO_ROOT}/platform/k3s/pytorch/native/oci2gds_torch_native.cpp"
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
    -e REQUIRE_NVFS_STATS_DELTA_MODE="${NVFS_STATS_MODE}" \
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
  printf '%s\n' "${summary}" > "${RESULTS_DIR}/host-qwen-gds-summary.json"
  local status
  local backend
  local direct_count
  local compat_count
  local cufile_init_ok
  local force_no_compat_evidence
  local throughput_mib_s
  local duration_ms
  status="$(printf '%s\n' "${summary}" | jq -r '.status // empty' 2>/dev/null || true)"
  backend="$(printf '%s\n' "${summary}" | jq -r '.backend // empty' 2>/dev/null || true)"
  direct_count="$(printf '%s\n' "${summary}" | jq -r '.mode_counts.direct // 0' 2>/dev/null || true)"
  compat_count="$(printf '%s\n' "${summary}" | jq -r '.mode_counts.compat // 0' 2>/dev/null || true)"
  cufile_init_ok="$(printf '%s\n' "${summary}" | jq -r '.cufile_init_ok // false | tostring' 2>/dev/null || true)"
  force_no_compat_evidence="$(printf '%s\n' "${summary}" | jq -r '.compat_mode_disabled_evidence // false | tostring' 2>/dev/null || true)"
  throughput_mib_s="$(printf '%s\n' "${summary}" | jq -r '.throughput_mib_s // 0' 2>/dev/null || true)"
  duration_ms="$(printf '%s\n' "${summary}" | jq -r '.duration_ms // 0' 2>/dev/null || true)"
  if [[ "${status}" != "ok" ]]; then
    die "host probe status is not ok: ${status}"
  fi
  if is_true "${REQUIRE_STRICT_PROBE_EVIDENCE}"; then
    [[ "${backend}" == "native-cufile" ]] || die "strict probe evidence failed: backend=${backend} (expected native-cufile)"
    [[ "${cufile_init_ok}" == "true" ]] || die "strict probe evidence failed: cufile_init_ok=${cufile_init_ok}"
  fi
  if [[ "${REQUIRE_DIRECT_GDS}" == "true" ]]; then
    [[ "${direct_count}" =~ ^[0-9]+$ ]] || die "unexpected direct_count=${direct_count}"
    (( direct_count > 0 )) || die "direct GDS required but direct_count=${direct_count}"
  fi
  if [[ "${OCI2GDS_FORCE_NO_COMPAT}" == "true" ]] && is_true "${REQUIRE_STRICT_PROBE_EVIDENCE}"; then
    [[ "${force_no_compat_evidence}" == "true" ]] || die "force_no_compat evidence missing in probe summary"
    [[ "${compat_count}" =~ ^[0-9]+$ ]] || die "unexpected compat_count=${compat_count}"
    (( compat_count == 0 )) || die "compat path observed while OCI2GDS_FORCE_NO_COMPAT=true (compat_count=${compat_count})"
  fi
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
  assert_min_throughput "${throughput_mib_s}"
  apply_baseline_regression_gate "${throughput_mib_s}" "${duration_ms}"
  log "host probe perf: duration_ms=${duration_ms} throughput_mib_s=${throughput_mib_s}"
  log "host qwen probe succeeded (artifact: ${probe_log})"
}

log "starting host-only qwen direct-GDS quick e2e"
ensure_cmd docker
ensure_cmd jq
ensure_cmd python3
ensure_cmd curl
resolve_nvfs_stats_mode
enforce_strict_gds_policy
resolve_oci2gdsd_cmd
seed_model_identity_if_needed
resolve_model_digest
resolve_oci2gdsd_global_args
write_environment_report

log "model_digest=${MODEL_DIGEST}"
log "validate_quick_example=${VALIDATE_QUICK_EXAMPLE}"
log "strict=${OCI2GDS_STRICT} require_direct_gds=${REQUIRE_DIRECT_GDS}"
log "force_no_compat=${OCI2GDS_FORCE_NO_COMPAT} force_exit_after_summary=${OCI2GDS_FORCE_EXIT_AFTER_SUMMARY} validate_sample_bytes=${OCI2GDS_VALIDATE_SAMPLE_BYTES} nvfs_stats_mode=${NVFS_STATS_MODE}"
if [[ -n "${MODEL_REF_OVERRIDE}" ]]; then
  log "model_ref_override=${MODEL_REF_OVERRIDE}"
fi
if [[ -n "${OCI2GDSD_REGISTRY_CONFIG}" ]]; then
  log "registry_config=${OCI2GDSD_REGISTRY_CONFIG}"
fi

validate_quick_example_cli

resolve_model_root
log "model_root_path=${MODEL_ROOT_PATH}"

check_nvfs_rw_stats_state
host_runtime_checkpoint "pre-probe"
run_host_probe
host_runtime_checkpoint "post-probe"
