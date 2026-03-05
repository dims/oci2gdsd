# PyTorch Workloads

Runtime-specific assets for PyTorch paths in k3s daemonset mode.

## Files

- `pytorch-daemon-client-job.yaml.tpl`: daemon client workload job.
- `pytorch_daemon_client.py`: daemon API + CUDA IPC handoff workflow.
- `qwen-hello/`: FastAPI deployment and startup probes for local-preloaded model files.

## Typical runs

- Daemonset mode e2e: `make verify-k3s-qwen-e2e-daemonset`
- qwen-hello quick loop: `make verify-k3s-qwen-smoke`
