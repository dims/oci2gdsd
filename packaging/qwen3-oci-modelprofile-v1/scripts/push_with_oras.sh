#!/usr/bin/env bash
set -euo pipefail

PAYLOAD_DIR=""
OCI_REF=""
ARTIFACT_TYPE="application/vnd.acme.model.v1"
CONFIG_MEDIA_TYPE="application/vnd.acme.model.config.v1+json"
SHARD_MEDIA_TYPE="application/vnd.acme.model.shard.v1+safetensors"
OUT_DIR=""
PLAIN_HTTP="false"

usage() {
  cat <<EOF
usage: $0 --payload-dir <dir> --oci-ref <registry/repo:tag> [--out-dir <dir>] [--plain-http]

Pushes the payload as an OCI artifact with:
  artifactType=${ARTIFACT_TYPE}
  config mediaType=${CONFIG_MEDIA_TYPE}
  shard mediaType=${SHARD_MEDIA_TYPE}
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --payload-dir)
      PAYLOAD_DIR="$2"
      shift 2
      ;;
    --oci-ref)
      OCI_REF="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
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

if [[ -z "${PAYLOAD_DIR}" || -z "${OCI_REF}" ]]; then
  usage
  exit 1
fi

if ! command -v oras >/dev/null 2>&1; then
  echo "oras is required in PATH" >&2
  exit 1
fi

PAYLOAD_DIR="$(realpath "${PAYLOAD_DIR}")"
if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="${PAYLOAD_DIR}"
fi
mkdir -p "${OUT_DIR}"

CONFIG_PATH="${PAYLOAD_DIR}/metadata/model-config.json"
if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "missing model config: ${CONFIG_PATH}" >&2
  exit 1
fi

mapfile -t SHARDS < <(find "${PAYLOAD_DIR}/shards" -maxdepth 1 -type f -name '*.safetensors' | sort)
if [[ "${#SHARDS[@]}" -eq 0 ]]; then
  echo "no shard files found in ${PAYLOAD_DIR}/shards" >&2
  exit 1
fi

declare -a PUSH_ARGS
for shard in "${SHARDS[@]}"; do
  base="$(basename "${shard}")"
  PUSH_ARGS+=("${shard}:${SHARD_MEDIA_TYPE}")
  echo "including shard ${base}"
done

declare -a ORAS_COMMON_ARGS
if [[ "${PLAIN_HTTP}" == "true" ]]; then
  ORAS_COMMON_ARGS+=(--plain-http)
fi

echo "pushing OCI artifact ${OCI_REF}"
oras push "${OCI_REF}" \
  "${ORAS_COMMON_ARGS[@]}" \
  --disable-path-validation \
  --artifact-type "${ARTIFACT_TYPE}" \
  --config "${CONFIG_PATH}:${CONFIG_MEDIA_TYPE}" \
  "${PUSH_ARGS[@]}"

echo "fetching descriptor for ${OCI_REF}"
oras manifest fetch "${ORAS_COMMON_ARGS[@]}" --descriptor "${OCI_REF}" > "${OUT_DIR}/manifest-descriptor.json"
cat "${OUT_DIR}/manifest-descriptor.json"
