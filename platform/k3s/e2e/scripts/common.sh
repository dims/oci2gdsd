#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${HARNESS_DIR}/../../.." && pwd)"
# shellcheck source=../../../lib/common.sh
source "${SCRIPT_DIR}/../../../lib/common.sh"
WORK_DIR="${HARNESS_DIR}/work"
LOG_DIR="${WORK_DIR}/logs"
mkdir -p "${WORK_DIR}" "${LOG_DIR}"

CLUSTER_MODE="${CLUSTER_MODE:-k3s}"
E2E_DEPLOY_MODE="${E2E_DEPLOY_MODE:-inline-daemon}"
K3S_USE_SUDO="${K3S_USE_SUDO:-true}"
E2E_NAMESPACE="${E2E_NAMESPACE:-oci2gdsd-e2e}"
QWEN_HELLO_NAMESPACE="${QWEN_HELLO_NAMESPACE:-qwen-hello}"
QWEN_HELLO_PROFILE="${QWEN_HELLO_PROFILE:-}"
QWEN_HELLO_TEMPLATE="${QWEN_HELLO_TEMPLATE:-}"
OCI2GDSD_DAEMON_NAMESPACE="${OCI2GDSD_DAEMON_NAMESPACE:-oci2gdsd-daemon}"
OCI2GDSD_SOCKET_HOST_PATH="${OCI2GDSD_SOCKET_HOST_PATH:-/var/run/oci2gdsd}"
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
VALIDATE_QWEN_HELLO="${VALIDATE_QWEN_HELLO:-true}"
VALIDATE_LOCAL_GDS="${VALIDATE_LOCAL_GDS:-true}"
REQUIRE_DAEMON_IPC_PROBE="${REQUIRE_DAEMON_IPC_PROBE:-}"
REQUIRE_DIRECT_GDS="${REQUIRE_DIRECT_GDS:-true}"
OCI2GDS_DAEMON_ENABLE="${OCI2GDS_DAEMON_ENABLE:-1}"
OCI2GDS_DAEMON_PROBE_SHARDS="${OCI2GDS_DAEMON_PROBE_SHARDS:-1}"
MIN_FREE_GB_DOCKER="${MIN_FREE_GB_DOCKER:-100}"
MIN_FREE_GB_K3S="${MIN_FREE_GB_K3S:-50}"
MIN_FREE_GB_OCI2GDS_ROOT="${MIN_FREE_GB_OCI2GDS_ROOT:-20}"
K3S_DATA_DIR="${K3S_DATA_DIR:-}"
AUTO_CONFIGURE_STORAGE="${AUTO_CONFIGURE_STORAGE:-true}"
AUTO_INSTALL_GPU_OPERATOR="${AUTO_INSTALL_GPU_OPERATOR:-true}"
GPU_OPERATOR_CHART_VERSION="${GPU_OPERATOR_CHART_VERSION:-v25.10.1}"

OCI2GDSD_IMAGE_SET="${OCI2GDSD_IMAGE+x}"
OCI2GDSD_IMAGE="${OCI2GDSD_IMAGE:-oci2gdsd:e2e}"
OCI2GDSD_CLI_IMAGE="${OCI2GDSD_CLI_IMAGE:-oci2gdsd:e2e}"
OCI2GDSD_CLI_DOCKERFILE="${OCI2GDSD_CLI_DOCKERFILE:-${HARNESS_DIR}/Dockerfile.oci2gdsd}"
OCI2GDSD_ENABLE_GDS_IMAGE_SET="${OCI2GDSD_ENABLE_GDS_IMAGE+x}"
REQUIRE_DAEMON_IPC_PROBE_SET="${REQUIRE_DAEMON_IPC_PROBE+x}"
OCI2GDSD_ENABLE_GDS_IMAGE="${OCI2GDSD_ENABLE_GDS_IMAGE:-false}"
OCI2GDSD_DOCKERFILE="${OCI2GDSD_DOCKERFILE:-}"
SKIP_OCI2GDSD_IMAGE_BUILD="${SKIP_OCI2GDSD_IMAGE_BUILD:-false}"
SKIP_OCI2GDSD_IMAGE_LOAD="${SKIP_OCI2GDSD_IMAGE_LOAD:-false}"
FORCE_OCI2GDSD_IMAGE_REBUILD_SET="${FORCE_OCI2GDSD_IMAGE_REBUILD+x}"
FORCE_OCI2GDSD_IMAGE_REBUILD="${FORCE_OCI2GDSD_IMAGE_REBUILD:-false}"
PACKAGER_IMAGE="${PACKAGER_IMAGE:-oci2gdsd-qwen3-packager:local}"
VLLM_RUNTIME_IMAGE="${VLLM_RUNTIME_IMAGE:-nvcr.io/nvidia/ai-dynamo/vllm-runtime@sha256:de8ac9afb52711b08169e0f58388528c091efae6fb367a6fcfa119edef4bb233}"
PRELOAD_VLLM_RUNTIME_IMAGE="${PRELOAD_VLLM_RUNTIME_IMAGE:-true}"
VLLM_IMAGE="${VLLM_IMAGE:-${VLLM_RUNTIME_IMAGE}}"
PYTORCH_RUNTIME_IMAGE="${PYTORCH_RUNTIME_IMAGE:-${VLLM_RUNTIME_IMAGE}}"
PRELOAD_PYTORCH_RUNTIME_IMAGE="${PRELOAD_PYTORCH_RUNTIME_IMAGE:-${PRELOAD_VLLM_RUNTIME_IMAGE:-true}}"
PRELOAD_WORKLOAD_IMAGE="${PRELOAD_WORKLOAD_IMAGE:-true}"
PYTORCH_IMAGE="${PYTORCH_IMAGE:-${PYTORCH_RUNTIME_IMAGE}}"
TENSORRTLLM_RUNTIME_IMAGE="${TENSORRTLLM_RUNTIME_IMAGE:-nvcr.io/nvidia/tensorrt-llm/release:latest}"
PRELOAD_TENSORRTLLM_RUNTIME_IMAGE="${PRELOAD_TENSORRTLLM_RUNTIME_IMAGE:-true}"
TENSORRTLLM_IMAGE="${TENSORRTLLM_IMAGE:-${TENSORRTLLM_RUNTIME_IMAGE}}"
WORKLOAD_RUNTIME="${WORKLOAD_RUNTIME:-pytorch}"
QWEN_GDS_RUNTIME_IMAGE="${QWEN_GDS_RUNTIME_IMAGE:-oci2gdsd-qwen-runtime-gds:e2e}"
BUILD_QWEN_GDS_RUNTIME_IMAGE="${BUILD_QWEN_GDS_RUNTIME_IMAGE:-false}"
QWEN_GDS_RUNTIME_DOCKERFILE="${QWEN_GDS_RUNTIME_DOCKERFILE:-${REPO_ROOT}/platform/k3s/workloads/pytorch/qwen-hello/Dockerfile.vllm-runtime-gds}"
REQUIRE_STRICT_PROFILE_PROBE="${REQUIRE_STRICT_PROFILE_PROBE:-true}"
REQUIRE_NO_COMPAT_EVIDENCE="${REQUIRE_NO_COMPAT_EVIDENCE:-true}"
MIN_PROFILE_PROBE_MIB_S="${MIN_PROFILE_PROBE_MIB_S:-0}"
PROFILE_PROBE_MAX_REGRESSION_PCT="${PROFILE_PROBE_MAX_REGRESSION_PCT:-0}"
PROFILE_PROBE_BASELINE_FILE="${PROFILE_PROBE_BASELINE_FILE:-${WORK_DIR}/results/qwen-profile-probe-baseline.json}"
RUNTIME_DRIFT_CHECKPOINTS="${RUNTIME_DRIFT_CHECKPOINTS:-true}"
RECORD_ENVIRONMENT_REPORT="${RECORD_ENVIRONMENT_REPORT:-true}"
ALLOW_RELAXED_GDS="${ALLOW_RELAXED_GDS:-false}"

