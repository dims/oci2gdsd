#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${HARNESS_DIR}/../.." && pwd)"
WORK_DIR="${HARNESS_DIR}/work"
RESULTS_DIR="${WORK_DIR}/results"
PAYLOAD_DIR="${WORK_DIR}/payload"
DEFAULT_LOCAL_E2E_ROOT="${WORK_DIR}/state"
if [[ -d /mnt/nvme && -w /mnt/nvme ]]; then
  DEFAULT_LOCAL_E2E_ROOT="/mnt/nvme/oci2gdsd-local-e2e"
fi
ROOT_DIR="${LOCAL_E2E_ROOT:-${DEFAULT_LOCAL_E2E_ROOT}}"
REGISTRY_NAME="${REGISTRY_NAME:-oci2gdsd-local-e2e-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5004}"
MODEL_ID="${MODEL_ID:-test-model}"
MODEL_REPO="${MODEL_REPO:-models/test-model}"
MODEL_TAG="${MODEL_TAG:-v1}"
LEASE_HOLDER="${LEASE_HOLDER:-local-e2e}"
SECOND_MODEL_ID="${SECOND_MODEL_ID:-test-model-b}"
SECOND_MODEL_REPO="${SECOND_MODEL_REPO:-models/test-model-b}"
SECOND_MODEL_TAG="${SECOND_MODEL_TAG:-v1}"
SECOND_LEASE_HOLDER="${SECOND_LEASE_HOLDER:-local-e2e-b}"
OCI2GDSD_BIN="${OCI2GDSD_BIN:-}"

mkdir -p "${RESULTS_DIR}" "${PAYLOAD_DIR}/shards" "${PAYLOAD_DIR}/metadata" "${ROOT_DIR}"

_ts() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  echo "[$(_ts)] $*"
}

die() {
  echo "[$(_ts)] ERROR: $*" >&2
  exit 1
}

ensure_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "missing required command: ${cmd}"
}

detect_docker_access() {
  if docker info >/dev/null 2>&1; then
    DOCKER_PREFIX=()
    return
  fi
  if sudo docker info >/dev/null 2>&1; then
    DOCKER_PREFIX=(sudo)
    return
  fi
  die "docker daemon is not reachable"
}

docker_cmd() {
  "${DOCKER_PREFIX[@]}" docker "$@"
}

cleanup() {
  docker_cmd rm -f "${REGISTRY_NAME}" >/dev/null 2>&1 || true
}

trap cleanup EXIT

resolve_oci2gdsd_bin() {
  if [[ -n "${OCI2GDSD_BIN}" ]]; then
    [[ -x "${OCI2GDSD_BIN}" ]] || die "OCI2GDSD_BIN is not executable: ${OCI2GDSD_BIN}"
    return
  fi
  if [[ -x "${REPO_ROOT}/oci2gdsd" ]]; then
    OCI2GDSD_BIN="${REPO_ROOT}/oci2gdsd"
    return
  fi
  if command -v oci2gdsd >/dev/null 2>&1; then
    OCI2GDSD_BIN="$(command -v oci2gdsd)"
    return
  fi
  ensure_cmd go
  OCI2GDSD_BIN="${WORK_DIR}/oci2gdsd"
  log "building oci2gdsd binary for local e2e"
  (cd "${REPO_ROOT}" && go build -o "${OCI2GDSD_BIN}" ./cmd/oci2gdsd)
}

