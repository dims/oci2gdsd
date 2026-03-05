apiVersion: v1
kind: Namespace
metadata:
  name: __REGISTRY_NAMESPACE__
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: __REGISTRY_SERVICE__
  namespace: __REGISTRY_NAMESPACE__
  labels:
    app.kubernetes.io/name: __REGISTRY_SERVICE__
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: __REGISTRY_SERVICE__
  template:
    metadata:
      labels:
        app.kubernetes.io/name: __REGISTRY_SERVICE__
    spec:
      tolerations:
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"
      - key: "node-role.kubernetes.io/master"
        operator: "Exists"
        effect: "NoSchedule"
      containers:
      - name: registry
        image: registry:2
        imagePullPolicy: IfNotPresent
        env:
        - name: REGISTRY_STORAGE_DELETE_ENABLED
          value: "true"
        ports:
        - containerPort: 5000
          name: http
        volumeMounts:
        - name: data
          mountPath: /var/lib/registry
      volumes:
      - name: data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: __REGISTRY_SERVICE__
  namespace: __REGISTRY_NAMESPACE__
spec:
  selector:
    app.kubernetes.io/name: __REGISTRY_SERVICE__
  ports:
  - name: http
    port: 5000
    protocol: TCP
    targetPort: http
