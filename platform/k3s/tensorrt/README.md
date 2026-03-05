# TensorRT-LLM Workloads

Runtime-specific assets for TensorRT-LLM paths in k3s daemonset mode.

## Files

- `tensorrt-daemon-client-job.yaml.tpl`: daemon client workload job.
- `tensorrt_daemon_client.py`: engine build + `ModelRunnerCpp` flow with GDS checks.

## Typical run

- `make verify-k3s-tensor-e2e-daemonset`
