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
  strategy:
    type: Recreate
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
      - name: oci2gdsd-run
        emptyDir: {}
      - name: oci2gdsd-bin
        emptyDir: {}
      - name: qwen-app
        configMap:
          name: qwen-hello-app
          defaultMode: 0555
      - name: qwen-native
        configMap:
          name: qwen-hello-native
          defaultMode: 0444
      - name: run-udev
        hostPath:
          path: /run/udev
          type: Directory
      - name: host-dev
        hostPath:
          path: /dev
          type: Directory
      initContainers:
      - name: preload-model
        image: __OCI2GDSD_IMAGE__
        imagePullPolicy: IfNotPresent
        securityContext:
          runAsUser: 0
          runAsGroup: 0
          privileged: true
        command: ["/bin/sh", "-ec"]
        args:
        - |
          set -eu
          cp /usr/local/bin/oci2gdsd /oci2gdsd-bin/oci2gdsd
          chmod 0755 /oci2gdsd-bin/oci2gdsd
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
        - name: oci2gdsd-bin
          mountPath: /oci2gdsd-bin
      containers:
      - name: pytorch-api
        image: __PYTORCH_RUNTIME_IMAGE__
        imagePullPolicy: IfNotPresent
        securityContext:
          runAsUser: 0
          runAsGroup: 0
          privileged: true
        command: ["/bin/sh", "-ec"]
        args:
        - |
          set -eu
          if [ ! -e /usr/local/cuda/lib64/libcufile.so ] && [ -e /usr/local/cuda/lib64/libcufile.so.0 ]; then
            ln -sf /usr/local/cuda/lib64/libcufile.so.0 /usr/local/cuda/lib64/libcufile.so
          fi
          if [ ! -e /usr/lib/x86_64-linux-gnu/libcufile.so ] && [ -e /usr/local/cuda/lib64/libcufile.so ]; then
            ln -sf /usr/local/cuda/lib64/libcufile.so /usr/lib/x86_64-linux-gnu/libcufile.so
          fi
          if [ ! -e /usr/local/cuda/lib64/libcuda.so.1 ] && [ -e /usr/local/cuda/compat/libcuda.so.1 ]; then
            ln -sf /usr/local/cuda/compat/libcuda.so.1 /usr/local/cuda/lib64/libcuda.so.1
          fi
          if [ -d /host-dev ]; then
            for nvfs in /host-dev/nvidia-fs*; do
              [ -c "${nvfs}" ] || continue
              ln -sf "${nvfs}" "/dev/$(basename "${nvfs}")"
            done
          fi
          python /app/deps_bootstrap.py
          daemon_pid=""
          daemon_enable="$(printf '%s' "${OCI2GDS_DAEMON_ENABLE:-1}" | tr '[:upper:]' '[:lower:]')"
          if [ "${daemon_enable}" != "0" ] && [ "${daemon_enable}" != "false" ] && [ "${daemon_enable}" != "no" ]; then
            /oci2gdsd-bin/oci2gdsd --registry-config /etc/oci2gdsd/config.yaml serve \
              --unix-socket /run/oci2gdsd/daemon.sock \
              --socket-perms 0660 &
            daemon_pid="$!"
          fi
          cleanup() {
            if [ -n "${daemon_pid}" ]; then
              kill "${daemon_pid}" 2>/dev/null || true
              wait "${daemon_pid}" 2>/dev/null || true
            fi
          }
          trap cleanup EXIT INT TERM
          python /app/qwen_server.py
        env:
        - name: MODEL_ROOT_PATH
          value: "__MODEL_ROOT_PATH__"
        - name: MODEL_ID
          value: "__MODEL_ID__"
        - name: MODEL_DIGEST
          value: "__MODEL_DIGEST__"
        - name: LEASE_HOLDER
          value: "__LEASE_HOLDER__"
        - name: OCI2GDS_DAEMON_SOCKET
          value: "/run/oci2gdsd/daemon.sock"
        - name: OCI2GDS_DAEMON_ENABLE
          value: "__OCI2GDS_DAEMON_ENABLE__"
        - name: OCI2GDS_DAEMON_PROBE_SHARDS
          value: "__OCI2GDS_DAEMON_PROBE_SHARDS__"
        - name: MAX_NEW_TOKENS
          value: "128"
        - name: TEMPERATURE
          value: "0.7"
        - name: TOP_P
          value: "0.95"
        - name: LOCAL_MODEL_DIR
          value: "/tmp/oci2gdsd-local-model"
        - name: OCI2GDS_TORCH_ENABLE_NATIVE
          value: "1"
        - name: OCI2GDS_TORCH_NATIVE_VERBOSE
          value: "0"
        - name: OCI2GDS_NATIVE_CPP_PATH
          value: "/app/native/oci2gds_torch_native.cpp"
        - name: OCI2GDS_ALLOW_RUNTIME_PIP_INSTALL
          value: "false"
        - name: CUDA_INCLUDE_DIR
          value: "/usr/local/cuda/include"
        - name: CUDA_LIB_DIR
          value: "/usr/local/cuda/lib64"
        - name: OCI2GDS_CHUNK_BYTES
          value: "4194304"
        - name: OCI2GDS_SAMPLE_BYTES_PER_SHARD
          value: "8388608"
        - name: OCI2GDS_STRICT
          value: "__OCI2GDS_STRICT__"
        - name: OCI2GDS_PROBE_STRICT
          value: "__OCI2GDS_PROBE_STRICT__"
        - name: OCI2GDS_FORCE_NO_COMPAT
          value: "__OCI2GDS_FORCE_NO_COMPAT__"
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
        - name: oci2gdsd-config
          mountPath: /etc/oci2gdsd
          readOnly: true
        - name: oci2gdsd-run
          mountPath: /run/oci2gdsd
          readOnly: false
        - name: oci2gdsd-bin
          mountPath: /oci2gdsd-bin
          readOnly: true
        - name: qwen-app
          mountPath: /app
          readOnly: true
        - name: qwen-native
          mountPath: /app/native
          readOnly: true
        - name: run-udev
          mountPath: /run/udev
          readOnly: true
        - name: host-dev
          mountPath: /host-dev
          readOnly: true
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
