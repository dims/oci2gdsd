# Qwen Packager Hello World (Docker Hub)

This is a minimal example of using the Qwen packager image from Docker Hub to build and push an OCI model artifact.

## 1. Start a local OCI registry

```bash
docker rm -f oci-model-registry 2>/dev/null || true
docker run -d --name oci-model-registry -p 5000:5000 registry:2
```

## 2. Pick the target artifact reference

```bash
export OCI_REF="localhost:5000/models/qwen3-0.6b:v1"
export WORK_DIR="$(pwd)/work/qwen-packager-hello"
mkdir -p "${WORK_DIR}"
```

## 3. Run the Docker Hub packager image

Set `HF_TOKEN` only if your model access requires it.

```bash
docker run --rm --network host \
  -e HF_TOKEN="${HF_TOKEN:-}" \
  -u "$(id -u):$(id -g)" \
  -v "${WORK_DIR}:/work" \
  docker.io/dims/oci2gdsd-qwen3-packager:latest \
  --hf-repo Qwen/Qwen3-0.6B \
  --hf-revision main \
  --model-id qwen3-0.6b \
  --oci-ref "${OCI_REF}" \
  --plain-http
```

## 4. Inspect the pushed artifact digest

```bash
cat "${WORK_DIR}/output/manifest-descriptor.json"
export MANIFEST_DIGEST="$(jq -r '.digest' "${WORK_DIR}/output/manifest-descriptor.json")"
echo "${MANIFEST_DIGEST}"
```

## 5. Confirm artifact exists in the registry

```bash
curl -s "http://localhost:5000/v2/_catalog" | jq .
curl -s "http://localhost:5000/v2/models/qwen3-0.6b/tags/list" | jq .
```

You can now use:

```bash
localhost:5000/models/qwen3-0.6b@${MANIFEST_DIGEST}
```

as the `--ref` for `oci2gdsd ensure`.

## Next step

For a full k3s + Kubernetes hello-world deployment using this artifact, see:

- `platform/k3s/examples/qwen-hello/qwen-packager-k3s-hello-world.md`
