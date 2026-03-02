apiVersion: v1
kind: Namespace
metadata:
  name: __QWEN_HELLO_NAMESPACE__
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: oci2gdsd-config
  namespace: __QWEN_HELLO_NAMESPACE__
data:
  config.yaml: |
    root: __OCI2GDSD_ROOT_PATH__
    model_root: __OCI2GDSD_ROOT_PATH__/models
    tmp_root: __OCI2GDSD_ROOT_PATH__/tmp
    locks_root: __OCI2GDSD_ROOT_PATH__/locks
    journal_dir: __OCI2GDSD_ROOT_PATH__/journal
    state_db: __OCI2GDSD_ROOT_PATH__/state.db
    registry:
      plain_http: true
      request_timeout_seconds: 600
      timeout_seconds: 600
      retries: 6
    transfer:
      max_models_concurrent: 2
      max_shards_concurrent_per_model: 8
      max_connections_per_registry: 32
      stream_buffer_bytes: 4194304
      max_resume_attempts: 2
    integrity:
      strict_digest: true
      strict_signature: false
      allow_unsigned_in_dev: true
    publish:
      require_ready_marker: true
      fsync_files: false
      fsync_directory: false
      atomic_publish: true
      deny_partial_reads: true
    retention:
      policy: lru_no_lease
      min_free_bytes: 0
      max_models: 64
      ttl_hours: 168
      emergency_low_space_mode: true
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qwen-hello
  namespace: __QWEN_HELLO_NAMESPACE__
