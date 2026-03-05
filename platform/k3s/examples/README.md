# Examples

Examples are organized by deployment workflow so you can start from the path
that matches your environment.

## Layout

- `models/profiles/`
  - `oci2gdsd.yaml`: reference service configuration.
- `platform/k3s/examples/qwen-hello/`
  - FastAPI + PyTorch Qwen hello deployment assets and packaging walkthroughs.
- `platform/k3s/examples/daemonset/`
  - DaemonSet + daemon-client manifest templates and workload scripts
    (`pytorch`, `tensorrt`, `vllm`).

## Start points

- Beginner Kubernetes flow: `platform/k3s/examples/qwen-hello/README.md`
- DaemonSet manifest flow: `platform/k3s/examples/daemonset/README.md`
- Full k3s harness docs: `platform/k3s/e2e/README.md`
