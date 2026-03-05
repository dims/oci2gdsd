# k3s Workloads

Kubernetes workload assets are organized by runtime, with shared daemon manifests
kept separately.

## Layout

- `platform/k3s/workloads/shared/`
  - `oci2gdsd-daemonset.yaml.tpl`: shared daemonset stack for `oci2gdsd serve`.
- `platform/k3s/workloads/pytorch/`
  - `pytorch-daemon-client-job.yaml.tpl`
  - `pytorch_daemon_client.py`
  - `qwen-hello/` FastAPI + PyTorch deployment and app/native sources.
- `platform/k3s/workloads/tensorrt/`
  - `tensorrt-daemon-client-job.yaml.tpl`
  - `tensorrt_daemon_client.py`
- `platform/k3s/workloads/vllm/`
  - `vllm-daemon-client-job.yaml.tpl`
  - `vllm_daemon_client.py`

## Start points

- PyTorch qwen-hello app: `platform/k3s/workloads/pytorch/qwen-hello/README.md`
- PyTorch daemon-client workload: `platform/k3s/workloads/pytorch/README.md`
- TensorRT daemon-client workload: `platform/k3s/workloads/tensorrt/README.md`
- vLLM daemon-client workload: `platform/k3s/workloads/vllm/README.md`
- Full harness entrypoint: `platform/k3s/e2e/README.md`
