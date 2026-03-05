# Examples

Examples are organized by deployment workflow so you can start from the path
that matches your environment.

## Layout

- `examples/config/`
  - `oci2gdsd.yaml`: reference service configuration.
- `examples/k3s/qwen-hello/`
  - FastAPI + PyTorch Qwen hello deployment assets and packaging walkthroughs.
- `examples/k3s/daemonset/`
  - DaemonSet + daemon-client manifest templates and workload scripts
    (`pytorch`, `tensorrt`, `vllm`).

## Start points

- Beginner Kubernetes flow: `examples/k3s/qwen-hello/README.md`
- DaemonSet manifest flow: `examples/k3s/daemonset/README.md`
- Full k3s harness docs: `testharness/k3s-e2e/README.md`
