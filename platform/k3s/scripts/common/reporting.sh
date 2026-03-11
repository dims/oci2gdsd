#!/usr/bin/env bash
# shellcheck shell=bash

write_environment_report() {
  if [[ "${RECORD_ENVIRONMENT_REPORT}" != "true" ]]; then
    return 0
  fi
  mkdir -p "${RESULTS_DIR}"
  local out="${RESULTS_DIR}/environment-report.txt"
  {
    echo "# k3s-e2e environment $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "cluster_mode=k3s"
    echo "workload_runtime=${WORKLOAD_RUNTIME}"
    echo "model_id=${MODEL_ID}"
    echo "model_digest=${MODEL_DIGEST:-}"
    echo "runtime_image=${WORKLOAD_RUNTIME_IMAGE}"
    echo "workload_image=${WORKLOAD_IMAGE}"
    echo "oci2gdsd_image=${OCI2GDSD_IMAGE}"
    echo "strict=${OCI2GDS_STRICT}"
    echo "probe_strict=${OCI2GDS_PROBE_STRICT}"
    echo "force_no_compat=${OCI2GDS_FORCE_NO_COMPAT}"
    echo "require_direct_gds=${REQUIRE_DIRECT_GDS}"
    echo "docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
    echo "kernel=$(uname -r)"
    echo "---- nvidia-smi ----"
    nvidia-smi || true
    echo "---- k3s versions ----"
    k3s --version || true
    kube version -o yaml || true
    echo "---- gpu operator ----"
    echo "gpu_operator_chart_version=${GPU_OPERATOR_CHART_VERSION}"
    helm_kube list -n gpu-operator || true
    kube -n gpu-operator get pods -o wide || true
    echo "---- node gpu allocatable ----"
    kube get nodes -o custom-columns=NAME:.metadata.name,ALLOC:.status.allocatable.nvidia\\.com/gpu,CAP:.status.capacity.nvidia\\.com/gpu || true
    echo "---- runtime image digest ----"
    docker image inspect "${WORKLOAD_RUNTIME_IMAGE}" --format '{{json .RepoDigests}}' 2>/dev/null || true
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

runtime_drift_checkpoint() {
  local label="$1"
  if [[ "${RUNTIME_DRIFT_CHECKPOINTS}" != "true" ]]; then
    return 0
  fi
  log "runtime drift checkpoint: ${label}"
  if ! node_has_allocatable_gpu; then
    die "runtime drift check failed (${label}): nvidia.com/gpu allocatable is missing"
  fi
  if ! gpu_operator_device_plugin_ready; then
    kube -n gpu-operator get daemonset -l app=nvidia-device-plugin-daemonset -o wide || true
    die "runtime drift check failed (${label}): nvidia-device-plugin daemonset is not ready"
  fi
  if [[ ! -d /run/udev ]]; then
    die "runtime drift check failed (${label}): /run/udev missing on host"
  fi
  if ! ls /dev/nvidia-fs* >/dev/null 2>&1; then
    warn "runtime drift check (${label}): /dev/nvidia-fs* missing; relying on strict functional direct-path probes"
  fi
  if [[ "${REQUIRE_DIRECT_GDS}" == "true" ]] && ! check_direct_gds_platform_support; then
    die "runtime drift check failed (${label}): direct GDS platform support check failed"
  fi
}

validate_local_gds_loader() {
  if [[ "${VALIDATE_LOCAL_GDS}" != "true" ]]; then
    log "skipping local GDS validation"
    return
  fi
  ensure_go_path
  mkdir -p "${RESULTS_DIR}"
  local bin_path="${WORK_DIR}/oci2gdsd-gds"
  local gds_root="${WORK_DIR}/gds-root"
  local model_path="${gds_root}/models/demo/sha256-1111111111111111111111111111111111111111111111111111111111111111"
  local cuda_build_env cuda_include_dir cuda_ldflags cuda_runtime_library_path
  mapfile -t cuda_build_env < <(resolve_local_gds_cuda_build_env)
  cuda_include_dir="${cuda_build_env[0]:-}"
  cuda_ldflags="${cuda_build_env[1]:-}"
  cuda_runtime_library_path="${cuda_build_env[2]:-}"
  [[ -n "${cuda_include_dir}" ]] || die "failed to resolve CUDA include directory for local GDS validation"
  [[ -n "${cuda_ldflags}" ]] || die "failed to resolve CUDA linker flags for local GDS validation"
  [[ -n "${cuda_runtime_library_path}" ]] || die "failed to resolve CUDA runtime library path for local GDS validation"
  log "building local oci2gdsd binary with -tags gds for preflight validation (cuda_include=${cuda_include_dir})"
  (
    cd "${REPO_ROOT}"
    CGO_ENABLED=1 \
      CGO_CFLAGS="-I${cuda_include_dir}" \
      CGO_LDFLAGS="${cuda_ldflags}" \
      go build -buildvcs=false -tags gds -o "${bin_path}" ./cmd/oci2gdsd
  )
  env LD_LIBRARY_PATH="${cuda_runtime_library_path}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "${bin_path}" --root "${gds_root}" --target-root "${gds_root}/models" gpu devices --json > "${RESULTS_DIR}/gpu-devices.json"
  local device_uuid
  device_uuid="$(jq -r '.[0].uuid // empty' "${RESULTS_DIR}/gpu-devices.json")"
  if [[ -z "${device_uuid}" ]]; then
    die "local GDS device discovery returned no devices; see ${RESULTS_DIR}/gpu-devices.json"
  fi
  env LD_LIBRARY_PATH="${cuda_runtime_library_path}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "${bin_path}" --root "${gds_root}" --target-root "${gds_root}/models" gpu probe --device-uuid "${device_uuid}" --json > "${RESULTS_DIR}/gpu-probe.json"
  if ! jq -e '.available == true' "${RESULTS_DIR}/gpu-probe.json" >/dev/null; then
    die "local GDS probe failed; see ${RESULTS_DIR}/gpu-probe.json"
  fi

  mkdir -p "${model_path}/shards" "${model_path}/metadata"
  dd if=/dev/zero of="${model_path}/shards/weights-00001.safetensors" bs=4096 count=1 status=none
  printf "{}\n" > "${model_path}/shards/config.json"
  local w_digest r_digest w_size r_size
  w_digest="$(sha256sum "${model_path}/shards/weights-00001.safetensors" | awk '{print $1}')"
  r_digest="$(sha256sum "${model_path}/shards/config.json" | awk '{print $1}')"
  w_size="$(stat -c %s "${model_path}/shards/weights-00001.safetensors")"
  r_size="$(stat -c %s "${model_path}/shards/config.json")"
  render_template "${HARNESS_DIR}/manifests/local-gds-model.json.tpl" "${model_path}/metadata/model.json" \
    "W_DIGEST=${w_digest}" \
    "W_SIZE=${w_size}" \
    "R_DIGEST=${r_digest}" \
    "R_SIZE=${r_size}"
  printf "ok\n" > "${model_path}/READY"

  env LD_LIBRARY_PATH="${cuda_runtime_library_path}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "${bin_path}" --root "${gds_root}" --target-root "${gds_root}/models" \
    gpu load --path "${model_path}" --mode benchmark --device-uuid "${device_uuid}" --chunk-bytes 4096 --strict --json > "${RESULTS_DIR}/gpu-load-benchmark.json"
  if ! jq -e '.status == "READY"' "${RESULTS_DIR}/gpu-load-benchmark.json" >/dev/null; then
    die "local GDS benchmark load failed; see ${RESULTS_DIR}/gpu-load-benchmark.json"
  fi
  if ! jq -e '.files | length == 1' "${RESULTS_DIR}/gpu-load-benchmark.json" >/dev/null; then
    die "expected exactly one weight shard to be loaded; see ${RESULTS_DIR}/gpu-load-benchmark.json"
  fi
  if ! jq -e '.files[0].direct == true' "${RESULTS_DIR}/gpu-load-benchmark.json" >/dev/null; then
    die "expected direct=true in local GDS benchmark result; see ${RESULTS_DIR}/gpu-load-benchmark.json"
  fi
}
