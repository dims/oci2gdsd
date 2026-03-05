#!/usr/bin/env bash
# shellcheck shell=bash

build_and_load_oci2gdsd_image() {
  local dockerfile="${OCI2GDSD_DOCKERFILE}"
  local docker_target="${OCI2GDSD_DOCKER_TARGET}"
  local force_load="false"
  local enable_gds_build="false"
  if [[ -z "${dockerfile}" ]]; then
    dockerfile="${HARNESS_DIR}/Dockerfile.oci2gdsd"
  fi
  if [[ "${OCI2GDSD_ENABLE_GDS_IMAGE}" == "true" ]]; then
    enable_gds_build="true"
  fi
  if [[ -z "${docker_target}" && "${dockerfile}" == "${HARNESS_DIR}/Dockerfile.oci2gdsd" ]]; then
    if [[ "${enable_gds_build}" == "true" ]]; then
      docker_target="runtime-gds"
    else
      docker_target="runtime"
    fi
  fi
  if [[ "${SKIP_OCI2GDSD_IMAGE_BUILD}" != "true" ]]; then
    [[ -f "${dockerfile}" ]] || die "oci2gdsd dockerfile not found: ${dockerfile}"
    if docker image inspect "${OCI2GDSD_IMAGE}" >/dev/null 2>&1 && ! is_true "${FORCE_OCI2GDSD_IMAGE_REBUILD}"; then
      log "reusing existing oci2gdsd image ${OCI2GDSD_IMAGE}"
    else
      local build_cmd=(docker build -f "${dockerfile}" -t "${OCI2GDSD_IMAGE}" --build-arg "ENABLE_GDS=${enable_gds_build}")
      if [[ -n "${docker_target}" ]]; then
        build_cmd+=(--target "${docker_target}")
      fi
      build_cmd+=("${REPO_ROOT}")
      log "building oci2gdsd image ${OCI2GDSD_IMAGE} using ${dockerfile} (ENABLE_GDS=${enable_gds_build}${docker_target:+, target=${docker_target}})"
      "${build_cmd[@]}"
      force_load="true"
    fi
  else
    log "skipping oci2gdsd image build for ${OCI2GDSD_IMAGE}"
  fi
  if [[ "${SKIP_OCI2GDSD_IMAGE_LOAD}" != "true" ]]; then
    cluster_load_image "${OCI2GDSD_IMAGE}" "${force_load}"
  else
    log "skipping cluster image load for ${OCI2GDSD_IMAGE}"
  fi
}

build_and_load_cli_image_if_needed() {
  if [[ "${E2E_DEPLOY_MODE}" != "daemonset-manifest" ]]; then
    return 0
  fi
  if [[ "${OCI2GDSD_CLI_IMAGE}" == "${OCI2GDSD_IMAGE}" ]]; then
    return 0
  fi
  [[ -f "${OCI2GDSD_CLI_DOCKERFILE}" ]] || die "oci2gdsd CLI dockerfile not found: ${OCI2GDSD_CLI_DOCKERFILE}"
  if docker image inspect "${OCI2GDSD_CLI_IMAGE}" >/dev/null 2>&1; then
    log "reusing existing oci2gdsd CLI image ${OCI2GDSD_CLI_IMAGE}"
  else
    local cli_target="${OCI2GDSD_CLI_DOCKER_TARGET}"
    if [[ -z "${cli_target}" && "${OCI2GDSD_CLI_DOCKERFILE}" == "${HARNESS_DIR}/Dockerfile.oci2gdsd" ]]; then
      cli_target="runtime"
    fi
    local cli_build_cmd=(docker build -f "${OCI2GDSD_CLI_DOCKERFILE}" -t "${OCI2GDSD_CLI_IMAGE}" --build-arg ENABLE_GDS=false)
    if [[ -n "${cli_target}" ]]; then
      cli_build_cmd+=(--target "${cli_target}")
    fi
    cli_build_cmd+=("${REPO_ROOT}")
    log "building oci2gdsd CLI image ${OCI2GDSD_CLI_IMAGE} using ${OCI2GDSD_CLI_DOCKERFILE} (ENABLE_GDS=false${cli_target:+, target=${cli_target}})"
    "${cli_build_cmd[@]}"
  fi
  cluster_load_image "${OCI2GDSD_CLI_IMAGE}"
}

