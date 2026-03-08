#!/usr/bin/env bash
# shellcheck shell=bash

ensure_k3s_cluster_ready() {
  if [[ "${K3S_USE_SUDO}" == "true" && "$(id -u)" -ne 0 ]]; then
    maybe_sudo systemctl enable --now k3s >/dev/null 2>&1 || true
  fi
  local tries=0
  local max_tries=30
  until kube get nodes >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [[ "${tries}" -ge "${max_tries}" ]]; then
      die "k3s API did not become queryable after ${max_tries} attempts"
    fi
    warn "waiting for k3s API/RBAC bootstrap (${tries}/${max_tries})"
    sleep 5
  done
  kube wait --for=condition=Ready nodes --all --timeout=300s
  kube get nodes -o wide
}

install_gpu_operator() {
  log "installing GPU Operator (helm chart version: ${GPU_OPERATOR_CHART_VERSION})"
  helm_kube repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
  helm_kube repo update >/dev/null
  helm_kube upgrade -i \
    --namespace gpu-operator \
    --create-namespace \
    --version "${GPU_OPERATOR_CHART_VERSION}" \
    --set cdi.enabled=false \
    --set driver.enabled=false \
    --set toolkit.enabled=false \
    --set dcgmExporter.enabled=false \
    --set nfd.enabled=true \
    --wait --timeout=600s \
    gpu-operator nvidia/gpu-operator
  kube -n gpu-operator rollout status daemonset -l app=nvidia-device-plugin-daemonset --timeout=300s || true
  kube -n gpu-operator get pods || true
}

verify_gpu_pod() {
  log "verifying GPU in a pod"
  kube -n kube-system delete pod/gpu-smoke --ignore-not-found >/dev/null 2>&1 || true
  kube apply -f "${HARNESS_DIR}/manifests/gpu-smoke-pod.yaml"
  kube -n kube-system wait pod/gpu-smoke --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s
  kube -n kube-system logs pod/gpu-smoke
  kube -n kube-system delete pod/gpu-smoke --ignore-not-found >/dev/null
}

node_has_allocatable_gpu() {
  local values
  values="$(kube get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null || true)"
  printf '%s\n' "${values}" | grep -Eq '^[1-9][0-9]*$'
}

ensure_gpu_capacity() {
  if node_has_allocatable_gpu; then
    return 0
  fi
  if ! is_true "${AUTO_INSTALL_GPU_OPERATOR}"; then
    die "nvidia.com/gpu is not allocatable and AUTO_INSTALL_GPU_OPERATOR=false"
  fi
  log "nvidia.com/gpu allocatable is missing; installing GPU Operator"
  install_gpu_operator
  local tries=0
  local max_tries=30
  until node_has_allocatable_gpu; do
    tries=$((tries + 1))
    if [[ "${tries}" -ge "${max_tries}" ]]; then
      kube get nodes -o wide || true
      kube -n gpu-operator get pods -o wide || true
      die "GPU allocatable did not appear after GPU Operator install"
    fi
    sleep 4
  done
}

gpu_operator_device_plugin_ready() {
  local ready desired
  ready="$(kube -n gpu-operator get daemonset -l app=nvidia-device-plugin-daemonset -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null || true)"
  desired="$(kube -n gpu-operator get daemonset -l app=nvidia-device-plugin-daemonset -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null || true)"
  [[ -n "${ready}" && -n "${desired}" && "${ready}" == "${desired}" && "${desired}" != "0" ]]
}
