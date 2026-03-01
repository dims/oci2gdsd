#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${HARNESS_DIR}/../.." && pwd)"
WORK_DIR="${HARNESS_DIR}/work"
LOG_DIR="${WORK_DIR}/logs"
mkdir -p "${WORK_DIR}" "${LOG_DIR}"

CLUSTER_NAME="${CLUSTER_NAME:-oci2gdsd-e2e}"
KUBECTL_CONTEXT="kind-${CLUSTER_NAME}"
E2E_NAMESPACE="${E2E_NAMESPACE:-oci2gdsd-e2e}"
REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-oci2gdsd-registry}"
REGISTRY_SERVICE="${REGISTRY_SERVICE:-oci-model-registry}"
LOCAL_REGISTRY_PORT="${LOCAL_REGISTRY_PORT:-5002}"

HF_REPO="${HF_REPO:-Qwen/Qwen3-0.6B}"
HF_REVISION="${HF_REVISION:-main}"
MODEL_ID="${MODEL_ID:-qwen3-0.6b}"
MODEL_REPO="${MODEL_REPO:-models/qwen3-0.6b}"
MODEL_TAG="${MODEL_TAG:-v1}"
LEASE_HOLDER="${LEASE_HOLDER:-k8s-e2e}"
MODEL_REF_OVERRIDE="${MODEL_REF_OVERRIDE:-}"
MODEL_DIGEST_OVERRIDE="${MODEL_DIGEST_OVERRIDE:-}"

OCI2GDSD_IMAGE="${OCI2GDSD_IMAGE:-oci2gdsd:e2e}"
PACKAGER_IMAGE="${PACKAGER_IMAGE:-oci2gdsd-qwen3-packager:local}"
PYTORCH_IMAGE="${PYTORCH_IMAGE:-pytorch/pytorch:2.4.1-cuda12.1-cudnn9-runtime}"

OCI2GDSD_ROOT_PATH="${OCI2GDSD_ROOT_PATH:-/var/lib/oci2gdsd}"

KIND_VERSION="${KIND_VERSION:-0.31.0}"
KUBECTL_VERSION="${KUBECTL_VERSION:-1.32.0}"
HELM_VERSION="${HELM_VERSION:-3.17.3}"
GO_VERSION="${GO_VERSION:-1.23.6}"

PF_PID_FILE="${WORK_DIR}/registry-port-forward.pid"

_ts() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  echo "[$(_ts)] $*"
}

warn() {
  echo "[$(_ts)] WARN: $*" >&2
}

die() {
  echo "[$(_ts)] ERROR: $*" >&2
  exit 1
}

ensure_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "missing required command: ${cmd}"
}

maybe_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
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
    return
  fi
  log "installing Go ${GO_VERSION}"
  curl -fsSL -o /tmp/go${GO_VERSION}.linux-amd64.tar.gz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
  maybe_sudo rm -rf /usr/local/go
  maybe_sudo tar -C /usr/local -xzf /tmp/go${GO_VERSION}.linux-amd64.tar.gz
  export PATH="/usr/local/go/bin:${PATH}"
}

ensure_go_path() {
  if command -v go >/dev/null 2>&1; then
    return
  fi
  if [[ -x /usr/local/go/bin/go ]]; then
    export PATH="/usr/local/go/bin:${PATH}"
  fi
}

install_kind_if_missing() {
  if command -v kind >/dev/null 2>&1; then
    return
  fi
  log "installing kind v${KIND_VERSION}"
  curl -fsSL -o /tmp/kind "https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-amd64"
  chmod +x /tmp/kind
  maybe_sudo mv /tmp/kind /usr/local/bin/kind
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
  maybe_sudo apt-get update -y >/dev/null
  maybe_sudo apt-get install -y docker.io >/dev/null
  maybe_sudo systemctl enable --now docker
  maybe_sudo usermod -aG docker "$(id -un)" || true
}

ensure_docker_access() {
  if docker info >/dev/null 2>&1; then
    return
  fi
  if maybe_sudo docker info >/dev/null 2>&1; then
    die "docker is installed but current user cannot access it yet; run 'newgrp docker' or log out/in, then rerun"
  fi
  die "docker daemon is not reachable"
}

install_nvidia_ctk_if_missing() {
  if command -v nvidia-ctk >/dev/null 2>&1; then
    return
  fi
  ensure_apt_available
  log "installing nvidia-container-toolkit"
  maybe_sudo apt-get update -y >/dev/null
  maybe_sudo apt-get install -y curl gnupg >/dev/null
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    maybe_sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    gsed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    maybe_sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  maybe_sudo apt-get update -y >/dev/null
  maybe_sudo apt-get install -y nvidia-container-toolkit >/dev/null
}

