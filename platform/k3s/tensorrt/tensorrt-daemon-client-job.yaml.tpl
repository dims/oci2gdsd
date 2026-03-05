apiVersion: batch/v1
kind: Job
metadata:
  name: oci2gdsd-tensorrt-daemon-client
  namespace: __E2E_NAMESPACE__
  labels:
    app.kubernetes.io/name: oci2gdsd-tensorrt-daemon-client
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: oci2gdsd-tensorrt-daemon-client
    spec:
      restartPolicy: Never
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
      - name: daemon-client-script
        configMap:
          name: tensorrt-daemon-client-script
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
          oci2gdsd --registry-config /etc/oci2gdsd/config.yaml --json ensure \
            --ref "__MODEL_REF__" \
            --model-id "__MODEL_ID__" \
            --lease-holder "__LEASE_HOLDER__" \
            --strict-integrity \
            --wait
          oci2gdsd --registry-config /etc/oci2gdsd/config.yaml --json status \
            --model-id "__MODEL_ID__" \
            --digest "__MODEL_DIGEST__"
          oci2gdsd --registry-config /etc/oci2gdsd/config.yaml --json verify \
            --model-id "__MODEL_ID__" \
            --digest "__MODEL_DIGEST__"
        volumeMounts:
        - name: oci2gdsd-root
          mountPath: __OCI2GDSD_ROOT_PATH__
        - name: oci2gdsd-config
          mountPath: /etc/oci2gdsd
          readOnly: true
      containers:
      - name: tensorrt-daemon-client
        image: __TENSORRTLLM_IMAGE__
        imagePullPolicy: IfNotPresent
        securityContext:
          runAsUser: 0
          runAsGroup: 0
          privileged: true
        command: ["/bin/sh", "-ec"]
        args:
        - |
          set -eu
          python3 /scripts/tensorrt_daemon_client.py
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
        - name: REQUIRE_DIRECT_GDS
          value: "__REQUIRE_DIRECT_GDS__"
        - name: OCI2GDS_STRICT
          value: "__OCI2GDS_STRICT__"
        - name: DEVICE_UUID
          value: ""
        - name: DEVICE_INDEX
          value: "0"
        - name: CUFILE_ENV_PATH_JSON
          value: "/etc/cufile.json"
        - name: TRT_MAX_INPUT_LEN
          value: "512"
        - name: TRT_MAX_SEQ_LEN
          value: "640"
        - name: TRT_MAX_OUTPUT_LEN
          value: "64"
        - name: TRT_FORCE_REBUILD
          value: "false"
        resources:
          limits:
            nvidia.com/gpu: "1"
          requests:
            nvidia.com/gpu: "1"
        volumeMounts:
        - name: oci2gdsd-root
          mountPath: __OCI2GDSD_ROOT_PATH__
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
