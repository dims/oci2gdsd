#!/usr/bin/env bash
set -euo pipefail

PAYLOAD_DIR=""
OCI_REF=""
ARTIFACT_TYPE="application/vnd.oci2gdsd.model.v1"
CONFIG_MEDIA_TYPE="application/vnd.oci2gdsd.model.config.v1+json"
WEIGHT_MEDIA_TYPE="application/vnd.oci2gdsd.model.shard.v1+safetensors"
RUNTIME_FILE_MEDIA_TYPE="application/vnd.oci2gdsd.model.file.v1"
OUT_DIR=""
PLAIN_HTTP="false"

usage() {
  cat <<EOF
usage: $0 --payload-dir <dir> --oci-ref <registry/repo:tag> [--out-dir <dir>] [--plain-http]

Pushes the payload as an OCI artifact with:
  artifactType=${ARTIFACT_TYPE}
  config mediaType=${CONFIG_MEDIA_TYPE}
  weight mediaType=${WEIGHT_MEDIA_TYPE}
  runtime file mediaType=${RUNTIME_FILE_MEDIA_TYPE}
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

mapfile -t SHARDS < <(find "${PAYLOAD_DIR}/shards" -maxdepth 1 -type f | sort)
if [[ "${#SHARDS[@]}" -eq 0 ]]; then
  echo "no artifact files found in ${PAYLOAD_DIR}/shards" >&2
  exit 1
fi

declare -a PUSH_ARGS
for shard in "${SHARDS[@]}"; do
  base="$(basename "${shard}")"
  media_type="${RUNTIME_FILE_MEDIA_TYPE}"
  if [[ "${base}" == *.safetensors ]]; then
    media_type="${WEIGHT_MEDIA_TYPE}"
  fi
  PUSH_ARGS+=("${shard}:${media_type}")
  echo "including artifact ${base} (${media_type})"
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
