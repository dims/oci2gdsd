#!/usr/bin/env bash
# shellcheck shell=bash

strip_go_prefix() {
  local version="$1"
  version="${version//$'\r'/}"
  version="${version#go}"
  echo "${version}"
}

require_linux_host() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    die "this harness currently supports Linux hosts (Brev/Ubuntu expected)"
  fi
}

ensure_apt_available() {
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found; install required dependencies manually or run on Ubuntu/Debian"
}

install_go_if_missing() {
  if command -v go >/dev/null 2>&1; then
    local current
    current="$(strip_go_prefix "$(go version 2>/dev/null | awk '{print $3}')")"
    if [[ -n "${current}" ]]; then
      local older
      older="$(printf '%s\n%s\n' "${current}" "${GO_VERSION}" | sort -V | head -n1)"
      if [[ "${older}" != "${current}" || "${current}" == "${GO_VERSION}" ]]; then
        return
      fi
      log "upgrading Go from ${current} to ${GO_VERSION}"
    fi
  else
    log "installing Go ${GO_VERSION}"
  fi
  curl -fsSL -o "/tmp/go${GO_VERSION}.linux-amd64.tar.gz" "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
  maybe_sudo rm -rf /usr/local/go
  maybe_sudo tar -C /usr/local -xzf "/tmp/go${GO_VERSION}.linux-amd64.tar.gz"
  export PATH="/usr/local/go/bin:${PATH}"
}

ensure_go_path() {
  if [[ -x /usr/local/go/bin/go ]]; then
    local preferred
    preferred="$(strip_go_prefix "$(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}')")"
    if ! command -v go >/dev/null 2>&1; then
      export PATH="/usr/local/go/bin:${PATH}"
      return
    fi
    local current
    current="$(strip_go_prefix "$(go version 2>/dev/null | awk '{print $3}')")"
    if [[ -n "${preferred}" && -n "${current}" ]]; then
      local older
      older="$(printf '%s\n%s\n' "${current}" "${preferred}" | sort -V | head -n1)"
      if [[ "${older}" == "${current}" && "${current}" != "${preferred}" ]]; then
        export PATH="/usr/local/go/bin:${PATH}"
      fi
    fi
  fi
}

install_kubectl_if_missing() {
  if command -v kubectl >/dev/null 2>&1; then
    return
  fi
  log "installing kubectl v${KUBECTL_VERSION}"
  curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  chmod +x /tmp/kubectl
  maybe_sudo mv /tmp/kubectl /usr/local/bin/kubectl
}

install_helm_if_missing() {
  if command -v helm >/dev/null 2>&1; then
    return
  fi
  log "installing helm v${HELM_VERSION}"
  local tarball="/tmp/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
  curl -fsSL -o "${tarball}" "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
  tar -xzf "${tarball}" -C /tmp
  maybe_sudo mv /tmp/linux-amd64/helm /usr/local/bin/helm
  maybe_sudo chmod +x /usr/local/bin/helm
}

install_jq_if_missing() {
  if command -v jq >/dev/null 2>&1; then
    return
  fi
  ensure_apt_available
  log "installing jq"
  maybe_sudo apt-get update -y >/dev/null
  maybe_sudo apt-get install -y jq >/dev/null
}

install_gsed_if_missing() {
  if command -v gsed >/dev/null 2>&1; then
    return
  fi
  if command -v sed >/dev/null 2>&1; then
    warn "gsed not found; creating compatibility shim via /usr/local/bin/gsed"
    maybe_sudo ln -sf "$(command -v sed)" /usr/local/bin/gsed
  fi
}

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1; then
    return
  fi
  ensure_apt_available
  log "installing docker.io"
  maybe_sudo apt-get update -y
  maybe_sudo apt-get install -y docker.io
  maybe_sudo systemctl enable --now docker
  maybe_sudo usermod -aG docker "$(id -un)" || true
}

