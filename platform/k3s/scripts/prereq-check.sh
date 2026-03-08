#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/../../lib" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=../../lib/prereq.sh
source "${LIB_DIR}/prereq.sh"

INSTALL_MISSING_PREREQS="${INSTALL_MISSING_PREREQS:-true}"
PREPULL_RUNTIME_IMAGE="${PREPULL_RUNTIME_IMAGE:-true}"

check_runtime_image_toolchain() {
  local image="$1"
  local probe_log="${RESULTS_DIR}/runtime-image-prereq.log"
  if [[ "${WORKLOAD_RUNTIME}" == "tensorrt" ]]; then
    local probe='set -eu
command -v python3 >/dev/null || { echo "missing: python3"; exit 41; }
command -v trtllm-build >/dev/null || { echo "missing: trtllm-build"; exit 42; }
python3 -c "from tensorrt_llm.runtime import ModelRunnerCpp" >/dev/null 2>&1 || { echo "missing: tensorrt_llm.runtime.ModelRunnerCpp"; exit 43; }
command -v c++ >/dev/null 2>&1 || { echo "missing: c++"; exit 45; }
python3 -c "from torch.utils.cpp_extension import load_inline" >/dev/null 2>&1 || { echo "missing: torch cpp extension"; exit 46; }
if [ ! -e /usr/local/cuda/lib64/libcufile.so ] && [ ! -e /usr/local/cuda/lib64/libcufile.so.0 ] && [ ! -e /usr/lib/x86_64-linux-gnu/libcufile.so ]; then
  echo "missing: libcufile"
  exit 44
fi
echo "runtime-image-probe:ok"'
    if [[ "${PREPULL_RUNTIME_IMAGE}" == "true" ]]; then
      log "pre-pulling runtime image ${image}"
      maybe_sudo docker pull "${image}" >/dev/null
    fi
    log "checking TensorRT runtime image toolchain: ${image}"
    if ! maybe_sudo docker run --rm --privileged --gpus all --user 0:0 \
      "${image}" /bin/sh -lc "${probe}" >"${probe_log}" 2>&1; then
      cat "${probe_log}" >&2 || true
      die "TensorRT runtime image prerequisite check failed; see ${probe_log}"
    fi
    return 0
  fi
  if [[ "${WORKLOAD_RUNTIME}" == "vllm" ]]; then
    local probe='set -eu
command -v python3 >/dev/null || { echo "missing: python3"; exit 51; }
command -v c++ >/dev/null 2>&1 || { echo "missing: c++"; exit 52; }
python3 -c "import vllm; from vllm import LLM, SamplingParams" >/dev/null 2>&1 || { echo "missing: vllm python package"; exit 53; }
python3 -c "import safetensors" >/dev/null 2>&1 || { echo "missing: safetensors python package"; exit 54; }
python3 -c "import fastsafetensors" >/dev/null 2>&1 || echo "warn: fastsafetensors missing; workload will use delegate_load_format=safetensors"
if [ ! -e /usr/local/cuda/lib64/libcufile.so ] && [ ! -e /usr/local/cuda/lib64/libcufile.so.0 ] && [ ! -e /usr/lib/x86_64-linux-gnu/libcufile.so ]; then
  echo "missing: libcufile"
  exit 55
fi
echo "runtime-image-probe:ok"'
    if [[ "${PREPULL_RUNTIME_IMAGE}" == "true" ]]; then
      log "pre-pulling runtime image ${image}"
      maybe_sudo docker pull "${image}" >/dev/null
    fi
    log "checking vLLM runtime image toolchain: ${image}"
    if ! maybe_sudo docker run --rm --privileged --gpus all --user 0:0 \
      "${image}" /bin/sh -lc "${probe}" >"${probe_log}" 2>&1; then
      cat "${probe_log}" >&2 || true
      die "vLLM runtime image prerequisite check failed; see ${probe_log}"
    fi
    return 0
  fi

  prereq_check_runtime_image_toolchain \
    "${image}" \
    "${probe_log}" \
    "${PREPULL_RUNTIME_IMAGE}"
}

check_manifest_contracts() {
  local validator="${SCRIPT_DIR}/validate-runtime-contract.sh"
  [[ -x "${validator}" ]] || die "runtime contract validator is missing or not executable: ${validator}"

  "${validator}" \
    --runtime "${WORKLOAD_RUNTIME}" \
    --include-qwen \
    --report "${RESULTS_DIR}/runtime-contract-report.json"
}

prereq_stage_base_common() {
  prereq_stage_begin "base-common"
  if [[ "${INSTALL_MISSING_PREREQS}" == "true" ]]; then
    bootstrap_tools
  else
    ensure_cmd docker
    ensure_cmd jq
    ensure_cmd gsed
    ensure_cmd curl
    ensure_cmd nvidia-smi
    ensure_cmd k3s
    ensure_cmd nvidia-ctk
  fi
  prereq_ensure_docker_access
  check_storage_prereqs
  prereq_stage_end "base-common"
}

prereq_stage_host_direct_gds() {
  prereq_stage_begin "host-direct-gds"
  if [[ "${REQUIRE_DIRECT_GDS}" == "true" ]]; then
    if ! check_direct_gds_platform_support; then
      die "REQUIRE_DIRECT_GDS=true but direct-GDS platform preflight failed"
    fi
  fi
  prereq_stage_end "host-direct-gds"
}

prereq_stage_k3s_cluster() {
  prereq_stage_begin "k3s-cluster"
  ensure_k3s_nvidia_runtime_prereqs
  if ! kube get nodes >/dev/null 2>&1; then
    die "k3s cluster is not reachable ($(cluster_hint))"
  fi
  prereq_stage_end "k3s-cluster"
}

prereq_stage_k3s_runtime() {
  prereq_stage_begin "k3s-runtime"
  mkdir -p "${RESULTS_DIR}"
  check_runtime_image_toolchain "${WORKLOAD_RUNTIME_IMAGE}"
  check_manifest_contracts
  write_environment_report
  prereq_stage_end "k3s-runtime"
}

log "running k3s prerequisite checks"
log "assumption: all GPU/GDS workload containers run privileged"
prereq_stage_base_common
prereq_stage_host_direct_gds
prereq_stage_k3s_cluster
prereq_stage_k3s_runtime
log "k3s prerequisites are satisfied"