if [[ -z "${REQUIRE_DAEMON_IPC_PROBE}" ]]; then
  REQUIRE_DAEMON_IPC_PROBE="${OCI2GDSD_ENABLE_GDS_IMAGE}"
fi

# Track whether these were explicitly set by caller; host-direct profile
# only overrides when the caller did not provide values.
OCI2GDSD_ROOT_PATH_SET="${OCI2GDSD_ROOT_PATH+x}"
OCI2GDS_STRICT_SET="${OCI2GDS_STRICT+x}"
OCI2GDS_PROBE_STRICT_SET="${OCI2GDS_PROBE_STRICT+x}"
OCI2GDS_FORCE_NO_COMPAT_SET="${OCI2GDS_FORCE_NO_COMPAT+x}"
OCI2GDSD_ROOT_PATH="${OCI2GDSD_ROOT_PATH:-/var/lib/oci2gdsd}"
OCI2GDS_STRICT="${OCI2GDS_STRICT:-true}"
OCI2GDS_PROBE_STRICT="${OCI2GDS_PROBE_STRICT:-true}"
OCI2GDS_FORCE_NO_COMPAT="${OCI2GDS_FORCE_NO_COMPAT:-true}"

KIND_VERSION="${KIND_VERSION:-0.31.0}"
KUBECTL_VERSION="${KUBECTL_VERSION:-1.32.0}"
HELM_VERSION="${HELM_VERSION:-3.17.3}"
GO_VERSION="${GO_VERSION:-1.23.6}"
K3S_VERSION="${K3S_VERSION:-v1.32.0+k3s1}"
CUDA_INCLUDE_DIR="${CUDA_INCLUDE_DIR:-/usr/local/cuda/include}"
CUDA_LIB_DIR="${CUDA_LIB_DIR:-/usr/local/cuda/lib64}"

PF_PID_FILE="${WORK_DIR}/registry-port-forward.pid"

emit_direct_gds_remediation() {
  cat >&2 <<'EOF'
Direct-GDS remediation options:
1. Full remediation bundle (default):
   - align kernel + driver + GDS packages
   - reboot
   - verify gdscheck
   - mount NVMe and move data paths to NVMe
   - run strict gdsio probe
2. Ensure GDS tools are installed and verify with:
   sudo gdscheck -p
3. Keep strict mode (default) for real validation:
   REQUIRE_DIRECT_GDS=true OCI2GDS_STRICT=true OCI2GDS_FORCE_NO_COMPAT=true
4. For non-direct smoke only (not a true GDS pass), relax gates:
   ALLOW_RELAXED_GDS=true REQUIRE_DIRECT_GDS=false OCI2GDS_STRICT=false
EOF
}

