# Qwen Packager + nvkind Hello World

This example uses:
- Docker Hub packager image: `docker.io/dims/oci2gdsd-qwen3-packager:latest`
- `nvkind` for a local GPU Kubernetes cluster
- `oci2gdsd` init container to preload model shards before app start

## 1. Create an nvkind cluster

```bash
export CLUSTER_NAME="qwen-hello"
nvkind cluster create --name "${CLUSTER_NAME}"
```

Install GPU Operator:

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update
helm upgrade -i \
  --kube-context "kind-${CLUSTER_NAME}" \
  --namespace gpu-operator \
  --create-namespace \
  --set driver.enabled=false \
  --set toolkit.enabled=false \
  --set dcgmExporter.enabled=false \
  --set nfd.enabled=true \
  --wait --timeout=600s \
  gpu-operator nvidia/gpu-operator
```

Smoke check GPU scheduling:

```bash
kubectl --context "kind-${CLUSTER_NAME}" apply -f - <<'EOF'
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
kubectl --context "kind-${CLUSTER_NAME}" -n kube-system wait pod/gpu-smoke --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s
kubectl --context "kind-${CLUSTER_NAME}" -n kube-system logs pod/gpu-smoke
kubectl --context "kind-${CLUSTER_NAME}" -n kube-system delete pod/gpu-smoke
```

## 2. Deploy an in-cluster registry

```bash
kubectl --context "kind-${CLUSTER_NAME}" apply -f examples/qwen-hello/oci-model-registry.yaml
kubectl --context "kind-${CLUSTER_NAME}" -n oci-model-registry rollout status deploy/oci-model-registry --timeout=180s
```

Port-forward for local push:

```bash
kubectl --context "kind-${CLUSTER_NAME}" -n oci-model-registry \
  port-forward svc/oci-model-registry 5000:5000
```

Keep that terminal open.

## 3. Package and push Qwen artifact with Docker Hub image

In a second terminal:

```bash
export WORK_DIR="$(pwd)/work/qwen-packager-nvkind-hello"
mkdir -p "${WORK_DIR}"

docker run --rm --network host \
  -e HF_TOKEN="${HF_TOKEN:-}" \
  -u "$(id -u):$(id -g)" \
  -v "${WORK_DIR}:/work" \
  docker.io/dims/oci2gdsd-qwen3-packager:latest \
  --hf-repo Qwen/Qwen3-0.6B \
  --hf-revision main \
  --model-id qwen3-0.6b \
  --oci-ref "localhost:5000/models/qwen3-0.6b:v1" \
  --plain-http

export MODEL_DIGEST="$(jq -r '.digest' "${WORK_DIR}/output/manifest-descriptor.json")"
export MODEL_REF="oci-model-registry.oci-model-registry.svc.cluster.local:5000/models/qwen3-0.6b@${MODEL_DIGEST}"
echo "${MODEL_REF}"
```

## 4. Build/load `oci2gdsd` image into cluster

```bash
docker build -f testharness/nvkind-e2e/Dockerfile.oci2gdsd -t oci2gdsd:hello .
kind load docker-image oci2gdsd:hello --name "${CLUSTER_NAME}"
docker pull nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1
kind load docker-image nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1 --name "${CLUSTER_NAME}"
```

## 5. Render and apply FastAPI + vLLM deployment

```bash
export MODEL_ID="qwen3-0.6b"
export OCI2GDSD_IMAGE="oci2gdsd:hello"
export OCI2GDSD_ROOT_PATH="/var/lib/oci2gdsd"
export QWEN_HELLO_NAMESPACE="qwen-hello"
export LEASE_HOLDER="qwen-hello"
export VLLM_RUNTIME_IMAGE="nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.1"
export MODEL_ROOT_PATH="${OCI2GDSD_ROOT_PATH}/models/${MODEL_ID}/${MODEL_DIGEST//:/-}"

cp examples/qwen-hello/qwen-nvkind-hello-deployment.yaml.tpl /tmp/qwen-nvkind-hello.yaml
gsed -i "s|__QWEN_HELLO_NAMESPACE__|${QWEN_HELLO_NAMESPACE}|g" /tmp/qwen-nvkind-hello.yaml
gsed -i "s|__MODEL_ID__|${MODEL_ID}|g" /tmp/qwen-nvkind-hello.yaml
gsed -i "s|__MODEL_REF__|${MODEL_REF}|g" /tmp/qwen-nvkind-hello.yaml
gsed -i "s|__MODEL_DIGEST__|${MODEL_DIGEST}|g" /tmp/qwen-nvkind-hello.yaml
gsed -i "s|__MODEL_ROOT_PATH__|${MODEL_ROOT_PATH}|g" /tmp/qwen-nvkind-hello.yaml
gsed -i "s|__OCI2GDSD_IMAGE__|${OCI2GDSD_IMAGE}|g" /tmp/qwen-nvkind-hello.yaml
gsed -i "s|__OCI2GDSD_ROOT_PATH__|${OCI2GDSD_ROOT_PATH}|g" /tmp/qwen-nvkind-hello.yaml
gsed -i "s|__VLLM_RUNTIME_IMAGE__|${VLLM_RUNTIME_IMAGE}|g" /tmp/qwen-nvkind-hello.yaml
gsed -i "s|__LEASE_HOLDER__|${LEASE_HOLDER}|g" /tmp/qwen-nvkind-hello.yaml

kubectl --context "kind-${CLUSTER_NAME}" apply -f /tmp/qwen-nvkind-hello.yaml
kubectl --context "kind-${CLUSTER_NAME}" -n "${QWEN_HELLO_NAMESPACE}" rollout status deploy/qwen-hello --timeout=1800s
kubectl --context "kind-${CLUSTER_NAME}" -n "${QWEN_HELLO_NAMESPACE}" port-forward svc/qwen-hello 18080:8000
```

In another terminal ask a question:

```bash
curl -sS -X POST http://127.0.0.1:18080/chat \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Explain in one sentence what GPU model preloading helps with."}' | jq .
```

You should get JSON with a non-empty `answer` field.

## 6. Cleanup

```bash
kubectl --context "kind-${CLUSTER_NAME}" delete namespace "${QWEN_HELLO_NAMESPACE}" --ignore-not-found
kubectl --context "kind-${CLUSTER_NAME}" delete namespace oci-model-registry --ignore-not-found
kind delete cluster --name "${CLUSTER_NAME}"
```
