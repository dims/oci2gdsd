#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${HARNESS_DIR}/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"
WORK_DIR="${HARNESS_DIR}/work"
ARTIFACTS_DIR="${WORK_DIR}/artifacts"
LOG_DIR="${ARTIFACTS_DIR}/logs"
RESULTS_DIR="${ARTIFACTS_DIR}/results"
RENDERED_DIR="${ARTIFACTS_DIR}/rendered"
mkdir -p "${WORK_DIR}" "${LOG_DIR}" "${RESULTS_DIR}" "${RENDERED_DIR}"
ENV_DEFAULTS_FILE="${HARNESS_DIR}/.env.defaults"
if [[ -f "${ENV_DEFAULTS_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_DEFAULTS_FILE}"
else
  die "missing k3s harness defaults file: ${ENV_DEFAULTS_FILE}"
fi

if [[ -z "${REQUIRE_DAEMON_IPC_PROBE}" ]]; then
  REQUIRE_DAEMON_IPC_PROBE="${OCI2GDSD_ENABLE_GDS_IMAGE}"
fi

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
  enforce_boolean_true_policy \
    "ALLOW_RELAXED_GDS" \
    "strict GDS policy" \
    REQUIRE_DIRECT_GDS \
    OCI2GDS_STRICT \
    OCI2GDS_PROBE_STRICT \
    OCI2GDS_FORCE_NO_COMPAT \
    REQUIRE_STRICT_PROFILE_PROBE \
    REQUIRE_NO_COMPAT_EVIDENCE
}

validate_runtime_contracts() {
  local runtime="${1:-${WORKLOAD_RUNTIME}}"
  local report="${2:-${RESULTS_DIR}/runtime-contract-report.json}"
  local validator="${SCRIPT_DIR}/validate-runtime-contract.sh"
  [[ -x "${validator}" ]] || die "runtime contract validator is missing or not executable: ${validator}"
  "${validator}" \
    --runtime "${runtime}" \
    --include-qwen \
    --report "${report}"
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

  local k3s_dir k3s_need k3s_avail nvme_avail
  k3s_dir="$(k3s_data_dir)"
  k3s_need=$((MIN_FREE_GB_K3S * 1024 * 1024))
  k3s_avail="$(path_available_kb "${k3s_dir}")"
  nvme_avail="$(path_available_kb "/mnt/nvme")"
  if (( k3s_avail < k3s_need )) && [[ "${k3s_dir}" != /mnt/nvme/* ]] && (( nvme_avail >= k3s_need )); then
    configure_k3s_data_dir "/mnt/nvme/k3s"
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

  mkdir -p "${RESULTS_DIR}"
  local report="${RESULTS_DIR}/storage-prereq.txt"
  {
    echo "# storage preflight $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    df -h
  } > "${report}" 2>&1 || true

  local docker_root
  docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  [[ -n "${docker_root}" ]] || die "failed to detect DockerRootDir from docker info"

  check_path_free_gb "docker data-root" "${docker_root}" "${MIN_FREE_GB_DOCKER}"
  check_path_free_gb "oci2gdsd root path" "${OCI2GDSD_ROOT_PATH}" "${MIN_FREE_GB_OCI2GDS_ROOT}"

  local k3s_dir
  k3s_dir="$(k3s_data_dir)"
  check_path_free_gb "k3s data root" "${k3s_dir}" "${MIN_FREE_GB_K3S}"
}

validate_deploy_mode() {
  [[ "${E2E_DEPLOY_MODE}" == "daemonset-manifest" ]] || \
    die "unsupported E2E_DEPLOY_MODE=${E2E_DEPLOY_MODE} (expected daemonset-manifest)"
}

validate_deploy_assets() {
  [[ -f "${OCI2GDSD_DAEMON_TEMPLATE}" ]] || die "missing daemonset template: ${OCI2GDSD_DAEMON_TEMPLATE}"
  [[ -f "${WORKLOAD_DAEMON_TEMPLATE}" ]] || die "missing daemonset workload template: ${WORKLOAD_DAEMON_TEMPLATE}"
  [[ -f "${WORKLOAD_DAEMON_SCRIPT}" ]] || die "missing daemon client script: ${WORKLOAD_DAEMON_SCRIPT}"
  if [[ "${WORKLOAD_RUNTIME}" == "pytorch" || "${WORKLOAD_RUNTIME}" == "vllm" || "${WORKLOAD_RUNTIME}" == "tensorrt" ]]; then
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
      WORKLOAD_ADAPTER_SCRIPT="${REPO_ROOT}/platform/k3s/runtimes/pytorch.sh"
      WORKLOAD_DAEMON_CONFIGMAP="pytorch-daemon-client-script"
      WORKLOAD_DAEMON_JOB_NAME="oci2gdsd-pytorch-daemon-client"
      WORKLOAD_DAEMON_CONTAINER_NAME="pytorch-daemon-client"
      ;;
    tensorrt)
      WORKLOAD_IMAGE="${TENSORRTLLM_IMAGE}"
      WORKLOAD_RUNTIME_IMAGE="${TENSORRTLLM_RUNTIME_IMAGE}"
      WORKLOAD_DAEMON_TEMPLATE="${TENSORRT_DAEMON_CLIENT_TEMPLATE}"
      WORKLOAD_DAEMON_SCRIPT="${TENSORRT_DAEMON_CLIENT_SCRIPT}"
      WORKLOAD_ADAPTER_SCRIPT="${REPO_ROOT}/platform/k3s/runtimes/tensorrt.sh"
      WORKLOAD_DAEMON_CONFIGMAP="tensorrt-daemon-client-script"
      WORKLOAD_DAEMON_JOB_NAME="oci2gdsd-tensorrt-daemon-client"
      WORKLOAD_DAEMON_CONTAINER_NAME="tensorrt-daemon-client"
      ;;
    vllm)
      WORKLOAD_IMAGE="${VLLM_IMAGE}"
      WORKLOAD_RUNTIME_IMAGE="${VLLM_RUNTIME_IMAGE}"
      WORKLOAD_DAEMON_TEMPLATE="${VLLM_DAEMON_CLIENT_TEMPLATE}"
      WORKLOAD_DAEMON_SCRIPT="${VLLM_DAEMON_CLIENT_SCRIPT}"
      WORKLOAD_ADAPTER_SCRIPT="${REPO_ROOT}/platform/k3s/runtimes/vllm.sh"
      WORKLOAD_DAEMON_CONFIGMAP="vllm-daemon-client-script"
      WORKLOAD_DAEMON_JOB_NAME="oci2gdsd-vllm-daemon-client"
      WORKLOAD_DAEMON_CONTAINER_NAME="vllm-daemon-client"
      ;;
  esac
  [[ -f "${WORKLOAD_ADAPTER_SCRIPT}" ]] || die "missing runtime adapter: ${WORKLOAD_ADAPTER_SCRIPT}"
  export WORKLOAD_IMAGE WORKLOAD_RUNTIME_IMAGE WORKLOAD_DAEMON_TEMPLATE WORKLOAD_DAEMON_SCRIPT \
    WORKLOAD_DAEMON_CONFIGMAP WORKLOAD_DAEMON_JOB_NAME WORKLOAD_DAEMON_CONTAINER_NAME \
    WORKLOAD_ADAPTER_SCRIPT
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

validate_deploy_mode
if [[ "${REGISTRY_NAMESPACE}" == "oci2gdsd-registry" ]]; then
  REGISTRY_NAMESPACE="oci-model-registry"
fi
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
if [[ "${REQUIRE_DIRECT_GDS}" == "true" && "${OCI2GDSD_ENABLE_GDS_IMAGE}" != "true" ]]; then
  if [[ -n "${OCI2GDSD_ENABLE_GDS_IMAGE_SET}" ]]; then
    die "REQUIRE_DIRECT_GDS=true requires OCI2GDSD_ENABLE_GDS_IMAGE=true in k3s daemonset harness"
  fi
  log "forcing OCI2GDSD_ENABLE_GDS_IMAGE=true for direct-GDS mode"
  OCI2GDSD_ENABLE_GDS_IMAGE="true"
fi
if [[ "${OCI2GDSD_ENABLE_GDS_IMAGE}" == "true" && -z "${REQUIRE_DAEMON_IPC_PROBE_SET}" ]]; then
  REQUIRE_DAEMON_IPC_PROBE="true"
fi
if [[ "${OCI2GDSD_ENABLE_GDS_IMAGE}" == "true" && -z "${OCI2GDSD_IMAGE_SET}" ]]; then
  OCI2GDSD_IMAGE="oci2gdsd:e2e-gds"
fi
if [[ "${OCI2GDSD_ENABLE_GDS_IMAGE}" == "true" && -z "${FORCE_OCI2GDSD_IMAGE_REBUILD_SET}" ]]; then
  FORCE_OCI2GDSD_IMAGE_REBUILD="true"
fi
if [[ -z "${QWEN_HELLO_TEMPLATE}" ]]; then
  QWEN_HELLO_TEMPLATE="${REPO_ROOT}/platform/k3s/pytorch/qwen-k3s-hello-deployment.yaml.tpl"
fi
OCI2GDSD_DAEMON_TEMPLATE="${OCI2GDSD_DAEMON_TEMPLATE:-${REPO_ROOT}/platform/k3s/shared/oci2gdsd-daemonset.yaml.tpl}"
PYTORCH_DAEMON_CLIENT_TEMPLATE="${PYTORCH_DAEMON_CLIENT_TEMPLATE:-${REPO_ROOT}/platform/k3s/pytorch/pytorch-daemon-client-job.yaml.tpl}"
PYTORCH_DAEMON_CLIENT_SCRIPT="${PYTORCH_DAEMON_CLIENT_SCRIPT:-${REPO_ROOT}/platform/k3s/pytorch/pytorch_daemon_client.py}"
TENSORRT_DAEMON_CLIENT_TEMPLATE="${TENSORRT_DAEMON_CLIENT_TEMPLATE:-${REPO_ROOT}/platform/k3s/tensorrt/tensorrt-daemon-client-job.yaml.tpl}"
TENSORRT_DAEMON_CLIENT_SCRIPT="${TENSORRT_DAEMON_CLIENT_SCRIPT:-${REPO_ROOT}/platform/k3s/tensorrt/tensorrt_daemon_client.py}"
VLLM_DAEMON_CLIENT_TEMPLATE="${VLLM_DAEMON_CLIENT_TEMPLATE:-${REPO_ROOT}/platform/k3s/vllm/vllm-daemon-client-job.yaml.tpl}"
VLLM_DAEMON_CLIENT_SCRIPT="${VLLM_DAEMON_CLIENT_SCRIPT:-${REPO_ROOT}/platform/k3s/vllm/vllm_daemon_client.py}"
PYTORCH_DAEMON_NATIVE_CPP="${PYTORCH_DAEMON_NATIVE_CPP:-${REPO_ROOT}/platform/k3s/pytorch/native/oci2gds_torch_native.cpp}"
validate_workload_runtime
configure_workload_runtime
validate_deploy_assets
enforce_strict_gds_policy

# Function modules (kept sourced from a single entrypoint for compatibility).
# shellcheck source=./common/tools.sh
source "${SCRIPT_DIR}/common/tools.sh"
# shellcheck source=./common/gds-platform.sh
source "${SCRIPT_DIR}/common/gds-platform.sh"
# shellcheck source=./common/cluster.sh
source "${SCRIPT_DIR}/common/cluster.sh"
# shellcheck source=./common/reporting.sh
source "${SCRIPT_DIR}/common/reporting.sh"

# shellcheck source=../lib/images.sh
source "${HARNESS_DIR}/lib/images.sh"
# shellcheck source=../lib/deploy.sh
source "${HARNESS_DIR}/lib/deploy.sh"
# shellcheck source=../lib/qwen.sh
source "${HARNESS_DIR}/lib/qwen.sh"