install_nvkind_if_missing() {
  ensure_go_path
  if command -v nvkind >/dev/null 2>&1; then
    return
  fi
  log "installing nvkind"
  go install github.com/NVIDIA/nvkind/cmd/nvkind@latest
  if [[ -d "${HOME}/go/bin" ]]; then
    export PATH="${HOME}/go/bin:${PATH}"
  fi
  ensure_cmd nvkind
}

bootstrap_tools() {
  require_linux_host
  install_go_if_missing
  ensure_go_path
  install_kind_if_missing
  install_kubectl_if_missing
  install_helm_if_missing
  install_jq_if_missing
  install_gsed_if_missing
  install_docker_if_missing
  ensure_docker_access
  install_nvidia_ctk_if_missing
  install_nvkind_if_missing
  ensure_cmd nvidia-smi
}

configure_nvidia_runtime() {
  log "configuring NVIDIA container runtime for Docker"
  maybe_sudo nvidia-ctk runtime configure --runtime=docker --set-as-default --cdi.enabled
  maybe_sudo nvidia-ctk config --set accept-nvidia-visible-devices-as-volume-mounts=true --in-place
  maybe_sudo nvidia-ctk config --set accept-nvidia-visible-devices-envvar-when-unprivileged=false --in-place
  maybe_sudo systemctl restart docker
}

create_nvkind_cluster() {
  if kind get clusters 2>/dev/null | grep -Fxq "${CLUSTER_NAME}"; then
    log "kind cluster ${CLUSTER_NAME} already exists"
  else
    log "creating nvkind cluster ${CLUSTER_NAME}"
    nvkind cluster create --name="${CLUSTER_NAME}" || warn "nvkind returned non-zero (continuing)"
  fi
  kubectl --context "${KUBECTL_CONTEXT}" wait --for=condition=Ready nodes --all --timeout=300s
  kubectl --context "${KUBECTL_CONTEXT}" get nodes -o wide
  nvkind cluster print-gpus --name="${CLUSTER_NAME}" || true
}

install_gpu_operator() {
  log "installing GPU Operator (helm)"
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade -i \
    --kube-context="${KUBECTL_CONTEXT}" \
    --namespace gpu-operator \
    --create-namespace \
    --set driver.enabled=false \
    --set toolkit.enabled=false \
    --set dcgmExporter.enabled=false \
    --set nfd.enabled=true \
    --wait --timeout=600s \
    gpu-operator nvidia/gpu-operator
  kubectl --context "${KUBECTL_CONTEXT}" -n gpu-operator \
    rollout status daemonset -l app=nvidia-device-plugin-daemonset --timeout=300s || true
  kubectl --context "${KUBECTL_CONTEXT}" -n gpu-operator get pods
}

verify_gpu_pod() {
  log "verifying GPU in a pod"
  cat <<EOF | kubectl --context "${KUBECTL_CONTEXT}" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-smoke
  namespace: kube-system
spec:
  restartPolicy: Never
  tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"
  containers:
  - name: nvidia-smi
    image: nvidia/cuda:12.8.0-base-ubuntu22.04
    command: ["nvidia-smi", "-L"]
    resources:
      limits:
        nvidia.com/gpu: 1
EOF
  kubectl --context "${KUBECTL_CONTEXT}" -n kube-system wait pod/gpu-smoke --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s
  kubectl --context "${KUBECTL_CONTEXT}" -n kube-system logs pod/gpu-smoke
  kubectl --context "${KUBECTL_CONTEXT}" -n kube-system delete pod/gpu-smoke --ignore-not-found >/dev/null
}

build_and_load_oci2gdsd_image() {
  log "building oci2gdsd image ${OCI2GDSD_IMAGE}"
  docker build -f "${HARNESS_DIR}/Dockerfile.oci2gdsd" -t "${OCI2GDSD_IMAGE}" "${REPO_ROOT}"
  kind load docker-image "${OCI2GDSD_IMAGE}" --name "${CLUSTER_NAME}"
}

build_packager_image() {
  log "building packager image ${PACKAGER_IMAGE}"
  docker build -t "${PACKAGER_IMAGE}" "${REPO_ROOT}/packaging/qwen3-oci-modelprofile-v1"
}

render_template() {
  local src="$1"
  local dst="$2"
  shift 2
  cp "${src}" "${dst}"
  local kv
  for kv in "$@"; do
    local key="${kv%%=*}"
    local value="${kv#*=}"
    gsed -i "s|__${key}__|${value}|g" "${dst}"
  done
}

