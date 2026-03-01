apiVersion: batch/v1
kind: Job
metadata:
  name: oci2gdsd-release-gc
  namespace: __E2E_NAMESPACE__
  labels:
    app.kubernetes.io/name: oci2gdsd-release-gc
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: oci2gdsd-release-gc
    spec:
      restartPolicy: Never
      nodeName: __NODE_NAME__
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
      containers:
      - name: release-gc
        image: __OCI2GDSD_IMAGE__
        imagePullPolicy: IfNotPresent
        command: ["/bin/sh", "-ec"]
        args:
        - |
          set -eu
          oci2gdsd --registry-config /etc/oci2gdsd/config.yaml --json release \
            --model-id "__MODEL_ID__" \
            --digest "__MODEL_DIGEST__" \
            --lease-holder "__LEASE_HOLDER__"
          oci2gdsd --registry-config /etc/oci2gdsd/config.yaml --json status \
            --model-id "__MODEL_ID__" \
            --digest "__MODEL_DIGEST__"
          oci2gdsd --registry-config /etc/oci2gdsd/config.yaml --json gc \
            --policy lru_no_lease \
            --min-free-bytes 100TiB
          oci2gdsd --registry-config /etc/oci2gdsd/config.yaml --json status \
            --model-id "__MODEL_ID__" \
            --digest "__MODEL_DIGEST__"
        volumeMounts:
        - name: oci2gdsd-root
          mountPath: __OCI2GDSD_ROOT_PATH__
        - name: oci2gdsd-config
          mountPath: /etc/oci2gdsd
          readOnly: true