ensure_docker_access() {
  if docker info >/dev/null 2>&1; then
    return
  fi
  if maybe_sudo docker info >/dev/null 2>&1; then
    warn "docker is installed but current user cannot access it yet; using sudo docker shim for this run"
    local shim_dir="${WORK_DIR}/bin"
    mkdir -p "${shim_dir}"
    cat > "${shim_dir}/docker" <<'EOF'
#!/usr/bin/env bash
exec sudo docker "$@"
EOF
    chmod +x "${shim_dir}/docker"
    export PATH="${shim_dir}:${PATH}"
    return
  fi
  die "docker daemon is not reachable"
}

install_nvidia_ctk_if_missing() {
  if command -v nvidia-ctk >/dev/null 2>&1; then
    return
  fi
  ensure_apt_available
  log "installing nvidia-container-toolkit"
  maybe_sudo apt-get update -y
  maybe_sudo apt-get install -y curl gnupg
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    maybe_sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    gsed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    maybe_sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  maybe_sudo apt-get update -y
  maybe_sudo apt-get install -y nvidia-container-toolkit
}

kubeadm_cluster_conflicts_with_k3s() {
  if ! command -v kubeadm >/dev/null 2>&1; then
    return 1
  fi
  if maybe_sudo systemctl is-active --quiet kubelet; then
    return 0
  fi
  if maybe_sudo test -d /etc/kubernetes/manifests; then
    return 0
  fi
  if maybe_sudo ss -ltn | grep -qE '[[:space:]]:6443[[:space:]]'; then
    return 0
  fi
  return 1
}

cleanup_kubeadm_static_pods() {
  if ! command -v crictl >/dev/null 2>&1; then
    return 0
  fi
  local name id
  for name in kube-apiserver kube-controller-manager kube-scheduler etcd; do
    while IFS= read -r id; do
      [[ -n "${id}" ]] || continue
      maybe_sudo crictl stop "${id}" >/dev/null 2>&1 || true
      maybe_sudo crictl rm -f "${id}" >/dev/null 2>&1 || true
    done < <(maybe_sudo crictl ps -a --name "${name}" -q 2>/dev/null || true)
  done
}

ensure_k3s_port_free() {
  local tries=0
  while maybe_sudo ss -ltn | grep -qE '[[:space:]]:6443[[:space:]]'; do
    tries=$((tries + 1))
    if [[ "${tries}" -ge 20 ]]; then
      maybe_sudo ss -ltnp | grep ':6443' >&2 || true
      die "port 6443 is still occupied after kubeadm reset; stop the conflicting Kubernetes control plane and retry"
    fi
    sleep 2
  done
}

reset_conflicting_kubeadm_cluster_if_present() {
  if ! kubeadm_cluster_conflicts_with_k3s; then
    return 0
  fi
  log "detected preinstalled kubeadm Kubernetes services; resetting them before installing k3s"
  maybe_sudo kubeadm reset -f
  maybe_sudo systemctl disable --now kubelet >/dev/null 2>&1 || true
  cleanup_kubeadm_static_pods
  ensure_k3s_port_free
}

install_k3s_if_missing() {
  if command -v k3s >/dev/null 2>&1; then
    return
  fi
  reset_conflicting_kubeadm_cluster_if_present
  log "installing k3s ${K3S_VERSION}"
  local install_exec
  install_exec="server --write-kubeconfig-mode=644 --disable=traefik --node-name=$(hostname)"
  if [[ -r /etc/rancher/k3s/config.yaml ]] && grep -Eq '^[[:space:]]*data-dir[[:space:]]*:' /etc/rancher/k3s/config.yaml; then
    install_exec="${install_exec} --config /etc/rancher/k3s/config.yaml"
  fi
  curl -sfL https://get.k3s.io | \
    maybe_sudo env \
      INSTALL_K3S_VERSION="${K3S_VERSION}" \
      INSTALL_K3S_EXEC="${install_exec}" \
      sh -
}

