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

install_k3s_if_missing() {
  if command -v k3s >/dev/null 2>&1; then
    return
  fi
  log "installing k3s ${K3S_VERSION}"
  local install_exec
  install_exec="server --write-kubeconfig-mode=644 --disable=traefik --node-name=$(hostname)"
  if [[ -r /etc/rancher/k3s/config.yaml ]] && grep -Eq '^[[:space:]]*data-dir[[:space:]]*:' /etc/rancher/k3s/config.yaml; then
    install_exec="${install_exec} --config /etc/rancher/k3s/config.yaml"
  fi
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    INSTALL_K3S_EXEC="${install_exec}" \
    maybe_sudo sh -
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
  ensure_cmd nvidia-smi
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

  local cfg="/etc/nvidia-container-runtime/config.toml"
  local changed=0
  if maybe_sudo test -f "${cfg}" && \
    maybe_sudo grep -Eq '^[[:space:]]*accept-nvidia-visible-devices-envvar-when-unprivileged[[:space:]]*=[[:space:]]*false' "${cfg}"; then
    log "enabling unprivileged NVIDIA_VISIBLE_DEVICES injection for k3s pods"
    maybe_sudo nvidia-ctk config --set accept-nvidia-visible-devices-envvar-when-unprivileged=true --in-place
    changed=1
  fi

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

