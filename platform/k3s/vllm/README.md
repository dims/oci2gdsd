# vLLM Workloads

Runtime-specific assets for vLLM paths in k3s daemonset mode.

## Files

- `vllm-daemon-client-job.yaml.tpl`: daemon client workload job.
- `vllm_daemon_client.py`: out-of-tree `load_format=oci2gds` loader registration + inference check.

## Typical run

- `make verify-k3s-vllm-e2e-daemonset`

## Parity mode

- `RUNTIME_PARITY_MODE=probe|partial|full`
- `REQUIRE_FULL_IPC_BIND=true` enforces full parameter rebinding coverage checks.
- `make verify-k3s-vllm-e2e-daemonset-parity` runs with `RUNTIME_PARITY_MODE=full` and `REQUIRE_FULL_IPC_BIND=true`.
- vLLM flow calls daemon `/v1/gpu/tensor-map` and emits:
  - `VLLM_IPC_TENSOR_MAP_OK`
  - `VLLM_IPC_BIND_OK`
- In `full` mode, the loader imports tensor-map entries from daemon-exported CUDA IPC handles and copies them into vLLM-owned parameters (including fused `qkv_proj` and `gate_up_proj` coverage).
- `VLLM_IPC_BIND_OK` reports strict bind stats (`status`, `rebound_params`, `rebound_bytes`, `fused_params`, `unresolved`) and full mode requires `status=ok` and `unresolved=0`.