install_gds_tools_if_missing() {
  if gdscheck_binary >/dev/null 2>&1; then
    return
  fi
  ensure_apt_available
  log "installing GPUDirect Storage user-space tools (gdscheck)"

  local repo_list="/etc/apt/sources.list.d/cuda-ubuntu2204-x86_64.list"
  if ! maybe_sudo test -f "${repo_list}"; then
    local keyring="/tmp/cuda-keyring_1.1-1_all.deb"
    curl -fsSL -o "${keyring}" \
      "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb"
    maybe_sudo dpkg -i "${keyring}" >/dev/null
  fi

  maybe_sudo apt-get update -y

  local pkg
  for pkg in nvidia-gds gds-tools-12-8 gds-tools-12-6 gds-tools-12-5; do
    if maybe_sudo apt-get install -y "${pkg}"; then
      if gdscheck_binary >/dev/null 2>&1; then
        return
      fi
    fi
  done

  die "failed to install gdscheck automatically; install nvidia-gds (or gds-tools) manually"
}

bootstrap_tools() {
  require_linux_host
  install_go_if_missing
  ensure_go_path
  install_kubectl_if_missing
  install_helm_if_missing
  install_jq_if_missing
  install_gsed_if_missing
  install_docker_if_missing
  ensure_docker_access
  install_nvidia_ctk_if_missing
  if [[ "${REQUIRE_DIRECT_GDS}" == "true" ]]; then
    install_gds_tools_if_missing
  fi
  install_k3s_if_missing
  if [[ "${VALIDATE_LOCAL_GDS:-false}" == "true" ]]; then
    ensure_local_gds_cuda_dev_prereqs
  fi
  ensure_cmd nvidia-smi
}

nvidia_runtime_wrapper_config_file() {
  local runtime_bin resolved candidate config_path
  runtime_bin="$(command -v nvidia-container-runtime 2>/dev/null || true)"
  resolved="$(readlink -f "${runtime_bin}" 2>/dev/null || true)"

  for candidate in "${runtime_bin}" "${resolved}" "/usr/local/nvidia/toolkit/nvidia-container-runtime"; do
    [[ -n "${candidate}" && -f "${candidate}" ]] || continue
    config_path="$(grep -Eo 'NVIDIA_CTK_CONFIG_FILE_PATH=[^[:space:]\\]+' "${candidate}" 2>/dev/null | head -n1 | cut -d= -f2-)"
    if [[ -n "${config_path}" ]]; then
      echo "${config_path}"
      return 0
    fi
  done
  return 1
}

