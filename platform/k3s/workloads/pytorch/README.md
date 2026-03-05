# PyTorch Workloads

Runtime-specific assets for PyTorch paths in k3s daemonset mode.

## Files

- `pytorch-daemon-client-job.yaml.tpl`: daemon client workload job.
- `pytorch_daemon_client.py`: daemon API + CUDA IPC handoff workflow.
- `qwen-hello.md`: qwen workload walkthrough and behavior notes.
- `app/`, `native/`, and `qwen-*.yaml.tpl`: qwen deployment/runtime assets.
- `Dockerfile.vllm-runtime-gds`: optional qwen runtime image used by strict
  probe experiments.

## Typical runs

- Daemonset mode e2e: `make verify-k3s-qwen-e2e-daemonset`
- qwen-hello quick loop: `make verify-k3s-qwen-smoke`

## Related docs

- `platform/k3s/workloads/pytorch/qwen-hello.md`
- `platform/k3s/e2e/README.md`