enforce_strict_gds_policy() {
  if is_true "${ALLOW_RELAXED_GDS}"; then
    warn "ALLOW_RELAXED_GDS=true: strict direct-GDS policy checks are relaxed for debugging"
    return 0
  fi

  local violations=()
  [[ "${REQUIRE_DIRECT_GDS}" == "true" ]] || violations+=("REQUIRE_DIRECT_GDS=${REQUIRE_DIRECT_GDS}")
  [[ "${OCI2GDS_STRICT}" == "true" ]] || violations+=("OCI2GDS_STRICT=${OCI2GDS_STRICT}")
  [[ "${OCI2GDS_PROBE_STRICT}" == "true" ]] || violations+=("OCI2GDS_PROBE_STRICT=${OCI2GDS_PROBE_STRICT}")
  [[ "${OCI2GDS_FORCE_NO_COMPAT}" == "true" ]] || violations+=("OCI2GDS_FORCE_NO_COMPAT=${OCI2GDS_FORCE_NO_COMPAT}")
  [[ "${REQUIRE_STRICT_PROFILE_PROBE}" == "true" ]] || violations+=("REQUIRE_STRICT_PROFILE_PROBE=${REQUIRE_STRICT_PROFILE_PROBE}")
  [[ "${REQUIRE_NO_COMPAT_EVIDENCE}" == "true" ]] || violations+=("REQUIRE_NO_COMPAT_EVIDENCE=${REQUIRE_NO_COMPAT_EVIDENCE}")
  if ((${#violations[@]} > 0)); then
    die "strict GDS policy violation: ${violations[*]} (set ALLOW_RELAXED_GDS=true only for temporary debugging)"
  fi
}

k3s_data_dir() {
  local dir="/var/lib/rancher/k3s"
  if [[ -n "${K3S_DATA_DIR}" ]]; then
    dir="${K3S_DATA_DIR}"
  elif [[ -r /etc/rancher/k3s/config.yaml ]]; then
    local cfg_dir
    cfg_dir="$(awk -F':' '/^[[:space:]]*data-dir[[:space:]]*:/ {sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2); gsub(/"/, "", $2); print $2; exit}' /etc/rancher/k3s/config.yaml)"
    if [[ -n "${cfg_dir}" ]]; then
      dir="${cfg_dir}"
    fi
  fi
  echo "${dir}"
}

configure_docker_data_root() {
  local target="${1:-/mnt/nvme/docker}"
  log "auto-configuring docker data-root=${target}"
  maybe_sudo mkdir -p "${target}"
  local tmp
  tmp="$(mktemp)"
  if maybe_sudo test -f /etc/docker/daemon.json; then
    maybe_sudo cat /etc/docker/daemon.json | jq \
      --arg root "${target}" \
      '. + {"data-root":$root,"default-runtime":"nvidia","features":((.features // {}) + {"cdi":true}),"runtimes":((.runtimes // {}) + {"nvidia":{"path":"nvidia-container-runtime","args":[]}})}' \
      > "${tmp}"
  else
    cat > "${tmp}" <<EOF
{
  "data-root": "${target}",
  "default-runtime": "nvidia",
  "features": { "cdi": true },
  "runtimes": { "nvidia": { "path": "nvidia-container-runtime", "args": [] } }
}
EOF
  fi
  maybe_sudo mv "${tmp}" /etc/docker/daemon.json
  maybe_sudo systemctl restart docker
}

configure_k3s_data_dir() {
  local target="${1:-/mnt/nvme/k3s}"
  log "auto-configuring k3s data-dir=${target}"
  maybe_sudo mkdir -p "${target}" /etc/rancher/k3s
  local cfg="/etc/rancher/k3s/config.yaml"
  if maybe_sudo test -f "${cfg}" && maybe_sudo grep -q '^[[:space:]]*data-dir[[:space:]]*:' "${cfg}"; then
    maybe_sudo gsed -i "s|^[[:space:]]*data-dir[[:space:]]*:.*$|data-dir: ${target}|" "${cfg}"
  else
    echo "data-dir: ${target}" | maybe_sudo tee -a "${cfg}" >/dev/null
  fi
  if maybe_sudo systemctl list-unit-files | grep -q '^k3s\.service'; then
    maybe_sudo systemctl restart k3s
  fi
}

maybe_auto_configure_storage() {
  if ! is_true "${AUTO_CONFIGURE_STORAGE}"; then
    return 0
  fi
  if [[ ! -d /mnt/nvme ]]; then
    return 0
  fi

  local docker_root
  docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  if [[ -n "${docker_root}" ]]; then
    local docker_need docker_avail nvme_avail
    docker_need=$((MIN_FREE_GB_DOCKER * 1024 * 1024))
    docker_avail="$(path_available_kb "${docker_root}")"
    nvme_avail="$(path_available_kb "/mnt/nvme")"
    if (( docker_avail < docker_need )) && [[ "${docker_root}" != /mnt/nvme/* ]] && (( nvme_avail >= docker_need )); then
      configure_docker_data_root "/mnt/nvme/docker"
    fi
  fi

  if [[ "${CLUSTER_MODE}" == "k3s" ]]; then
    local k3s_dir k3s_need k3s_avail nvme_avail
    k3s_dir="$(k3s_data_dir)"
    k3s_need=$((MIN_FREE_GB_K3S * 1024 * 1024))
    k3s_avail="$(path_available_kb "${k3s_dir}")"
    nvme_avail="$(path_available_kb "/mnt/nvme")"
    if (( k3s_avail < k3s_need )) && [[ "${k3s_dir}" != /mnt/nvme/* ]] && (( nvme_avail >= k3s_need )); then
      configure_k3s_data_dir "/mnt/nvme/k3s"
    fi
  fi
}

emit_storage_remediation() {
  cat >&2 <<'EOF'
Storage remediation options:
1. Attach/mount a larger data disk (prefer local NVMe), for example at /mnt/nvme.
2. Move Docker data-root to that disk:
   sudo mkdir -p /mnt/nvme/docker
   sudo tee /etc/docker/daemon.json >/dev/null <<JSON
   {
     "data-root": "/mnt/nvme/docker",
     "default-runtime": "nvidia",
     "features": { "cdi": true },
     "runtimes": { "nvidia": { "path": "nvidia-container-runtime", "args": [] } }
   }
JSON
   sudo systemctl restart docker
3. For k3s, keep /var/lib/rancher/k3s and OCI2GDSD_ROOT_PATH on high-capacity mounts.
4. As a temporary fallback only, prune local artifacts:
   docker system prune -af --volumes
EOF
}

check_path_free_gb() {
  local label="$1"
  local path="$2"
  local min_gb="$3"
  local avail_kb required_kb avail_gb mountpoint

  is_uint "${min_gb}" || die "${label} minimum free space is not numeric: ${min_gb}"
  avail_kb="$(path_available_kb "${path}")"
  required_kb=$((min_gb * 1024 * 1024))
  avail_gb=$((avail_kb / 1024 / 1024))
  mountpoint="$(path_mountpoint "${path}")"

  log "${label}: path=${path} mount=${mountpoint} available=${avail_gb}GiB required=${min_gb}GiB"
  if (( avail_kb < required_kb )); then
    emit_storage_remediation
    die "${label} has insufficient free space: ${avail_gb}GiB available < ${min_gb}GiB required (path=${path}, mount=${mountpoint})"
  fi
}

check_storage_prereqs() {
  maybe_auto_configure_storage

  mkdir -p "${WORK_DIR}/results"
  local report="${WORK_DIR}/results/storage-prereq.txt"
  {
    echo "# storage preflight $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    df -h
  } > "${report}" 2>&1 || true

  local docker_root
  docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  [[ -n "${docker_root}" ]] || die "failed to detect DockerRootDir from docker info"

  check_path_free_gb "docker data-root" "${docker_root}" "${MIN_FREE_GB_DOCKER}"
  check_path_free_gb "oci2gdsd root path" "${OCI2GDSD_ROOT_PATH}" "${MIN_FREE_GB_OCI2GDS_ROOT}"

  if [[ "${CLUSTER_MODE}" == "k3s" ]]; then
    local k3s_dir
    k3s_dir="$(k3s_data_dir)"
    check_path_free_gb "k3s data root" "${k3s_dir}" "${MIN_FREE_GB_K3S}"
  fi
}

resolve_cluster_mode() {
  case "${CLUSTER_MODE}" in
    k3s|auto)
      CLUSTER_MODE="k3s"
      ;;
    *)
      die "unsupported CLUSTER_MODE=${CLUSTER_MODE} (expected k3s|auto)"
      ;;
  esac
}

validate_deploy_mode() {
  case "${E2E_DEPLOY_MODE}" in
    inline-daemon|daemonset-manifest)
      ;;
    *)
      die "unsupported E2E_DEPLOY_MODE=${E2E_DEPLOY_MODE} (expected inline-daemon|daemonset-manifest)"
      ;;
  esac
}

validate_deploy_assets() {
  if [[ "${E2E_DEPLOY_MODE}" != "daemonset-manifest" ]]; then
    return 0
  fi
  [[ -f "${OCI2GDSD_DAEMON_TEMPLATE}" ]] || die "missing daemonset template: ${OCI2GDSD_DAEMON_TEMPLATE}"
  [[ -f "${WORKLOAD_DAEMON_TEMPLATE}" ]] || die "missing daemonset workload template: ${WORKLOAD_DAEMON_TEMPLATE}"
  [[ -f "${WORKLOAD_DAEMON_SCRIPT}" ]] || die "missing daemon client script: ${WORKLOAD_DAEMON_SCRIPT}"
  if [[ "${WORKLOAD_RUNTIME}" == "pytorch" ]]; then
    [[ -f "${PYTORCH_DAEMON_NATIVE_CPP}" ]] || die "missing daemon native source: ${PYTORCH_DAEMON_NATIVE_CPP}"
  fi
}

validate_workload_runtime() {
  case "${WORKLOAD_RUNTIME}" in
    pytorch|tensorrt|vllm)
      ;;
    *)
      die "unsupported WORKLOAD_RUNTIME=${WORKLOAD_RUNTIME} (expected pytorch|tensorrt|vllm)"
      ;;
  esac
}

configure_workload_runtime() {
  case "${WORKLOAD_RUNTIME}" in
    pytorch)
      WORKLOAD_IMAGE="${PYTORCH_IMAGE}"
      WORKLOAD_RUNTIME_IMAGE="${PYTORCH_RUNTIME_IMAGE}"
      WORKLOAD_DAEMON_TEMPLATE="${PYTORCH_DAEMON_CLIENT_TEMPLATE}"
      WORKLOAD_DAEMON_SCRIPT="${PYTORCH_DAEMON_CLIENT_SCRIPT}"
      WORKLOAD_DAEMON_CONFIGMAP="pytorch-daemon-client-script"
      WORKLOAD_DAEMON_JOB_NAME="oci2gdsd-pytorch-daemon-client"
      WORKLOAD_DAEMON_CONTAINER_NAME="pytorch-daemon-client"
      ;;
    tensorrt)
      WORKLOAD_IMAGE="${TENSORRTLLM_IMAGE}"
      WORKLOAD_RUNTIME_IMAGE="${TENSORRTLLM_RUNTIME_IMAGE}"
      WORKLOAD_DAEMON_TEMPLATE="${TENSORRT_DAEMON_CLIENT_TEMPLATE}"
      WORKLOAD_DAEMON_SCRIPT="${TENSORRT_DAEMON_CLIENT_SCRIPT}"
      WORKLOAD_DAEMON_CONFIGMAP="tensorrt-daemon-client-script"
      WORKLOAD_DAEMON_JOB_NAME="oci2gdsd-tensorrt-daemon-client"
      WORKLOAD_DAEMON_CONTAINER_NAME="tensorrt-daemon-client"
      ;;
    vllm)
      WORKLOAD_IMAGE="${VLLM_IMAGE}"
      WORKLOAD_RUNTIME_IMAGE="${VLLM_RUNTIME_IMAGE}"
      WORKLOAD_DAEMON_TEMPLATE="${VLLM_DAEMON_CLIENT_TEMPLATE}"
      WORKLOAD_DAEMON_SCRIPT="${VLLM_DAEMON_CLIENT_SCRIPT}"
      WORKLOAD_DAEMON_CONFIGMAP="vllm-daemon-client-script"
      WORKLOAD_DAEMON_JOB_NAME="oci2gdsd-vllm-daemon-client"
      WORKLOAD_DAEMON_CONTAINER_NAME="vllm-daemon-client"
      ;;
  esac
  export WORKLOAD_IMAGE WORKLOAD_RUNTIME_IMAGE WORKLOAD_DAEMON_TEMPLATE WORKLOAD_DAEMON_SCRIPT \
    WORKLOAD_DAEMON_CONFIGMAP WORKLOAD_DAEMON_JOB_NAME WORKLOAD_DAEMON_CONTAINER_NAME
}

kube() {
  if [[ "${K3S_USE_SUDO}" == "true" && "$(id -u)" -ne 0 ]]; then
    sudo k3s kubectl "$@"
  else
    k3s kubectl "$@"
  fi
}

helm_kube() {
  if [[ "${K3S_USE_SUDO}" == "true" && "$(id -u)" -ne 0 ]]; then
    sudo helm --kubeconfig /etc/rancher/k3s/k3s.yaml "$@"
  else
    helm --kubeconfig /etc/rancher/k3s/k3s.yaml "$@"
  fi
}

cluster_hint() {
  echo "k3s"
}

resolve_cluster_mode
validate_deploy_mode
if [[ "${CLUSTER_MODE}" == "k3s" && "${REGISTRY_NAMESPACE}" == "oci2gdsd-registry" ]]; then
  REGISTRY_NAMESPACE="oci-model-registry"
fi
if [[ -z "${QWEN_HELLO_PROFILE}" ]]; then
  if [[ "${CLUSTER_MODE}" == "k3s" ]]; then
    QWEN_HELLO_PROFILE="host-direct"
  else
    QWEN_HELLO_PROFILE="default"
  fi
fi
if [[ "${QWEN_HELLO_PROFILE}" == "host-direct" ]]; then
  if [[ -z "${OCI2GDSD_ROOT_PATH_SET}" ]]; then
    OCI2GDSD_ROOT_PATH="/mnt/nvme/oci2gdsd"
  fi
  if [[ -z "${OCI2GDS_STRICT_SET}" ]]; then
    OCI2GDS_STRICT="true"
  fi
  if [[ -z "${OCI2GDS_PROBE_STRICT_SET}" ]]; then
    OCI2GDS_PROBE_STRICT="true"
  fi
  if [[ -z "${OCI2GDS_FORCE_NO_COMPAT_SET}" ]]; then
    OCI2GDS_FORCE_NO_COMPAT="true"
  fi
fi
if [[ "${E2E_DEPLOY_MODE}" == "daemonset-manifest" && "${REQUIRE_DIRECT_GDS}" == "true" && "${OCI2GDSD_ENABLE_GDS_IMAGE}" != "true" ]]; then
  if [[ -n "${OCI2GDSD_ENABLE_GDS_IMAGE_SET}" ]]; then
    die "E2E_DEPLOY_MODE=daemonset-manifest with REQUIRE_DIRECT_GDS=true requires OCI2GDSD_ENABLE_GDS_IMAGE=true"
  fi
  log "forcing OCI2GDSD_ENABLE_GDS_IMAGE=true for daemonset-manifest direct-GDS mode"
  OCI2GDSD_ENABLE_GDS_IMAGE="true"
fi
if [[ "${E2E_DEPLOY_MODE}" == "daemonset-manifest" && "${OCI2GDSD_ENABLE_GDS_IMAGE}" == "true" && -z "${REQUIRE_DAEMON_IPC_PROBE_SET}" ]]; then
  REQUIRE_DAEMON_IPC_PROBE="true"
fi
if [[ "${OCI2GDSD_ENABLE_GDS_IMAGE}" == "true" && -z "${OCI2GDSD_IMAGE_SET}" ]]; then
  OCI2GDSD_IMAGE="oci2gdsd:e2e-gds"
fi
if [[ "${OCI2GDSD_ENABLE_GDS_IMAGE}" == "true" && -z "${FORCE_OCI2GDSD_IMAGE_REBUILD_SET}" ]]; then
  FORCE_OCI2GDSD_IMAGE_REBUILD="true"
fi
if [[ -z "${QWEN_HELLO_TEMPLATE}" ]]; then
  QWEN_HELLO_TEMPLATE="${REPO_ROOT}/platform/k3s/workloads/pytorch/qwen-hello/qwen-k3s-hello-deployment.yaml.tpl"
fi
OCI2GDSD_DAEMON_TEMPLATE="${OCI2GDSD_DAEMON_TEMPLATE:-${REPO_ROOT}/platform/k3s/workloads/shared/oci2gdsd-daemonset.yaml.tpl}"
PYTORCH_DAEMON_CLIENT_TEMPLATE="${PYTORCH_DAEMON_CLIENT_TEMPLATE:-${REPO_ROOT}/platform/k3s/workloads/pytorch/pytorch-daemon-client-job.yaml.tpl}"
PYTORCH_DAEMON_CLIENT_SCRIPT="${PYTORCH_DAEMON_CLIENT_SCRIPT:-${REPO_ROOT}/platform/k3s/workloads/pytorch/pytorch_daemon_client.py}"
TENSORRT_DAEMON_CLIENT_TEMPLATE="${TENSORRT_DAEMON_CLIENT_TEMPLATE:-${REPO_ROOT}/platform/k3s/workloads/tensorrt/tensorrt-daemon-client-job.yaml.tpl}"
TENSORRT_DAEMON_CLIENT_SCRIPT="${TENSORRT_DAEMON_CLIENT_SCRIPT:-${REPO_ROOT}/platform/k3s/workloads/tensorrt/tensorrt_daemon_client.py}"
VLLM_DAEMON_CLIENT_TEMPLATE="${VLLM_DAEMON_CLIENT_TEMPLATE:-${REPO_ROOT}/platform/k3s/workloads/vllm/vllm-daemon-client-job.yaml.tpl}"
VLLM_DAEMON_CLIENT_SCRIPT="${VLLM_DAEMON_CLIENT_SCRIPT:-${REPO_ROOT}/platform/k3s/workloads/vllm/vllm_daemon_client.py}"
PYTORCH_DAEMON_NATIVE_CPP="${PYTORCH_DAEMON_NATIVE_CPP:-${REPO_ROOT}/platform/k3s/workloads/pytorch/qwen-hello/native/oci2gds_torch_native.cpp}"
validate_workload_runtime
configure_workload_runtime
validate_deploy_assets
enforce_strict_gds_policy

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
  if [[ "${CLUSTER_MODE}" != "k3s" ]]; then
    return
  fi
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

has_guest_nvme() {
  ls /dev/nvme*n1 >/dev/null 2>&1 || ls /dev/nvme*n1p* >/dev/null 2>&1 || ls /dev/nvme[0-9] >/dev/null 2>&1
}

find_nvme_mount_candidate() {
  lsblk -pnro NAME,TYPE,FSTYPE,MOUNTPOINT | awk '$1 ~ /^\/dev\/nvme/ && $2=="part" && $3!="" && $4=="" {print $1; exit 0}'
}

find_nvme_raw_disk_candidate() {
  lsblk -pnro NAME,TYPE | awk '$1 ~ /^\/dev\/nvme/ && $2=="disk" {print $1; exit 0}'
}

attempt_full_gds_remediation_bundle() {
  local gdscheck_bin="$1"
  local log_file="${WORK_DIR}/results/gds-remediation.log"
  local post_report="${WORK_DIR}/results/gdscheck-post-remediation.txt"
  local needs_reboot=0

  : > "${log_file}"
  {
    echo "## full remediation attempt $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "kernel_before=$(uname -r)"
    echo "driver_before=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
  } >> "${log_file}"

  if ! has_guest_nvme; then
    {
      echo "hard_blocker=no_guest_nvme"
      echo "lsblk:"
      lsblk -f || true
    } >> "${log_file}"
    return 2
  fi

  echo "non_destructive_step=skip_driver_kernel_package_mutation" >> "${log_file}"
  maybe_sudo modprobe nvidia_fs >> "${log_file}" 2>&1 || true

  maybe_sudo mkdir -p /mnt/nvme >> "${log_file}" 2>&1 || true
  if ! mountpoint -q /mnt/nvme; then
    local part
    part="$(find_nvme_mount_candidate || true)"
    if [[ -z "${part}" ]]; then
      local raw_disk
      raw_disk="$(find_nvme_raw_disk_candidate || true)"
      if [[ -n "${raw_disk}" ]]; then
        local part_name="${raw_disk}p1"
        if ! lsblk -pnro NAME "${raw_disk}" | grep -q "^${part_name}$"; then
          maybe_sudo parted -s "${raw_disk}" mklabel gpt >> "${log_file}" 2>&1 || true
          maybe_sudo parted -s "${raw_disk}" mkpart primary ext4 0% 100% >> "${log_file}" 2>&1 || true
        fi
        if ! maybe_sudo blkid "${part_name}" >/dev/null 2>&1; then
          maybe_sudo mkfs.ext4 -F "${part_name}" >> "${log_file}" 2>&1 || true
        fi
        part="${part_name}"
      fi
    fi
    if [[ -n "${part}" ]]; then
      maybe_sudo mount -o rw,noatime,data=ordered "${part}" /mnt/nvme >> "${log_file}" 2>&1 || true
      echo "mounted_nvme_part=${part}" >> "${log_file}"
    else
      echo "mounted_nvme_part=none" >> "${log_file}"
    fi
  fi

  if mountpoint -q /mnt/nvme; then
    configure_docker_data_root "/mnt/nvme/docker" >> "${log_file}" 2>&1 || true
  fi

  if [[ -f /var/run/reboot-required || -f /run/reboot-required ]]; then
    needs_reboot=1
  fi
  echo "reboot_required=${needs_reboot}" >> "${log_file}"

  maybe_sudo "${gdscheck_bin}" -p > "${post_report}" 2>&1 || true
  cat "${post_report}" >> "${log_file}" 2>&1 || true

  if grep -Eq 'NVMe[[:space:]]*:[[:space:]]*Supported' "${post_report}"; then
    return 0
  fi
  if [[ "${needs_reboot}" -eq 1 ]]; then
    return 3
  fi
  return 1
}

check_direct_gds_platform_support() {
  local gdscheck
  if ! gdscheck="$(gdscheck_binary)"; then
    warn "gdscheck not found; cannot verify direct GDS platform support"
    emit_direct_gds_remediation
    return 1
  fi
  mkdir -p "${WORK_DIR}/results"
  maybe_sudo chown -R "$(id -u):$(id -g)" "${WORK_DIR}/results" >/dev/null 2>&1 || true
  local report="${WORK_DIR}/results/gdscheck.txt"
  local tmp_report
  tmp_report="$(mktemp)"
  if ! maybe_sudo "${gdscheck}" -p >"${tmp_report}" 2>&1; then
    cat "${tmp_report}" >"${report}" 2>/dev/null || true
    rm -f "${tmp_report}"
    warn "gdscheck failed; see ${report}"
    emit_direct_gds_remediation
    return 1
  fi
  cat "${tmp_report}" >"${report}"
  rm -f "${tmp_report}"
  if ! grep -Eq 'NVMe[[:space:]]*:[[:space:]]*Supported' "${report}"; then
    if attempt_full_gds_remediation_bundle "${gdscheck}"; then
      log "full GDS remediation succeeded; proceeding with strict validation"
      cp "${WORK_DIR}/results/gdscheck-post-remediation.txt" "${report}" || true
      return 0
    fi
    local rc=$?
    if [[ "${rc}" -eq 2 ]]; then
      warn "gdscheck direct preflight failed and host has no guest-visible NVMe (/dev/nvme*)"
    elif [[ "${rc}" -eq 3 ]]; then
      warn "full GDS remediation attempted but reboot is required before strict validation"
    else
      warn "full GDS remediation attempted but NVMe direct path is still unavailable"
    fi
    emit_direct_gds_remediation
    return 1
  fi
  return 0
}

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
  cat <<EOF | kube apply -f -
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

write_environment_report() {
  if [[ "${RECORD_ENVIRONMENT_REPORT}" != "true" ]]; then
    return 0
  fi
  mkdir -p "${WORK_DIR}/results"
  local out="${WORK_DIR}/results/environment-report.txt"
  {
    echo "# k3s-e2e environment $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "cluster_mode=${CLUSTER_MODE}"
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
    die "runtime drift check failed (${label}): /dev/nvidia-fs* is missing"
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
  mkdir -p "${WORK_DIR}/results"
  local bin_path="${WORK_DIR}/oci2gdsd-gds"
  local gds_root="${WORK_DIR}/gds-root"
  local model_path="${gds_root}/models/demo/sha256-1111111111111111111111111111111111111111111111111111111111111111"
  log "building local oci2gdsd binary with -tags gds for preflight validation"
  (
    cd "${REPO_ROOT}"
    CGO_ENABLED=1 \
      CGO_CFLAGS="-I${CUDA_INCLUDE_DIR}" \
      CGO_LDFLAGS="-L${CUDA_LIB_DIR}" \
      go build -tags gds -o "${bin_path}" ./cmd/oci2gdsd
  )
  "${bin_path}" --root "${gds_root}" --target-root "${gds_root}/models" gpu probe --json > "${WORK_DIR}/results/gpu-probe.json"
  if ! jq -e '.available == true' "${WORK_DIR}/results/gpu-probe.json" >/dev/null; then
    die "local GDS probe failed; see ${WORK_DIR}/results/gpu-probe.json"
  fi

  mkdir -p "${model_path}/shards" "${model_path}/metadata"
  dd if=/dev/zero of="${model_path}/shards/weights-00001.safetensors" bs=4096 count=1 status=none
  printf "{}\n" > "${model_path}/shards/config.json"
  local w_digest r_digest w_size r_size
  w_digest="$(sha256sum "${model_path}/shards/weights-00001.safetensors" | awk '{print $1}')"
  r_digest="$(sha256sum "${model_path}/shards/config.json" | awk '{print $1}')"
  w_size="$(stat -c %s "${model_path}/shards/weights-00001.safetensors")"
  r_size="$(stat -c %s "${model_path}/shards/config.json")"
  cat > "${model_path}/metadata/model.json" <<EOF
{
  "schemaVersion": 1,
  "modelId": "demo",
  "manifestDigest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
  "profile": {
    "schemaVersion": 1,
    "modelId": "demo",
    "modelRevision": "r1",
    "framework": "pytorch",
    "format": "safetensors",
    "shards": [
      {"name": "weights-00001.safetensors", "digest": "sha256:${w_digest}", "size": ${w_size}, "ordinal": 1, "kind": "weight"},
      {"name": "config.json", "digest": "sha256:${r_digest}", "size": ${r_size}, "ordinal": 2, "kind": "runtime"}
    ],
    "integrity": {"manifestDigest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"}
  }
}
EOF
  printf "ok\n" > "${model_path}/READY"

  "${bin_path}" --root "${gds_root}" --target-root "${gds_root}/models" \
    gpu load --path "${model_path}" --mode benchmark --device 0 --chunk-bytes 4096 --strict --json > "${WORK_DIR}/results/gpu-load-benchmark.json"
  if ! jq -e '.status == "READY"' "${WORK_DIR}/results/gpu-load-benchmark.json" >/dev/null; then
    die "local GDS benchmark load failed; see ${WORK_DIR}/results/gpu-load-benchmark.json"
  fi
  if ! jq -e '.files | length == 1' "${WORK_DIR}/results/gpu-load-benchmark.json" >/dev/null; then
    die "expected exactly one weight shard to be loaded; see ${WORK_DIR}/results/gpu-load-benchmark.json"
  fi
  if ! jq -e '.files[0].direct == true' "${WORK_DIR}/results/gpu-load-benchmark.json" >/dev/null; then
    die "expected direct=true in local GDS benchmark result; see ${WORK_DIR}/results/gpu-load-benchmark.json"
  fi
}

build_and_load_oci2gdsd_image() {
  local dockerfile="${OCI2GDSD_DOCKERFILE}"
  local force_load="false"
  if [[ -z "${dockerfile}" ]]; then
    if [[ "${OCI2GDSD_ENABLE_GDS_IMAGE}" == "true" ]]; then
      dockerfile="${HARNESS_DIR}/Dockerfile.oci2gdsd.gds"
    else
      dockerfile="${HARNESS_DIR}/Dockerfile.oci2gdsd"
    fi
  fi
  if [[ "${SKIP_OCI2GDSD_IMAGE_BUILD}" != "true" ]]; then
    [[ -f "${dockerfile}" ]] || die "oci2gdsd dockerfile not found: ${dockerfile}"
    if docker image inspect "${OCI2GDSD_IMAGE}" >/dev/null 2>&1 && ! is_true "${FORCE_OCI2GDSD_IMAGE_REBUILD}"; then
      log "reusing existing oci2gdsd image ${OCI2GDSD_IMAGE}"
    else
      log "building oci2gdsd image ${OCI2GDSD_IMAGE} using ${dockerfile}"
      docker build -f "${dockerfile}" -t "${OCI2GDSD_IMAGE}" "${REPO_ROOT}"
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
    log "building oci2gdsd CLI image ${OCI2GDSD_CLI_IMAGE} using ${OCI2GDSD_CLI_DOCKERFILE}"
    docker build -f "${OCI2GDSD_CLI_DOCKERFILE}" -t "${OCI2GDSD_CLI_IMAGE}" "${REPO_ROOT}"
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
  if [[ "${image}" != */* ]]; then
    maybe_sudo k3s ctr -n k8s.io images tag "${image}" "docker.io/library/${image}" || true
  fi
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
  docker build -t "${PACKAGER_IMAGE}" "${REPO_ROOT}/models/packaging/qwen3-oci-modelprofile-v1"
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

ensure_namespace() {
  local ns="$1"
  if kube get namespace "${ns}" >/dev/null 2>&1; then
    return
  fi
  kube create namespace "${ns}" >/dev/null
}

apply_configmap_from_files() {
  local ns="$1"
  local name="$2"
  shift 2
  kube create configmap "${name}" -n "${ns}" "$@" --dry-run=client -o yaml | kube apply -f -
}

apply_daemonset_stack() {
  mkdir -p "${WORK_DIR}/rendered"
  local rendered="${WORK_DIR}/rendered/oci2gdsd-daemonset.yaml"
  render_template "${OCI2GDSD_DAEMON_TEMPLATE}" "${rendered}" \
    "OCI2GDSD_DAEMON_NAMESPACE=${OCI2GDSD_DAEMON_NAMESPACE}" \
    "OCI2GDSD_ROOT_PATH=${OCI2GDSD_ROOT_PATH}" \
    "OCI2GDSD_SOCKET_HOST_PATH=${OCI2GDSD_SOCKET_HOST_PATH}" \
    "OCI2GDSD_IMAGE=${OCI2GDSD_IMAGE}"
  kube apply -f "${rendered}"
  kube -n "${OCI2GDSD_DAEMON_NAMESPACE}" rollout status daemonset/oci2gdsd-daemon --timeout=900s
}

capture_daemonset_logs() {
  local out="${1:-${WORK_DIR}/results/daemonset.log}"
  mkdir -p "$(dirname "${out}")"
  local pod_name
  pod_name="$(kube -n "${OCI2GDSD_DAEMON_NAMESPACE}" get pod \
    -l app.kubernetes.io/name=oci2gdsd-daemon \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${pod_name}" ]]; then
    warn "failed to resolve oci2gdsd daemon pod name in namespace ${OCI2GDSD_DAEMON_NAMESPACE}"
    return 1
  fi
  kube -n "${OCI2GDSD_DAEMON_NAMESPACE}" logs "pod/${pod_name}" > "${out}" 2>/dev/null || true
}

