# Helm Chart: oci2gdsd Daemon

Chart path: `deploy/charts/oci2gdsd-daemon`

This chart deploys the daemon-only control plane (`oci2gdsd serve`) as a privileged
DaemonSet. It does not deploy application workloads.

## Install

```bash
helm upgrade --install oci2gdsd-daemon ./deploy/charts/oci2gdsd-daemon \
  --namespace oci2gdsd-daemon \
  --create-namespace \
  --set image.repository=oci2gdsd \
  --set image.tag=e2e
```

## Uninstall

```bash
helm uninstall oci2gdsd-daemon -n oci2gdsd-daemon
```

## Important values

- `image.repository`, `image.tag`, `image.pullPolicy`
- `hostPaths.root` (shared model cache root)
- `hostPaths.socketDir` (host UNIX socket dir mounted at `/run/oci2gdsd`)
- `daemon.socketPath` and `daemon.socketPerms`
- `daemon.runtimeClassName` (defaults `nvidia`)
- `daemon.extraEnv` (defaults include `NVIDIA_VISIBLE_DEVICES=all`)
- `securityContext.privileged` (must remain `true` for current GDS test path)
- `config.registry`, `config.transfer`, `config.integrity`, `config.publish`, `config.retention`

## Operational notes

- Workload pods must mount the same host paths (`root` and socket dir).
- Workload pods are expected to run privileged in current strict GDS test posture.
- For strict direct mode, host must pass `gdscheck -p` with `NVMe : Supported`.