spec:
  replicas: 1
  selector:
    matchLabels:
      app: qwen-hello
  template:
    metadata:
      labels:
        app: qwen-hello
    spec:
      restartPolicy: Always
      tolerations:
      - key: "nvidia.com/gpu"
        operator: "Exists"
        effect: "NoSchedule"
      volumes:
      - name: oci2gdsd-root
        hostPath:
          path: __OCI2GDSD_ROOT_PATH__
          type: DirectoryOrCreate
      - name: oci2gdsd-config
        configMap:
          name: oci2gdsd-config
      initContainers:
      - name: preload-model
        image: __OCI2GDSD_IMAGE__
        imagePullPolicy: IfNotPresent
        command: ["/bin/sh", "-ec"]
        args:
        - |
          set -eu
          oci2gdsd --registry-config /etc/oci2gdsd/config.yaml --json ensure \
            --ref "__MODEL_REF__" \
            --model-id "__MODEL_ID__" \
            --lease-holder "__LEASE_HOLDER__" \
            --strict-integrity \
            --wait
          oci2gdsd --registry-config /etc/oci2gdsd/config.yaml --json status \
            --model-id "__MODEL_ID__" \
            --digest "__MODEL_DIGEST__"
        volumeMounts:
        - name: oci2gdsd-root
          mountPath: __OCI2GDSD_ROOT_PATH__
        - name: oci2gdsd-config
          mountPath: /etc/oci2gdsd
          readOnly: true
      containers:
      - name: vllm-api
        image: __VLLM_RUNTIME_IMAGE__
        imagePullPolicy: IfNotPresent
        command: ["/bin/sh", "-ec"]
        args:
        - |
          python - <<'PY'
          import os
          import json
          import shutil
          from pathlib import Path
          from fastapi import FastAPI, HTTPException
          from pydantic import BaseModel
          import uvicorn
          from vllm import LLM, SamplingParams

          model_root = Path(os.environ["MODEL_ROOT_PATH"])
          if not (model_root / "READY").exists():
              raise RuntimeError("READY marker missing")
          meta = json.loads((model_root / "metadata" / "model.json").read_text(encoding="utf-8"))
          profile = meta.get("profile", {})
          source = profile.get("source", {})
          shard_entries = sorted(
              profile.get("shards", []),
              key=lambda s: int(s.get("ordinal", 0)),
          )
          if not shard_entries:
              raise RuntimeError("profile.shards is empty; cannot build local runtime model directory")

          runtime_dir = Path(os.environ.get("VLLM_LOCAL_MODEL_DIR", "/tmp/oci2gdsd-local-model"))
          if runtime_dir.exists():
              shutil.rmtree(runtime_dir)
          runtime_dir.mkdir(parents=True, exist_ok=True)

          weights_found = 0
          for shard in shard_entries:
              name = str(shard.get("name", "")).strip()
              if not name:
                  raise RuntimeError("profile shard name is empty")
              src = model_root / "shards" / name
              if not src.exists():
                  raise RuntimeError(f"expected shard file missing: {src}")
              dst = runtime_dir / name
              os.symlink(src, dst)
              if name.endswith(".safetensors"):
                  weights_found += 1

          metadata_dir = model_root / "metadata"
          if metadata_dir.is_dir():
              for src in sorted(metadata_dir.iterdir(), key=lambda p: p.name):
                  if not src.is_file() or src.name == "model.json":
                      continue
                  dst = runtime_dir / src.name
                  if not dst.exists():
                      os.symlink(src, dst)

          if not (runtime_dir / "config.json").exists():
              raise RuntimeError(f"config.json missing in local runtime dir: {runtime_dir}")
          tokenizer_candidates = [
              "tokenizer.json",
              "tokenizer.model",
              "vocab.json",
          ]
          if not any((runtime_dir / name).exists() for name in tokenizer_candidates):
              raise RuntimeError(f"tokenizer artifacts missing in local runtime dir: {runtime_dir}")
          if weights_found == 0:
              raise RuntimeError(f"no .safetensors files found in local runtime dir: {runtime_dir}")

          model_name = str(runtime_dir)
          sampling_params = SamplingParams(
              max_tokens=int(os.environ.get("MAX_TOKENS", "256")),
              temperature=float(os.environ.get("TEMPERATURE", "0.7")),
          )

          app = FastAPI(title="qwen-hello-vllm")
          llm = LLM(model=model_name, trust_remote_code=True)

          class ChatRequest(BaseModel):
              prompt: str

          @app.get("/healthz")
          def healthz():
              return {
                  "status": "ok",
                  "model_name": model_name,
                  "source_repo": source.get("repoId", ""),
                  "model_id": meta.get("modelId"),
                  "manifest_digest": meta.get("manifestDigest"),
              }

          @app.post("/chat")
          def chat(req: ChatRequest):
              prompt = (req.prompt or "").strip()
              if not prompt:
                  raise HTTPException(status_code=400, detail="prompt must be non-empty")
              outputs = llm.generate([prompt], sampling_params)
              text = outputs[0].outputs[0].text.strip()
              return {
                  "answer": text,
                  "model_name": model_name,
                  "source_repo": source.get("repoId", ""),
                  "model_id": meta.get("modelId"),
                  "manifest_digest": meta.get("manifestDigest"),
              }

          uvicorn.run(app, host="0.0.0.0", port=8000)
          PY
        env:
        - name: MODEL_ROOT_PATH
          value: "__MODEL_ROOT_PATH__"
        - name: HF_HOME
          value: "/tmp/hf-cache"
        - name: XDG_CACHE_HOME
          value: "/tmp/hf-cache"
        - name: HF_HUB_OFFLINE
          value: "1"
        - name: TRANSFORMERS_OFFLINE
          value: "1"
        startupProbe:
          httpGet:
            path: /healthz
            port: 8000
          periodSeconds: 10
          failureThreshold: 120
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8000
          periodSeconds: 10
          failureThreshold: 6
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8000
          periodSeconds: 20
          failureThreshold: 6
        resources:
          limits:
            nvidia.com/gpu: "1"
          requests:
            nvidia.com/gpu: "1"
        volumeMounts:
        - name: oci2gdsd-root
          mountPath: __OCI2GDSD_ROOT_PATH__
          readOnly: false
---
apiVersion: v1
kind: Service
metadata:
  name: qwen-hello
  namespace: __QWEN_HELLO_NAMESPACE__
spec:
  selector:
    app: qwen-hello
  ports:
  - name: http
    port: 8000
    targetPort: 8000
