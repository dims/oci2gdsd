# DaemonSet Deployment Example

This directory provides raw Kubernetes manifests for running `oci2gdsd serve` as a
node-level DaemonSet and validating it with a PyTorch job that uses daemon GPU
load/export/attach/heartbeat/detach/unload APIs.

Files:

- `oci2gdsd-daemonset.yaml.tpl`: namespace + configmap + daemonset stack.
- `pytorch-daemon-client-job.yaml.tpl`: job that preloads model via `ensure` init
  and then calls daemon GPU lifecycle APIs from a PyTorch container.
- `pytorch_daemon_client.py`: daemon-client workload script used via ConfigMap.
  It imports CUDA IPC handles and rebinds model parameters to daemon-backed VRAM
  tensor views before inference.
- `tensorrt-daemon-client-job.yaml.tpl`: job that preloads model via `ensure` init
  and then runs TensorRT-LLM runtime flow in daemonset mode.
- `tensorrt_daemon_client.py`: TensorRT-LLM daemon-client workload script that
  builds an engine and uses `ModelRunnerCpp.from_dir(..., use_gpu_direct_storage=True)`.
  The TensorRT workload mounts host `/run/udev` and `/etc/cufile.json` to satisfy
  strict cuFile registration requirements in containers.

This path is intended for manifest-first deployments and `k3s-e2e` daemonset mode.
For Helm packaging of the same daemonset stack, see:

- `deploy/charts/oci2gdsd-daemon`

Related docs:

- `docs/daemonset-manifest-guide.md`
- `docs/helm-daemon-chart.md`