wait_for_registry() {
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if curl -fsS "http://127.0.0.1:${REGISTRY_PORT}/v2/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

run_cli() {
  "${OCI2GDSD_BIN}" --registry-config "${WORK_DIR}/local-config.yaml" "$@"
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${path}" | awk '{print $1}'
    return 0
  fi
  die "missing checksum command: sha256sum or shasum"
}

filesize_bytes() {
  local path="$1"
  if stat -c %s "${path}" >/dev/null 2>&1; then
    stat -c %s "${path}"
    return 0
  fi
  stat -f %z "${path}"
}

write_environment_report() {
  local out="${RESULTS_DIR}/environment-report.txt"
  {
    echo "# local-e2e environment $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "repo_root=${REPO_ROOT}"
    echo "root_dir=${ROOT_DIR}"
    echo "registry_name=${REGISTRY_NAME}"
    echo "registry_port=${REGISTRY_PORT}"
    echo "model_id=${MODEL_ID}"
    echo "second_model_id=${SECOND_MODEL_ID}"
    echo "docker_root=$(docker_cmd info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
    echo "kernel=$(uname -r)"
    echo "---- docker version ----"
    docker_cmd version || true
    echo "---- oras version ----"
    oras version || true
    echo "---- go version ----"
    go version || true
  } > "${out}" 2>&1
  log "wrote environment report: ${out}"
}

log "starting local CLI lifecycle e2e"
ensure_cmd docker
ensure_cmd curl
ensure_cmd jq
ensure_cmd oras
detect_docker_access
resolve_oci2gdsd_bin
[[ -x "${OCI2GDSD_BIN}" ]] || die "resolved oci2gdsd binary is not executable: ${OCI2GDSD_BIN}"
write_environment_report

log "starting local OCI registry ${REGISTRY_NAME} on port ${REGISTRY_PORT}"
docker_cmd rm -f "${REGISTRY_NAME}" >/dev/null 2>&1 || true
if ! docker_cmd run -d --rm -p "${REGISTRY_PORT}:5000" --name "${REGISTRY_NAME}" registry:2 \
  >"${RESULTS_DIR}/registry-run.log" 2>&1; then
  cat "${RESULTS_DIR}/registry-run.log" >&2 || true
  die "failed to start local registry container"
fi
if ! wait_for_registry; then
  docker_cmd logs "${REGISTRY_NAME}" >"${RESULTS_DIR}/registry.log" 2>&1 || true
  die "local registry did not become ready on port ${REGISTRY_PORT}; see ${RESULTS_DIR}/registry.log"
fi

SHARD_PATH="${PAYLOAD_DIR}/shards/model-00001-of-00001.safetensors"
log "creating dummy shard at ${SHARD_PATH}"
dd if=/dev/urandom of="${SHARD_PATH}" bs=1048576 count=1 >/dev/null 2>&1
SHARD_DIGEST="sha256:$(sha256_file "${SHARD_PATH}")"
SHARD_SIZE="$(filesize_bytes "${SHARD_PATH}")"

cat > "${PAYLOAD_DIR}/metadata/model.json" <<EOF
{
  "schemaVersion": 1,
  "modelId": "${MODEL_ID}",
  "modelRevision": "v1",
  "framework": "pytorch",
  "format": "safetensors",
  "shards": [
    {
      "name": "model-00001-of-00001.safetensors",
      "digest": "${SHARD_DIGEST}",
      "size": ${SHARD_SIZE},
      "ordinal": 1,
      "kind": "weight"
    }
  ],
  "integrity": {
    "manifestDigest": "resolved-manifest-digest"
  }
}
EOF

SECOND_SHARD_PATH="${PAYLOAD_DIR}/shards/model-b-00001-of-00001.safetensors"
log "creating second dummy shard at ${SECOND_SHARD_PATH}"
dd if=/dev/urandom of="${SECOND_SHARD_PATH}" bs=524288 count=1 >/dev/null 2>&1
SECOND_SHARD_DIGEST="sha256:$(sha256_file "${SECOND_SHARD_PATH}")"
SECOND_SHARD_SIZE="$(filesize_bytes "${SECOND_SHARD_PATH}")"
cat > "${PAYLOAD_DIR}/metadata/model-b.json" <<EOF
{
  "schemaVersion": 1,
  "modelId": "${SECOND_MODEL_ID}",
  "modelRevision": "v1",
  "framework": "pytorch",
  "format": "safetensors",
  "shards": [
    {
      "name": "model-b-00001-of-00001.safetensors",
      "digest": "${SECOND_SHARD_DIGEST}",
      "size": ${SECOND_SHARD_SIZE},
      "ordinal": 1,
      "kind": "weight"
    }
  ],
  "integrity": {
    "manifestDigest": "resolved-manifest-digest"
  }
}
EOF

OCI_REF="localhost:${REGISTRY_PORT}/${MODEL_REPO}:${MODEL_TAG}"
log "pushing artifact ${OCI_REF}"
(
  cd "${PAYLOAD_DIR}"
  oras push --plain-http "${OCI_REF}" \
    --artifact-type application/vnd.oci2gdsd.model.v1 \
    --config "metadata/model.json:application/vnd.oci2gdsd.model.config.v1+json" \
    "shards/model-00001-of-00001.safetensors:application/vnd.oci2gdsd.model.shard.v1+safetensors"
) | tee "${RESULTS_DIR}/oras-push.log" >/dev/null

MODEL_DIGEST="$(oras resolve --plain-http "${OCI_REF}")"
[[ "${MODEL_DIGEST}" == sha256:* ]] || die "failed to resolve digest for ${OCI_REF}"
MODEL_REF="localhost:${REGISTRY_PORT}/${MODEL_REPO}@${MODEL_DIGEST}"
MODEL_KEY="${MODEL_ID}@${MODEL_DIGEST}"
log "resolved model digest: ${MODEL_DIGEST}"

SECOND_OCI_REF="localhost:${REGISTRY_PORT}/${SECOND_MODEL_REPO}:${SECOND_MODEL_TAG}"
log "pushing second artifact ${SECOND_OCI_REF}"
(
  cd "${PAYLOAD_DIR}"
  oras push --plain-http "${SECOND_OCI_REF}" \
    --artifact-type application/vnd.oci2gdsd.model.v1 \
    --config "metadata/model-b.json:application/vnd.oci2gdsd.model.config.v1+json" \
    "shards/model-b-00001-of-00001.safetensors:application/vnd.oci2gdsd.model.shard.v1+safetensors"
) | tee "${RESULTS_DIR}/oras-push-second.log" >/dev/null
SECOND_MODEL_DIGEST="$(oras resolve --plain-http "${SECOND_OCI_REF}")"
[[ "${SECOND_MODEL_DIGEST}" == sha256:* ]] || die "failed to resolve digest for ${SECOND_OCI_REF}"
SECOND_MODEL_REF="localhost:${REGISTRY_PORT}/${SECOND_MODEL_REPO}@${SECOND_MODEL_DIGEST}"
SECOND_MODEL_KEY="${SECOND_MODEL_ID}@${SECOND_MODEL_DIGEST}"
log "resolved second model digest: ${SECOND_MODEL_DIGEST}"

cat > "${WORK_DIR}/local-config.yaml" <<EOF
root: ${ROOT_DIR}
model_root: ${ROOT_DIR}/models
tmp_root: ${ROOT_DIR}/tmp
locks_root: ${ROOT_DIR}/locks
journal_dir: ${ROOT_DIR}/journal
state_db: ${ROOT_DIR}/state.db
registry:
  plain_http: true
retention:
  min_free_bytes: 0
EOF

log "running ensure/status/list/verify/release/gc lifecycle"
run_cli ensure \
  --ref "${MODEL_REF}" \
  --model-id "${MODEL_ID}" \
  --lease-holder "${LEASE_HOLDER}" \
  --wait \
  --json | tee "${RESULTS_DIR}/ensure.json" >/dev/null
jq -e '.status == "READY"' "${RESULTS_DIR}/ensure.json" >/dev/null || die "ensure status assertion failed"
jq -e --arg model "${MODEL_ID}" '.model_id == $model' "${RESULTS_DIR}/ensure.json" >/dev/null || die "ensure model_id assertion failed"
jq -e --arg digest "${MODEL_DIGEST}" '.manifest_digest == $digest' "${RESULTS_DIR}/ensure.json" >/dev/null || die "ensure digest assertion failed"

run_cli ensure \
  --ref "${MODEL_REF}" \
  --model-id "${MODEL_ID}" \
  --lease-holder "${LEASE_HOLDER}" \
  --wait \
  --json | tee "${RESULTS_DIR}/ensure-idempotent.json" >/dev/null
jq -e '.status == "READY"' "${RESULTS_DIR}/ensure-idempotent.json" >/dev/null || die "idempotent ensure assertion failed"

CONCURRENT_HOLDER_A="${LEASE_HOLDER}-concurrent-a"
log "running concurrent ensure validations (same-model and cross-model)"
run_cli ensure \
  --ref "${MODEL_REF}" \
  --model-id "${MODEL_ID}" \
  --lease-holder "${CONCURRENT_HOLDER_A}" \
  --wait \
  --json > "${RESULTS_DIR}/ensure-concurrent-a.json" &
pid_a=$!
run_cli ensure \
  --ref "${SECOND_MODEL_REF}" \
  --model-id "${SECOND_MODEL_ID}" \
  --lease-holder "${SECOND_LEASE_HOLDER}" \
  --wait \
  --json > "${RESULTS_DIR}/ensure-second.json" &
pid_b=$!
wait "${pid_a}"
wait "${pid_b}"
jq -e '.status == "READY"' "${RESULTS_DIR}/ensure-concurrent-a.json" >/dev/null || die "concurrent ensure (same model) assertion failed"
jq -e '.status == "READY"' "${RESULTS_DIR}/ensure-second.json" >/dev/null || die "concurrent ensure (second model) assertion failed"

run_cli status --model-id "${MODEL_ID}" --digest "${MODEL_DIGEST}" --json \
  | tee "${RESULTS_DIR}/status-ready.json" >/dev/null
jq -e '.status == "READY"' "${RESULTS_DIR}/status-ready.json" >/dev/null || die "status READY assertion failed"
jq -e '.active_leases | length >= 2' "${RESULTS_DIR}/status-ready.json" >/dev/null || die "status lease-count assertion failed"

run_cli status --model-id "${SECOND_MODEL_ID}" --digest "${SECOND_MODEL_DIGEST}" --json \
  | tee "${RESULTS_DIR}/status-second-ready.json" >/dev/null
jq -e '.status == "READY"' "${RESULTS_DIR}/status-second-ready.json" >/dev/null || die "second model status READY assertion failed"

run_cli list --json | tee "${RESULTS_DIR}/list-ready.json" >/dev/null
jq -e --arg key "${MODEL_KEY}" 'map(.model_id + "@" + .manifest_digest) | index($key) != null' "${RESULTS_DIR}/list-ready.json" >/dev/null || die "list assertion failed"
jq -e --arg key "${SECOND_MODEL_KEY}" 'map(.model_id + "@" + .manifest_digest) | index($key) != null' "${RESULTS_DIR}/list-ready.json" >/dev/null || die "list second-model assertion failed"

run_cli verify --model-id "${MODEL_ID}" --digest "${MODEL_DIGEST}" --json \
  | tee "${RESULTS_DIR}/verify.json" >/dev/null
jq -e '.status == "READY"' "${RESULTS_DIR}/verify.json" >/dev/null || die "verify assertion failed"

run_cli verify --model-id "${SECOND_MODEL_ID}" --digest "${SECOND_MODEL_DIGEST}" --json \
  | tee "${RESULTS_DIR}/verify-second.json" >/dev/null
jq -e '.status == "READY"' "${RESULTS_DIR}/verify-second.json" >/dev/null || die "second model verify assertion failed"

run_cli profile lint --ref "${MODEL_REF}" --json | tee "${RESULTS_DIR}/profile-lint.json" >/dev/null
jq -e '.valid == true' "${RESULTS_DIR}/profile-lint.json" >/dev/null || die "profile lint assertion failed"

run_cli profile inspect --ref "${MODEL_REF}" --json | tee "${RESULTS_DIR}/profile-inspect.json" >/dev/null
jq -e --arg model "${MODEL_ID}" '.model_id == $model' "${RESULTS_DIR}/profile-inspect.json" >/dev/null || die "profile inspect assertion failed"

run_cli release \
  --model-id "${MODEL_ID}" \
  --digest "${MODEL_DIGEST}" \
  --lease-holder "${CONCURRENT_HOLDER_A}" \
  --json | tee "${RESULTS_DIR}/release-concurrent-a.json" >/dev/null

run_cli release \
  --model-id "${MODEL_ID}" \
  --digest "${MODEL_DIGEST}" \
  --lease-holder "${LEASE_HOLDER}" \
  --json | tee "${RESULTS_DIR}/release.json" >/dev/null
jq -e '.remaining_leases == 0' "${RESULTS_DIR}/release.json" >/dev/null || die "release primary assertion failed"

run_cli release \
  --model-id "${SECOND_MODEL_ID}" \
  --digest "${SECOND_MODEL_DIGEST}" \
  --lease-holder "${SECOND_LEASE_HOLDER}" \
  --json | tee "${RESULTS_DIR}/release-second.json" >/dev/null
jq -e '.remaining_leases == 0' "${RESULTS_DIR}/release-second.json" >/dev/null || die "release second-model assertion failed"

run_cli release \
  --model-id "${MODEL_ID}" \
  --digest "${MODEL_DIGEST}" \
  --lease-holder "${LEASE_HOLDER}" \
  --json | tee "${RESULTS_DIR}/release-idempotent.json" >/dev/null
jq -e '.remaining_leases == 0' "${RESULTS_DIR}/release-idempotent.json" >/dev/null || die "release idempotent assertion failed"

run_cli gc --policy lru_no_lease --min-free-bytes 8000000000000000000 --json \
  | tee "${RESULTS_DIR}/gc.json" >/dev/null
jq -e --arg key "${MODEL_KEY}" '.deleted_models | index($key) != null' "${RESULTS_DIR}/gc.json" >/dev/null || die "gc assertion failed"
jq -e --arg key "${SECOND_MODEL_KEY}" '.deleted_models | index($key) != null' "${RESULTS_DIR}/gc.json" >/dev/null || die "gc second-model assertion failed"

run_cli status --model-id "${MODEL_ID}" --digest "${MODEL_DIGEST}" --json \
  | tee "${RESULTS_DIR}/status-released.json" >/dev/null
jq -e '.status == "RELEASED"' "${RESULTS_DIR}/status-released.json" >/dev/null || die "final status assertion failed"

run_cli status --model-id "${SECOND_MODEL_ID}" --digest "${SECOND_MODEL_DIGEST}" --json \
  | tee "${RESULTS_DIR}/status-second-released.json" >/dev/null
jq -e '.status == "RELEASED"' "${RESULTS_DIR}/status-second-released.json" >/dev/null || die "final second-model status assertion failed"

cat > "${RESULTS_DIR}/summary.txt" <<EOF
local-e2e: success
model_ref=${MODEL_REF}
model_digest=${MODEL_DIGEST}
second_model_ref=${SECOND_MODEL_REF}
second_model_digest=${SECOND_MODEL_DIGEST}
root=${ROOT_DIR}
ensure_duration_ms=$(jq -r '.duration_ms // 0' "${RESULTS_DIR}/ensure.json")
ensure_idempotent_duration_ms=$(jq -r '.duration_ms // 0' "${RESULTS_DIR}/ensure-idempotent.json")
ensure_second_duration_ms=$(jq -r '.duration_ms // 0' "${RESULTS_DIR}/ensure-second.json")
EOF

log "local CLI lifecycle e2e completed successfully"
log "artifacts:"
log "  ${RESULTS_DIR}/ensure.json"
log "  ${RESULTS_DIR}/status-ready.json"
log "  ${RESULTS_DIR}/status-second-ready.json"
log "  ${RESULTS_DIR}/verify.json"
log "  ${RESULTS_DIR}/verify-second.json"
log "  ${RESULTS_DIR}/release.json"
log "  ${RESULTS_DIR}/release-second.json"
log "  ${RESULTS_DIR}/gc.json"
log "  ${RESULTS_DIR}/status-released.json"
log "  ${RESULTS_DIR}/status-second-released.json"
log "  ${RESULTS_DIR}/environment-report.txt"
log "  ${RESULTS_DIR}/summary.txt"
