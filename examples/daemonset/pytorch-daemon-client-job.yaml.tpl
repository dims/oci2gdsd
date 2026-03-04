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
          name: pytorch-daemon-client-script
          defaultMode: 0555
      - name: oci2gdsd-socket-dir
        hostPath:
          path: __OCI2GDSD_SOCKET_HOST_PATH__
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
        - name: DEVICE_INDEX
          value: "0"
        resources:
          limits:
            nvidia.com/gpu: "1"
          requests:
            nvidia.com/gpu: "1"
        volumeMounts:
        - name: oci2gdsd-root
          mountPath: __OCI2GDSD_ROOT_PATH__
          readOnly: true
        - name: daemon-client-script
          mountPath: /scripts
          readOnly: true
        - name: oci2gdsd-socket-dir
          mountPath: /run/oci2gdsd
          readOnly: true
