apiVersion: v1
kind: Namespace
metadata:
  name: __OCI2GDSD_DAEMON_NAMESPACE__
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: oci2gdsd-daemon-config
  namespace: __OCI2GDSD_DAEMON_NAMESPACE__
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
kind: DaemonSet
metadata:
  name: oci2gdsd-daemon
  namespace: __OCI2GDSD_DAEMON_NAMESPACE__
  labels:
    app.kubernetes.io/name: oci2gdsd-daemon
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: oci2gdsd-daemon
  template:
    metadata:
      labels:
        app.kubernetes.io/name: oci2gdsd-daemon
    spec:
      runtimeClassName: nvidia
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
          name: oci2gdsd-daemon-config
      - name: oci2gdsd-socket-dir
        hostPath:
          path: __OCI2GDSD_SOCKET_HOST_PATH__
          type: DirectoryOrCreate
      - name: run-udev
        hostPath:
          path: /run/udev
          type: Directory
      - name: host-dev
        hostPath:
          path: /dev
          type: Directory
      containers:
      - name: daemon
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
          mkdir -p /run/oci2gdsd
          exec oci2gdsd --registry-config /etc/oci2gdsd/config.yaml serve \
            --unix-socket /run/oci2gdsd/daemon.sock \
            --socket-perms 0660
        env:
        - name: NVIDIA_VISIBLE_DEVICES
          value: all
        - name: NVIDIA_DRIVER_CAPABILITIES
          value: compute,utility
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -ec
            - test -S /run/oci2gdsd/daemon.sock
          periodSeconds: 5
          failureThreshold: 12
        livenessProbe:
          exec:
            command:
            - /bin/sh
            - -ec
            - test -S /run/oci2gdsd/daemon.sock
          periodSeconds: 10
          failureThreshold: 12
        volumeMounts:
        - name: oci2gdsd-root
          mountPath: __OCI2GDSD_ROOT_PATH__
        - name: oci2gdsd-config
          mountPath: /etc/oci2gdsd
          readOnly: true
        - name: oci2gdsd-socket-dir
          mountPath: /run/oci2gdsd
        - name: run-udev
          mountPath: /run/udev
          readOnly: true
        - name: host-dev
          mountPath: /host-dev
          readOnly: true