apply_registry() {
  mkdir -p "${WORK_DIR}/rendered"
  local rendered="${WORK_DIR}/rendered/registry.yaml"
  render_template "${HARNESS_DIR}/manifests/registry.yaml.tpl" "${rendered}" \
    "REGISTRY_NAMESPACE=${REGISTRY_NAMESPACE}" \
    "REGISTRY_SERVICE=${REGISTRY_SERVICE}"
  kubectl --context "${KUBECTL_CONTEXT}" apply -f "${rendered}"
  kubectl --context "${KUBECTL_CONTEXT}" -n "${REGISTRY_NAMESPACE}" rollout status deploy/"${REGISTRY_SERVICE}" --timeout=180s
}

start_registry_port_forward() {
  if [[ -f "${PF_PID_FILE}" ]]; then
    local stale_pid
    stale_pid="$(cat "${PF_PID_FILE}" || true)"
    if [[ -n "${stale_pid}" ]] && kill -0 "${stale_pid}" 2>/dev/null; then
      kill "${stale_pid}" || true
    fi
    rm -f "${PF_PID_FILE}"
  fi

  kubectl --context "${KUBECTL_CONTEXT}" -n "${REGISTRY_NAMESPACE}" \
    port-forward svc/"${REGISTRY_SERVICE}" "${LOCAL_REGISTRY_PORT}:5000" \
    > "${LOG_DIR}/registry-port-forward.log" 2>&1 &
  echo $! > "${PF_PID_FILE}"
  sleep 3
  curl -fsS "http://localhost:${LOCAL_REGISTRY_PORT}/v2/_catalog" >/dev/null
}

stop_registry_port_forward() {
  if [[ -f "${PF_PID_FILE}" ]]; then
    local pid
    pid="$(cat "${PF_PID_FILE}" || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" || true
    fi
    rm -f "${PF_PID_FILE}"
  fi
}

package_model_to_registry() {
  if [[ -n "${MODEL_REF_OVERRIDE}" && -n "${MODEL_DIGEST_OVERRIDE}" ]]; then
    MODEL_DIGEST="${MODEL_DIGEST_OVERRIDE}"
    MODEL_REF="${MODEL_REF_OVERRIDE}"
    MODEL_ROOT_PATH="${OCI2GDSD_ROOT_PATH}/models/${MODEL_ID}/${MODEL_DIGEST//:/-}"
    export MODEL_DIGEST MODEL_REF MODEL_ROOT_PATH
    log "using pre-existing model ref override: ${MODEL_REF}"
    return
  fi
  local packager_work="${WORK_DIR}/packager"
  mkdir -p "${packager_work}"
  log "packaging model ${HF_REPO}@${HF_REVISION} to local registry"
  docker run --rm --network host \
    -u "$(id -u):$(id -g)" \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    -v "${packager_work}:/work" \
    "${PACKAGER_IMAGE}" \
    --hf-repo "${HF_REPO}" \
    --hf-revision "${HF_REVISION}" \
    --model-id "${MODEL_ID}" \
    --oci-ref "localhost:${LOCAL_REGISTRY_PORT}/${MODEL_REPO}:${MODEL_TAG}" \
    --plain-http
  MODEL_DIGEST="$(jq -r '.digest' "${packager_work}/output/manifest-descriptor.json")"
  if [[ -z "${MODEL_DIGEST}" || "${MODEL_DIGEST}" == "null" ]]; then
    die "failed to parse model digest from manifest-descriptor.json"
  fi
  MODEL_REF="${REGISTRY_SERVICE}.${REGISTRY_NAMESPACE}.svc.cluster.local:5000/${MODEL_REPO}@${MODEL_DIGEST}"
  MODEL_ROOT_PATH="${OCI2GDSD_ROOT_PATH}/models/${MODEL_ID}/${MODEL_DIGEST//:/-}"
  export MODEL_DIGEST MODEL_REF MODEL_ROOT_PATH
  log "model digest: ${MODEL_DIGEST}"
  log "model ref for pods: ${MODEL_REF}"
}

collect_debug() {
  warn "collecting debug artifacts"
  kubectl --context "${KUBECTL_CONTEXT}" get nodes -o wide || true
  kubectl --context "${KUBECTL_CONTEXT}" get pods -A || true
  kubectl --context "${KUBECTL_CONTEXT}" -n gpu-operator get pods -o wide || true
  kubectl --context "${KUBECTL_CONTEXT}" -n "${E2E_NAMESPACE}" get pods -o wide || true
  kubectl --context "${KUBECTL_CONTEXT}" -n "${E2E_NAMESPACE}" get jobs || true
}
