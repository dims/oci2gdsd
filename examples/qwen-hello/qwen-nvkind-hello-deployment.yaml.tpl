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
      - name: hello
        image: pytorch/pytorch:2.4.1-cuda12.1-cudnn9-runtime
        imagePullPolicy: IfNotPresent
        command: ["/bin/sh", "-ec"]
        args:
        - |
          python - <<'PY'
          import json
          import os
          from pathlib import Path
          import torch

          model_root = Path(os.environ["MODEL_ROOT_PATH"])
          if not (model_root / "READY").exists():
              raise RuntimeError("READY marker missing")
          meta = json.loads((model_root / "metadata" / "model.json").read_text(encoding="utf-8"))
          shard_count = len(meta.get("profile", {}).get("shards", []))
          if shard_count == 0:
              raise RuntimeError("no shards discovered")
          if not torch.cuda.is_available():
              raise RuntimeError("cuda not available")
          x = torch.randn((1024, 1024), device="cuda")
          y = torch.randn((1024, 1024), device="cuda")
          z = x @ y
          torch.cuda.synchronize()
          print("QWEN_NVKIND_HELLO_SUCCESS",
                "model_id=", meta.get("modelId"),
                "manifest=", meta.get("manifestDigest"),
                "shards=", shard_count,
                "gpu=", torch.cuda.get_device_name(0),
                "mean=", float(z.mean().item()))
          PY
          sleep 3600
        env:
        - name: MODEL_ROOT_PATH
          value: "__MODEL_ROOT_PATH__"
        resources:
          limits:
            nvidia.com/gpu: "1"
          requests:
            nvidia.com/gpu: "1"
        volumeMounts:
        - name: oci2gdsd-root
          mountPath: __OCI2GDSD_ROOT_PATH__
          readOnly: true