ensure_image_local_or_pull() {
  local image="$1"
  local max_tries="${2:-3}"
  if docker image inspect "${image}" >/dev/null 2>&1; then
    log "using local image ${image}"
    return
  fi
  local tries=0
  until docker pull "${image}"; do
    tries=$((tries + 1))
    if [[ "${tries}" -ge "${max_tries}" ]]; then
      die "failed to pull image after ${max_tries} attempts: ${image}"
    fi
    warn "retrying image pull (${tries}/${max_tries}): ${image}"
    sleep 5
  done
}

build_and_load_qwen_gds_runtime_image() {
  if [[ "${BUILD_QWEN_GDS_RUNTIME_IMAGE}" != "true" ]]; then
    return
  fi
  [[ -f "${QWEN_GDS_RUNTIME_DOCKERFILE}" ]] || die "qwen gds runtime dockerfile not found: ${QWEN_GDS_RUNTIME_DOCKERFILE}"
  log "building qwen gds runtime image ${QWEN_GDS_RUNTIME_IMAGE} using ${QWEN_GDS_RUNTIME_DOCKERFILE}"
  docker build -f "${QWEN_GDS_RUNTIME_DOCKERFILE}" -t "${QWEN_GDS_RUNTIME_IMAGE}" "${REPO_ROOT}"
  cluster_load_image "${QWEN_GDS_RUNTIME_IMAGE}"
  PYTORCH_RUNTIME_IMAGE="${QWEN_GDS_RUNTIME_IMAGE}"
  export PYTORCH_RUNTIME_IMAGE
  log "using qwen gds runtime image for qwen-hello: ${PYTORCH_RUNTIME_IMAGE}"
}

preload_workload_image() {
  if [[ "${PRELOAD_WORKLOAD_IMAGE}" != "true" ]]; then
    log "skipping pre-load for ${WORKLOAD_IMAGE}; cluster will pull image on demand"
    return
  fi
  local max_tries=3
  ensure_image_local_or_pull "${WORKLOAD_IMAGE}" "${max_tries}"
  cluster_load_image "${WORKLOAD_IMAGE}"
  case "${WORKLOAD_RUNTIME}" in
    pytorch)
      if [[ "${PRELOAD_PYTORCH_RUNTIME_IMAGE}" == "true" ]]; then
        ensure_image_local_or_pull "${PYTORCH_RUNTIME_IMAGE}" "${max_tries}"
        cluster_load_image "${PYTORCH_RUNTIME_IMAGE}"
      else
        log "skipping pre-load for ${PYTORCH_RUNTIME_IMAGE}; cluster will pull image on demand"
      fi
      ;;
    tensorrt)
      if [[ "${PRELOAD_TENSORRTLLM_RUNTIME_IMAGE}" == "true" ]]; then
        ensure_image_local_or_pull "${TENSORRTLLM_RUNTIME_IMAGE}" "${max_tries}"
        cluster_load_image "${TENSORRTLLM_RUNTIME_IMAGE}"
      else
        log "skipping pre-load for ${TENSORRTLLM_RUNTIME_IMAGE}; cluster will pull image on demand"
      fi
      ;;
    vllm)
      if [[ "${PRELOAD_VLLM_RUNTIME_IMAGE}" == "true" ]]; then
        ensure_image_local_or_pull "${VLLM_RUNTIME_IMAGE}" "${max_tries}"
        cluster_load_image "${VLLM_RUNTIME_IMAGE}"
      else
        log "skipping pre-load for ${VLLM_RUNTIME_IMAGE}; cluster will pull image on demand"
      fi
      ;;
  esac
}

cluster_load_image() {
  local image="$1"
  local force="${2:-false}"
  if [[ "${force}" != "true" ]] && cluster_image_present "${image}"; then
    log "image already present in k3s containerd: ${image}"
    return 0
  fi
  if [[ "${force}" == "true" ]]; then
    log "forcing image import into k3s containerd: ${image}"
  else
    log "importing image into k3s containerd: ${image}"
  fi
  docker save "${image}" | maybe_sudo k3s ctr -n k8s.io images import -
}

cluster_image_present() {
  local image="$1"
  local refs
  refs="$(maybe_sudo k3s ctr -n k8s.io images ls -q 2>/dev/null || true)"
  [[ -n "${refs}" ]] || return 1
  if printf '%s\n' "${refs}" | grep -Fx -- "${image}" >/dev/null 2>&1; then
    return 0
  fi
  if [[ "${image}" != */* ]]; then
    if printf '%s\n' "${refs}" | grep -Fx -- "docker.io/library/${image}" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

build_packager_image() {
  log "building packager image ${PACKAGER_IMAGE}"
  docker build -t "${PACKAGER_IMAGE}" "${REPO_ROOT}/models/qwen3-oci-modelprofile-v1"
}