apply_registry() {
  mkdir -p "${WORK_DIR}/rendered"
  local rendered="${WORK_DIR}/rendered/registry.yaml"
  render_template "${HARNESS_DIR}/manifests/registry.yaml.tpl" "${rendered}" \
    "REGISTRY_NAMESPACE=${REGISTRY_NAMESPACE}" \
    "REGISTRY_SERVICE=${REGISTRY_SERVICE}"
  kube apply -f "${rendered}"
  kube -n "${REGISTRY_NAMESPACE}" rollout status deploy/"${REGISTRY_SERVICE}" --timeout=180s
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

  kube -n "${REGISTRY_NAMESPACE}" \
    port-forward svc/"${REGISTRY_SERVICE}" "${LOCAL_REGISTRY_PORT}:5000" \
    > "${LOG_DIR}/registry-port-forward.log" 2>&1 &
  echo $! > "${PF_PID_FILE}"

  local pid
  pid="$(cat "${PF_PID_FILE}")"
  local attempts="${REGISTRY_PORT_FORWARD_RETRIES:-60}"
  local delay="${REGISTRY_PORT_FORWARD_RETRY_DELAY_SEC:-1}"
  local i
  for ((i=1; i<=attempts; i++)); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      warn "registry port-forward exited early (pid=${pid})"
      if [[ -f "${LOG_DIR}/registry-port-forward.log" ]]; then
        warn "registry port-forward log:"
        cat "${LOG_DIR}/registry-port-forward.log" >&2 || true
      fi
      die "registry port-forward failed to stay running"
    fi
    if curl --max-time 2 -fsS "http://127.0.0.1:${LOCAL_REGISTRY_PORT}/v2/_catalog" >/dev/null 2>&1; then
      log "registry port-forward is ready on 127.0.0.1:${LOCAL_REGISTRY_PORT}"
      return 0
    fi
    sleep "${delay}"
  done

  warn "registry endpoint did not become ready after ${attempts} attempts"
  if [[ -f "${LOG_DIR}/registry-port-forward.log" ]]; then
    warn "registry port-forward log:"
    cat "${LOG_DIR}/registry-port-forward.log" >&2 || true
  fi
  die "registry readiness check failed at 127.0.0.1:${LOCAL_REGISTRY_PORT}"
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
  mkdir -p "${packager_work}/.cache/huggingface"
  log "packaging model ${HF_REPO}@${HF_REVISION} to local registry"
  docker run --rm --network host \
    -u "$(id -u):$(id -g)" \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    -e HOME="/work" \
    -e HF_HOME="/work/.cache/huggingface" \
    -e XDG_CACHE_HOME="/work/.cache" \
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

assert_profile_probe_perf_gates() {
  local throughput="$1"
  local duration_ms="$2"
  local min_required="${MIN_PROFILE_PROBE_MIB_S}"
  local baseline_file="${PROFILE_PROBE_BASELINE_FILE}"
  local max_reg_pct="${PROFILE_PROBE_MAX_REGRESSION_PCT}"

  if ! [[ "${min_required}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    die "MIN_PROFILE_PROBE_MIB_S must be numeric (got ${min_required})"
  fi
  if ! [[ "${max_reg_pct}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    die "PROFILE_PROBE_MAX_REGRESSION_PCT must be numeric (got ${max_reg_pct})"
  fi
  awk -v t="${throughput}" -v m="${min_required}" 'BEGIN {exit !(t+0 >= m+0)}' || \
    die "profile probe throughput too low: ${throughput} MiB/s < ${min_required} MiB/s"

  mkdir -p "$(dirname "${baseline_file}")"
  if [[ ! -f "${baseline_file}" ]]; then
    jq -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson throughput "$(printf '%s' "${throughput}")" \
      --argjson duration_ms "$(printf '%s' "${duration_ms}")" \
      '{created_at:$ts, throughput_mib_s:$throughput, duration_ms:$duration_ms}' > "${baseline_file}"
    log "created profile probe baseline: ${baseline_file}"
    return 0
  fi
  if [[ "${max_reg_pct}" == "0" || "${max_reg_pct}" == "0.0" ]]; then
    return 0
  fi
  local baseline_throughput
  baseline_throughput="$(jq -r '.throughput_mib_s // 0' "${baseline_file}" 2>/dev/null || echo 0)"
  local min_allowed
  min_allowed="$(awk -v b="${baseline_throughput}" -v p="${max_reg_pct}" 'BEGIN {printf "%.2f", b * (1 - (p/100.0))}')"
  awk -v t="${throughput}" -v m="${min_allowed}" 'BEGIN {exit !(t+0 >= m+0)}' || \
    die "profile probe throughput regression exceeded threshold: current=${throughput} baseline=${baseline_throughput} max_regression_pct=${max_reg_pct} min_allowed=${min_allowed}"
}

validate_qwen_hello_example() {
  local template="${QWEN_HELLO_TEMPLATE}"
  local app_dir="${REPO_ROOT}/platform/k3s/workloads/pytorch/qwen-hello/app"
  local native_dir="${REPO_ROOT}/platform/k3s/workloads/pytorch/qwen-hello/native"
  if [[ ! -f "${template}" ]]; then
    warn "missing example template: ${template}"
    return 1
  fi
  [[ -f "${app_dir}/qwen_server.py" ]] || die "missing qwen app script: ${app_dir}/qwen_server.py"
  [[ -f "${app_dir}/deps_bootstrap.py" ]] || die "missing qwen deps script: ${app_dir}/deps_bootstrap.py"
  [[ -f "${native_dir}/oci2gds_torch_native.cpp" ]] || die "missing native source: ${native_dir}/oci2gds_torch_native.cpp"

  ensure_namespace "${QWEN_HELLO_NAMESPACE}"
  apply_configmap_from_files "${QWEN_HELLO_NAMESPACE}" "qwen-hello-app" \
    --from-file=qwen_server.py="${app_dir}/qwen_server.py" \
    --from-file=deps_bootstrap.py="${app_dir}/deps_bootstrap.py"
  apply_configmap_from_files "${QWEN_HELLO_NAMESPACE}" "qwen-hello-native" \
    --from-file=oci2gds_torch_native.cpp="${native_dir}/oci2gds_torch_native.cpp"

  if [[ "${QWEN_HELLO_PROFILE}" == "host-direct" && "${CLUSTER_MODE}" == "k3s" ]]; then
    maybe_sudo mkdir -p "${OCI2GDSD_ROOT_PATH}" || true
  fi
  mkdir -p "${WORK_DIR}/rendered" "${WORK_DIR}/results"
  local rendered="${WORK_DIR}/rendered/qwen-hello.yaml"
  local model_root="${OCI2GDSD_ROOT_PATH}/models/${MODEL_ID}/${MODEL_DIGEST//:/-}"
  render_template "${template}" "${rendered}" \
    "QWEN_HELLO_NAMESPACE=${QWEN_HELLO_NAMESPACE}" \
    "MODEL_ID=${MODEL_ID}" \
    "MODEL_REF=${MODEL_REF}" \
    "MODEL_DIGEST=${MODEL_DIGEST}" \
    "MODEL_ROOT_PATH=${model_root}" \
    "OCI2GDSD_IMAGE=${OCI2GDSD_IMAGE}" \
    "OCI2GDSD_ROOT_PATH=${OCI2GDSD_ROOT_PATH}" \
    "OCI2GDS_STRICT=${OCI2GDS_STRICT}" \
    "OCI2GDS_PROBE_STRICT=${OCI2GDS_PROBE_STRICT}" \
    "OCI2GDS_FORCE_NO_COMPAT=${OCI2GDS_FORCE_NO_COMPAT}" \
    "OCI2GDS_DAEMON_ENABLE=${OCI2GDS_DAEMON_ENABLE}" \
    "OCI2GDS_DAEMON_PROBE_SHARDS=${OCI2GDS_DAEMON_PROBE_SHARDS}" \
    "PYTORCH_RUNTIME_IMAGE=${PYTORCH_RUNTIME_IMAGE}" \
    "LEASE_HOLDER=${LEASE_HOLDER}"

  if [[ "${CLUSTER_MODE}" == "k3s" ]] && ! grep -q 'runtimeClassName: nvidia' "${rendered}"; then
    gsed -i 's|restartPolicy: Always|restartPolicy: Always\
      runtimeClassName: nvidia|' "${rendered}"
  fi

  kube apply -f "${rendered}"
  kube -n "${QWEN_HELLO_NAMESPACE}" \
    rollout status deploy/qwen-hello --timeout=1800s
  local log_file="${WORK_DIR}/results/qwen-hello.log"
  : > "${log_file}"
  local pod_name
  pod_name="$(kube -n "${QWEN_HELLO_NAMESPACE}" \
    get pod -l app=qwen-hello -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${pod_name}" ]]; then
    warn "failed to resolve qwen-hello pod name"
    return 1
  fi

  local pf_pid_file="${WORK_DIR}/qwen-hello-port-forward.pid"
  local pf_log="${WORK_DIR}/logs/qwen-hello-port-forward.log"
  local local_port="${QWEN_HELLO_LOCAL_PORT:-18080}"
  rm -f "${pf_pid_file}"
  kube -n "${QWEN_HELLO_NAMESPACE}" \
    port-forward svc/qwen-hello "${local_port}:8000" >"${pf_log}" 2>&1 &
  echo "$!" > "${pf_pid_file}"

  local start_ts timeout_secs now
  start_ts="$(date +%s)"
  timeout_secs=300
  while true; do
    if curl -fsS "http://127.0.0.1:${local_port}/healthz" >/dev/null 2>&1; then
      break
    fi
    now="$(date +%s)"
    if (( now - start_ts >= timeout_secs )); then
      warn "qwen hello API did not become healthy within ${timeout_secs}s"
      if [[ -s "${pf_log}" ]]; then
        warn "port-forward log:"
        cat "${pf_log}" >&2 || true
      fi
      if [[ -f "${pf_pid_file}" ]]; then
        kill "$(cat "${pf_pid_file}")" 2>/dev/null || true
      fi
      return 1
    fi
    sleep 3
  done

  local prompt='Explain in one sentence what GPU model preloading helps with.'
  local health_response
  health_response="$(curl -fsS "http://127.0.0.1:${local_port}/healthz" || true)"
  local health_status
  health_status="$(printf '%s' "${health_response}" | jq -r '.status // empty' 2>/dev/null || true)"
  local oci2gds_profile_status
  oci2gds_profile_status="$(printf '%s' "${health_response}" | jq -r '.oci2gds_profile.status // empty' 2>/dev/null || true)"
  local oci2gds_profile_backend
  oci2gds_profile_backend="$(printf '%s' "${health_response}" | jq -r '.oci2gds_profile.backend // empty' 2>/dev/null || true)"
  local oci2gds_backend
  oci2gds_backend="$(printf '%s' "${health_response}" | jq -r '.oci2gds_backend.backend // empty' 2>/dev/null || true)"
  local oci2gds_mode_counts
  oci2gds_mode_counts="$(printf '%s' "${health_response}" | jq -r '.oci2gds_profile.mode_counts // "{}"' 2>/dev/null || true)"
  local oci2gds_direct_count
  oci2gds_direct_count="$(printf '%s' "${health_response}" | jq -r '
    (.oci2gds_profile.mode_counts // {}) |
    (if type=="string" then (try fromjson catch {}) elif type=="object" then . else {} end) |
    .direct // 0
  ' 2>/dev/null || true)"
  local oci2gds_compat_count
  oci2gds_compat_count="$(printf '%s' "${health_response}" | jq -r '
    (.oci2gds_profile.mode_counts // {}) |
    (if type=="string" then (try fromjson catch {}) elif type=="object" then . else {} end) |
    .compat // 0
  ' 2>/dev/null || true)"
  local oci2gds_force_no_compat
  oci2gds_force_no_compat="$(printf '%s' "${health_response}" | jq -r '(.oci2gds_backend.force_no_compat // .oci2gds_profile.force_no_compat // false) | tostring' 2>/dev/null || true)"
  local oci2gds_cufile_env_path
  oci2gds_cufile_env_path="$(printf '%s' "${health_response}" | jq -r '.oci2gds_backend.cufile_env_path // .oci2gds_profile.cufile_env_path // ""' 2>/dev/null || true)"
  local oci2gds_cufile_init_ok
  oci2gds_cufile_init_ok="$(printf '%s' "${health_response}" | jq -r '(.oci2gds_profile.cufile_init_ok // false) | tostring' 2>/dev/null || true)"
  local oci2gds_probe_duration_ms
  oci2gds_probe_duration_ms="$(printf '%s' "${health_response}" | jq -r '.oci2gds_profile.duration_ms // 0' 2>/dev/null || true)"
  local oci2gds_probe_throughput_mib_s
  oci2gds_probe_throughput_mib_s="$(printf '%s' "${health_response}" | jq -r '.oci2gds_profile.throughput_mib_s // 0' 2>/dev/null || true)"
  local oci2gds_ipc_status
  oci2gds_ipc_status="$(printf '%s' "${health_response}" | jq -r '.oci2gds_ipc.status // empty' 2>/dev/null || true)"
  local oci2gds_ipc_backend
  oci2gds_ipc_backend="$(printf '%s' "${health_response}" | jq -r '.oci2gds_ipc.import_backend // empty' 2>/dev/null || true)"
  local response
  response="$(curl -fsS -X POST "http://127.0.0.1:${local_port}/chat" \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg prompt "${prompt}" '{prompt:$prompt}')" || true)"
  local answer
  answer="$(printf '%s' "${response}" | jq -r '.answer // empty' 2>/dev/null || true)"

  kube -n "${QWEN_HELLO_NAMESPACE}" \
    logs "pod/${pod_name}" -c pytorch-api > "${log_file}" 2>/dev/null || true
  printf '\nQWEN_K3S_HELLO_HEALTH_RESPONSE %s\n' "${health_response}" >> "${log_file}"
  printf '\nQWEN_K3S_HELLO_CHAT_RESPONSE %s\n' "${response}" >> "${log_file}"

  if [[ -f "${pf_pid_file}" ]]; then
    kill "$(cat "${pf_pid_file}")" 2>/dev/null || true
    rm -f "${pf_pid_file}"
  fi

  if [[ -z "${answer}" ]]; then
    warn "qwen hello API returned empty answer; response=${response}"
    return 1
  fi
  if [[ "${health_status}" != "ok" ]]; then
    warn "qwen hello health status is not ok: ${health_status}"
    return 1
  fi
  if [[ -z "${oci2gds_profile_status}" || "${oci2gds_profile_status}" != "ok" ]]; then
    warn "qwen hello oci2gds profile probe failed: status=${oci2gds_profile_status} backend=${oci2gds_profile_backend} mode_counts=${oci2gds_mode_counts}"
    return 1
  fi
  if [[ "${REQUIRE_STRICT_PROFILE_PROBE}" == "true" ]]; then
    if [[ "${oci2gds_profile_backend}" != "native-cufile" ]]; then
      warn "strict profile probe backend check failed: profile_backend=${oci2gds_profile_backend} runtime_backend=${oci2gds_backend}"
      return 1
    fi
    if [[ "${oci2gds_cufile_init_ok}" != "true" ]]; then
      warn "strict profile probe cufile init check failed: cufile_init_ok=${oci2gds_cufile_init_ok}"
      return 1
    fi
  fi
  if [[ "${REQUIRE_DIRECT_GDS}" == "true" ]]; then
    if [[ -z "${oci2gds_direct_count}" || "${oci2gds_direct_count}" == "0" ]]; then
      warn "qwen hello direct GDS requirement failed: direct_count=${oci2gds_direct_count} mode_counts=${oci2gds_mode_counts}"
      return 1
    fi
  fi
  if [[ "${REQUIRE_NO_COMPAT_EVIDENCE}" == "true" && "${OCI2GDS_FORCE_NO_COMPAT}" == "true" ]]; then
    if [[ "${oci2gds_force_no_compat}" != "true" ]]; then
      warn "force-no-compat evidence missing from health payload: force_no_compat=${oci2gds_force_no_compat}"
      return 1
    fi
    if [[ -z "${oci2gds_cufile_env_path}" ]]; then
      warn "force-no-compat evidence missing: cufile_env_path is empty"
      return 1
    fi
    if [[ "${oci2gds_compat_count}" != "0" ]]; then
      warn "compat mode reads observed despite OCI2GDS_FORCE_NO_COMPAT=true: compat_count=${oci2gds_compat_count}"
      return 1
    fi
  fi
  if [[ "${REQUIRE_DAEMON_IPC_PROBE}" == "true" && "${oci2gds_ipc_status}" != "ok" ]]; then
    warn "qwen hello daemon ipc probe not ok: status=${oci2gds_ipc_status} backend=${oci2gds_ipc_backend}"
    return 1
  fi
  assert_profile_probe_perf_gates "${oci2gds_probe_throughput_mib_s}" "${oci2gds_probe_duration_ms}"
  log "qwen profile probe perf: duration_ms=${oci2gds_probe_duration_ms} throughput_mib_s=${oci2gds_probe_throughput_mib_s}"
  printf 'QWEN_K3S_HELLO_SUCCESS prompt=%s answer=%s oci2gds_profile_status=%s oci2gds_backend=%s oci2gds_mode_counts=%s oci2gds_ipc_status=%s oci2gds_ipc_backend=%s\n' \
    "${prompt}" "${answer}" "${oci2gds_profile_status}" "${oci2gds_backend}" "${oci2gds_mode_counts}" "${oci2gds_ipc_status}" "${oci2gds_ipc_backend}" >> "${log_file}"
  printf 'QWEN_K3S_HELLO_PROFILE_PROBE backend=%s direct=%s compat=%s cufile_init_ok=%s force_no_compat=%s cufile_env_path=%s duration_ms=%s throughput_mib_s=%s\n' \
    "${oci2gds_profile_backend}" "${oci2gds_direct_count}" "${oci2gds_compat_count}" "${oci2gds_cufile_init_ok}" "${oci2gds_force_no_compat}" "${oci2gds_cufile_env_path}" "${oci2gds_probe_duration_ms}" "${oci2gds_probe_throughput_mib_s}" >> "${log_file}"
  return 0
}

cleanup_qwen_hello_example() {
  kube delete namespace "${QWEN_HELLO_NAMESPACE}" --ignore-not-found >/dev/null || true
}

collect_debug() {
  warn "collecting debug artifacts"
  kube get nodes -o wide || true
  kube get pods -A || true
  kube -n gpu-operator get pods -o wide || true
  kube -n "${OCI2GDSD_DAEMON_NAMESPACE}" get pods -o wide || true
  kube -n "${E2E_NAMESPACE}" get pods -o wide || true
  kube -n "${E2E_NAMESPACE}" get jobs || true
  kube -n "${QWEN_HELLO_NAMESPACE}" get pods -o wide || true
}
