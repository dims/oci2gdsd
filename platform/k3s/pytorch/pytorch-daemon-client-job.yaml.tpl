apiVersion: batch/v1
kind: Job
metadata:
  name: oci2gdsd-pytorch-daemon-client
  namespace: __E2E_NAMESPACE__
  labels:
    app.kubernetes.io/name: oci2gdsd-pytorch-daemon-client
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: oci2gdsd-pytorch-daemon-client
    spec:
      hostIPC: true
      hostPID: true
      restartPolicy: Never
      runtimeClassName: nvidia
      tolerations:
      - key: "nvidia.com/gpu"
        operator: "Exists"
        effect: "NoSchedule"
      volumes:
      - name: daemon-client-script
        configMap:
          name: pytorch-daemon-client-script
          defaultMode: 0555
      - name: oci2gdsd-socket-dir
        hostPath:
          path: __OCI2GDSD_SOCKET_HOST_PATH__
          type: Directory
      - name: host-udev
        hostPath:
          path: /run/udev
          type: Directory
      - name: host-cufile-config
        hostPath:
          path: /etc/cufile.json
          type: File
      containers:
      - name: pytorch-daemon-client
        image: __PYTORCH_IMAGE__
        imagePullPolicy: IfNotPresent
        securityContext:
          runAsUser: 0
          runAsGroup: 0
          privileged: true
        command: ["/bin/sh", "-ec"]
        args:
        - |
          set -eu
          python /scripts/pytorch_daemon_client.py
        env:
        - name: MODEL_REF
          value: "__MODEL_REF__"
        - name: MODEL_ID
          value: "__MODEL_ID__"
        - name: MODEL_DIGEST
          value: "__MODEL_DIGEST__"
        - name: RUNTIME_BUNDLE_ROOT
          value: "/tmp/oci2gdsd-runtime-bundle"
        - name: LEASE_HOLDER
          value: "__LEASE_HOLDER__"
        - name: OCI2GDS_DAEMON_SOCKET
          value: "/run/oci2gdsd/daemon.sock"
        - name: OCI2GDS_TORCH_ENABLE_NATIVE
          value: "1"
        - name: OCI2GDS_NATIVE_CPP_PATH
          value: "/scripts/oci2gds_torch_native.cpp"
        - name: CUDA_INCLUDE_DIR
          value: "/usr/local/cuda/include"
        - name: CUDA_LIB_DIR
          value: "/usr/local/cuda/lib64"
        - name: REQUIRE_DIRECT_GDS
          value: "__REQUIRE_DIRECT_GDS__"
        - name: OCI2GDS_STRICT
          value: "__OCI2GDS_STRICT__"
        - name: RUNTIME_PARITY_MODE
          value: "__RUNTIME_PARITY_MODE__"
        - name: PERF_MODE
          value: "__PERF_MODE__"
        - name: CUFILE_ENV_PATH_JSON
          value: "/etc/cufile.json"
        - name: DEVICE_UUID
          value: ""
        - name: DEVICE_INDEX
          value: "0"
        resources:
          limits:
            nvidia.com/gpu: "1"
          requests:
            nvidia.com/gpu: "1"
        volumeMounts:
        - name: daemon-client-script
          mountPath: /scripts
          readOnly: true
        - name: oci2gdsd-socket-dir
          mountPath: /run/oci2gdsd
          readOnly: true
        - name: host-udev
          mountPath: /run/udev
          readOnly: true
        - name: host-cufile-config
          mountPath: /etc/cufile.json
          readOnly: true
