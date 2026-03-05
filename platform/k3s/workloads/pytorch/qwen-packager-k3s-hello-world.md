# Qwen Packager + k3s Hello World

This walkthrough packages `Qwen/Qwen3-0.6B` as an OCI artifact and deploys the
`qwen-hello` FastAPI example on host-native `k3s`.

## Recommended: automated path

From repo root:

```bash
make verify-k3s-qwen-e2e-inline
```

That flow already performs packaging, preload, workload validation, and lifecycle checks.

## Manual path (k3s)

### 1. Verify k3s and GPU scheduling

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
```

If `nvidia.com/gpu` is missing, install GPU Operator:

```bash
sudo helm --kubeconfig /etc/rancher/k3s/k3s.yaml repo add nvidia https://helm.ngc.nvidia.com/nvidia
sudo helm --kubeconfig /etc/rancher/k3s/k3s.yaml repo update
sudo helm --kubeconfig /etc/rancher/k3s/k3s.yaml upgrade -i \
  --namespace gpu-operator \
  --create-namespace \
  --set driver.enabled=false \
  --set toolkit.enabled=false \
  --set dcgmExporter.enabled=false \
  --set nfd.enabled=true \
  --wait --timeout=600s \
  gpu-operator nvidia/gpu-operator
```

### 2. Deploy in-cluster OCI registry

```bash
sudo k3s kubectl apply -f platform/k3s/workloads/pytorch/oci-model-registry.yaml
sudo k3s kubectl -n oci-model-registry rollout status deploy/oci-model-registry --timeout=180s
```

Port-forward registry (keep this terminal open):

```bash
sudo k3s kubectl -n oci-model-registry port-forward svc/oci-model-registry 5000:5000
```

### 3. Build and run the packager

In another terminal:

```bash
docker build -t oci2gdsd-qwen3-packager:local models/qwen3-oci-modelprofile-v1

export WORK_DIR="$(pwd)/work/qwen-packager-k3s-hello"
mkdir -p "${WORK_DIR}"

docker run --rm --network host \
  -e HF_TOKEN="${HF_TOKEN:-}" \
  -u "$(id -u):$(id -g)" \
  -v "${WORK_DIR}:/work" \
  oci2gdsd-qwen3-packager:local \
  --hf-repo Qwen/Qwen3-0.6B \
  --hf-revision main \
  --model-id qwen3-0.6b \
  --oci-ref "localhost:5000/models/qwen3-0.6b:v1" \
  --plain-http

export MODEL_DIGEST="$(jq -r '.digest' "${WORK_DIR}/output/manifest-descriptor.json")"
export MODEL_REF="oci-model-registry.oci-model-registry.svc.cluster.local:5000/models/qwen3-0.6b@${MODEL_DIGEST}"
```

### 4. Build `oci2gdsd` runtime image

```bash
docker build -f platform/k3s/e2e/Dockerfile.oci2gdsd -t oci2gdsd:hello .
docker save oci2gdsd:hello | sudo k3s ctr -n k8s.io images import -
```

### 5. Render and apply qwen-hello deployment

```bash
export MODEL_ID="qwen3-0.6b"
export OCI2GDSD_IMAGE="oci2gdsd:hello"
export OCI2GDSD_ROOT_PATH="/mnt/nvme/oci2gdsd"
export QWEN_HELLO_NAMESPACE="qwen-hello"
export LEASE_HOLDER="qwen-hello"
export PYTORCH_RUNTIME_IMAGE="nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1"
export OCI2GDS_STRICT="true"
export OCI2GDS_PROBE_STRICT="true"
export OCI2GDS_FORCE_NO_COMPAT="true"
export MODEL_ROOT_PATH="${OCI2GDSD_ROOT_PATH}/models/${MODEL_ID}/${MODEL_DIGEST//:/-}"

cp platform/k3s/workloads/pytorch/qwen-k3s-hello-deployment.yaml.tpl /tmp/qwen-k3s-hello.yaml
gsed -i "s|__QWEN_HELLO_NAMESPACE__|${QWEN_HELLO_NAMESPACE}|g" /tmp/qwen-k3s-hello.yaml
gsed -i "s|__MODEL_ID__|${MODEL_ID}|g" /tmp/qwen-k3s-hello.yaml
gsed -i "s|__MODEL_REF__|${MODEL_REF}|g" /tmp/qwen-k3s-hello.yaml
gsed -i "s|__MODEL_DIGEST__|${MODEL_DIGEST}|g" /tmp/qwen-k3s-hello.yaml
gsed -i "s|__MODEL_ROOT_PATH__|${MODEL_ROOT_PATH}|g" /tmp/qwen-k3s-hello.yaml
gsed -i "s|__OCI2GDSD_IMAGE__|${OCI2GDSD_IMAGE}|g" /tmp/qwen-k3s-hello.yaml
gsed -i "s|__OCI2GDSD_ROOT_PATH__|${OCI2GDSD_ROOT_PATH}|g" /tmp/qwen-k3s-hello.yaml
gsed -i "s|__OCI2GDS_STRICT__|${OCI2GDS_STRICT}|g" /tmp/qwen-k3s-hello.yaml
gsed -i "s|__OCI2GDS_PROBE_STRICT__|${OCI2GDS_PROBE_STRICT}|g" /tmp/qwen-k3s-hello.yaml
gsed -i "s|__OCI2GDS_FORCE_NO_COMPAT__|${OCI2GDS_FORCE_NO_COMPAT}|g" /tmp/qwen-k3s-hello.yaml
gsed -i "s|__PYTORCH_RUNTIME_IMAGE__|${PYTORCH_RUNTIME_IMAGE}|g" /tmp/qwen-k3s-hello.yaml
gsed -i "s|__LEASE_HOLDER__|${LEASE_HOLDER}|g" /tmp/qwen-k3s-hello.yaml

sudo k3s kubectl create namespace "${QWEN_HELLO_NAMESPACE}" --dry-run=client -o yaml | sudo k3s kubectl apply -f -
sudo k3s kubectl -n "${QWEN_HELLO_NAMESPACE}" create configmap qwen-hello-app \
  --from-file=qwen_server.py=platform/k3s/workloads/pytorch/app/qwen_server.py \
  --from-file=deps_bootstrap.py=platform/k3s/workloads/pytorch/app/deps_bootstrap.py \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -
sudo k3s kubectl -n "${QWEN_HELLO_NAMESPACE}" create configmap qwen-hello-native \
  --from-file=oci2gds_torch_native.cpp=platform/k3s/workloads/pytorch/native/oci2gds_torch_native.cpp \
  --dry-run=client -o yaml | sudo k3s kubectl apply -f -

sudo k3s kubectl apply -f /tmp/qwen-k3s-hello.yaml
sudo k3s kubectl -n "${QWEN_HELLO_NAMESPACE}" rollout status deploy/qwen-hello --timeout=1800s
sudo k3s kubectl -n "${QWEN_HELLO_NAMESPACE}" port-forward svc/qwen-hello 18080:8000
```

### 6. Query the API

```bash
curl -sS -X POST http://127.0.0.1:18080/chat \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Explain in one sentence what GPU model preloading helps with."}' | jq .

curl -sS http://127.0.0.1:18080/healthz | jq .
```

## Cleanup

```bash
sudo k3s kubectl delete namespace qwen-hello --ignore-not-found
sudo k3s kubectl delete namespace oci-model-registry --ignore-not-found
docker rm -f oci-model-registry 2>/dev/null || true
```

For repeated iteration after first successful run, use:

```bash
make verify-k3s-qwen-smoke
```
