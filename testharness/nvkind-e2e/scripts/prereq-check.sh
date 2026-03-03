#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

INSTALL_MISSING_PREREQS="${INSTALL_MISSING_PREREQS:-true}"
PREPULL_RUNTIME_IMAGE="${PREPULL_RUNTIME_IMAGE:-true}"

check_runtime_image_toolchain() {
  local image="$1"
  local probe_log="${WORK_DIR}/results/runtime-image-prereq.log"
  local probe='set -eu
command -v python3 >/dev/null || { echo "missing: python3"; exit 31; }
command -v c++ >/dev/null 2>&1 || { echo "missing: c++"; exit 32; }
if [ ! -e /usr/local/cuda/lib64/libcufile.so ] && [ ! -e /usr/local/cuda/lib64/libcufile.so.0 ] && [ ! -e /usr/lib/x86_64-linux-gnu/libcufile.so ]; then
  echo "missing: libcufile"
  exit 33
fi
echo "runtime-image-probe:ok"'

  if [[ "${PREPULL_RUNTIME_IMAGE}" == "true" ]]; then
    log "pre-pulling runtime image ${image}"
    maybe_sudo docker pull "${image}" >/dev/null
  fi

  log "checking runtime image toolchain: ${image}"
  if ! maybe_sudo docker run --rm --privileged --gpus all --user 0:0 \
    "${image}" /bin/sh -lc "${probe}" >"${probe_log}" 2>&1; then
    cat "${probe_log}" >&2 || true
    if grep -q 'missing: c++' "${probe_log}"; then
      die "runtime image is missing c++ (native torch extension cannot build). Use PYTORCH_RUNTIME_IMAGE=nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1 or an equivalent image with compiler toolchain"
    fi
    die "runtime image prerequisite check failed; see ${probe_log}"
  fi
}

check_privileged_assumptions() {
  local qwen_template="${QWEN_HELLO_TEMPLATE}"
  local workload_template="${HARNESS_DIR}/manifests/workload-job.yaml.tpl"

  if ! grep -Eq 'privileged:[[:space:]]*true' "${qwen_template}"; then
    die "qwen template does not declare privileged container securityContext: ${qwen_template}"
  fi
  if ! grep -Eq 'privileged:[[:space:]]*true' "${workload_template}"; then
    die "workload template does not declare privileged container securityContext: ${workload_template}"
  fi
}

log "running nvkind/k3s prerequisite checks"
log "assumption: all GPU/GDS workload containers run privileged"

if [[ "${INSTALL_MISSING_PREREQS}" == "true" ]]; then
  bootstrap_tools
else
  ensure_cmd docker
  ensure_cmd jq
  ensure_cmd gsed
  ensure_cmd curl
  ensure_cmd nvidia-smi
  if [[ "${CLUSTER_MODE}" == "k3s" ]]; then
    ensure_cmd k3s
    ensure_cmd nvidia-ctk
  else
    ensure_cmd kubectl
    ensure_cmd kind
    ensure_cmd nvkind
  fi
fi

if [[ "${CLUSTER_MODE}" == "k3s" ]]; then
  ensure_k3s_nvidia_runtime_prereqs
fi

if ! kube get nodes >/dev/null 2>&1; then
  die "cluster ${CLUSTER_MODE} is not reachable ($(cluster_hint))"
fi

if [[ "${REQUIRE_DIRECT_GDS}" == "true" ]]; then
  if ! check_direct_gds_platform_support; then
    die "REQUIRE_DIRECT_GDS=true but direct-GDS platform preflight failed"
  fi
fi

mkdir -p "${WORK_DIR}/results"
check_runtime_image_toolchain "${PYTORCH_RUNTIME_IMAGE}"
check_privileged_assumptions

log "nvkind/k3s prerequisites are satisfied"
