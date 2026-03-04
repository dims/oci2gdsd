# oci2gdsd Daemon Helm Chart

This chart deploys `oci2gdsd serve` as a privileged DaemonSet with hostPath-backed
model cache and UNIX socket.

## Install

```bash
helm upgrade --install oci2gdsd-daemon ./deploy/charts/oci2gdsd-daemon \
  --namespace oci2gdsd-daemon \
  --create-namespace \
  --set image.repository=oci2gdsd \
  --set image.tag=e2e
```

## Key values

- `image.repository` / `image.tag`: daemon image
- `hostPaths.root`: shared model root path on node
- `hostPaths.socketDir`: shared host socket directory
- `daemon.socketPath`: in-container UNIX socket path (defaults `/run/oci2gdsd/daemon.sock`)
- `daemon.runtimeClassName`: defaults to `nvidia`
- `daemon.extraEnv`: defaults include `NVIDIA_VISIBLE_DEVICES=all`
- `securityContext.privileged`: must stay `true` for current GDS test posture

## Notes

- The chart deploys the daemon only. Workload examples remain under `examples/`.
- Strict direct-GDS behavior still depends on host qualification (`gdscheck -p`).
