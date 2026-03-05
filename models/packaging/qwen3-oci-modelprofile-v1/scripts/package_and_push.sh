#!/usr/bin/env bash
set -euo pipefail

HF_REPO="Qwen/Qwen3-0.6B"
HF_REVISION="main"
MODEL_ID="qwen3-0.6b"
OCI_REF=""
WORK_DIR="/work"
PLAIN_HTTP="false"

usage() {
  cat <<EOF
usage: $0 --oci-ref <registry/repo:tag> [options]

options:
  --hf-repo <repo>         default: ${HF_REPO}
  --hf-revision <rev>      default: ${HF_REVISION}
  --model-id <id>          default: ${MODEL_ID}
  --work-dir <dir>         default: ${WORK_DIR}
  --plain-http             use HTTP for registry operations (for local test registries)

Environment:
  HF_TOKEN                 optional Hugging Face access token
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hf-repo)
      HF_REPO="$2"
      shift 2
      ;;
    --hf-revision)
      HF_REVISION="$2"
      shift 2
      ;;
    --model-id)
      MODEL_ID="$2"
      shift 2
      ;;
    --oci-ref)
      OCI_REF="$2"
      shift 2
      ;;
    --work-dir)
      WORK_DIR="$2"
      shift 2
      ;;
    --plain-http)
      PLAIN_HTTP="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${OCI_REF}" ]]; then
  usage
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(realpath "${WORK_DIR}")"
SNAPSHOT_DIR="${WORK_DIR}/snapshot"
PAYLOAD_DIR="${WORK_DIR}/payload"
OUTPUT_DIR="${WORK_DIR}/output"

rm -rf "${SNAPSHOT_DIR}" "${PAYLOAD_DIR}" "${OUTPUT_DIR}"
mkdir -p "${SNAPSHOT_DIR}" "${PAYLOAD_DIR}" "${OUTPUT_DIR}"

python3 "${SCRIPT_DIR}/fetch_hf_snapshot.py" \
  --hf-repo "${HF_REPO}" \
  --hf-revision "${HF_REVISION}" \
  --out-dir "${SNAPSHOT_DIR}"

python3 "${SCRIPT_DIR}/prepare_payload.py" \
  --source-dir "${SNAPSHOT_DIR}" \
  --payload-dir "${PAYLOAD_DIR}" \
  --model-id "${MODEL_ID}" \
  --model-revision "${HF_REVISION}" \
  --hf-repo "${HF_REPO}" \
  --framework "transformers" \
  --format "safetensors"

if [[ "${PLAIN_HTTP}" == "true" ]]; then
  "${SCRIPT_DIR}/push_with_oras.sh" \
    --payload-dir "${PAYLOAD_DIR}" \
    --oci-ref "${OCI_REF}" \
    --out-dir "${OUTPUT_DIR}" \
    --plain-http
else
  "${SCRIPT_DIR}/push_with_oras.sh" \
    --payload-dir "${PAYLOAD_DIR}" \
    --oci-ref "${OCI_REF}" \
    --out-dir "${OUTPUT_DIR}"
fi

echo
echo "done"
echo "manifest descriptor: ${OUTPUT_DIR}/manifest-descriptor.json"