cuda_dev_package_series() {
  if [[ -n "${CUDA_DEV_PACKAGE_SERIES:-}" ]]; then
    echo "${CUDA_DEV_PACKAGE_SERIES}"
    return 0
  fi
  local cuda_root base
  cuda_root="$(readlink -f /usr/local/cuda 2>/dev/null || true)"
  base="$(basename "${cuda_root}")"
  if [[ "${base}" =~ ^cuda-([0-9]+)\.([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

cuda_include_dir_candidates() {
  {
    if [[ -n "${CUDA_INCLUDE_DIR:-}" ]]; then
      echo "${CUDA_INCLUDE_DIR}"
    fi
    echo "/usr/local/cuda/include"
    echo "/usr/local/cuda/targets/x86_64-linux/include"
    echo "/usr/include"
  } | awk 'NF && !seen[$0]++ { print }'
}

cuda_lib_dir_candidates() {
  {
    if [[ -n "${CUDA_LIB_DIR:-}" ]]; then
      echo "${CUDA_LIB_DIR}"
    fi
    echo "/usr/local/cuda/lib64"
    echo "/usr/local/cuda/targets/x86_64-linux/lib"
    echo "/usr/local/cuda/targets/x86_64-linux/lib/stubs"
    echo "/usr/lib/x86_64-linux-gnu"
    echo "/usr/lib64"
  } | awk 'NF && !seen[$0]++ { print }'
}

find_cuda_include_dir() {
  local dir
  while IFS= read -r dir; do
    [[ -n "${dir}" && -d "${dir}" ]] || continue
    if [[ -f "${dir}/cuda.h" && -f "${dir}/cuda_runtime_api.h" && -f "${dir}/cufile.h" && -f "${dir}/crt/host_defines.h" ]]; then
      echo "${dir}"
      return 0
    fi
  done < <(cuda_include_dir_candidates)
  return 1
}

find_cuda_lib_dir_with() {
  local libname="$1"
  local dir
  while IFS= read -r dir; do
    [[ -n "${dir}" && -d "${dir}" ]] || continue
    if [[ -f "${dir}/${libname}" ]]; then
      echo "${dir}"
      return 0
    fi
  done < <(cuda_lib_dir_candidates)
  return 1
}

ensure_local_gds_cuda_dev_prereqs() {
  local include_dir cufile_dir cudart_dir cuda_dir
  include_dir="$(find_cuda_include_dir || true)"
  cufile_dir="$(find_cuda_lib_dir_with libcufile.so || true)"
  cudart_dir="$(find_cuda_lib_dir_with libcudart.so || true)"
  cuda_dir="$(find_cuda_lib_dir_with libcuda.so || true)"
  if [[ -n "${include_dir}" && -n "${cufile_dir}" && -n "${cudart_dir}" && -n "${cuda_dir}" ]]; then
    return 0
  fi

  ensure_apt_available
  local series
  series="$(cuda_dev_package_series || true)"
  [[ -n "${series}" ]] || die "missing CUDA dev headers/libraries for local GDS validation and unable to infer CUDA_DEV_PACKAGE_SERIES; install cuda-cudart-dev manually or set VALIDATE_LOCAL_GDS=false"

  log "installing CUDA dev packages cuda-cudart-dev-${series} and cuda-crt-${series} for local GDS validation"
  maybe_sudo apt-get update -y
  maybe_sudo apt-get install -y "cuda-cudart-dev-${series}" "cuda-crt-${series}"

  include_dir="$(find_cuda_include_dir || true)"
  cufile_dir="$(find_cuda_lib_dir_with libcufile.so || true)"
  cudart_dir="$(find_cuda_lib_dir_with libcudart.so || true)"
  cuda_dir="$(find_cuda_lib_dir_with libcuda.so || true)"
  if [[ -z "${include_dir}" || -z "${cufile_dir}" || -z "${cudart_dir}" || -z "${cuda_dir}" ]]; then
    die "CUDA dev headers/libraries for local GDS validation are still incomplete after installing cuda-cudart-dev-${series} and cuda-crt-${series}; install matching CUDA dev packages manually or set VALIDATE_LOCAL_GDS=false"
  fi
}

resolve_local_gds_cuda_build_env() {
  ensure_local_gds_cuda_dev_prereqs

  local include_dir cufile_dir cudart_dir cuda_dir dir
  include_dir="$(find_cuda_include_dir || true)"
  cufile_dir="$(find_cuda_lib_dir_with libcufile.so || true)"
  cudart_dir="$(find_cuda_lib_dir_with libcudart.so || true)"
  cuda_dir="$(find_cuda_lib_dir_with libcuda.so || true)"

  [[ -n "${include_dir}" ]] || die "failed to locate CUDA headers (cuda.h, cuda_runtime_api.h, cufile.h, crt/host_defines.h) for local GDS validation"
  [[ -n "${cufile_dir}" ]] || die "failed to locate libcufile.so for local GDS validation"
  [[ -n "${cudart_dir}" ]] || die "failed to locate libcudart.so for local GDS validation"
  [[ -n "${cuda_dir}" ]] || die "failed to locate libcuda.so for local GDS validation"

  local -a ldflags=()
  local -a runtime_lib_dirs=()
  local seen_dirs=""
  for dir in "${cufile_dir}" "${cudart_dir}" "${cuda_dir}"; do
    [[ -n "${dir}" ]] || continue
    if [[ " ${seen_dirs} " != *" ${dir} "* ]]; then
      ldflags+=("-L${dir}")
      seen_dirs="${seen_dirs} ${dir}"
    fi
  done

  seen_dirs=""
  for dir in "${cufile_dir}" "${cudart_dir}"; do
    [[ -n "${dir}" ]] || continue
    if [[ " ${seen_dirs} " != *" ${dir} "* ]]; then
      runtime_lib_dirs+=("${dir}")
      seen_dirs="${seen_dirs} ${dir}"
    fi
  done

  printf '%s\n' "${include_dir}"
  printf '%s\n' "${ldflags[*]}"
  printf '%s\n' "$(IFS=:; echo "${runtime_lib_dirs[*]}")"
}

nvidia_runtime_config_files() {
  local wrapper_cfg
  wrapper_cfg="$(nvidia_runtime_wrapper_config_file || true)"
  {
    if [[ -n "${wrapper_cfg}" ]]; then
      echo "${wrapper_cfg}"
    fi
    echo "/etc/nvidia-container-runtime/config.toml"
  } | awk 'NF && !seen[$0]++ { print }'
}

nvidia_runtime_config_set_if_matches() {
  local cfg="$1"
  local pattern="$2"
  local key="$3"
  local value="$4"
  local message="$5"
  if maybe_sudo test -f "${cfg}" && maybe_sudo grep -Eq "${pattern}" "${cfg}"; then
    log "${message} (${cfg})"
    maybe_sudo nvidia-ctk config --config-file "${cfg}" --set "${key}=${value}" --in-place
    return 0
  fi
  return 1
}

configure_nvidia_runtime() {
  log "configuring NVIDIA container runtime for Docker"
  maybe_sudo nvidia-ctk runtime configure --runtime=docker --set-as-default --cdi.enabled
  maybe_sudo nvidia-ctk config --set accept-nvidia-visible-devices-as-volume-mounts=true --in-place
  maybe_sudo nvidia-ctk config --set accept-nvidia-visible-devices-envvar-when-unprivileged=false --in-place
  maybe_sudo systemctl restart docker
}

ensure_k3s_nvidia_runtime_prereqs() {
  ensure_cmd k3s
  ensure_cmd nvidia-ctk

  local changed=0
  local cfg
  while IFS= read -r cfg; do
    [[ -n "${cfg}" ]] || continue
    if nvidia_runtime_config_set_if_matches \
      "${cfg}" \
      '^[[:space:]]*mode[[:space:]]*=[[:space:]]*"cdi"' \
      "nvidia-container-runtime.mode" \
      "legacy" \
      "switching NVIDIA container runtime from CDI mode to legacy mode for k3s GPU pods"; then
      changed=1
    fi
    if nvidia_runtime_config_set_if_matches \
      "${cfg}" \
      '^[[:space:]]*accept-nvidia-visible-devices-envvar-when-unprivileged[[:space:]]*=[[:space:]]*false' \
      "accept-nvidia-visible-devices-envvar-when-unprivileged" \
      "true" \
      "enabling unprivileged NVIDIA_VISIBLE_DEVICES injection for k3s pods"; then
      changed=1
    fi
  done < <(nvidia_runtime_config_files)

  if (( changed == 1 )); then
    log "restarting k3s to apply NVIDIA runtime config"
    maybe_sudo systemctl restart k3s
  fi

  local tries=0
  local max_tries=60
  until kube get nodes >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [[ "${tries}" -ge "${max_tries}" ]]; then
      die "k3s API did not become queryable after ${max_tries} attempts"
    fi
    sleep 3
  done
}
