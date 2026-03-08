# oci2gdsd Architecture Diagram

This document gives a visual map of how `oci2gdsd` moves model bytes from OCI
registries to node-local storage and then into GPU memory through strict
GPUDirect Storage (GDS)-oriented flows.

## 1) System Topology (DaemonSet Path)

```mermaid
flowchart LR
  subgraph Build["Packaging / Registry"]
    HF["Hugging Face model source"]
    PKG["OCI packager\n(OCI-ModelProfile-v1)"]
    REG["OCI Registry\n(digest-pinned refs)"]
    HF --> PKG --> REG
  end

  subgraph Node["GPU Node (k3s)"]
    INIT["Init container\nensure / status / verify"]
    CACHE[("NVMe model cache\nOCI2GDSD_ROOT_PATH")]
    D["oci2gdsd serve\n(daemonset, unix socket)"]
    GPU[("GPU VRAM")]

    INIT -->|publish READY + shards| CACHE
    D -->|read shard files| CACHE
    D -->|persistent gpu load / export / tensor-map| GPU
  end

  subgraph Workload["Runtime Pod"]
    RT["Runtime container\nPyTorch / TensorRT-LLM / vLLM"]
  end

  REG -->|ensure pull by digest| INIT
  RT -->|daemon API over unix socket| D
  RT -->|import IPC handles / tensor metadata| GPU
```

## 2) Control/Data Plane Split

- Control plane:
  - `ensure`, `status`, `verify`, `release`, `gc`
  - daemon lifecycle APIs (`/v1/gpu/attach`, `/v1/gpu/heartbeat`, `/v1/gpu/detach`)
- Data plane:
  - shard bytes on NVMe (`shards/` under published model path)
  - GDS read path (`O_DIRECT` + cuFile) into GPU allocations
  - runtime-side tensor binding/import from daemon-exported metadata

## 3) End-to-End Sequence (Strict GDS-Oriented)

```mermaid
sequenceDiagram
  autonumber
  participant OP as Operator
  participant PRE as prereq-check
  participant REG as OCI Registry
  participant INIT as Init Container
  participant CACHE as NVMe Cache
  participant DAEMON as oci2gdsd Daemon
  participant GPU as GPU
  participant RT as Runtime Container

  OP->>PRE: make prereq-k3s
  PRE->>PRE: gdscheck + strict gdsio gate
  OP->>INIT: start workload
  INIT->>REG: fetch manifest/config/layers by digest
  INIT->>CACHE: write + verify shards, write READY
  RT->>DAEMON: POST /v1/gpu/load (mode=persistent)
  DAEMON->>CACHE: open shard (O_DIRECT)
  DAEMON->>GPU: cuFileRead into device memory
  RT->>DAEMON: POST /v1/gpu/export + /v1/gpu/tensor-map
  DAEMON-->>RT: CUDA IPC handles + tensor index metadata
  RT->>GPU: import/map handles
  RT->>RT: run inference
  RT->>DAEMON: detach / unload lifecycle
```

## 4) Deployment Modes in Repo

- Local CLI mode (`make verify-local`):
  - no GPU, no Kubernetes; validates lifecycle guarantees only.
- Host strict probe mode (`./platform/host/scripts/quick-qwen.sh`):
  - host-only direct-GDS qualification/probe.
- k3s daemonset mode (`make verify-k3s-{qwen,tensor,vllm}`):
  - node daemon + runtime workloads (PyTorch, TensorRT-LLM, vLLM).

## 5) Runtime Tracks

- PyTorch:
  - daemon-client checks and qwen workload path.
- TensorRT-LLM:
  - daemon-client parity checks and runtime integration gate.
- vLLM:
  - daemon-client parity checks and loader/inference integration gate.

## 6) Related Docs

- [daemonset-manifest-guide.md](daemonset-manifest-guide.md)
- [direct-gds-runbook.md](direct-gds-runbook.md)
- [troubleshooting.md](troubleshooting.md)
- [../platform/k3s/README.md](../platform/k3s/README.md)
- [../platform/host/README.md](../platform/host/README.md)
