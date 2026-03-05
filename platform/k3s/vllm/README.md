# vLLM Workloads

Runtime-specific assets for vLLM paths in k3s daemonset mode.

## Files

- `vllm-daemon-client-job.yaml.tpl`: daemon client workload job.
- `vllm_daemon_client.py`: out-of-tree `load_format=oci2gds` loader registration + inference check.

## Typical run

- `make verify-k3s-vllm-e2e-daemonset`
